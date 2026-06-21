#!/usr/bin/env bash
# =============================================================================
# anddev — 서버 켜기 (매번 실행)
#
#   1) proot Ubuntu 안의 sshd 기동
#   2) cloudflared Quick Tunnel 로 SSH 포트 외부 노출 (trycloudflare.com)
#   3) 접속 주소/명령을 화면에 출력
#
#   Quick Tunnel 특성상 실행할 때마다 URL 이 바뀐다 → 매번 새 주소를 띄워준다.
#
# 사용:  bash start.sh
# 종료:  Ctrl-C  (sshd + 터널 같이 정리됨)
# =============================================================================
set -euo pipefail

DISTRO="ubuntu"
STATE_DIR="${HOME}/.anddev"
CRED_FILE="${STATE_DIR}/credentials"
TUNNEL_LOG="${STATE_DIR}/cloudflared.log"
NOTIFY_CONF="${STATE_DIR}/notify.conf"   # 있으면 이메일 발송 (선택)

# 백엔드 추상화(proot↔chroot) 로드
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/backend.sh
source "${SCRIPT_DIR}/lib/backend.sh"

c_ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

[ -f "$CRED_FILE" ] || { c_err "자격증명이 없습니다. 먼저 'bash setup.sh' 를 실행하세요."; exit 1; }
# shellcheck disable=SC1090
source "$CRED_FILE"

SSHD_PID=""
CF_PID=""

cleanup() {
  c_info "정리 중..."
  [ -n "$CF_PID" ]   && kill "$CF_PID"   2>/dev/null || true
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null || true
  pkill -f "sshd -D" 2>/dev/null || true
  # chroot 백엔드면 바인드 마운트 해제
  anddev_is_rooted && chroot_teardown
  c_ok "종료됨"
}
trap cleanup EXIT INT TERM

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

    (또는 repo 의  bash connect.sh ${TUNNEL_HOST}  한 줄)

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

main() {
  start_sshd
  start_tunnel
  print_connect
  send_email
  # 포그라운드 유지 — cloudflared 가 살아있는 동안 대기
  wait "$CF_PID"
}

main "$@"
