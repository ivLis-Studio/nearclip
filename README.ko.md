<p align="center"><img src="design/out/nearclip-512.png" width="128" alt="Nearclip"></p>

<h1 align="center">Nearclip</h1>
<p align="center"><b>여기서 복사하고, 저기서 붙여넣기.</b><br>Mac · Windows · Android · iPhone을 위한 유니버설 클립보드 — 기기끼리 직접, Nearclip 서버 없이</p>

<p align="center"><a href="README.md">English</a></p>

---

한 기기에서 복사하면 다른 모든 기기에서 붙여넣을 수 있습니다. Nearclip은 같은 Wi‑Fi에 있는 내 기기들의 클립보드와
검색 가능한 공유 기록을 동기화하고, **원격 연결**을 켜면 서로 다른 네트워크(집, 회사, 모바일 데이터)에서도 동기화합니다.
**Nearclip 서버도, Nearclip 계정도 없습니다.** 같은 네트워크에서는 기기들이 Bonjour/mDNS로 서로를 찾아 TCP로 직접
통신하고, 다른 네트워크에서는 앱에 내장된 Tailscale 노드가 같은 연결을 이어 줍니다(무료 Tailscale 계정으로 로그인).
어느 쪽이든 모든 내용은 내 기기만 가진 키로 **종단 간 암호화**됩니다.

| | macOS | Windows | Android | iOS / iPadOS |
|---|---|---|---|---|
| 앱 형태 | 메뉴 막대 앱 + Spotlight 스타일 패널 | 트레이 앱 + Win+V 스타일 플라이아웃 | Material 3 앱 + 백그라운드 서비스 | SwiftUI 앱 |
| 언어 / UI | Swift · SwiftUI + AppKit | C# · WinUI 3 (Windows App SDK) | Kotlin · Jetpack Compose | Swift · SwiftUI |
| 보내기 | 복사하면 자동 | 복사하면 자동 | 앱 열기 · 타일 · 알림 · 공유 · 텍스트 선택 / Shizuku로 텍스트 즉시 불러오기 선택 가능 | 붙여넣기 버튼 / 열 때 자동 |
| 받기 | 자동 (+알림, 큰 이미지는 진행률) | 자동 (+알림, 큰 이미지는 진행률) | 백그라운드에서 자동 (+큰 이미지는 진행률 알림) | 앱이 열려 있을 때 (+열면 밀린 내용 수신) |
| 폴더 | `apple/macOS` | `windows/` | `android/` | `apple/iOS` |

네 앱 모두 네이티브 앱입니다(Electron·웹뷰 없음).

<table>
<tr>
<td align="center"><img src="docs/screenshots/macos/ko-dark-panel.png" width="230"><br><sub>macOS · 메뉴 막대 패널 (⌃⌘V)</sub></td>
<td align="center"><img src="docs/screenshots/windows/ko-dark-flyout.png" width="230"><br><sub>Windows · 트레이 플라이아웃 (Win+Alt+V)</sub></td>
<td align="center"><img src="docs/screenshots/android/ko-light/01-history.png" width="190"><br><sub>Android · 기록</sub></td>
<td align="center"><img src="docs/screenshots/ios/ko-06-home-history.png" width="190"><br><sub>iPhone · 기록 + 붙여넣기 막대</sub></td>
</tr>
</table>


## 기능

* 텍스트·링크·색상 코드·이미지(최대 32MB) **실시간 동기화**
* **큰 이미지는 받는 중부터 표시**: 이미지를 복사한 기기가 인코딩하기 전에 먼저 알려서, 다른 기기에 바로 *iPhone에서 이미지
  받는 중…*과 진행률 바·용량이 뜹니다(컴퓨터는 토스트, 휴대폰 앱은 카드, Android 백그라운드는 조용한 배너). 다 받으면 같은
  자리가 *iPhone에서 복사됨*으로 바뀝니다.
* 모든 기기에 **공유 기록**: 검색, 필터(텍스트·링크·이미지·고정됨), 고정, 모든 기기에서 삭제
* **계정 없는 연결**: 휴대폰으로 QR 코드 스캔(시스템 카메라도 가능), 또는 주변 컴퓨터를 골라 두 화면의 6자리 코드를 비교.
  연결된 기기라면 어느 기기에서든 새 기기를 추가할 수 있습니다.
* **메시 동기화**: 닿는 모든 기기끼리 연결하고 받은 클립을 전달하므로, 일부만 연결돼도 결국 모두 같아집니다.
  잠시 떨어져 있던 기기는 돌아오면 최근 7일치를 받아옵니다.
* **원격 연결**(선택): *다른 네트워크에서도 동기화*를 켜고 각 기기에서 같은 무료 Tailscale 계정으로 로그인하세요.
  앱마다 Tailscale 노드가 내장되어 있어 따로 설치할 앱도, VPN 프로필도 없습니다. 기기들은 이 노드를 통해 연결되며,
  NAT 통과가 되면 직접, 안 되면 Tailscale 중계(DERP)를 거칩니다. Wi‑Fi 연결이 항상 우선이고, 기기마다 연결 방식
  (*연결됨 · 같은 네트워크* 또는 *연결됨 · 원격*)을 보여 줍니다.
* **개인정보 보호**: 암호 관리자가 비공개로 표시한 항목은 동기화하지 않음, 컴퓨터에서 앱별 제외 목록, 일시정지, 모든 기기에서 삭제
* **플랫폼다운 완성도**: macOS 26+ Liquid Glass, Windows 11 Mica, Android Material You, iOS SwiftUI · 라이트/다크 · 한국어/영어 ·
  키보드 중심 데스크톱 패널(Mac ⌃⌘V, Windows Win+Alt+V)

<table>
<tr>
<td align="center"><img src="docs/screenshots/macos/ko-light-devices-remote.png" width="230"><br><sub>macOS · 기기</sub></td>
<td align="center"><img src="docs/screenshots/windows/ko-dark-devices-remote.png" width="230"><br><sub>Windows · 기기</sub></td>
<td align="center"><img src="docs/screenshots/android/ko-dark/17-devices-remote.png" width="160"><br><sub>Android · 내 기기</sub></td>
<td align="center"><img src="docs/screenshots/ios/ko-13-devices-remote.png" width="160"><br><sub>iPhone · 기기</sub></td>
</tr>
</table>
<p align="center"><sub>원격 연결: 각 앱이 다른 네트워크의 기기를 <i>연결됨 · 원격</i>으로 표시합니다(테스트용 조정 서버로 촬영).</sub></p>

## 동작 방식

```
 Mac ──────────── Windows PC         • 기기 찾기: DNS-SD 서비스 _nearclip._tcp (Bonjour / mDNS)
  │  ╲          ╱    │               • 전송: 기기 쌍마다 TCP 연결 하나, 길이 접두 프레임
  │    ╲      ╱      │               • 암호화: P-256 ECDH(일회용 키) + HKDF-SHA256 + AES-256-GCM
 iPhone ──── Android                  • 한 기기에서 받은 클립은 다른 기기로 전달(ID로 중복 제거)
```

* 설치할 때마다 무작위 256비트 키를 가진 **그룹**이 만들어지고, 연결(페어링)은 QR 비밀값이나 6자리 숫자 비교(커밋먼트 포함 —
  중간자가 숫자를 맞출 수 없음)로 인증된 채널을 통해 새 기기에 그 키를 전달합니다.
* 연결마다 그룹 키에 묶인 일회용 ECDH 핸드셰이크를 수행해 전방 보안을 제공하며, 클립·기기 목록·연결 결과는 모두 암호화됩니다.
  통신 규격은 [docs/PROTOCOL.md](docs/PROTOCOL.md), 검증 데이터는 [spec/test-vectors.json](spec/test-vectors.json)에 있습니다.
* **원격 연결**([PROTOCOL.md §10](docs/PROTOCOL.md), [tailnet/](tailnet/README.md)): 앱마다 [tsnet](https://tailscale.com/kb/1244/tsnet)
  노드를 사용자 공간에서 실행합니다(WireGuard + gVisor 네트워크 스택, 시스템 VPN 아님). 노드 이름은 `nearclip-<기기>-<id>`이며,
  같은 그룹의 기기들은 테일넷의 기기 목록에서 이 이름으로 서로를 찾아 노드를 통해 연결합니다. Nearclip 세션과 암호화는
  WireGuard 안에서 그대로 동작합니다. Tailscale 조정 서버는 기기 이름과 주소만 알 뿐 클립은 볼 수 없고, Nearclip 자체는
  여전히 서버를 운영하지 않습니다.
* 제품·UX 결정은 [docs/DESIGN.md](docs/DESIGN.md)에 정리했습니다.

## 빌드와 실행

### 내장 Tailscale 라이브러리(`tailnet/`, 먼저 빌드)

원격 연결에는 플랫폼별로 작은 Go 라이브러리가 필요하며, Xcode·Gradle·.NET 바깥에서 빌드합니다.

```sh
tailnet/build.sh all              # Go(tailnet/go.mod 참고), Xcode, Android NDK, llvm-mingw — tailnet/README.md 참고
```

`apple/NearclipKit/Binaries/NCTailnet.xcframework`, `android/app/src/main/jniLibs/*/libnctailnet.so`,
`windows/native/win-*/nctailnet.dll`(모두 저장소 미포함)을 만들고 라이선스 고지 `tailnet/notices/THIRD_PARTY_NOTICES.txt`를
갱신합니다. 라이브러리가 없으면 앱 빌드가 이유를 알려 주며 멈춥니다.

### macOS · iOS (`apple/`)

필요: Xcode 16 이상(Xcode 27 beta로 빌드·테스트), [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
cd apple
xcodegen generate                 # Nearclip.xcodeproj 생성(저장소에도 포함)
open Nearclip.xcodeproj           # 스킴: Nearclip(macOS), NearclipiOS
scripts/build-release.sh          # 유니버설·ad-hoc 서명된 dist/Nearclip-macOS.zip
```

* macOS 14 이상. 앱은 메뉴 막대(그리고 ⌃⌘V)에 있습니다. 처음 복사할 때 macOS가 클립보드 접근을 물으면 **항상 허용**을 선택하세요
  (시스템 설정 › 개인정보 보호 및 보안 › 다른 앱에서 붙여넣기).
* iOS 17 이상. iPhone에 설치하려면 `NearclipiOS` 타깃의 *Signing & Capabilities*에서 팀을 선택하세요.

### Android (`android/`) · Windows (`windows/`)

[android/README.md](android/README.md), [windows/README.md](windows/README.md)를 참고하세요.

## 테스트

| 테스트 | 명령 |
|---|---|
| Swift 엔진(검증 데이터 + localhost 연결·동기화 시나리오) | `cd apple/NearclipKit && swift test` |
| Kotlin 엔진 | `cd android && ./gradlew :core:test` |
| C# 엔진 | `cd windows && dotnet test --project tests/Nearclip.Core.Tests/Nearclip.Core.Tests.csproj` |
| 테일넷 브리지(Go, 프로세스 내 조정 서버 사용) | `cd tailnet && go test ./...` |
| **구현 간 상호 운용**(Swift × Kotlin × C#, 원격·이미지 진행률 포함 48개 시나리오) | `python3 tools/interop/run.py` |
| iOS UI 흐름(온보딩 → 연결 → 밀린 내용 → 보내기, 원격, 라이선스) | `xcodebuild test -scheme NearclipiOS …` (`apple/iOSUITests`) |
| macOS 실사용 데모(실제 앱 + 가상 기기) | `python3 apple/tools/demo.py` |
| 실제 앱의 큰 이미지 진행률(천천히 보내는 기기 + 스크린샷) | `tools/acceptance/mac_transfer.py`, `tools/acceptance/windows_transfer.py`, `tools/acceptance/android_transfer.py`, `apple/tools/ios_transfer.py` |
| 실제 앱의 원격 연결(테스트용 Tailscale 조정 서버) | `apple/tools/remote_demo.py`, `apple/tools/ios_remote.py`, `tools/acceptance/android_remote.py`, `tools/acceptance/windows_remote.py` |
| 실제 Tailscale 서비스로 원격 연결(사람이 직접 로그인) | `python3 tools/acceptance/real_remote.py` |

## 검증한 내용

* **엔진**: Swift 테스트 12개, Kotlin 24개, C# 28개, Go 브리지 테스트 — `spec/test-vectors.json`의 모든 값, 실제 localhost
  연결·동기화 시나리오, 테일넷 연결·탐색 로직
* **상호 운용**: `tools/interop/run.py` **48/48 통과** (Swift × Kotlin × C#: 모든 방향의 QR·코드 연결, 한글+이모지 실시간 텍스트,
  여러 조각으로 나뉜 이미지, 모든 기기에서 삭제, 재시작 후 밀린 내용 수신, 기기 제거, 제거된 기기 다시 추가, 모든 순열의 3단 메시 전달,
  모든 순서쌍의 **이미지 진행률**(예고 → 준비 중 → 진행률 → 클립, 예고 없는 이미지, 취소, 예고 중 보낸 기기 끊김, 밀린 내용엔 진행률 없음),
  그리고 **원격**: 모든 순서쌍이 LAN에서 연결한 뒤 원격 연결을 켜고 새 포트로 재시작해 테일넷으로 서로를 찾아 양방향 동기화)
* **실제 앱의 큰 이미지 진행률**(10.6MB 사진을 초당 0.9MB로 보내는 기기): macOS 앱(분리된 인스턴스), Windows 11 ARM64 VM,
  Android 16 에뮬레이터, iPhone 시뮬레이터 모두 *…에서 이미지 받는 중…*과 *준비 중…*을 먼저 보여 준 뒤 *3.1 / 10.6 MB*,
  *7.3 / 10.6 MB*로 차오르고(Windows는 파일 탐색기와 같은 단위라 *3.0 / 10.1 MB*), 같은 자리에서 *…에서 복사됨*으로 바뀌며
  클립보드에 이미지가 들어감. 전송 중에 컴퓨터 토스트를 클릭하면 다 받을 때까지 다시 뜨지 않음. 취소된 예고는 조용히 사라지고,
  전송 중 보낸 기기가 끊기면 *이미지를 받지 못했습니다 · …에서 다시 복사해 보세요.*, 자동 복사가 꺼져 있으면 *…에서 받은 이미지 ·
  기록에 저장됨*. Android는 백그라운드에서도 확인(시작 배너, 알림창 진행률, 썸네일이 붙은 *…에서 복사됨* 배너), 공유로 보낸 이미지는
  읽기 전에 예고됨(0.2초 뒤 크기 확인). **아직 검증하지 않은 것:** 실제 휴대폰과 실제 Windows PC
* **배포본 최종 점검(2026-10-24)**: 엔진 테스트(Swift 12, Kotlin 24, C# 33, Go), 상호 운용 48/48, 위의 수락 테스트 전부(macOS 앱,
  Windows VM, Android 에뮬레이터, iPhone·iPad 시뮬레이터), Android 계측 테스트. `dist/` 파일 자체도 확인: macOS zip을 분리된
  인스턴스로 실행(서명, 유니버설 바이너리, 텍스트 양방향, PNG 바이트 일치), Android 1.0.2 릴리스 APK(디버그 불가 빌드, 텍스트 양방향,
  이미지), 퍼블리시된 Windows arm64·x64(링크로 연결, Windows 클립보드로 텍스트 양방향). 이어서 네 앱(macOS 배포본, Windows VM,
  Android 에뮬레이터, iPhone 시뮬레이터)을 한 그룹으로 묶어 각자 보낸 텍스트가 나머지 셋에 출처 그대로 도착함. 이 과정에서
  ARM64 PC에서 에뮬레이션으로 도는 x64 Windows 빌드가 원격 연결이 켜져 있으면 시작 직후 멈추는 문제를 찾아 고침(windows/NOTES.md)
* **실제 앱 네 가지를 한 그룹으로**(이 Mac의 macOS 앱, iPhone·iPad 시뮬레이터, Android 16 에뮬레이터, Windows 11 ARM64 VM):
  각 플랫폼에서 복사한 클립이 나머지 모두에 도착 — Mac → Windows 클립보드·Android·iPhone, Windows → Mac 클립보드·Android·iPhone,
  Android 공유 → Mac·Windows 클립보드·iPhone, iPhone 붙여넣기 버튼 → Mac·Windows 클립보드·Android
* Bonjour/mDNS 기기 찾기: Mac끼리, Mac ↔ iOS, Mac ↔ Windows(Parallels 네트워크 경유), Android → Mac. 코드 연결 시 두 화면의 6자리 코드 일치.
  암호 관리자 항목 제외(macOS concealed 타입, Android `EXTRA_IS_SENSITIVE` 기기 테스트)
* **실제 앱의 원격 연결**(테스트용 Tailscale 조정 서버 사용 — tsnet·WireGuard·DERP 코드는 실제 그대로, 조정 서버만 로컬):
  macOS 앱, iPhone 시뮬레이터, Android 16 에뮬레이터, Windows 11 ARM64 VM 모두 *켜짐 · ‹계정›*을 표시하고, LAN으로는 닿지 않는
  기기를 *연결됨 · 원격*으로 보여 주며 그 기기의 클립을 받음(Windows는 클립보드까지 확인). iPhone은 14초간 백그라운드에 있다가
  돌아와도 다시 *원격*으로 연결됨
* **실제 Tailscale 서비스**(login.tailscale.com, 실제 계정, `tools/acceptance/real_remote.py`): macOS 앱과 Android 앱(에뮬레이터)이
  로그인해 *켜짐 · ‹계정›*과 테일넷 주소를 표시함. LAN 경로를 없앤 뒤 서로를 *연결됨 · 원격*으로 표시했고, Mac → Android,
  Android → Mac(Mac 클립보드까지) 양방향으로 클립이 도착했으며, 두 노드 모두 직접 WireGuard 경로를 사용함. 각 앱의
  *Tailscale에서 로그아웃*으로 노드가 오프라인·키 만료 상태가 됨.
  **아직 검증하지 않은 것:** 서로 다른 실제 네트워크(두 노드가 같은 공유기 뒤에 있어 인터넷을 건너는 NAT 통과와 DERP 중계는
  확인하지 못함), 실제 서비스에서의 iPhone·Windows, 모바일 데이터의 휴대폰, 배터리 사용량
* UI: 모든 주요 화면을 라이트/다크 × 영어/한국어로 캡처 — [docs/screenshots](docs/screenshots)

## 다운로드

`dist/`(로컬 빌드, 저장소에는 미포함): `Nearclip-macOS.zip`(유니버설, ad-hoc 서명), `Nearclip-Windows-arm64.zip` /
`Nearclip-Windows-x64.zip`(자체 포함, 압축을 풀고 `Nearclip\Nearclip.exe` 실행), `Nearclip-Android.apk`(로컬 디버그 키로 서명한
릴리스 빌드). iOS는 Xcode에서 본인 팀으로 빌드해 설치하세요. 내장 Tailscale 노드 때문에 플랫폼마다 약 20MB가 늘었습니다.


## 제한 사항

* 원격 연결을 켜지 않으면 모든 기기가 **같은 로컬 네트워크**에 있어야 합니다. 기기 간 통신이나 mDNS를 막는 게스트·회사 Wi‑Fi에서는
  *주소로 연결*을 사용하세요. 원격 연결에는 각 기기에 (무료) Tailscale 계정 로그인이 필요합니다. 직접 경로를 만들 수 없으면
  Tailscale 중계(DERP)를 거치며, 이때도 종단 간 암호화는 유지되지만 느려질 수 있습니다. 접근 규칙(ACL)을 따로 정한 테일넷은
  내 기기 사이의 TCP 45821을 허용해야 하고, 기기 승인을 켠 테일넷은 관리 콘솔에서 Nearclip 기기를 승인해야 합니다.
* iOS는 앱이 열려 있을 때만 동기화합니다(iOS는 백그라운드 클립보드 접근을 허용하지 않음). 열면 즉시 밀린 내용을 받고 최신 클립을 자동으로 복사할 수 있습니다.
  원격 연결도 마찬가지로 앱이 열려 있는 동안 동작합니다.
* Nearclip에서 Tailscale 로그아웃은 Tailscale 공식 앱과 같게 동작합니다. 기기 키가 만료되고, Tailscale 관리 콘솔에서 직접
  삭제하기 전까지는 (만료된 기기로) 목록에 남습니다.
* Android의 기본 보내기 방식은 앱 열기·빠른 설정 타일·알림 버튼·공유 시트·텍스트 선택 메뉴입니다.
  설정의 *복사한 항목 바로 Nearclip에 불러오기*를 선택하면 Shizuku 설치·시작·허용 안내 후 텍스트와 링크를 백그라운드에서 즉시 보낼 수 있습니다.
  기본은 꺼져 있으며 원하는 사람만 켭니다. 루팅하지 않은 기기는 재부팅 후 Shizuku를 다시 시작해야 합니다.
  Android 12 이상에서는 복사할 때 Shell의 클립보드 접근 알림이 표시될 수 있습니다. 민감한 정보로 표시된 항목은 제외하고,
  사진은 기존 보내기 방식을 사용합니다. 받기는 백그라운드에서 됩니다.
* 기기 제거는 협조적으로 이뤄집니다. 키를 완전히 바꾸려면 나머지 기기에서 그룹을 나간 뒤 다시 연결하세요.
* 아직 공개 배포용 코드 서명은 하지 않았습니다. 내려받은 사본은 macOS Gatekeeper와 Windows SmartScreen이 경고하며,
  Windows 빌드는 설치 프로그램(MSIX) 없이 폴더째 실행하는 형태입니다. Windows 첫 실행 때 방화벽 허용을 묻는데,
  Nearclip은 온보딩과 설정에서 방화벽 상태와 *허용…* 버튼을 보여 줍니다.

## 서드파티 소프트웨어

원격 연결에는 오픈소스 소프트웨어가 들어 있습니다: Tailscale(BSD-3-Clause), wireguard-go(MIT), gVisor(Apache-2.0),
Go 표준 라이브러리(BSD-3-Clause)와 그 밖의 Go 모듈. 라이선스 전문은 [tailnet/notices/THIRD_PARTY_NOTICES.txt](tailnet/notices/THIRD_PARTY_NOTICES.txt)와
각 앱의 정보 › 오픈소스 라이선스에서 볼 수 있습니다.

Android의 선택 기능인 즉시 불러오기는 Shizuku API(MIT)와 Android Hidden API Bypass(Apache-2.0)를 사용합니다.
라이선스 전문은 Android 앱의 설정 › 오픈소스 라이선스에서 볼 수 있습니다.

## 라이선스

MIT © 2026 ivLis Studio

