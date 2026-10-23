<p align="center"><img src="design/out/nearclip-512.png" width="128" alt="Nearclip"></p>

<h1 align="center">Nearclip</h1>
<p align="center"><b>여기서 복사하고, 저기서 붙여넣기.</b><br>Mac · Windows · Android · iPhone을 위한, 로컬 네트워크 밖으로 나가지 않는 유니버설 클립보드</p>

<p align="center"><a href="README.md">English</a></p>

---

한 기기에서 복사하면 다른 모든 기기에서 붙여넣을 수 있습니다. Nearclip은 같은 Wi‑Fi에 있는 내 기기들의 클립보드와
검색 가능한 공유 기록을 동기화합니다. **서버도 계정도 없습니다.** 기기들은 Bonjour/mDNS로 서로를 찾아 TCP로 직접
통신하고, 모든 내용은 내 기기만 가진 키로 **종단 간 암호화**됩니다.

| | macOS | Windows | Android | iOS / iPadOS |
|---|---|---|---|---|
| 앱 형태 | 메뉴 막대 앱 + Spotlight 스타일 패널 | 트레이 앱 + Win+V 스타일 플라이아웃 | Material 3 앱 + 백그라운드 서비스 | SwiftUI 앱 |
| 언어 / UI | Swift · SwiftUI + AppKit | C# · WinUI 3 (Windows App SDK) | Kotlin · Jetpack Compose | Swift · SwiftUI |
| 보내기 | 복사하면 자동 | 복사하면 자동 | 앱 열기 · 빠른 설정 타일 · 알림 · 공유 시트 · 텍스트 선택 메뉴 | 붙여넣기 버튼 / 열 때 자동 |
| 받기 | 자동 (+알림) | 자동 (+알림) | 백그라운드에서 자동 | 앱이 열려 있을 때 (+열면 밀린 내용 수신) |
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
* 모든 기기에 **공유 기록**: 검색, 필터(텍스트·링크·이미지·고정됨), 고정, 모든 기기에서 삭제
* **계정 없는 연결**: 휴대폰으로 QR 코드 스캔(시스템 카메라도 가능), 또는 주변 컴퓨터를 골라 두 화면의 6자리 코드를 비교.
  연결된 기기라면 어느 기기에서든 새 기기를 추가할 수 있습니다.
* **메시 동기화**: 닿는 모든 기기끼리 연결하고 받은 클립을 전달하므로, 일부만 연결돼도 결국 모두 같아집니다.
  잠시 떨어져 있던 기기는 돌아오면 최근 7일치를 받아옵니다.
* **개인정보 보호**: 암호 관리자가 비공개로 표시한 항목은 동기화하지 않음, 컴퓨터에서 앱별 제외 목록, 일시정지, 모든 기기에서 삭제
* **플랫폼다운 완성도**: macOS 26+ Liquid Glass, Windows 11 Mica, Android Material You, iOS SwiftUI · 라이트/다크 · 한국어/영어 ·
  키보드 중심 데스크톱 패널(Mac ⌃⌘V, Windows Win+Alt+V)

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
* 제품·UX 결정은 [docs/DESIGN.md](docs/DESIGN.md)에 정리했습니다.

## 빌드와 실행

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
| **구현 간 상호 운용**(Swift × Kotlin × C#, 30개 시나리오) | `python3 tools/interop/run.py` |
| iOS UI 흐름(온보딩 → 연결 → 밀린 내용 → 보내기) | `xcodebuild test -scheme NearclipiOS …` (`apple/iOSUITests`) |
| macOS 실사용 데모(실제 앱 + 가상 기기) | `python3 apple/tools/demo.py` |

## 검증한 내용

* **엔진**: Swift 테스트 10개, Kotlin 22개, C# 26개 — `spec/test-vectors.json`의 모든 값과 실제 localhost 연결·동기화 시나리오
* **상호 운용**: `tools/interop/run.py` **30/30 통과** (Swift × Kotlin × C#: 모든 방향의 QR·코드 연결, 한글+이모지 실시간 텍스트,
  여러 조각으로 나뉜 이미지, 모든 기기에서 삭제, 재시작 후 밀린 내용 수신, 기기 제거, 제거된 기기 다시 추가, 모든 순열의 3단 메시 전달)
* **실제 앱 네 가지를 한 그룹으로**(이 Mac의 macOS 앱, iPhone·iPad 시뮬레이터, Android 16 에뮬레이터, Windows 11 ARM64 VM):
  각 플랫폼에서 복사한 클립이 나머지 모두에 도착 — Mac → Windows 클립보드·Android·iPhone, Windows → Mac 클립보드·Android·iPhone,
  Android 공유 → Mac·Windows 클립보드·iPhone, iPhone 붙여넣기 버튼 → Mac·Windows 클립보드·Android
* Bonjour/mDNS 기기 찾기: Mac끼리, Mac ↔ iOS, Mac ↔ Windows(Parallels 네트워크 경유), Android → Mac. 코드 연결 시 두 화면의 6자리 코드 일치.
  암호 관리자 항목 제외(macOS concealed 타입, Android `EXTRA_IS_SENSITIVE` 기기 테스트)
* UI: 모든 주요 화면을 라이트/다크 × 영어/한국어로 캡처 — [docs/screenshots](docs/screenshots)

## 다운로드

`dist/`(로컬 빌드, 저장소에는 미포함): `Nearclip-macOS.zip`(유니버설, ad-hoc 서명), `Nearclip-Windows-arm64.zip` /
`Nearclip-Windows-x64.zip`(자체 포함, `Nearclip.exe` 실행), `Nearclip-Android.apk`(로컬 디버그 키로 서명한 릴리스 빌드).
iOS는 Xcode에서 본인 팀으로 빌드해 설치하세요.


## 제한 사항

* 모든 기기가 **같은 로컬 네트워크**에 있어야 합니다(설계상 인터넷 중계 없음). 기기 간 통신이나 mDNS를 막는 게스트·회사 Wi‑Fi에서는
  *주소로 연결*을 사용하세요.
* iOS는 앱이 열려 있을 때만 동기화합니다(iOS는 백그라운드 클립보드 접근을 허용하지 않음). 열면 즉시 밀린 내용을 받고 최신 클립을 자동으로 복사할 수 있습니다.
* Android 10 이상은 화면에 떠 있는 앱만 클립보드를 읽을 수 있어서, 보낼 때는 앱·빠른 설정 타일·알림 버튼·공유 시트·텍스트 선택 메뉴를 씁니다. 받기는 백그라운드에서 됩니다.
* 기기 제거는 협조적으로 이뤄집니다. 키를 완전히 바꾸려면 나머지 기기에서 그룹을 나간 뒤 다시 연결하세요.
* 아직 공개 배포용 코드 서명은 하지 않았습니다. 내려받은 사본은 macOS Gatekeeper와 Windows SmartScreen이 경고하며,
  Windows 빌드는 설치 프로그램(MSIX) 없이 폴더째 실행하는 형태입니다. Windows 첫 실행 때 방화벽 허용을 묻는데,
  Nearclip은 온보딩과 설정에서 방화벽 상태와 *허용…* 버튼을 보여 줍니다.

## 라이선스

MIT © 2026 ivLis Studio

