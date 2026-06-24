#!/usr/bin/env bash
# =============================================================================
# anddev tunnel_host_from_log 계약 테스트 — 경계값 4종 (정상/매핑/None/변조)
#
#   대상: anddev.sh 의 tunnel_host_from_log (cloudflared 로그 → 현재 터널 호스트).
#   왜:   접속 주소의 "신뢰 source" 다. 모델/사람이 부르는 값이 아니라 cloudflared
#         로그에서 파싱한다(계약적 사고). 'status' 서브커맨드와 start_tunnel 이 이걸
#         공유하므로, 다중 URL(재연결)/빈 로그/오염 라인을 정확히 다뤄야 한다.
#
#   실행:  bash tests/tunnel_test.sh      (종료코드 0 = 전체 통과)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

# 소싱 — 가드 덕분에 main 은 안 돌고 함수만 로드된다.
# shellcheck disable=SC1090
source "$ROOT/anddev.sh"
set +e   # anddev.sh 의 'set -euo pipefail' 가 하네스에 번지지 않게 -e 해제

PASS=0; FAIL=0
# expect <설명> <기대 출력> -- <로그 내용(printf %b)>
expect() {
  local desc="$1" want="$2"; shift 2
  [ "$1" = "--" ] && shift
  local log="$SANDBOX/cf.log"
  printf '%b' "$1" > "$log"
  local got; got="$(tunnel_host_from_log "$log")"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  ✗ %s\n    기대=<%s> 실제=<%s>\n' "$desc" "$want" "$got"; fi
}

echo "== 1) 정상 — 단일 URL 라인에서 호스트 추출 =="
expect "단일 URL"        "abcd-efgh.trycloudflare.com" -- \
  "2026-01-01 INF +-----+\n| https://abcd-efgh.trycloudflare.com |\n+-----+\n"
expect "URL 만 있는 줄"  "x1-y2.trycloudflare.com"     -- "https://x1-y2.trycloudflare.com\n"

echo "== 2) 매핑/다중 — 재연결로 URL 이 여러 개면 '마지막(현재)' 을 쓴다 =="
expect "다중 URL → 마지막" "second-host.trycloudflare.com" -- \
  "https://first-host.trycloudflare.com\n...reconnect...\nhttps://second-host.trycloudflare.com\n"

echo "== 3) None — 빈/주소없는 로그는 빈 문자열 (오류 아님) =="
expect "빈 로그"          "" -- ""
expect "주소 없는 로그"   "" -- "INF Starting tunnel\nINF Registered tunnel connection\n"
# 파일 자체가 없을 때 — rc=0, 빈 출력
miss="$(tunnel_host_from_log "$SANDBOX/does-not-exist.log")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$miss" ]; then PASS=$((PASS+1)); echo "  ✓ 로그 파일 부재 → rc=0 + 빈 출력"
else FAIL=$((FAIL+1)); echo "  ✗ 로그 파일 부재 처리 실패 (rc=$rc out=$miss)"; fi

echo "== 4) 변조 — 도메인/스킴 위조 라인은 무시 =="
# trycloudflare.com 이 아닌 호스트는 매칭되지 않아야 한다 (피싱/오염 라인 차단)
expect "다른 도메인 무시"  "" -- "https://evil.example.com\nhttp://attacker.test\n"
# 정상 호스트 뒤에 가짜 접미사를 붙여도 trycloudflare.com 경계까지만 가져온다
expect "접미사 위조 경계"  "good.trycloudflare.com" -- "https://good.trycloudflare.com.attacker.com\n"
# http(s) 스킴이 아니면(스킴 없는 평문) 매칭 안 됨
expect "스킴 없는 평문 무시" "" -- "host=plain.trycloudflare.com (no scheme)\n"
# 정상 + 오염이 섞여 있어도, 마지막 '유효한' trycloudflare URL 을 고른다
expect "혼재 → 마지막 유효" "real.trycloudflare.com" -- \
  "https://evil.example.com\nhttps://real.trycloudflare.com\nplain.trycloudflare.com\n"

echo
echo "------------------------------------------------------------"
printf '결과:  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "✗ 실패한 테스트가 있습니다."; exit 1; }
echo "✓ 전체 통과"
