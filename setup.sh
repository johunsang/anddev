#!/usr/bin/env bash
# =============================================================================
# anddev — 원터치 안드로이드 리눅스 원격 개발서버 (1단계: Termux 스크립트)
#
#   Termux 위에서 한 번만 실행하는 "설치(install)" 스크립트.
#   - proot 로 Ubuntu 루트파일시스템 부트스트랩 (루팅 불필요)
#   - Ubuntu 안에 sshd + git + Node.js + Codex CLI + Claude Code 설치
#   - cloudflared (Quick Tunnel) 설치
#
#   설치가 끝나면 start.sh 로 매번 서버를 띄운다.
#
# 사용:  bash setup.sh
# =============================================================================
set -euo pipefail

# --- 설정값 -----------------------------------------------------------------
DISTRO="ubuntu"                       # proot-distro 배포판
SSH_PORT=22                           # proot 내부 sshd 포트
DEV_USER="dev"                        # SSH 로그인 계정
STATE_DIR="${HOME}/.anddev"           # 자격증명/상태 저장 위치
CRED_FILE="${STATE_DIR}/credentials"

# 백엔드 추상화(proot↔chroot) 로드
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/backend.sh
source "${SCRIPT_DIR}/lib/backend.sh"

# --- 색 출력 ----------------------------------------------------------------
c_ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

# --- D1: Termux 환경인지 확인 (계약적 사고 — 환경을 의심) -------------------
require_termux() {
  if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *com.termux* ]]; then
    c_err "이 스크립트는 Termux 안에서 실행해야 합니다."
    c_err "F-Droid 에서 Termux 를 설치한 뒤 다시 실행하세요."
    exit 1
  fi
  c_ok "Termux 환경 확인됨"
}

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
  local rootfs="${PREFIX}/var/lib/proot-distro/installed-rootfs/${DISTRO}"
  if [ -d "$rootfs" ] && [ -n "$(ls -A "$rootfs" 2>/dev/null)" ]; then
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
  local rootfs="${PREFIX}/var/lib/proot-distro/installed-rootfs/${DISTRO}"
  local provision="${rootfs}/root/anddev-provision.sh"

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

# --- 메인 -------------------------------------------------------------------
main() {
  echo "=============================================="
  echo "  anddev — 안드로이드 원격 개발서버 설치"
  echo "=============================================="
  require_termux
  install_termux_pkgs
  install_distro
  gen_credentials
  provision_distro

  echo
  c_ok "설치 완료!"
  echo
  c_info "이제 서버를 켜려면:   bash start.sh"
  echo
}

main "$@"
