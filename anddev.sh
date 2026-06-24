#!/usr/bin/env bash
# =============================================================================
# anddev — 원터치 안드로이드 리눅스 원격 개발서버 (단일 파일)
#
#   git clone / 여러 파일 없이 "이 한 파일" 로 설치 + 실행이 끝난다.
#   백엔드(proot↔chroot) / 설치(setup) / 실행(start) / 접속(connect) 로직을
#   모두 자기완결(self-contained) 로 담는다.  → 단일 source of truth.
#
# 사용 (폰 Termux 에서):
#   bash anddev.sh            # 원터치: 미설치면 설치 후 실행, 설치돼 있으면 바로 실행
#   bash anddev.sh setup      # 설치만
#   bash anddev.sh start      # 실행만 (서버 켜기)
#
# 사용 (내 PC 에서):
#   bash anddev.sh connect <호스트.trycloudflare.com> [사용자=dev]
#
# 강제 proot:  ANDDEV_FORCE_PROOT=1
# 종료:        Ctrl-C  (sshd + 터널 같이 정리됨)
# =============================================================================
set -euo pipefail

# --- 설정값 -----------------------------------------------------------------
DISTRO="${DISTRO:-ubuntu}"             # proot-distro 배포판
SSH_PORT="${SSH_PORT:-22}"             # proot 내부 sshd 포트
DEV_USER="${DEV_USER:-dev}"            # SSH 로그인 계정
STATE_DIR="${HOME}/.anddev"            # 자격증명/상태 저장 위치
CRED_FILE="${STATE_DIR}/credentials"
TUNNEL_LOG="${STATE_DIR}/cloudflared.log"
NOTIFY_CONF="${STATE_DIR}/notify.conf" # 있으면 이메일 발송 (선택)

# --- 색 출력 ----------------------------------------------------------------
c_ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

# =============================================================================
# 백엔드 추상화 (proot ↔ chroot)  — 원본: lib/backend.sh 를 인라인
#   - 루트(su) 가 있으면 chroot  : 더 빠르고 커널기능(Docker 등) 가능
#   - 없으면 proot               : 루팅 불필요 (기본)
#   두 백엔드 모두 같은 Ubuntu 루트파일시스템을 공유한다.
# =============================================================================
ROOTFS="${PREFIX:-}/var/lib/proot-distro/installed-rootfs/${DISTRO}"

# --- D1: 루트 사용 가능 여부 (계약적 사고 — su 가 실제로 uid 0 을 주는지 검증) -
anddev_is_rooted() {
  [ "${ANDDEV_FORCE_PROOT:-0}" = "1" ] && return 1
  command -v su >/dev/null 2>&1 || return 1
  # su -c 'id -u' 가 진짜 0 을 돌려줄 때만 신뢰
  [ "$(su -c 'id -u' 2>/dev/null | tr -dc '0-9' | head -c1)" = "0" ] 2>/dev/null
}

anddev_backend() { anddev_is_rooted && echo "chroot" || echo "proot"; }

# --- chroot 준비: 가상 파일시스템 바인드 마운트 (멱등) ----------------------
chroot_prepare() {
  su -c "
    set -e
    mkdir -p '$ROOTFS/proc' '$ROOTFS/sys' '$ROOTFS/dev' '$ROOTFS/dev/pts'
    mountpoint -q '$ROOTFS/proc'    || mount -t proc  proc  '$ROOTFS/proc'
    mountpoint -q '$ROOTFS/sys'     || mount -t sysfs sys   '$ROOTFS/sys'
    mountpoint -q '$ROOTFS/dev'     || mount -o bind  /dev  '$ROOTFS/dev'
    mountpoint -q '$ROOTFS/dev/pts' || mount -o bind  /dev/pts '$ROOTFS/dev/pts'
    cp /etc/resolv.conf '$ROOTFS/etc/resolv.conf' 2>/dev/null || true
  "
}

# --- chroot 정리: 마운트 해제 (종료 시) ------------------------------------
chroot_teardown() {
  su -c "
    umount '$ROOTFS/dev/pts' 2>/dev/null || true
    umount '$ROOTFS/dev'     2>/dev/null || true
    umount '$ROOTFS/sys'     2>/dev/null || true
    umount '$ROOTFS/proc'    2>/dev/null || true
  " 2>/dev/null || true
}

# --- distro 안에서 명령 실행 (포그라운드) ----------------------------------
#   인자: bash -lc 로 넘길 명령 문자열 1개
distro_exec() {
  local cmd="$1"
  if anddev_is_rooted; then
    chroot_prepare
    su -c "chroot '$ROOTFS' /usr/bin/env -i \
      HOME=/root TERM=\${TERM:-xterm} \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      /bin/bash -lc \"$cmd\""
  else
    proot-distro login "$DISTRO" -- /bin/bash -lc "$cmd"
  fi
}

# --- sshd 데몬 기동 (백그라운드, PID 를 전역 SSHD_PID 에) -------------------
distro_start_sshd() {
  if anddev_is_rooted; then
    chroot_prepare
    su -c "chroot '$ROOTFS' /usr/sbin/sshd -D" &
  else
    proot-distro login "$DISTRO" -- /usr/sbin/sshd -D &
  fi
  SSHD_PID=$!
}

# =============================================================================
# 공통 가드
# =============================================================================
# --- Termux 환경인지 확인 (계약적 사고 — 환경을 의심) -----------------------
require_termux() {
  if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *com.termux* ]]; then
    c_err "이 명령은 Termux 안에서 실행해야 합니다."
    c_err "F-Droid 에서 Termux 를 설치한 뒤 다시 실행하세요."
    exit 1
  fi
}

# --- 설치 완료 여부 (rootfs 채워짐 + 자격증명 존재) -------------------------
anddev_installed() {
  [ -n "${PREFIX:-}" ] || return 1
  [ -d "$ROOTFS" ] && [ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ] && [ -f "$CRED_FILE" ]
}

# =============================================================================
# setup — 설치 (원본: setup.sh)
# =============================================================================
# --- 1) Termux 패키지 설치 ---------------------------------------------------
install_termux_pkgs() {
  c_info "Termux 패키지 업데이트 / 설치..."
  yes | pkg update -y || true
  pkg install -y proot-distro openssh

  # cloudflared: 메인 저장소에 없으면 tur-repo 에서 (탈출구)
  if ! pkg install -y cloudflared; then
    c_warn "cloudflared 기본 저장소 실패 → tur-repo 시도"
    pkg install -y tur-repo
    pkg install -y cloudflared
  fi
  command -v cloudflared >/dev/null || { c_err "cloudflared 설치 실패"; exit 1; }
  c_ok "Termux 패키지 준비 완료"
}

# --- 2) Ubuntu 루트파일시스템 부트스트랩 (멱등) ------------------------------
install_distro() {
  if [ -d "$ROOTFS" ] && [ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ]; then
    c_ok "Ubuntu 루트파일시스템 이미 존재 — 건너뜀"
  else
    c_info "Ubuntu 루트파일시스템 다운로드/설치 (최초 1회, 수백 MB)..."
    proot-distro install "$DISTRO"
    c_ok "Ubuntu 설치 완료"
  fi
}

# --- 3) 자격증명 생성 (D2: 모델/사람이 아니라 엔진이 만든 랜덤값) -----------
gen_credentials() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [ -f "$CRED_FILE" ]; then
    c_ok "기존 자격증명 재사용 ($CRED_FILE)"
    return
  fi
  local pw
  pw="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
  {
    echo "DEV_USER=${DEV_USER}"
    echo "DEV_PASS=${pw}"
    echo "SSH_PORT=${SSH_PORT}"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  c_ok "SSH 자격증명 생성 ($CRED_FILE)"
}

# --- 4) Ubuntu 내부 프로비저닝 (sshd + dev도구 + Node + Codex) ---------------
provision_distro() {
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  local provision="${ROOTFS}/root/anddev-provision.sh"

  c_info "Ubuntu 내부 프로비저닝 스크립트 작성..."
  cat > "$provision" <<PROVISION
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[provision] apt 업데이트 + 기본 도구"
apt-get update -y
apt-get install -y --no-install-recommends \\
  openssh-server sudo curl ca-certificates git nano \\
  build-essential python3 python3-pip locales

echo "[provision] 로케일"
locale-gen en_US.UTF-8 || true

echo "[provision] Node.js 22 (NodeSource) — Codex CLI 용"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

echo "[provision] Codex CLI 전역 설치"
npm install -g @openai/codex || echo "[provision] codex 설치 실패 — 나중에 'npm i -g @openai/codex' 재시도"

echo "[provision] Claude Code 전역 설치"
npm install -g @anthropic-ai/claude-code || echo "[provision] claude 설치 실패 — 나중에 'npm i -g @anthropic-ai/claude-code' 재시도"

echo "[provision] dev 사용자 + 비밀번호"
id -u ${DEV_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${DEV_USER}
echo "${DEV_USER}:${DEV_PASS}" | chpasswd
usermod -aG sudo ${DEV_USER}
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/anddev

echo "[provision] sshd 설정"
mkdir -p /run/sshd
ssh-keygen -A
sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\\?Port .*/Port ${SSH_PORT}/'                              /etc/ssh/sshd_config
grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port ${SSH_PORT}' >> /etc/ssh/sshd_config

echo "[provision] 완료"
PROVISION

  c_info "Ubuntu 내부에서 프로비저닝 실행 [백엔드: $(anddev_backend)] (몇 분 소요)..."
  distro_exec "bash /root/anddev-provision.sh"
  c_ok "Ubuntu 프로비저닝 완료 (sshd / Node / Codex / Claude Code 준비됨)"
}

setup_main() {
  echo "=============================================="
  echo "  anddev — 안드로이드 원격 개발서버 설치"
  echo "=============================================="
  require_termux
  c_ok "Termux 환경 확인됨"
  install_termux_pkgs
  install_distro
  gen_credentials
  provision_distro

  echo
  c_ok "설치 완료!"
  echo
  c_info "이제 서버를 켜려면:   bash anddev.sh start"
  echo
}

# =============================================================================
# start — 서버 켜기 (원본: start.sh)
# =============================================================================
SSHD_PID=""
CF_PID=""
TUNNEL_HOST=""

start_cleanup() {
  c_info "정리 중..."
  [ -n "$CF_PID" ]   && kill "$CF_PID"   2>/dev/null || true
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null || true
  pkill -f "sshd -D" 2>/dev/null || true
  # chroot 백엔드면 바인드 마운트 해제
  anddev_is_rooted && chroot_teardown
  c_ok "종료됨"
}

# --- 1) proot 내부 sshd 기동 (foreground -D 를 백그라운드로) -----------------
start_sshd() {
  c_info "Ubuntu sshd 기동 (포트 ${SSH_PORT}) [백엔드: $(anddev_backend)]..."
  # ssh-keygen -A 는 provision 에서 끝남. sshd -D 를 백그라운드로. (백엔드가 proot/chroot 선택)
  distro_start_sshd
  sleep 2
  kill -0 "$SSHD_PID" 2>/dev/null || { c_err "sshd 기동 실패"; exit 1; }
  c_ok "sshd 실행 중 (localhost:${SSH_PORT})"
}

# --- 2) cloudflared Quick Tunnel -------------------------------------------
start_tunnel() {
  c_info "Cloudflare Quick Tunnel 연결 (ssh://localhost:${SSH_PORT})..."
  : > "$TUNNEL_LOG"
  cloudflared tunnel --no-autoupdate --url "ssh://localhost:${SSH_PORT}" \
    > "$TUNNEL_LOG" 2>&1 &
  CF_PID=$!

  # D3: 모델/사람이 아니라 cloudflared 로그에서 실제 URL 을 파싱 (신뢰는 검증 후)
  local host="" tries=0
  c_info "터널 주소 대기 중..."
  while [ -z "$host" ] && [ $tries -lt 30 ]; do
    sleep 1; tries=$((tries+1))
    host="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" \
            | head -n1 | sed 's#https://##')"
    kill -0 "$CF_PID" 2>/dev/null || { c_err "cloudflared 종료됨 — 로그: $TUNNEL_LOG"; exit 1; }
  done
  [ -n "$host" ] || { c_err "터널 주소를 못 받았습니다 — 로그: $TUNNEL_LOG"; exit 1; }
  TUNNEL_HOST="$host"
  c_ok "터널 연결됨: ${TUNNEL_HOST}"
}

print_connect() {
  cat <<INFO

================ 접속 정보 ================

  호스트   : ${TUNNEL_HOST}
  사용자   : ${DEV_USER}
  비밀번호 : ${DEV_PASS}

  내 노트북/PC 에서 (cloudflared 설치 필요):

    ssh -L 1455:localhost:1455 \\
        -o ProxyCommand="cloudflared access ssh --hostname ${TUNNEL_HOST}" \\
        ${DEV_USER}@${TUNNEL_HOST}

    (또는 repo 의  bash anddev.sh connect ${TUNNEL_HOST}  한 줄)

  접속 후 브라우저 인증:
    claude   →  URL 떠서 PC 브라우저로 승인 후 코드 붙여넣기
    codex    →  '-L 1455' 포트포워딩으로 PC 브라우저 흐름 그대로 완성

==========================================

  (이 창을 닫으면 서버가 꺼집니다. Ctrl-C 로 종료)

INFO
}

# --- 3) 터널 주소 이메일 발송 (선택, notify.conf 있을 때만) -----------------
#   notify.conf 예시:
#     NOTIFY_TO=johunsang@gmail.com
#     SMTP_USER=youraddress@gmail.com
#     SMTP_PASS=gmail-앱-비밀번호-16자
#     SMTP_URL=smtps://smtp.gmail.com:465
send_email() {
  [ -f "$NOTIFY_CONF" ] || { c_warn "이메일 미설정 (notify.conf 없음) — 발송 건너뜀"; return 0; }
  # shellcheck disable=SC1090
  source "$NOTIFY_CONF"
  : "${NOTIFY_TO:?}" "${SMTP_USER:?}" "${SMTP_PASS:?}"
  local smtp="${SMTP_URL:-smtps://smtp.gmail.com:465}"

  c_info "터널 주소 이메일 발송 → ${NOTIFY_TO}"
  local body
  body="$(cat <<MAIL
From: anddev <${SMTP_USER}>
To: ${NOTIFY_TO}
Subject: [anddev] 원격 개발서버 접속 주소

호스트   : ${TUNNEL_HOST}
사용자   : ${DEV_USER}
비밀번호 : ${DEV_PASS}

접속 명령 (PC, cloudflared 필요):
ssh -L 1455:localhost:1455 -o ProxyCommand="cloudflared access ssh --hostname ${TUNNEL_HOST}" ${DEV_USER}@${TUNNEL_HOST}

접속 후:  claude  /  codex
MAIL
)"

  if curl --silent --show-error --ssl-reqd --url "$smtp" \
       --mail-from "$SMTP_USER" --mail-rcpt "$NOTIFY_TO" \
       --user "${SMTP_USER}:${SMTP_PASS}" \
       --upload-file <(printf '%s\n' "$body"); then
    c_ok "이메일 발송 완료"
  else
    c_warn "이메일 발송 실패 — 설정/앱비밀번호 확인 (접속정보는 위 화면 참고)"
  fi
}

start_main() {
  [ -f "$CRED_FILE" ] || { c_err "자격증명이 없습니다. 먼저 'bash anddev.sh setup' 을 실행하세요."; exit 1; }
  # shellcheck disable=SC1090
  source "$CRED_FILE"

  trap start_cleanup EXIT INT TERM
  start_sshd
  start_tunnel
  print_connect
  send_email
  # 포그라운드 유지 — cloudflared 가 살아있는 동안 대기
  wait "$CF_PID"
}

# =============================================================================
# connect — PC 에서 폰 개발서버로 접속 (원본: connect.sh)
#   브라우저 인증(codex 의 localhost:1455 콜백)을 위해 포트포워딩을 포함한다.
# =============================================================================
connect_main() {
  local host="${1:-}"
  local user_name="${2:-dev}"

  if [ -z "$host" ]; then
    echo "사용법: bash anddev.sh connect <호스트.trycloudflare.com> [사용자=dev]" >&2
    exit 1
  fi
  command -v cloudflared >/dev/null || { echo "✗ cloudflared 가 필요합니다 (PC 에 설치)"; exit 1; }

  echo "▶ 접속: ${user_name}@${host}  (codex 인증용 1455 포트포워딩 포함)"
  exec ssh \
    -L 1455:localhost:1455 \
    -o ProxyCommand="cloudflared access ssh --hostname ${host}" \
    "${user_name}@${host}"
}

# =============================================================================
# 서브커맨드 디스패치
# =============================================================================
usage() {
  cat <<USAGE
anddev — 원터치 안드로이드 리눅스 원격 개발서버 (단일 파일)

사용 (폰 Termux):
  bash anddev.sh            원터치: 미설치면 설치 후 실행, 설치돼 있으면 바로 실행
  bash anddev.sh setup      설치만
  bash anddev.sh start      서버 켜기

사용 (내 PC):
  bash anddev.sh connect <호스트.trycloudflare.com> [사용자=dev]

환경변수:  ANDDEV_FORCE_PROOT=1  (루트 있어도 proot 강제)
USAGE
}

main() {
  local cmd="${1:-auto}"
  case "$cmd" in
    setup)         setup_main ;;
    start)         start_main ;;
    connect)       shift; connect_main "$@" ;;
    auto)
      # 원터치: 설치돼 있으면 바로 실행, 아니면 설치 후 실행
      if anddev_installed; then
        c_info "이미 설치됨 — 서버를 켭니다 (재설치: bash anddev.sh setup)"
        start_main
      else
        c_info "최초 실행 — 설치 후 서버를 켭니다"
        setup_main
        start_main
      fi
      ;;
    -h|--help|help) usage ;;
    *)             c_err "알 수 없는 명령: $cmd"; echo; usage; exit 1 ;;
  esac
}

main "$@"
