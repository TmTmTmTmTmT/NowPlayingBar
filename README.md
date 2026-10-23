# NowPlayingBar

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

**지금 재생 중인 곡**을 보여 주는 macOS 메뉴 막대 위젯입니다. 위젯을 클릭하면 Liquid Glass
컨트롤 카드가 열립니다. 표시할 재생 앱(Apple Music, Safari, Spotify 등)을 고를 수 있고,
긴 제목은 **왼쪽으로 천천히 흐르며(마퀴)** 전체를 보여 줍니다.

![메뉴 막대 위젯](docs/menubar.png)

![컨트롤 카드](docs/card.png)

## 기능

- **메뉴 막대 제목** — 재생 중인 앱의 곡 제목을 표시하고, 긴 제목은 마퀴로 흐릅니다. 일시정지하면 흐리게 표시됩니다.
- **재생 앱 필터** — 선택한 앱만 표시하고, 새로 재생한 앱은 목록에 자동으로 추가됩니다.
- **표시 옵션** — 아티스트, 앨범, 일시정지 시 숨기기, 위젯 너비(프리셋 또는 80~600pt 직접 입력), 스크롤 속도.
- **컨트롤 카드** (위젯 왼쪽 클릭) — 앨범 커버, 제목·아티스트·앨범, 재생/일시정지, 이전/다음, 클릭·드래그로 이동하는 재생 막대. 커버를 클릭하면 재생 앱이 열립니다.
- **버튼 하이라이트** — 버튼에 포인터를 올리면 원형 강조가 나타나고, 누르면 더 진해지며 살짝 커집니다. HDR을 지원하는 화면(다크 모드)에서는 누르는 순간 일반 흰색보다 밝게 빛납니다.
- **셔플·반복 버튼** (옵션) — 재생 앱에 토글 명령을 보냅니다. Apple Music은 현재 상태(켜짐은 파란색, 한 곡 반복은 `repeat.1` 아이콘)도 표시합니다.
- **Liquid Glass 선택** — 카드를 Regular(기본) 또는 Clear로 바꿉니다. Clear는 더 투명한 유리에 뒤 화면 블러를 더하고, 버튼과 제목은 또렷하게, 앨범 커버는 85% 투명도로 보여 줍니다(끄면 100%).

## 요구 사항

- macOS 26 이상 (Liquid Glass 컨트롤 카드).
- Xcode 26 또는 macOS 26 SDK가 있는 Command Line Tools (Swift 5.9 이상). Homebrew는 빌드에 필요하지 않습니다.

## Homebrew로 설치

```sh
brew install TmTmTmTmTmT/tap/nowplayingbar
open "$(brew --prefix)/opt/nowplayingbar/NowPlayingBar.app"
```

Homebrew가 내 Mac에서 소스를 직접 빌드하므로 Command Line Tools(`xcode-select --install`)와
macOS 26 이상이 필요합니다. 응용 프로그램 폴더에 두려면
`cp -R "$(brew --prefix)/opt/nowplayingbar/NowPlayingBar.app" /Applications/` 를 실행하세요.
업데이트는 `brew upgrade nowplayingbar`, 삭제는 `brew uninstall nowplayingbar` 입니다
(설정은 남으며, `defaults delete com.local.nowplayingbar` 로 지울 수 있습니다).

## 직접 빌드해서 실행

```sh
git clone https://github.com/TmTmTmTmTmT/NowPlayingBar.git
cd NowPlayingBar
chmod +x build-app.sh
./build-app.sh
open build/NowPlayingBar.app
```

터미널에서 로그를 보면서 실행하려면:

```sh
./build/NowPlayingBar.app/Contents/MacOS/NowPlayingBar
```

앱은 메뉴 막대에만 있습니다(Dock 아이콘 없음). 허용한 앱에서 곡이 재생되기 전에는 아무것도 표시되지 않습니다.

## 사용법

- **왼쪽 클릭** — 컨트롤 카드를 열거나 닫습니다.
- **오른쪽 클릭**(또는 Control-클릭) — 옵션 메뉴를 엽니다.
  - **Sources** — `Show all sources` 와 앱별 체크박스. 체크한 앱만 메뉴 막대에 표시됩니다.
  - **Display**
    - `Show artist` — 제목 뒤에 `— 아티스트` 를 붙입니다.
    - `Show album` — 제목 뒤에 `— 앨범` 을 붙입니다(아티스트가 켜져 있으면 그 뒤).
    - `Hide when paused` — 실제로 재생 중일 때만 표시합니다. 끄면 일시정지 중에는 제목이 흐리게 보입니다.
    - `Width` — 이 너비보다 긴 제목은 흐르고, 짧으면 멈춰 있습니다. Narrow 120 · Medium 176 · Wide 240 · Extra wide 320 pt, 또는 `Custom…`(80~600pt).
    - `Scroll speed` — Slow / Medium / Fast.
    - `Liquid Glass` — `Regular` / `Clear` 중 선택하고, 아래 두 항목으로 Clear일 때 앨범 커버를 85%로 투명하게 할지, 뒤 화면 블러를 없애 순수한 투명 유리로 할지 정합니다. 선택해도 메뉴가 닫히지 않습니다.
    - `Show shuffle & repeat` — 컨트롤 카드에 셔플·반복 버튼을 추가합니다(카드 너비가 320에서 360pt로 늘어남). 각 버튼은 재생 앱에 토글 명령을 보냅니다. Apple Music은 현재 상태도 표시하며, 파란색은 켜짐, `repeat.1` 아이콘은 한 곡 반복입니다. 다른 앱은 상태를 표시하지 않습니다.
  - **Quit** (⌘Q)

## 권한

Apple Music의 셔플·반복 상태는 AppleScript로 읽기 때문에, `Show shuffle & repeat` 를 켠 채
카드를 처음 열면 macOS가 Music에 대한 **자동화(Automation)** 권한을 요청합니다. 거부해도
버튼은 토글 명령을 보내지만 상태는 표시되지 않습니다. 이 옵션을 켰을 때만 권한을 요청합니다.

권한을 거부했거나 초기화된 경우(앱이 ad-hoc 서명이라 다시 빌드하면 초기화될 수 있습니다)
시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 자동화에서 다시 허용하거나, 아래를 실행하세요.

```sh
tccutil reset AppleEvents com.local.nowplayingbar
```

## 별도 도우미가 필요한 이유

**macOS 15.4** 이후(**macOS 26 "Tahoe"** 포함) Apple의 `mediaremoted` 데몬은 일반 서드파티 앱이
호출하는 비공개 `MediaRemote.framework` 요청을 거부합니다. 시스템 전체의 재생 정보를 얻는
**공개 API는 없습니다**.

유일하게 동작하는 방법은 [**ungive/mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter)
(BSD 3-Clause)입니다. Apple 자체의 `/usr/bin/perl`(코드 서명 ID `com.apple.perl`) 안에서 작은
도우미 프레임워크를 불러와, 데몬의 권한 검사를 통과합니다. SIP 변경이나 시스템 수정은 필요 없고,
도우미는 별도 프로세스로 실행되어 JSON을 출력합니다.

이 프로젝트는 해당 어댑터를 `vendor/mediaremote-adapter/` 에 **포함(vendoring)** 하고 빌드할 때
컴파일합니다. 컴파일된 프레임워크는 앱 번들 안에만 있습니다.

## 재생 앱 필터링 방식

업데이트마다 `bundleIdentifier`(재생을 게시한 프로세스)와
`parentApplicationBundleIdentifier`(소유 앱) 두 ID가 함께 옵니다. **Safari** 에서 재생되는 미디어는
WebKit 하위 프로세스가 게시하므로, 위젯은 부모 ID(`com.apple.Safari`)가 있으면 그것으로 필터링합니다.
그렇지 않으면 Safari 곡이 목록과 맞지 않게 됩니다.

## 프로젝트 구조

```
Package.swift                      SwiftPM 실행 파일
Resources/Info.plist               앱 Info.plist (LSUIElement = 메뉴 막대 전용)
build-app.sh                       clang + swift -> 서명된 .app
docs/                              README 스크린샷
Sources/NowPlayingBar/
  main.swift                       진입점, 리소스 경로 결정
  NowPlayingInfo.swift             모델 + JSON / AppleScript 출력 파서
  NowPlayingMonitor.swift          perl 어댑터 실행, 업데이트 스트림, 명령 전송
  Preferences.swift                재생 앱 허용 목록 + 옵션 (UserDefaults)
  MarqueeView.swift                Core Animation 마퀴
  StatusContentView.swift          상태 항목 내용 (마퀴 + 크기 계산)
  NowPlayingPopoverController.swift  컨트롤 카드: 커버, 버튼, 재생 막대
  HighlightButton.swift            hover·누름 하이라이트 버튼
  KeepOpenMenu.swift               선택해도 닫히지 않는 메뉴 행
  AppDelegate.swift                상태 항목, 메뉴, 카드 패널, 연결
vendor/mediaremote-adapter/        포함된 BSD-3 도우미 (빌드 때 컴파일)
```

## 주의 사항

- `com.apple.perl` 방식으로 **비공개** 프레임워크에 의존합니다. Apple이 이후 macOS 업데이트에서 막을 수 있습니다(15.4에서 한 번 강화됨). 그렇게 되면 위젯은 표시되지 않은 채로 있습니다.
- 샌드박스를 쓰지 않고 App Store 배포도 불가능합니다(비공개 프레임워크). 개인 사용을 목적으로 ad-hoc 서명으로 빌드합니다.
- 셔플·반복 상태 표시는 Apple Music에서만 동작합니다. 다른 앱은 이 상태를 시스템에 알리지 않습니다.

## 라이선스

이 프로젝트는 MIT 라이선스입니다 — [LICENSE](LICENSE) 참고. `vendor/mediaremote-adapter/` 는
BSD 3-Clause이며, 자체 [LICENSE](vendor/mediaremote-adapter/LICENSE) 를 따릅니다.

## 크레딧

- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) — Now Playing 연동 (BSD 3-Clause).
- 마퀴 기법은 [Jaysce/Jukebox](https://github.com/Jaysce/Jukebox) 에서 영감을 얻었습니다.
