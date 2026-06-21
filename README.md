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

## 설치 (폰의 Termux 에서, 최초 1회)

```bash
pkg install -y git
git clone https://github.com/johunsang/anddev.git
cd anddev
bash setup.sh
```

## 서버 켜기 (매번)

```bash
cd anddev
bash start.sh
```

실행하면 접속 정보가 출력됩니다:

```
호스트   : abcd-efgh.trycloudflare.com
사용자   : dev
비밀번호 : (자동 생성된 20자리)
```

## 접속 (내 PC 에서)

```bash
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

## 알려진 제약

- **백그라운드 종료**: 안드로이드가 메모리 부족 시 Termux 를 죽일 수 있음 → Termux 배터리 최적화 예외 설정 권장. (2단계 APK 의 foreground service 가 근본 해결)
- **URL 변동**: Quick Tunnel 은 재시작마다 주소가 바뀜.
- **성능**: proot 오버헤드로 네이티브보다 느림. 코딩/빌드엔 충분, 무거운 도커 워크로드는 부적합.

## 자격증명

`~/.anddev/credentials` 에 평문 저장됩니다 (개인 기기 가정). 재설치해도 재사용됩니다.
비밀번호를 새로 만들려면 이 파일을 지우고 `setup.sh` 를 다시 실행하세요.

## 라이선스

MIT
