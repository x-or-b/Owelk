# Owelk for iPad (native)

데스크톱 Owelk(Qt)의 폴더 동기화에 **컴퓨터 한 대로 참여하는 iPad 뷰어**입니다. SwiftUI + UIKit + PDFKit만 쓰고, 외부 패키지는 쓰지 않습니다. 데스크톱은 그대로 Qt이며, 예전 Qt iPad 빌드는 `ipad` 브랜치(`Owelk-ipad` 작업 폴더)에 예비로 남아 있습니다.

## v1에서 되는 것

- 동기화 폴더 고르기: 파일 앱에서 Synctrain이 맞추는 `Owelk` 폴더(또는 그 위 폴더)를 고릅니다. 접근 권한은 북마크로 기억합니다. iPadOS는 다른 앱의 폴더가 바뀌어도 알려 주지 않으므로, 앱이 앞으로 올 때, 앞에 있는 동안 30초마다, 목록을 당겨 새로 고칠 때 다시 읽습니다.
- 라이브러리: 제목·저자·연도·읽기 상태·태그, Collections(중첩)와 Tags, Recent(어느 컴퓨터에서 열었든), 제목·저자 검색, 정렬(Last Opened·Title·Date Added). PDF가 아직 도착하지 않은 논문은 흐리게 "Waiting for the PDF".
- 읽기: PDFKit의 스크롤·확대·글자 선택과 복사, 쪽 썸네일, 목차, 논문 안 찾기(⌘F).
- 주석 보기(읽기 전용): 컴퓨터에서 단 하이라이트·코멘트·텍스트 상자·그림·펜·영역을 같은 자리·같은 모양으로 그립니다. 노트가 있는 표시를 누르면 노트를 보여 줍니다. 원본 PDF에는 아무것도 쓰지 않습니다(메모리에서만 그림).
- 써 보내는 것은 둘뿐: 읽던 위치(`reading_positions`)와 연 시각(`recent_documents`). iPad 자기 폴더 `devices/<iPad ID>/`에만 씁니다. Mac에서 그 논문을 열면 iPad에서 읽던 쪽으로 갑니다.

다음 단계(PencilKit 펜·하이라이트 쓰기, 지우개·실행 취소, 노트, AI)는 [docs/NEXT.md](../docs/NEXT.md)에 있습니다.

## 구조

| 파일 | 하는 일 |
| --- | --- |
| `Owelk/Sync/SyncProtocol.swift` | 변경 줄 형식, 표와 키, 버전 비교(나중 시각, 같으면 큰 기기 ID) |
| `Owelk/Sync/SyncState.swift` | 모든 컴퓨터의 변경을 합친 행들(나중 것 우선)과 파일별로 읽은 위치, 시작을 빠르게 하는 스냅숏 |
| `Owelk/Sync/SyncFolder.swift` | 폴더 읽기(파일은 늘기만 하므로 읽은 곳부터, 끝나지 않은 줄은 기다림)와 쓰기(256KB에서 다음 파일, 줄 단위) |
| `Owelk/Sync/SyncEngine.swift` | 동기화 한 번(읽기 → 쓰기 → 도착한 PDF), iPad가 쓰는 행 만들기 |
| `Owelk/Library/` | 논문(같은 SHA-256의 `documents` 행은 한 논문), Collections·Tags·Recent·읽던 위치, UI가 보는 저장소 |
| `Owelk/Reader/` | PDF 화면, 주석 그리기와 쪽 좌표 변환, 목차·찾기 |
| `Owelk/Views/` | 라이브러리 화면 |

데스크톱과 맞춘 규칙(`src/LibrarySync.cpp`):

- iPad에는 데이터베이스가 없습니다. 모든 컴퓨터의 변경 파일을 합친 것이 곧 상태라서, **자기 폴더도 함께 읽습니다**(다시 켜도 자기가 쓴 위치를 기억).
- `SyncState.schema`를 올리면 스냅숏을 버리고 모든 기록을 처음부터 다시 읽습니다(데스크톱의 "업데이트 후 첫 동기화는 다시 읽기"와 같음). 읽는 표나 열을 늘리면 올립니다.
- iPad가 쓰는 행은 **받은 행을 그대로 두고 아는 열만 바꿉니다.** 위치 JSON도 `page`·`y`만 바꾸고 Mac의 `zoom`·`fit`·`x`는 그대로 둡니다. 데스크톱은 받은 행에 있는 열만 고치므로 모르는 열은 지워지지 않습니다.
- 쓰는 시각은 그 행의 지금 버전보다 항상 뒤(`max(지금, 이전 + 1)`)라서, iPad 시계가 조금 늦어도 바뀐 위치가 지지 않습니다.
- 문서 ID는 그 SHA-256의 행 중 가장 작은 ID입니다. 컴퓨터들이 같은 PDF를 합칠 때 남기는 ID라서, 다른 ID로 알고 있는 컴퓨터도 별칭으로 맞춥니다. 재키(rekey)는 하지 않습니다.
- 주석 좌표는 "보이는 쪽(크롭 박스, /Rotate 적용)의 왼쪽 위에서의 비율"이고, `PageGeometry`는 `src/AnnotatedPdf.cpp`의 `Page::point`와 같은 식으로 PDF 좌표로 바꿉니다.

## 빌드와 테스트

저장소 맨 위 폴더에서 실행합니다.

```bash
xcodebuild build -project ios/Owelk.xcodeproj -scheme Owelk -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' -derivedDataPath build-native-ios
```

```bash
xcodebuild test -project ios/Owelk.xcodeproj -scheme Owelk -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' -derivedDataPath build-native-ios
```

시뮬레이터가 "runtime is not available"로 켜지지 않으면 `killall -9 com.apple.CoreSimulator.CoreSimulatorService` 뒤 다시 실행합니다.

`project.pbxproj`는 손으로 쓴 파일이고 `Owelk/`·`OwelkTests/` 폴더와 동기화됩니다(Xcode 16+). 새 Swift 파일은 폴더에 넣기만 하면 됩니다.

### 데스크톱과 같은 파일로 확인

두 구현이 어긋나지 않도록 `tests/data/sync`를 함께 씁니다.

- `mac/Owelk/`, `mac/expected.json`: 데스크톱 코드가 만든 동기화 폴더와 그 라이브러리 내용. iPad 테스트(`OwelkTests/ConformanceTests.swift`)가 읽어 같은지 봅니다. 데스크톱 테스트(`sync_conformance`)도 이 폴더를 새 컴퓨터로 다시 읽어 봅니다.
- `ipad/<ID>/`: iPad 코드가 쓴 변경 파일(고정 기기 ID·시각). iPad 테스트는 지금 코드가 같은 파일을 쓰는지, 데스크톱 테스트는 그 파일을 받아 읽던 위치·연 시각이 맞는지 봅니다.

다시 만들기(형식을 일부러 바꿨을 때):

```bash
OWELK_WRITE_SYNC_FIXTURE=1 QT_QPA_PLATFORM=offscreen build/owelk_sync_tests regenerateFixture
```

```bash
TEST_RUNNER_OWELK_WRITE_FIXTURES=1 xcodebuild test -project ios/Owelk.xcodeproj -scheme Owelk -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' -derivedDataPath build-native-ios
```

Mac 쪽을 다시 만들면 문서 ID가 바뀌므로 iPad 쪽도 이어서 다시 만듭니다. 그 뒤 `ctest --test-dir build -R sync_conformance`.

## iPad에 설치

무료 Apple ID(Personal Team `8JHKTUZYV4`)로 서명하므로 7일마다 다시 설치합니다. iPad 잠금을 풀어 둡니다. Bundle ID는 `org.owelk.pad`라 Qt 빌드(`org.owelk.reader`) 옆에 따로 설치됩니다.

```bash
xcodebuild build -project ios/Owelk.xcodeproj -scheme Owelk -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build-native-ios -allowProvisioningUpdates -allowProvisioningDeviceRegistration
```

```bash
xcrun devicectl device install app --device 00008112-0005591C2123601E build-native-ios/Build/Products/Release-iphoneos/Owelk.app
```

처음 실행 전에 iPad 설정 › 일반 › VPN 및 기기 관리에서 개발자 앱을 신뢰해야 할 수 있습니다.

## 쓰는 법

1. Mac의 Syncthing에서 Owelk 동기화 폴더를 iPad(Synctrain)와 공유합니다. Synctrain에서는 **Send & Receive**로 받고, PDF까지 모두 받도록 둡니다.
2. 앱을 처음 켜면 **Choose Sync Folder…** → 파일 앱의 나의 iPad › Synctrain 아래 그 폴더를 고릅니다. 고른 폴더에 `owelk-sync.json`이 있거나 그 안의 `Owelk` 폴더에 있으면 됩니다. Qt 앱이 보여 주는 나의 iPad › Owelk는 다른 폴더입니다.
3. 폴더를 바꾸려면 왼쪽 열 위의 폴더 버튼을 누릅니다. 왼쪽 열 아래에 마지막 동기화 시각과 함께 쓰는 컴퓨터 이름이 보입니다.

인터페이스 글자는 영어만 있습니다(데스크톱의 한글 표기 도구 `tools/hangul.py`는 아직 적용하지 않음).
