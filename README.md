# anddev — 안드로이드 폰을 원터치 리눅스 원격 개발서버로

낡은/여분 안드로이드 폰을 **루팅 없이** 리눅스 원격 개발서버로 바꿔주는 스크립트입니다.
SSH 로 접속하면 바로 **Codex** 와 **Claude Code** 를 쓸 수 있습니다.

```
┌─────────── 안드로이드 폰 (Termux) ───────────┐
│  proot Ubuntu                                 │
│  ┌──────────────┐                             │
│  │ sshd :22     │◀─ localhost ─┐              │
│  │ codex/claude │              │              │
│  └──────────────┘     ┌────────┴─────┐        │
│                       │ cloudflared  │── 바깥으로 ──┐
│                       └──────────────┘        │     │
└───────────────────────────────────────────────┘     ▼
                                              Cloudflare 엣지
   내 PC:  ssh ... dev@xxx.trycloudflare.com  ◀──────┘
```

- **루팅 불필요** — `proot` 가 `ptrace` 로 가짜 chroot 를 만듦 (Termux 방식)
- **공인 IP·포트포워딩 불필요** — Cloudflare **Quick Tunnel** 이 바깥으로 나가는 연결만 사용
- **무계정·무도메인** — `*.trycloudflare.com` 랜덤 주소 (실행 때마다 바뀜)

> 1단계(현재): Termux 셸 스크립트로 핵심 체인 검증.
> 2단계(예정): 검증된 로직을 독립 APK 로 포장 (foreground service + 원터치 UI).

---

## 준비물

- 안드로이드 폰 + **Termux** (⚠️ Play 스토어 말고 **[F-Droid](https://f-droid.org/packages/com.termux/)** 또는 GitHub 릴리스 버전)
- 저장공간 2~4GB, 가급적 충전 연결 권장 (상시 서버라 발열/배터리 소모)
- 접속할 PC 에 [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) 설치

## 설치 + 실행 (폰의 Termux 에서) — 단일 파일, 원터치

`git clone` 도 여러 파일도 필요 없습니다. **`anddev.sh` 한 파일**만 받아서 실행하면
미설치면 설치하고, 설치돼 있으면 바로 서버를 켭니다.

```bash
curl -fsSL https://raw.githubusercontent.com/johunsang/anddev/main/anddev.sh -o anddev.sh
bash anddev.sh        # 원터치: 설치(최초 1회) → 서버 켜기
```

> 한 줄로 끝내려면:
> `curl -fsSL https://raw.githubusercontent.com/johunsang/anddev/main/anddev.sh | bash`
> (단, 다음부터 다시 켜려면 파일을 남겨두는 위쪽 방식이 편합니다.)

## 다시 켜기 (매번)

```bash
bash anddev.sh start   # 또는 인자 없이 bash anddev.sh (자동 감지)
```

설치만 다시 하려면 `bash anddev.sh setup`.
(`setup.sh` / `start.sh` / `connect.sh` 는 `anddev.sh` 로 위임하는 하위호환 wrapper 입니다.)

실행하면 접속 정보가 출력됩니다:

```
호스트   : abcd-efgh.trycloudflare.com
사용자   : dev
비밀번호 : (자동 생성된 20자리)
```

## 접속 (내 PC 에서)

```bash
bash anddev.sh connect <호스트>      # 권장: 인증용 1455 포트포워딩 포함
# 또는 수동:
ssh -o ProxyCommand="cloudflared access ssh --hostname <호스트>" dev@<호스트>
```

접속되면 바로:

```bash
codex     # OpenAI Codex CLI
claude    # Claude Code
```

---

## 동작 원리 / 결정 기록

| ID | 결정 | 이유 / 트레이드오프 | 탈출구 |
|----|------|----------------------|--------|
| D1 | **proot/chroot 자동선택** | 루트 없으면 proot(기본), 있으면 chroot(빠름·Docker가능). 자동 감지 | `ANDDEV_FORCE_PROOT=1` 로 강제 proot |
| D2 | 접속 = **SSH** | 터미널 개발에 충분, 가장 단순 | code-server 추가 가능 |
| D3 | **Quick Tunnel** | 무계정/무도메인, 진짜 원터치 | 고정 URL 필요 시 Named Tunnel |
| D4 | **스크립트 먼저** | 핵심 로직 분리 검증 후 APK 포장 | 그대로 APK 에 번들 |
| D5 | **단일 파일 `anddev.sh`** | 진짜 원터치 — clone 불필요, `curl` 한 줄로 설치+실행. 유일한 source of truth | 기존 `setup/start/connect.sh` 는 위임 shim 으로 보존 |
| D6 | **폰 기능 = 파일 릴레이 브리지** | proot 게스트는 `termux-*` 바이너리에 직접 접근 불가(다른 libc/네임스페이스). 게스트가 요청 파일을 쓰면 Termux 데몬이 실행 → 결과 파일 반환 | 루팅 시 네임스페이스 공유로 직접 호출 가능 / 미설치 시 명령이 `rc=3` 으로 우아하게 실패 |

## 안드로이드 폰 기능 (Termux:API 브리지)

SSH 로 접속한 **개발서버(proot Ubuntu) 안에서** 폰의 카메라·문자·위치 같은
안드로이드 기능을 명령 한 줄로 호출할 수 있습니다.

### 왜 브리지가 필요한가 (구조)

`termux-*` 명령은 **Termux 네임스페이스**에서 도는데, 당신이 SSH 로 들어간 셸은
그 안쪽의 **proot Ubuntu** 입니다. proot 안에는 termux 바이너리가 없고 libc 도
달라서 직접 호출이 안 됩니다. 그래서 **파일 릴레이** 방식으로 잇습니다:

```
proot Ubuntu (게스트)                   Termux (호스트)
  photo / sms / ...                        bridge 데몬 (백그라운드)
      │ ① 요청 파일 쓰기                      │
      ▼                                      │ ② 폴링해서 읽음
  /opt/anddev-bridge/req/*.req ───공유경로──▶ │
                                             │ ③ termux-api / am 실행
      ▲ ⑤ 결과 읽고 출력                      ▼
  /opt/anddev-bridge/res/*.res ◀──공유경로─── ④ 결과 파일 쓰기
```

스풀 디렉터리(`/opt/anddev-bridge`)는 rootfs 안에 있어 **양쪽에서 같이 보입니다.**
데몬은 `bash anddev.sh start` 가 자동으로 띄우고, 종료 시 같이 정리됩니다.

### 명령 목록 (접속 후 `phone-help`)

| 명령 | 동작 |
|------|------|
| `photo [파일명] [카메라ID]` | 폰 카메라로 촬영 → `/opt/anddev-bridge/out/` 에 저장 (SSH 로 내려받아 봄) |
| `sms <번호> <메시지...>` | 폰 SIM 으로 문자 발송 |
| `smslist` | 받은 문자 목록 (JSON) |
| `openurl <https://...>` | 폰 기본 브라우저로 URL 열기 |
| `app <패키지명>` | 앱 실행 (예: `app com.android.chrome`) |
| `battery` | 배터리 상태 (JSON) |
| `location` | GPS 위치 (JSON) |
| `clip [텍스트...]` | 인자 없으면 클립보드 읽기 / 있으면 설정 |
| `notify <제목> <내용...>` | 상단 알림 표시 |
| `vibrate [ms=300]` | 진동 |
| `say <텍스트...>` | TTS 로 읽기 |
| `sensors` | 센서 목록 |
| `contacts` | 연락처 목록 (JSON) |
| `calllog` | 통화 기록 (JSON) |

### 준비물 (이게 없으면 명령이 `rc=3` 으로 실패)

1. **Termux:API 앱** — F-Droid 에서 설치 (⚠️ `pkg install termux-api` 패키지만으론 부족, **앱**도 필요)
2. **권한** — 카메라/문자/위치/연락처는 첫 사용 시 폰에 **권한 팝업**이 한 번 뜹니다. 허용해야 동작.

`bash anddev.sh setup` 이 `termux-api` 패키지와 게스트 명령을 자동 설치합니다.

### ⚠️ "트리거"와 "원격 시청"은 다르다

- **사진 / 문자 / 배터리 / 위치 / 연락처** → 결과가 **데이터**(파일·JSON)라서 SSH 로 그대로 받아봄 → **원격으로 완결.**
- **app / openurl** → 동작은 **폰의 실제 화면**에서 일어남. "켜라"는 되지만 원격에서 **그 화면을 보거나 터치할 순 없음.** (화면 미러링은 `scrcpy`/VNC 등 별도 도구 영역)

### 보안 (계약적 사고)

- 데몬은 **임의 문자열을 `eval` 하지 않습니다.** 허용된 동사(화이트리스트)만 처리.
- 인자는 실행 전 정규화: 파일명은 `[A-Za-z0-9._-]` 외 제거(경로 탈출 차단), 번호는 숫자/`+` 만, URL 은 `http(s)` 스킴만, 패키지명은 영숫자/`.`/`_` 만.
- 요청 파일은 `.tmp`→`rename(.req)` 로 원자적 생성(데몬이 반쪽 파일을 읽지 않음).

## 알려진 제약

- **백그라운드 종료**: 안드로이드가 메모리 부족 시 Termux 를 죽일 수 있음 → Termux 배터리 최적화 예외 설정 권장. (2단계 APK 의 foreground service 가 근본 해결)
- **URL 변동**: Quick Tunnel 은 재시작마다 주소가 바뀜.
- **성능**: proot 오버헤드로 네이티브보다 느림. 코딩/빌드엔 충분, 무거운 도커 워크로드는 부적합.

## 자격증명

`~/.anddev/credentials` 에 평문 저장됩니다 (개인 기기 가정). 재설치해도 재사용됩니다.
비밀번호를 새로 만들려면 이 파일을 지우고 `setup.sh` 를 다시 실행하세요.

## 라이선스

MIT
