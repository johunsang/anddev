#!/usr/bin/env bash
# =============================================================================
# anddev — PC(노트북)에서 폰 개발서버로 접속하는 헬퍼
#
#   브라우저 인증(codex 의 localhost:1455 콜백)을 위해 포트포워딩을 포함한다.
#
# 사용:  bash connect.sh <트라이클라우드플레어-호스트>
# 예:    bash connect.sh abcd-efgh.trycloudflare.com
#
# 사전 준비: 이 PC 에 cloudflared 설치
#   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
# =============================================================================
set -euo pipefail

HOST="${1:-}"
USER_NAME="${2:-dev}"

if [ -z "$HOST" ]; then
  echo "사용법: bash connect.sh <호스트.trycloudflare.com> [사용자=dev]" >&2
  exit 1
fi
command -v cloudflared >/dev/null || { echo "✗ cloudflared 가 필요합니다 (PC 에 설치)"; exit 1; }

echo "▶ 접속: ${USER_NAME}@${HOST}  (codex 인증용 1455 포트포워딩 포함)"
exec ssh \
  -L 1455:localhost:1455 \
  -o ProxyCommand="cloudflared access ssh --hostname ${HOST}" \
  "${USER_NAME}@${HOST}"
