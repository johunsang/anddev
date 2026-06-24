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
  bridge_setup

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
  [ -n "$CF_PID" ]     && kill "$CF_PID"     2>/dev/null || true
  [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
  [ -n "$SSHD_PID" ]   && kill "$SSHD_PID"   2>/dev/null || true
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

  폰 기능 (접속 후 'phone-help' 로 전체 목록):
    photo · sms · openurl · app · battery · location · clip
    notify · vibrate · say · sensors · contacts · calllog
    (Termux:API 앱 + 권한 필요)

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
  bridge_start
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
# 안드로이드 기능 브리지 (D6) — proot 안에서 폰 기능 호출 (전체 세트)
#   proot 게스트는 termux-* 바이너리에 직접 접근 못 한다(다른 libc/네임스페이스).
#   → 게스트가 스풀에 "요청 파일"을 쓰면, Termux 쪽 데몬이 읽어 해당 termux-api
#     명령을 실행하고 결과 파일을 돌려주는 파일 릴레이 방식.
#   스풀은 rootfs 안(= Termux 에서도 보이는 경로)에 둔다: 게스트 /opt/anddev-bridge
#   계약적 사고: 데몬은 임의 문자열을 eval 하지 않는다 — 허용된 동사만(화이트리스트),
#   인자는 정규화(파일명/번호/URL 스킴/패키지명) 후 개별 termux-* / am 에 전달.
#   제공 명령: photo sms smslist openurl app battery location clip notify
#             vibrate say sensors contacts calllog  (게스트에서 'phone-help')
# =============================================================================
BRIDGE_REL="/opt/anddev-bridge"                 # 게스트(우분투)에서 본 경로
bridge_base() { echo "${ROOTFS}${BRIDGE_REL}"; }  # Termux 에서 본 실제 경로
BRIDGE_PID=""

# --- 프로토콜 ---------------------------------------------------------------
#   요청 파일(.req):  1줄=동사, 2줄~=인자(한 줄에 하나, 게스트가 받은 그대로).
#   응답 파일(.res):  1줄=RC=<종료코드>, 2줄~=출력. (게스트는 RC 로 exit)
#   임시파일(.tmp)→rename(.req) 로 데몬이 반쪽짜리 파일을 읽지 않게(원자적) 한다.

# --- 게스트(우분투)에 폰 명령 래퍼 설치 (멱등; Termux 에서 rootfs 에 직접 씀) -
#   동사만 다르고 본문이 같은 래퍼들은 한 본문(__VERB__ 치환)으로 찍어낸다.
bridge_install_guest_cmds() {
  local bin="${ROOTFS}/usr/local/bin" base; base="$(bridge_base)"
  mkdir -p "$bin" "$base/req" "$base/res" "$base/out"

  local body
  body="$(cat <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
B=/opt/anddev-bridge; id="req-$$-${RANDOM}"
{ printf '%s\n' '__VERB__'; for a in "$@"; do printf '%s\n' "$a"; done; } > "$B/req/$id.tmp"
mv "$B/req/$id.tmp" "$B/req/$id.req"
for _ in $(seq 1 120); do
  if [ -f "$B/res/$id.res" ]; then
    rc="$(sed -n '1s/^RC=//p' "$B/res/$id.res")"
    sed '1d' "$B/res/$id.res"; rm -f "$B/res/$id.res"; exit "${rc:-0}"
  fi
  sleep 0.5
done
echo "✗ 응답 없음 — 브리지 데몬이 켜져 있는지 확인 (bash anddev.sh start)" >&2; exit 1
GUEST
)"

  # 게스트명령:동사  (동사는 데몬 화이트리스트와 일치해야 함)
  local pair name verb
  for pair in \
      photo:photo  sms:sms-send  smslist:sms-list  openurl:openurl  app:app \
      battery:battery  location:location  notify:notify  vibrate:vibrate \
      say:tts  sensors:sensors  contacts:contacts  calllog:calllog ; do
    name="${pair%%:*}"; verb="${pair##*:}"
    printf '%s\n' "${body//__VERB__/$verb}" > "${bin}/${name}"
    chmod +x "${bin}/${name}"
  done

  # clip 은 클라이언트에서 분기(인자 없으면 읽기, 있으면 설정)
  cat > "${bin}/clip" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
B=/opt/anddev-bridge; id="req-$$-${RANDOM}"
if [ "$#" -eq 0 ]; then verb=clip-get; else verb=clip-set; fi
{ printf '%s\n' "$verb"; for a in "$@"; do printf '%s\n' "$a"; done; } > "$B/req/$id.tmp"
mv "$B/req/$id.tmp" "$B/req/$id.req"
for _ in $(seq 1 120); do
  if [ -f "$B/res/$id.res" ]; then
    rc="$(sed -n '1s/^RC=//p' "$B/res/$id.res")"
    sed '1d' "$B/res/$id.res"; rm -f "$B/res/$id.res"; exit "${rc:-0}"
  fi
  sleep 0.5
done
echo "✗ 응답 없음 — 브리지 데몬 확인" >&2; exit 1
GUEST
  chmod +x "${bin}/clip"

  # 명령 목록 도우미
  cat > "${bin}/phone-help" <<'GUEST'
#!/usr/bin/env bash
cat <<'H'
anddev 폰 기능 (Termux:API 브리지) — SSH 접속 후 바로 사용:

  photo [파일명] [카메라ID]    폰 카메라 촬영 → /opt/anddev-bridge/out/
  sms <번호> <메시지...>       문자 발송 (SIM)
  smslist                     받은 문자 목록(JSON)
  openurl <https://...>       폰 기본 브라우저로 URL 열기
  app <패키지명>              앱 실행 (예: app com.android.chrome)
  battery                     배터리 상태(JSON)
  location                    GPS 위치(JSON)
  clip [텍스트...]            인자 없으면 읽기 / 있으면 클립보드 설정
  notify <제목> <내용...>      상단 알림 표시
  vibrate [ms=300]            진동
  say <텍스트...>             TTS 로 읽기
  sensors                     센서 목록
  contacts                    연락처 목록(JSON)
  calllog                     통화 기록(JSON)

주의: 기능별로 폰에서 권한 팝업이 한 번 뜰 수 있음(카메라/SMS/위치/연락처).
      Termux:API 앱(F-Droid)이 설치돼 있어야 동작합니다.
H
GUEST
  chmod +x "${bin}/phone-help"
}

# --- Termux 쪽 동작 분기 (화이트리스트) — 데몬이 요청마다 호출 ---------------
#   계약적 사고: 임의 문자열 eval 금지. 허용된 동사만, 인자는 정규화 후 개별
#   termux-* / am 에 전달. 출력은 stdout, 결과코드는 return.
_bridge_need() { command -v "$1" >/dev/null 2>&1 || { echo "termux-api 미설치 (pkg install termux-api + Termux:API 앱)"; return 3; }; }
bridge_dispatch() {
  local base; base="$(bridge_base)"
  local verb="${1:-}"; shift || true
  case "$verb" in
    photo)
      local name cam
      name="$(printf '%s' "${1:-photo.jpg}" | tr -dc 'A-Za-z0-9._-')"; name="${name:-photo.jpg}"
      cam="$(printf '%s' "${2:-0}" | tr -dc '0-9')"; cam="${cam:-0}"
      _bridge_need termux-camera-photo || return 3
      termux-camera-photo -c "$cam" "$base/out/$name" >/dev/null 2>&1 || { echo "촬영 실패 (카메라 권한 확인)"; return 1; }
      echo "촬영됨 → ${BRIDGE_REL}/out/${name}" ;;
    sms-send)
      local num; num="$(printf '%s' "${1:-}" | tr -dc '0-9+')"; shift || true
      [ -n "$num" ] || { echo "번호 이상값"; return 2; }
      _bridge_need termux-sms-send || return 3
      termux-sms-send -n "$num" "$*" >/dev/null 2>&1 || { echo "발송 실패 (SMS 권한 확인)"; return 1; }
      echo "발송됨 → ${num}" ;;
    sms-list)  _bridge_need termux-sms-list || return 3; termux-sms-list 2>&1 ;;
    openurl)
      local url="${1:-}"
      case "$url" in https://*|http://*) ;; *) echo "거부: http(s) URL 만 허용"; return 2 ;; esac
      _bridge_need termux-open-url || return 3
      termux-open-url "$url" >/dev/null 2>&1 && echo "열림 → ${url}" || { echo "열기 실패"; return 1; } ;;
    app)
      local pkg; pkg="$(printf '%s' "${1:-}" | tr -dc 'A-Za-z0-9._')"
      [ -n "$pkg" ] || { echo "패키지명 필요 (예: app com.android.chrome)"; return 2; }
      local act; act="$(cmd package resolve-activity --brief "$pkg" 2>/dev/null | tail -n1)"
      if [ -n "$act" ] && [ "$act" != "$pkg" ] && command -v am >/dev/null 2>&1; then
        am start -n "$act" >/dev/null 2>&1 && echo "실행 → ${pkg}" || { echo "실행 실패"; return 1; }
      elif command -v monkey >/dev/null 2>&1; then
        monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 && echo "실행 → ${pkg}" || { echo "실행 실패 (패키지명 확인)"; return 1; }
      else echo "am/monkey 사용 불가 — 앱 실행 미지원 단말"; return 3; fi ;;
    battery)   _bridge_need termux-battery-status || return 3; termux-battery-status 2>&1 ;;
    location)  _bridge_need termux-location || return 3; termux-location 2>&1 ;;
    contacts)  _bridge_need termux-contact-list || return 3; termux-contact-list 2>&1 ;;
    calllog)   _bridge_need termux-call-log || return 3; termux-call-log 2>&1 ;;
    sensors)   _bridge_need termux-sensor || return 3; termux-sensor -l 2>&1 ;;
    clip-get)  _bridge_need termux-clipboard-get || return 3; termux-clipboard-get 2>&1 ;;
    clip-set)  _bridge_need termux-clipboard-set || return 3; printf '%s' "$*" | termux-clipboard-set && echo "클립보드 설정됨" ;;
    notify)
      local title="${1:-anddev}"; shift || true
      _bridge_need termux-notification || return 3
      termux-notification --title "$title" --content "$*" >/dev/null 2>&1 && echo "알림 표시됨" || { echo "알림 실패"; return 1; } ;;
    vibrate)
      local ms; ms="$(printf '%s' "${1:-300}" | tr -dc '0-9')"; ms="${ms:-300}"
      _bridge_need termux-vibrate || return 3
      termux-vibrate -d "$ms" >/dev/null 2>&1 && echo "진동 ${ms}ms" ;;
    tts)       _bridge_need termux-tts-speak || return 3; termux-tts-speak "$*" >/dev/null 2>&1 && echo "읽음" ;;
    *) echo "알 수 없는 명령: ${verb}"; return 2 ;;
  esac
}

# --- Termux 쪽 데몬: 요청 파일을 읽어 bridge_dispatch 실행 -------------------
#   주: 한 요청이 실패해도 데몬 전체가 죽지 않도록 출력/코드를 || rc=$? 로 캡처.
bridge_daemon() {
  local base; base="$(bridge_base)"
  mkdir -p "$base/req" "$base/res" "$base/out"
  while true; do
    local f
    for f in "$base/req"/*.req; do
      [ -e "$f" ] || continue
      local id rc=0 out="" lines=() verb args=()
      id="$(basename "$f" .req)"
      mapfile -t lines < "$f"
      verb="${lines[0]:-}"
      args=("${lines[@]:1}")
      out="$(bridge_dispatch "$verb" "${args[@]}")" || rc=$?
      printf 'RC=%s\n%s\n' "$rc" "$out" > "$base/res/$id.tmp"
      mv "$base/res/$id.tmp" "$base/res/$id.res"
      rm -f "$f"
    done
    sleep 0.5
  done
}

# --- 설치 단계 훅: termux-api 패키지 + 게스트 래퍼 --------------------------
bridge_setup() {
  c_info "안드로이드 기능 브리지 설치 (전체 세트)..."
  pkg install -y termux-api || c_warn "termux-api 패키지 설치 실패 — 나중에 'pkg install termux-api'"
  bridge_install_guest_cmds
  c_ok "브리지 명령 설치됨 (게스트에서 'phone-help' 로 목록 확인)"
  c_warn "Termux:API '앱'도 F-Droid 에서 설치해야 동작합니다 (패키지만으론 부족)"
}

# --- 실행 단계 훅: 데몬 기동 (래퍼도 멱등 재설치해 기존 사용자도 바로 사용) --
bridge_start() {
  bridge_install_guest_cmds
  c_info "안드로이드 기능 브리지 데몬 기동..."
  bridge_daemon &
  BRIDGE_PID=$!
  c_ok "브리지 실행 중 (SSH 접속 후 'phone-help')"
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

# 소싱(테스트)일 땐 함수 정의만 로드하고, 직접 실행/파이프(curl|bash)일 때만 main 실행.
#   (return 은 소싱된 컨텍스트에서만 성공 → 'bash anddev.sh' / 'curl|bash' 동작은 그대로,
#    테스트는 'source anddev.sh' 로 bridge_dispatch 등 계약 로직만 떼어 검증한다.)
if ! (return 0 2>/dev/null); then
  main "$@"
fi
