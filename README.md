# Claude Usage — macOS 메뉴 막대 사용량 모니터

claude.ai 설정의 **사용 한도** 화면(현재 세션 · 주간 · 모델별 주간)을 메뉴 막대에서 바로 보여주는 작은 앱입니다.
RunCat처럼 메뉴 막대 아이콘을 누르면 패널이 열립니다.

> ⚠️ **비공식 도구입니다.** Anthropic이 만들거나 보증한 앱이 아닙니다. 공개 문서가 없는 API를 사용하므로 언제든 동작이 멈출 수 있습니다.

```
◔ 5% · 16%        ← 메뉴 막대: 링은 가장 높은 한도, 텍스트는 세션 · 주간
```

## 기능

- **실시간 사용량** — 현재 세션(5시간), 주간(모든 모델), 모델별 주간(예: Fable) 사용률과 재설정까지 남은 시간
- **소진 예측** — 최근 사용 속도로 "이 속도면 14:40쯤 소진"을 계산
- **실시간 활동** — 이 Mac의 Claude Code 로그로 분당 토큰, 오늘 요청 수, 캐시 적중률, 모델 비중을 표시 (패널이 열려 있을 때만 계산)
- **macOS 알림** — 선택한 % 도달, 도달 N%p 전, 재설정 전 소진 예상, 한도 재설정
- **토큰 절약 팁** — 현재 상황(속도, 캐시 적중률, 컨텍스트 크기, 모델 비중, 서브에이전트 비중 등)에 맞춘 팁 + 일반 팁

## 요구 사항

- macOS 14 이상
- [Claude Code](https://docs.claude.com/en/docs/claude-code)에 회사(Team/Enterprise) 계정으로 로그인되어 있을 것 (`claude` → `/login`)
- Xcode 또는 Command Line Tools (`xcode-select --install`)

## 설치 (소스에서 빌드)

```bash
git clone <this repo> && cd agent-usage
scripts/build-app.sh --install   # ~/Applications/Claude Usage.app 설치 후 실행
```

처음 실행하면 알림 권한을 묻습니다. 설정(⚙︎)에서 알림 기준, 메뉴 막대 표시, 로그인 시 자동 실행을 바꿀 수 있습니다.

> **빌드된 .app을 주고받지 말고 각자 소스에서 빌드하세요.** 이 앱은 Claude 로그인 토큰을 읽습니다.
> 출처를 확인할 수 없는 바이너리는 같은 방식으로 토큰을 빼돌릴 수 있으므로, 코드를 확인하고 직접 빌드하는 것이 안전합니다.
> (서명·공증된 배포가 필요하면 회사 Developer ID로 서명/notarize 하세요.)

테스트: `scripts/test.sh`

### 빌드 문제 해결 (Xcode 없이 Command Line Tools만 있을 때)

- **`@State` 매크로를 찾을 수 없다는 오류:** macOS 27 베타 SDK에 필요한 SwiftUI 매크로 플러그인이 Command Line Tools에 없어서 생깁니다. 빌드 스크립트가 설치된 SDK 중 26.5처럼 정식 버전을 자동으로 고릅니다. 직접 지정하려면 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-app.sh`
- **`build.db: disk I/O error` 또는 `internal inconsistency`:** iCloud로 동기화되는 폴더(예: `~/Documents`) 안에서 빌드할 때 생깁니다. 스크립트는 빌드 결과물을 `~/Library/Caches/agent-usage-*`에 둡니다.
- **`no such module 'Testing'`:** `swift test`를 직접 실행하지 말고 `scripts/test.sh`를 쓰세요. 테스트 매크로 플러그인 경로를 자동으로 넣어 줍니다.

## 동작 방식

| 데이터 | 출처 | 주기 |
|---|---|---|
| 사용 한도 % | `GET https://api.anthropic.com/api/oauth/usage` (Claude Code의 `/usage`와 같은 데이터) | 기본 60초 (30초–5분) |
| 실시간 활동 | `~/.claude/projects/**/*.jsonl` 의 `usage` 필드 | 패널이 열려 있을 때만 5초 |

### 인증

별도 로그인 화면이 없습니다. **Claude Code가 macOS 키체인(`Claude Code-credentials`)에 저장한 OAuth 액세스 토큰을 읽기 전용으로** 사용합니다.

- 토큰을 **갱신하지 않습니다.** refresh token으로 갱신하면 Claude Code의 로그인이 끊길 수 있기 때문입니다. 토큰이 만료되면 Claude Code를 한 번 사용하면 자동 갱신되고, 앱이 다음 주기에 새 토큰을 읽습니다.
- refresh token은 디코딩 대상에서 제외되어 앱 메모리에 문자열로 남지 않습니다.
- 키체인은 `/usr/bin/security`로 읽습니다. 이 항목의 접근 권한이 이미 이 도구를 신뢰하므로 키체인 암호 프롬프트가 뜨지 않습니다.

## 보안 · 개인정보

| 항목 | 처리 |
|---|---|
| 토큰 전송 대상 | `https://api.anthropic.com` 한 곳뿐 (HTTPS, TLS 1.2+). **HTTP 리다이렉트를 거부**하고, 응답 호스트도 다시 확인 |
| 토큰 저장 | 디스크에 저장하지 않음. 메모리에만 보관, 만료/401 시 폐기. UserDefaults·로그·알림에 포함되지 않음 |
| 토큰 노출 | `print`/`dump`/디버거 출력에서 `<redacted>`로 표시. 오류 메시지에 URL·헤더를 담지 않음 |
| 네트워크 캐시 | 에페메럴 세션, URL 캐시·쿠키·자격 증명 저장소 모두 비활성 |
| 헤더 주입 | 공백·제어 문자가 섞인 토큰은 거부 |
| refresh token | 디코딩하지 않음. 키체인에서 읽은 원본 JSON 버퍼는 파싱 직후 0으로 덮어씀 |
| 자격 증명 파일 | `~/.claude/.credentials.json`은 심볼릭 링크를 따라가지 않고(`O_NOFOLLOW`), 64KB 이하 일반 파일만 읽음 |
| 대화 로그 | 로컬에서 `usage` 숫자만 집계. 대화 내용은 저장·전송하지 않음. 16MB를 넘는 줄은 건너뜀 |
| 비정상 값 | NaN·무한대·초대형 숫자, 잘못된 `Retry-After`가 와도 앱이 죽거나 갱신이 멈추지 않도록 값을 제한 |
| 화면 표시 | 서버·로그에서 온 문자열은 Markdown/링크로 해석하지 않고 그대로 표시 |
| 외부 입력 | 열려 있는 포트, URL 스킴, XPC 없음 |
| 바이너리 | Hardened Runtime으로 ad-hoc 서명 (디버거 attach 차단) |

### 토큰을 다루는 코드 직접 확인하기

토큰을 만지는 코드는 아래 두 파일뿐입니다. 업데이트를 받을 때마다 이 두 파일의 diff를 확인하세요.

- `Sources/AgentUsageCore/CredentialStore.swift` — 키체인에서 읽기
- `Sources/AgentUsageCore/UsageAPI.swift` — API 호출

```bash
# 앱이 접속하거나 여는 URL 전체 — api.anthropic.com, claude.ai, 시스템 설정만 나와야 정상
grep -rn 'URL(string' Sources
# 외부 프로세스 실행 — /usr/bin/security 하나만 나와야 정상
grep -rn 'executableURL' Sources
# 토큰 사용처 — UsageStore가 UsageAPI에 넘기는 한 줄과 UsageAPI.swift의 Authorization 헤더만 나와야 정상
grep -rn 'accessToken' Sources/AgentUsage Sources/AgentUsageCore | grep -v 'CredentialStore.swift'
```

- 이 API는 **공개 문서가 없는 엔드포인트**입니다(Claude Code가 내부적으로 사용). 예고 없이 바뀔 수 있고, 그 경우 앱에 오류가 표시됩니다.
- 회사 네트워크에서 TLS 검사 프록시를 쓰면 프록시가 토큰을 볼 수 있습니다. Claude Code 자체도 같은 조건입니다.

### 보안 점검 결과 (2026-10-12)

토큰을 중심으로 두 번 점검했습니다. 한 번은 작성자가 코드를 한 줄씩 직접 봤고, 한 번은 설계 의도를 모르는 별도 검토자가 독립적으로 봤습니다.
**두 점검 모두 토큰이 새는 경로는 찾지 못했습니다.** 아래는 발견한 위험과 처리 결과입니다. 1%라도 가능성이 있는 항목은 모두 고쳤고, 각 항목에 회귀 테스트(`SecurityTests`, `HostileInputTests`)를 붙였습니다.

| 발견 내용 | 심각도 | 처리 |
|---|---|---|
| HTTP 리다이렉트 시 요청 헤더가 다른 호스트로 재전송될 가능성 | 낮음 | 리다이렉트를 전면 거부하고 응답 호스트를 재확인. 로컬 서버로 시험해 보니 macOS는 다른 호스트로 갈 때 `Authorization`을 이미 제거함. 차단은 추가 방어선 |
| URL 캐시·쿠키가 디스크에 남을 가능성 | 낮음 | 에페메럴 세션, 캐시·쿠키·자격 증명 저장소 비활성 |
| refresh token이 메모리에 문자열로 남음 | 낮음 | 필요한 필드만 디코딩하고 원본 버퍼를 0으로 덮어씀 |
| `print`·디버거 출력에 토큰 노출 가능성 | 낮음 | 출력 시 `<redacted>`로 대체 |
| 토큰에 섞인 개행 문자로 HTTP 헤더 주입 | 낮음 | 출력 가능한 ASCII 외 문자는 거부 |
| 서버·로그 문자열이 패널에서 클릭 가능한 링크로 표시됨 | 낮음 | `Text(verbatim:)` 사용 |
| `osascript` 알림 대체 경로(외부 명령 실행) | 낮음 | 기능 삭제 |
| 서버 응답의 초대형 숫자, 로그의 극단적인 토큰 수로 앱 강제 종료 | 낮음 | 값 범위 제한 |
| 잘못된 `Retry-After`(NaN) 하나로 자동 갱신이 영구 정지 | 낮음 | 유한한 양수만 허용, 최대 15분 |
| 자격 증명 파일 심볼릭 링크 검사와 읽기 사이의 경쟁 조건 | 낮음 | `O_NOFOLLOW`로 열고 열린 파일에서 종류·크기 검사 |
| 매우 긴 로그 줄로 메모리가 무한히 커질 가능성 | 낮음 | 한 줄 16MB 상한 |

**코드로 없앨 수 없는 위험**

- **공급망(가장 중요):** Claude Code의 키체인 항목은 원래 이 사용자로 실행되는 어떤 프로세스든 확인 창 없이 읽을 수 있습니다. 이 앱이 만든 노출은 아니지만, 변조된 빌드나 악성 커밋이 섞인 업데이트는 같은 방법으로 토큰을 가져갈 수 있습니다. 그래서 **바이너리를 주고받지 말고 소스에서 빌드**하고, 업데이트 때는 위의 두 파일을 확인하세요.
- **메모리:** 액세스 토큰은 만료될 때까지 앱 메모리에 있습니다. 버퍼를 덮어써도 시스템 내부에서 만든 복사본까지 지울 수는 없습니다. Hardened Runtime이 다른 프로세스가 디버거로 붙는 것을 막습니다.
- **비공개 API:** 공개 문서가 없는 엔드포인트라 예고 없이 바뀔 수 있습니다.

## 저장소 관리자용: 공개 전 체크리스트

- [ ] **브랜치 보호:** `main`에 직접 푸시를 막고 리뷰를 필수로 설정
- [ ] **CODEOWNERS:** `Sources/AgentUsageCore/CredentialStore.swift`, `Sources/AgentUsageCore/UsageAPI.swift`, `scripts/build-app.sh`에 보안 담당 리뷰어 지정
  ```
  # .github/CODEOWNERS
  /Sources/AgentUsageCore/CredentialStore.swift  @<reviewer>
  /Sources/AgentUsageCore/UsageAPI.swift         @<reviewer>
  /scripts/build-app.sh                          @<reviewer>
  ```
- [ ] **배포 방식:** 소스에서 빌드하도록 안내하고, 릴리스는 서명된 태그로 표시. 바이너리를 배포해야 한다면 회사 Developer ID로 서명하고 공증(notarize)
- [ ] **이름·아이콘:** "Claude Usage"와 Claude 느낌의 아이콘이 공식 앱처럼 보일 수 있음. 비공식 안내는 넣어 두었고, 이름을 바꿀지 결정
- [ ] **이용 약관:** 회사 밖으로 공개할 경우, Claude Code 로그인 토큰으로 비공개 API를 호출하는 것이 Anthropic 약관에 맞는지 확인
- [ ] **라이선스:** `LICENSE` 파일 추가 (사내 전용이면 사내 정책에 따름)
- [ ] **저장소 공개 범위:** 사내 동료용이면 회사 GitHub 조직의 private/internal 저장소 권장

## 리소스 사용

패널이 닫혀 있을 때는 설정한 주기마다 작은 HTTPS 요청 하나만 보냅니다. 로그 스캔이나 화면 갱신은 하지 않습니다.

- 메모리 footprint 약 17MB, 유휴 CPU 0%, idle wakeups 0 (Apple Silicon, macOS 26 측정)
- 로그는 새로 추가된 바이트만 1MB 단위로 읽고, 디렉터리 전체 탐색은 30초에 한 번만
- 타이머에 tolerance를 줘서 시스템이 깨어나는 시점을 묶을 수 있게 함

## 구조

```
Sources/AgentUsageCore/   UI 없는 로직 (테스트 대상)
  CredentialStore.swift   키체인에서 토큰 읽기
  UsageAPI.swift          사용량 API (리다이렉트 차단, 캐시 없음)
  UsageModels.swift       응답 파싱 → UsageLimit
  LocalLogScanner.swift   Claude Code 로그 증분 읽기
  ActivityStats.swift     토큰 집계 · 모델 비중 · 캐시 적중률
  Projection.swift        소진 시각 예측
  AlertPlanner.swift      알림 판정 (중복 방지)
  TipEngine.swift         상황별 · 일반 팁
Sources/AgentUsage/       SwiftUI 메뉴 막대 앱
scripts/build-app.sh      .app 번들 생성 · 서명 · 설치
```
