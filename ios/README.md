# Owelk for iPad (native)

데스크톱 Owelk(Qt)의 폴더 동기화에 **컴퓨터 한 대로 참여하는 iPad 뷰어**입니다. SwiftUI + UIKit + PDFKit만 쓰고, 외부 패키지는 쓰지 않습니다. 데스크톱은 그대로 Qt이며, 예전 Qt iPad 빌드는 `ipad` 브랜치(`Owelk-ipad` 작업 폴더)에 예비로 남아 있습니다.

## v1에서 되는 것

- 동기화 폴더 고르기: 파일 앱에서 Synctrain이 맞추는 `Owelk` 폴더(또는 그 위 폴더)를 고릅니다. 접근 권한은 북마크로 기억합니다. iPadOS는 다른 앱의 폴더가 바뀌어도 알려 주지 않으므로, 앱이 앞으로 올 때, 앞에 있는 동안 30초마다, 목록을 당겨 새로 고칠 때 다시 읽습니다.
- 라이브러리: 제목·저자·연도·읽기 상태·태그, Collections(중첩)와 Tags, Recent(어느 컴퓨터에서 열었든), 제목·저자 검색, 정렬(Last Opened·Title·Date Added). PDF가 아직 도착하지 않은 논문은 흐리게 "Waiting for the PDF".
- 읽기: PDFKit의 스크롤·확대·글자 선택과 복사, 쪽 썸네일, 목차, 논문 안 찾기(⌘F).
- 주석 보기: 컴퓨터에서 단 하이라이트·코멘트·텍스트 상자·그림·펜·영역을 같은 자리·같은 모양으로 그립니다. 노트가 있는 표시를 누르면 노트를 보여 줍니다. 원본 PDF에는 아무것도 쓰지 않습니다(메모리에서만 그림).
- 펜(Apple Pencil): 막대의 **Draw**를 켜면 Pencil로 그리고 지우며, 손가락은 그대로 스크롤·확대합니다(끄면 Pencil도 손가락처럼). 아래 막대에서 데스크톱과 같은 여섯 가지 표시 색, 지우개(획 하나씩, Mac에서 그린 획도), 실행 취소·다시 실행을 고르고, 두 손가락으로 탭해도 실행 취소됩니다. Pencil 두 번 탭과 Pencil Pro 쥐기는 설정 › Apple Pencil에서 고른 대로(지우개 전환, 직전 도구, 펜 끝 옆 팔레트) 합니다. 획은 데스크톱처럼 2pt 한 굵기이고, 한 획이 데스크톱의 Pen 표시 하나(`highlights`, `kind` draw)가 됩니다. 지우면 `deleted_at`만 적습니다. PencilKit은 그리는 동안의 획만 보여 주고, 펜을 떼면 그 획은 다른 표시처럼 PDFKit이 그립니다(Mac과 같은 굵기, 확대해도 선명). PencilKit의 한 굵기 잉크는 점 크기 s를 약 2s − 3.5pt로 그리므로, 그리는 동안의 굵기는 그린 획마다 맞춰 2pt가 되게 합니다(`InkWidth`). Draw를 켜 둔 동안 Pencil은 쪽을 움직이지 않습니다.
- 논문 추가: 목록 위 **+ › Add PDFs from Files…**(여러 개 한 번에), 다른 앱(파일, Safari 등)에서 PDF를 목록으로 끌어다 놓기, 또는 **+ › Search the Web…**. 웹 검색은 데스크톱 웹 탭과 같은 엔진(Google Scholar 기본, arXiv·Google·DuckDuckGo)을 쓰고, 주소 칸에 단어·주소·DOI(`10.…`)·arXiv ID(`1706.03762`)를 넣을 수 있습니다. PDF를 보여 주는 쪽에서는 아래 막대의 **Add to Library**, arXiv 초록 쪽에서는 **Open PDF**가 나오고, PDF를 내려받는 링크는 바로 추가됩니다. 학교 로그인 같은 웹 로그인은 앱을 다시 켜도 남습니다. Google Scholar가 사람인지 확인하는 쪽을 보이면 직접 풀면 됩니다. 보고 있던 Collection·Tag에 함께 들어갑니다. PDF는 동기화 폴더 `Papers/<SHA-256>.pdf`로, 논문 행은 iPad 자기 변경 파일로 가고, 컴퓨터는 그 PDF를 원래 파일 이름으로 자기 Library에 복사합니다. 같은 PDF(바이트가 같음)가 이미 있으면 다시 넣지 않고, Library에서 뺐거나 Trash에 있던 것이면 되살립니다. 제목은 PDF가 밝힌 제목(파일 이름·기본값이 아니면) 또는 파일 이름이고, 저자·연도·DOI·arXiv는 컴퓨터가 PDF를 읽어 채웁니다(다음 실행 때나 그 논문을 열 때).
- 써 보내는 것: 읽던 위치(`reading_positions`), 연 시각(`recent_documents`), 추가한 논문(`documents`와 그 PDF, Collection·Tag 소속), 펜 획과 지운 표시(`highlights`). iPad 자기 폴더 `devices/<iPad ID>/`와 `Papers/`에만 씁니다. Mac에서 그 논문을 열면 iPad에서 읽던 쪽으로 갑니다.

다음 단계(Pencil로 글자 하이라이트, 영역·코멘트, 노트, AI)는 [docs/NEXT.md](../docs/NEXT.md)에 있습니다.

## 구조

| 파일 | 하는 일 |
| --- | --- |
| `Owelk/Sync/SyncProtocol.swift` | 변경 줄 형식, 표와 키, 버전 비교(나중 시각, 같으면 큰 기기 ID) |
| `Owelk/Sync/SyncState.swift` | 모든 컴퓨터의 변경을 합친 행들(나중 것 우선)과 파일별로 읽은 위치, 시작을 빠르게 하는 스냅숏 |
| `Owelk/Sync/SyncFolder.swift` | 폴더 읽기(파일은 늘기만 하므로 읽은 곳부터, 끝나지 않은 줄은 기다림)와 쓰기(256KB에서 다음 파일, 줄 단위) |
| `Owelk/Sync/SyncEngine.swift` | 동기화 한 번(읽기 → 쓰기 → 도착한 PDF), iPad가 쓰는 행 만들기 |
| `Owelk/Library/` | 논문(같은 SHA-256의 `documents` 행은 한 논문), Collections·Tags·Recent·읽던 위치, UI가 보는 저장소, 추가하는 PDF(`NewPaper.swift`) |
| `Owelk/Reader/` | PDF 화면, 옆의 쪽 그림(`PageList.swift`), 주석 그리기와 쪽 좌표 변환, 목차·찾기, Pencil 펜·지우개(`PenLayer.swift`: 화면에 보이는 쪽마다 얹는 층. 표시를 벡터 도형으로 그리고, Draw 중에만 PencilKit 캔버스를 두며, 지우개와 실행 취소를 맡음) |
| `Owelk/Views/` | 라이브러리 화면(논문 추가·끌어다 놓기), 웹 검색(`WebSearch.swift`) |

데스크톱과 맞춘 규칙(`src/LibrarySync.cpp`):

- iPad에는 데이터베이스가 없습니다. 모든 컴퓨터의 변경 파일을 합친 것이 곧 상태라서, **자기 폴더도 함께 읽습니다**(다시 켜도 자기가 쓴 위치를 기억).
- `SyncState.schema`를 올리면 스냅숏을 버리고 모든 기록을 처음부터 다시 읽습니다(데스크톱의 "업데이트 후 첫 동기화는 다시 읽기"와 같음). 읽는 표나 열을 늘리면 올립니다.
- 새로 추가한 논문의 행은 데스크톱이 보내는 `documents` 열을 모두 담습니다. `url`은 파일 이름만 뜻이 있고(`file:///<이름>.pdf`, 각 컴퓨터가 자기 보관 위치로 바꿈), `metadata_origin`을 비워 두어 컴퓨터가 PDF에서 정보를 읽게 합니다. PDF는 다른 이름으로 다 쓴 뒤 `Papers/<SHA-256>.pdf`로 바꾸므로 Synctrain이 반쯤 쓴 파일을 보내지 않습니다.
- iPad가 쓰는 행은 **받은 행을 그대로 두고 아는 열만 바꿉니다.** 위치 JSON도 `page`·`y`만 바꾸고 Mac의 `zoom`·`fit`·`x`는 그대로 둡니다. 데스크톱은 받은 행에 있는 열만 고치므로 모르는 열은 지워지지 않습니다.
- 쓰는 시각은 그 행의 지금 버전보다 항상 뒤(`max(지금, 이전 + 1)`)라서, iPad 시계가 조금 늦어도 바뀐 위치가 지지 않습니다.
- 문서 ID는 그 SHA-256의 행 중 가장 작은 ID입니다. 컴퓨터들이 같은 PDF를 합칠 때 남기는 ID라서, 다른 ID로 알고 있는 컴퓨터도 별칭으로 맞춥니다. 재키(rekey)는 하지 않습니다.
- 주석 좌표는 "보이는 쪽(크롭 박스, /Rotate 적용)의 왼쪽 위에서의 비율"이고, `PageGeometry`는 `src/AnnotatedPdf.cpp`의 `Page::point`와 같은 식으로 PDF 좌표로 바꿉니다. PDFKit이 쪽 위에 얹는 캔버스는 돌리기 전 크롭 박스의 왼쪽 위에서 잰 point라서(돌리기는 PDFKit이 뷰째 함), `OverlayGeometry`가 그 사이를 바꿉니다(`PenTests`가 PDFKit 자체 변환과 맞춰 봄).
- 하이라이트·코멘트·영역·펜 표시는 PDFKit 주석으로 그리지 않고 그 층에 `CAShapeLayer`로 그립니다. PDFKit은 주석을 확대와 상관없이 쪽 1 point당 1 pixel로 그린 뒤 늘려서, 2 pt 펜 선이 확대하면 8 pixel 계단이 됐습니다(`PenTests`의 4배 확대 테스트가 확인). 글상자와 그림은 아직 PDFKit이 그립니다. `MarkAnnotation`은 쪽에 남아 탭·지우개가 찾는 자리입니다.
- Draw 중에는 PDFKit의 제스처(두 번 탭 확대·글자 선택·끌기)를 손가락만 받게 합니다. Pencil로 빠르게 두 번 찍으면 확대되어 화면이 튀었습니다.
- 쪽은 위쪽 바 아래까지 이어지고(SwiftUI 화면이 안전 영역을 무시, PDFKit이 그만큼 안쪽에서 시작), 바 아래 띠(`barBand`)가 iOS 26의 Liquid Glass 가장자리 효과(hard)를 PDF 스크롤 뷰에 직접 요청해(`UIScrollEdgeElementContainerInteraction`), 지나가는 쪽을 흐리게 비추면서 바를 구분합니다. SwiftUI의 바는 SwiftUI 스크롤 뷰에만 효과를 걸어서 PDFKit 스크롤에는 효과가 없었습니다. iOS 18은 흐린 띠와 가는 선입니다. PDFKit은 처음에 첫 쪽을 바 높이만큼 한 번 더 내려 두어서, 저장된 위치가 없으면 스크롤 범위 맨 위로 맞춥니다(`ReaderBarTests`).
- 옆의 쪽 그림은 PDFKit의 `PDFThumbnailView`를 쓰지 않습니다. 그 안의 `PDFIconsView`가 레이아웃할 때마다(획을 그은 뒤, 쪽이 바뀐 뒤, 확대한 뒤, 숨겨 둔 동안에도) `goToPage`를 불러 화면을 현재 쪽 맨 위로 옮겼습니다(2026-11-06 기기 진단 기록의 호출 스택으로 확인). `PageList`는 탭할 때만 쪽을 옮깁니다.

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
- `ipad/<ID>/`: iPad 코드가 쓴 변경 파일(고정 기기 ID·시각·새 논문 ID). iPad 테스트는 지금 코드가 같은 파일을 쓰는지, 데스크톱 테스트는 그 파일을 받아 읽던 위치·연 시각, iPad에서 추가한 논문(제목·파일 이름·복사된 PDF·Collection·Tag)이 맞는지 봅니다.
- `ipad/Papers/`: iPad 테스트가 추가하는 PDF(스스로 밝힌 제목이 있는 한 쪽짜리).

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
3. 폴더를 바꾸거나 바로 동기화하려면 왼쪽 열 위의 Settings(톱니바퀴)를 누릅니다. 마지막 동기화 시각과 함께 쓰는 컴퓨터 이름도 거기 있습니다. 왼쪽 열 아래에는 동기화하는 동안과 실패했을 때만 알림이 보입니다.

인터페이스 글자는 영어만 있습니다(데스크톱의 한글 표기 도구 `tools/hangul.py`는 아직 적용하지 않음).
