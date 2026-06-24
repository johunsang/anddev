#!/usr/bin/env bash
# =============================================================================
# anddev 브리지 계약(contract) 테스트 — 경계값 4종 (정상 / 매핑 / None / 변조)
#
#   대상: anddev.sh 의 bridge_dispatch (Termux 쪽 화이트리스트 디스패처).
#   왜:   이 함수가 "신뢰 경계"다 — proot 게스트가 보낸 임의 인자를 받아
#         실제 폰 명령(termux-*/am)에 넘기기 직전에 정규화/검증한다.
#         경로 탈출·스킴 위조·잘못된 동사를 여기서 막지 못하면 폰이 노출된다.
#
#   실폰/Termux 없이 검증하려면 termux-* 바이너리를 PATH 스텁으로 가짜 주입한다.
#   스텁은 "받은 인자"를 그대로 기록 → 정규화 결과를 눈으로 단언(assert)할 수 있다.
#
#   실행:  bash tests/bridge_test.sh      (종료코드 0 = 전체 통과)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# --- 격리 샌드박스: 스텁 PATH + 가짜 ROOTFS --------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
STUB_BIN="$SANDBOX/bin"; mkdir -p "$STUB_BIN"
CALL_LOG="$SANDBOX/calls.log"            # 스텁이 받은 인자 기록
: > "$CALL_LOG"

# 화이트리스트가 호출하는 모든 외부 명령을 "인자 기록" 스텁으로 깐다.
#   STUB_FAIL 에 명령 이름이 들어 있으면 그 명령은 실패(비정상 종료)를 흉내낸다.
for cmd in termux-camera-photo termux-sms-send termux-sms-list termux-open-url \
           termux-battery-status termux-location termux-contact-list \
           termux-call-log termux-sensor termux-clipboard-get termux-clipboard-set \
           termux-notification termux-vibrate termux-tts-speak am monkey cmd; do
  cat > "$STUB_BIN/$cmd" <<STUB
#!/usr/bin/env bash
echo "$cmd \$*" >> "$CALL_LOG"
case " \${STUB_FAIL:-} " in *" $cmd "*) exit 1 ;; esac
echo "$cmd:OK"   # stdout 마커 — 조회 계열(battery 등)의 결과 relay 검증용
exit 0
STUB
  chmod +x "$STUB_BIN/$cmd"
done
PATH="$STUB_BIN:$PATH"

# anddev.sh 를 소싱 — 가드 덕분에 main 은 안 돌고 함수만 로드된다.
# shellcheck disable=SC1090
source "$ROOT/anddev.sh"
set +e   # anddev.sh 의 'set -euo pipefail' 가 우리 하네스에 번지지 않게 -e 해제
# 가짜 rootfs 로 바꿔 실제 시스템 경로를 건드리지 않게 한다.
ROOTFS="$SANDBOX/rootfs"; mkdir -p "$(bridge_base)/out"

# --- 미니 테스트 하네스 -----------------------------------------------------
PASS=0; FAIL=0
# run <설명> <기대RC> <stdout 기대 정규식|-> -- <verb> [args...]
run() {
  local desc="$1" want_rc="$2" want_re="$3"; shift 3
  [ "$1" = "--" ] && shift
  : > "$CALL_LOG"
  local out rc=0
  out="$(bridge_dispatch "$@" 2>&1)" || rc=$?
  local ok=1 why=""
  if [ "$rc" != "$want_rc" ]; then ok=0; why="rc=$rc(기대 $want_rc)"; fi
  if [ "$want_re" != "-" ] && ! printf '%s' "$out" | grep -Eq "$want_re"; then
    ok=0; why="$why out!~/$want_re/"
  fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  ✗ %s  [%s]\n    out=<%s>\n' "$desc" "$why" "$out"; fi
}
# 마지막 스텁 호출이 받은 인자가 정규식과 맞는지 (정규화 결과 확인)
log_matches() {
  local re="$1" desc="$2"
  if grep -Eq "$re" "$CALL_LOG"; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  ✗ %s  [calls.log!~/%s/]\n    log=<%s>\n' "$desc" "$re" "$(cat "$CALL_LOG")"; fi
}

echo "== 1) 정상 (normal) — 올바른 입력은 통과하고 폰 명령에 그대로 전달 =="
run "battery → JSON 조회"        0 'termux-battery-status:OK' -- battery
log_matches '^termux-battery-status' "battery 가 termux-battery-status 호출"
run "photo 정상 파일명"          0 '촬영됨.*shot1\.jpg'      -- photo shot1.jpg 0
log_matches 'termux-camera-photo -c 0 .*/out/shot1\.jpg' "photo 가 cam0 + out 경로로 호출"
run "sms 정상 번호+본문"         0 '발송됨.*\+8210'          -- sms-send +82-10-1234 "hello world"
log_matches 'termux-sms-send -n \+82101234 hello world' "sms 번호 정규화(+숫자만) & 본문 전달"
run "openurl https 허용"         0 '열림.*example'           -- openurl https://example.com
run "vibrate 정상 ms"            0 '진동 500ms'              -- vibrate 500
log_matches 'termux-vibrate -d 500' "vibrate 가 500ms 로 호출"

echo "== 2) 매핑 (mapping) — 동사→실제 명령, 정상 변환이 맞는지 =="
run "smslist → sms-list 매핑"    0 'termux-sms-list:OK'      -- sms-list
log_matches '^termux-sms-list'    "smslist 가 termux-sms-list 로 매핑"
run "say → tts-speak 매핑"       0 '읽음'                    -- tts "안녕"
log_matches '^termux-tts-speak 안녕' "say 가 termux-tts-speak 로 매핑"
run "clip-get → clipboard-get"   0 'termux-clipboard-get:OK' -- clip-get
log_matches '^termux-clipboard-get' "clip(읽기) 가 termux-clipboard-get 로 매핑"
run "clip-set → clipboard-set"   0 '클립보드 설정됨'         -- clip-set "복사할 텍스트"
log_matches '^termux-clipboard-set' "clip(설정) 가 termux-clipboard-set 로 매핑"

echo "== 3) None (빈값/누락) — 기본값으로 안전하게 떨어지는지 =="
run "photo 인자 없음 → 기본값"   0 '촬영됨.*photo\.jpg'      -- photo
log_matches 'termux-camera-photo -c 0 .*/out/photo\.jpg' "photo 기본 파일명/카메라 적용"
run "vibrate 인자 없음 → 300ms"  0 '진동 300ms'             -- vibrate
log_matches 'termux-vibrate -d 300' "vibrate 기본 300ms 적용"
run "sms 번호 누락 → rc=2 거부"  2 '번호 이상값'            -- sms-send "" "본문만"
run "app 패키지 누락 → rc=2"     2 '패키지명 필요'          -- app
run "notify 제목만 → 동작"       0 '알림 표시됨'            -- notify "제목만"

echo "== 4) 변조 (tampered/adversarial) — 악의/이상 입력을 막는지 =="
run "photo 경로탈출 파일명 차단"  0 '촬영됨'                 -- photo "../../etc/passwd" 0
# 핵심 계약: 슬래시 제거로 out/ 밖으로 못 나간다 — basename 에 '/' 가 없어야 한다.
log_matches '/out/[A-Za-z0-9._-]+$' "photo 파일명 슬래시 제거 → out/ 안에 갇힘(경로탈출 차단)"
run "photo 카메라ID 숫자만"      0 '촬영됨'                 -- photo ok.jpg "0; rm -rf /"
log_matches 'termux-camera-photo -c 0 ' "photo 카메라ID 가 숫자만 남김(주입 차단)"
run "openurl file:// 스킴 거부"   2 'http\(s\) URL 만 허용'  -- openurl "file:///etc/passwd"
run "openurl javascript: 거부"    2 'http\(s\) URL 만 허용'  -- openurl "javascript:alert(1)"
run "sms 번호 인젝션 → 숫자/+만" 0 '발송됨'                 -- sms-send "10;reboot" "x"
log_matches 'termux-sms-send -n 10 ' "sms 번호에서 비숫자 제거(인젝션 차단)"
run "app 패키지 인젝션 정규화"   0 '실행'                   -- app "com.x;rm -rf /"
log_matches 'resolve-activity --brief com\.xrmrf' "app 패키지명에서 위험문자 제거(영숫자/./_ 만; -·;·공백 제거)"
run "알 수 없는 동사 → rc=2"     2 '알 수 없는 명령'        -- definitely-not-a-verb
run "빈 동사 → rc=2"             2 '알 수 없는 명령'        -- ""

echo "== 5) 의존성 부재 / 실패 전파 (계약: rc 로 우아하게 실패) =="
( # termux-battery-status 가 PATH 에 없으면 _bridge_need 가 rc=3 으로 막아야 한다
  PATH="/usr/bin:/bin"
  rc=0; out="$(bridge_dispatch battery 2>&1)" || rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q '미설치'; then
    PASS=$((PASS+1)); echo "  ✓ termux-api 미설치 시 rc=3 으로 우아하게 실패"
  else FAIL=$((FAIL+1)); echo "  ✗ termux-api 미설치 rc=3 실패 (rc=$rc out=$out)"; fi
)
export STUB_FAIL="termux-sms-send"   # 폰 명령 자체가 실패하는 상황 (권한 거부 등)
run "폰 명령 실패 → rc=1 전파"   1 '발송 실패'             -- sms-send "+8210" "x"
unset STUB_FAIL

echo
echo "------------------------------------------------------------"
printf '결과:  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "✗ 실패한 테스트가 있습니다."; exit 1; }
echo "✓ 전체 통과"
