# D5 — 단일 파일 설치 스크립트 `anddev.sh`

## 결정
설치+실행+접속 로직을 **자기완결 단일 파일 `anddev.sh`** 로 통합한다.
기존 `lib/backend.sh` 를 인라인하고, `setup.sh`/`start.sh`/`connect.sh` 는
`anddev.sh <cmd>` 로 위임하는 1줄 shim 으로 바꾼다. `lib/backend.sh` 는 제거.

## 이유 (왜)
"원터치"가 목표인데 기존 설치는 `git clone` + 여러 파일 + 2단계(setup→start)였다.
단일 파일이면 `curl -fsSL .../anddev.sh -o anddev.sh && bash anddev.sh` 한 번으로
clone 없이 설치+실행이 끝난다. 인자 없이 실행하면 미설치=설치 후 실행, 설치됨=바로 실행(`auto`).

## 비용 / 트레이드오프
- 단일 파일이 길어짐(~16KB). 모듈 분리의 가독성을 일부 포기.
- 백엔드 로직이 `anddev.sh` 안에만 존재 → 단일 source of truth (드리프트 없음).

## 탈출구 (롤백/대안)
- 모듈 버전(`lib/backend.sh` 등)은 git 히스토리에 보존 — `git revert`/`git show` 로 복구.
- shim 덕분에 `bash setup.sh` / `bash start.sh` / `bash connect.sh` 기존 사용법 그대로 동작.

## 서브커맨드
| cmd | 동작 |
|-----|------|
| (없음)/`auto` | 미설치면 `setup`+`start`, 설치됨이면 `start` |
| `setup` | 설치만 |
| `start` | 서버 켜기 (sshd + Quick Tunnel) |
| `connect <host> [user]` | PC→폰 접속 (1455 포워딩 포함) |

## 검증 (경계 4종)
- 정상: `--help`, syntax(`bash -n`) 통과.
- 매핑: shim(`connect.sh`)이 `anddev.sh connect` 로 정상 위임.
- None: `connect` 호스트 누락 → usage + exit 1.
- 변조/환경결핍: 비-Termux 에서 `setup`/`auto` → `require_termux` 차단(설치 시도 전), exit 1;
  cloudflared 없을 때 `connect` → 명확한 안내 후 종료.
- 실기 검증(Termux 실제 설치 체인)은 안드로이드 기기에서만 가능 — 사람/클린기기 확인 필요.
