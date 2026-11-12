# 기획서 대비 구현 현황

2026-10-18 기준. 현재는 **PDF 리더 + 웹 탭 + 라이브러리 + 주석·노트와 연결 + 단어·의미 검색 + 탭 그룹 + AI 읽기 보조 + 백업·내보내기 + 폴더 동기화**를 갖춘 Research Workspace입니다. 기획서 v0.1–v0.5와 v1 마무리 항목을 구현했습니다. macOS에서 빌드·자동 검증했고, Linux는 Docker(Ubuntu 24.04, ARM64)와 CI로, Windows는 CI로 빌드·테스트합니다(실기기 확인은 남음).

핵심 원칙은 **가볍고 빠름**입니다. 시작할 때 라이브러리를 훑지 않고, 무거운 작업(본문 색인·OCR·의미 벡터·백업)은 낮은 우선순위 배경 스레드에서 읽는 동안 멈추며, 선택 기능(의미 검색·OCR·주석 PDF)은 켜거나 설치하기 전에는 아무 비용이 없습니다.

| 기획서 | 현재 구현 | 남은 범위 |
| --- | --- | --- |
| 1–3. 개요·원칙 | 로컬 저장, 원본 PDF 불변, 출처 검증(SHA-256·파일 스탬프 캐시), 외부 전송은 웹 탭·명시적 조회·동의한 AI·의미 검색 엔진 요청만 | 실제 대형 PDF 성능 실측 |
| 4. 객체 모델 | 공통 Document ID(PDF·웹, 탭에도 저장), 공통 DocumentAnchor(위치·문장 인용, 하나의 이동 경로) | 앵커 저장 형식 통합(현재는 읽을 때 구성) |
| 5–6. 실행·Home | 세션 복원, 비정상 종료 감지·안내·편집 초안 복구, Home 검색·웹 검색·이어 읽기 카드·Collections·최근 논문·노트·AI 대화(마지막으로 연 순서) | — |
| 7–10. 문서·웹·탭 | PDF·암호 PDF·분할·탭 단축키, 웹 탭(진행 막대·프레임 PDF 안내), 이름 있는 탭 그룹(접기·Collection 저장), AI 탭 정리(승인 후 적용) | Reader Mode, 웹 탭 상태 유지, OS 창 분리 |
| 11. 정리 | 라이브러리(Papers·Notes·Trash, Collection·Tag·읽기 상태·중복·색인 제외), 논문·노트·AI 대화를 함께 담는 휴지통, 관련 논문·노트 | Smart Collection |
| 12–16. 검색·커맨드 | FTS5 본문(+OCR), 단어 순서 무관·점수 순위, 범위 칩·검색어 조건, 선택적 의미 검색(Ollama·OpenAI), 명령 팔레트 | — |
| 17–21. 주석·연결 | 5색 주석·코멘트, 영역 표시(캡션 함께), 노트 링크·역링크, 주석 포함 PDF 내보내기(표준 주석). 이전 Captures는 주석·노트로 통합(스키마 15) | Figure 자동 인식 |
| 22–27. 노트·AI | Markdown 노트, AI 5종(Claude API, OpenAI API, ChatGPT 계정(공식 Sign in with ChatGPT: 브라우저 로그인, 답은 ChatGPT 플랜 사용, 갱신 토큰만 키 저장소에), ChatGPT 계정(Codex), Ollama), 모델·추론 강도·Fast, 웹 검색(입력창 아래 지구본, AI 설정마다 기억: ChatGPT 계정·Codex는 처음부터 켜짐, API 키는 검색마다 요금이 붙어 처음엔 꺼짐. 켜져 있으면 각 AI의 자체 검색을 쓸지는 AI가 질문마다 판단(최근 연구·논문 이후 방법·자료에 없는 사실은 예시일 뿐)하고 웹 출처는 링크로 답함, Codex는 `web_search="live"`(끄면 "disabled"), OpenAI·ChatGPT 계정은 `web_search` 도구, Claude는 `web_search_20260209`(이전 모델은 `web_search_20250305`) 5번까지·링크 없이 인용한 페이지는 답 끝 Sources에, 검색어는 생각 줄에 "Searching the web: …", Ollama는 없음, 보낸 질문에 Web search 칩), 이미지·PDF/웹 영역 첨부(저장 안 함), Threads 패널(채팅 폴더: 논문별 자동 생성·직접 만들기·끌어 옮기기, 최근순·Manual 정렬(Manual은 끌어서 대화·Thread 순서를 정하고, 그 순서는 대화·Thread의 position 열로 다른 컴퓨터와 동기화, 새 것은 맨 위), 검색), 채팅에 여러 논문(3편까지 전문, 그 이상과 Collection은 논문마다 개요(색인에서 첫 부분(초록·서론)과 결론, 논문당 최대 4,000자 + 2,000자, 40편까지)와 질문에 맞는 구절. 그래서 "전부 요약해줘"처럼 주제어가 없는 질문도 모든 논문에 닿음. 답의 Sources에는 인용한 것만. 칩 옆 Read each paper in full(2~8편)을 켜면 그 질문 하나만 논문마다 따로 요청해 본문(편당 8만 자까지)을 읽고 질문에 맞춘 메모(쪽 인용 포함)를 받은 뒤 그 메모로 답함: 동시에 3편(Ollama는 1편), 진행 표시 "Reading each paper in full · 2 of 5 done", Stop은 읽는 중인 것까지 모두 멈춤, 답의 인용은 각 논문의 그 쪽으로 이동)·Collection·라이브러리 전체 첨부, 노트 첨부와 AI 노트 제안(고친 노트·새 노트를 카드로 보여 주고 Apply/Create를 눌러야 저장, Undo), 선호 언어, 논문 비교표, 쪽별 번역·논문 요약, 탭·Collection AI 정리 | 라이브러리 전체에 묻기(v0.6) |
| 28–32. 데이터·기술 | C++20 + Qt Quick/PDF/WebEngine, 공유 폴더를 통한 컴퓨터 간 동기화(Google Drive·Dropbox·Syncthing, 항목별 나중 변경 우선), SQLite(라이브러리 스키마 21, 색인 5, 업그레이드 전 백업), 백업·복원, Markdown·BibTeX 내보내기, 단축키 변경, macOS·Linux·Windows 키 저장소, 로컬 설치 스크립트(macOS·Linux `install-local.sh`, Windows `install-local.ps1`, 모두 `tools/qt.txt`의 Qt 6.11.3 하나로 고정), Docker 빌드·테스트, 자동 테스트 9묶음(동기화 호환 포함)과 iPad XCTest | Linux/Windows 실기기, 배포 패키지 |

## 우선순위

가볍고 빠름을 먼저 지키고, 기획서 순서보다 실제 사용 중 불편한 부분을 먼저 고칩니다. 기능별 사용법은 [README](../README.md)와 각 문서에, 변경 이력은 git 로그에 있습니다.

## 이번 단계 (2026-11-05): iPad 앱을 새로(네이티브)

Qt로 옮긴 iPad 빌드는 스크롤·확대·Pencil·글자 선택·키보드를 QML로 다시 만들어야 해서 기기에서 느리고 어긋났습니다. 그래서 iPad는 SwiftUI + PDFKit 앱(`ios/`, bundle ID `org.owelk.pad`)으로 새로 시작해 단계별로 기능을 붙입니다. 데스크톱은 Qt 그대로이고, Qt iPad 빌드는 `ipad` 브랜치에 예비로 남겨 둡니다.

- v1은 동기화 중심 뷰어입니다. Synctrain이 맞추는 `Owelk` 폴더를 파일 앱에서 고르면 라이브러리(제목·저자·읽기 상태·Collection·Tag·검색, 기본 정렬은 어느 컴퓨터에서든 마지막으로 연 순서)와 PDF(PDFKit 스크롤·확대·썸네일·찾기·글자 선택 복사)를 보여 주고, 컴퓨터에서 단 주석을 같은 자리에 그립니다(누르면 노트). iPad는 읽던 위치와 연 시각을 자기 `devices/<iPad ID>/`에 써서 Mac이 이어 읽게 합니다. 사용법과 구조: [ios/README.md](../ios/README.md), 동기화: [SYNC.md](SYNC.md#ipad).
- 논문 추가: 파일 앱에서 고르기, 다른 앱에서 끌어다 놓기, 웹 검색(데스크톱 웹 탭과 같은 Google Scholar·arXiv·Google·DuckDuckGo, PDF 쪽의 Add to Library, 내려받는 PDF는 바로). PDF는 동기화 폴더 `Papers/`로, 논문 행(데스크톱이 보내는 열 모두, 정보 읽기는 컴퓨터에 맡김)은 iPad 변경 파일로 가며 보고 있던 Collection·Tag에 들어갑니다. 같은 PDF는 다시 넣지 않고, Library에서 뺀 것은 되살립니다.
- 하이라이트·코멘트: 고른 글자를 메뉴의 Highlight·Comment…로 표시하고(데스크톱과 같은 행, Mac의 sync_conformance가 읽어 봄), 표시를 누르면 노트(Scribble)·색을 바꾸거나 지웁니다. Annotations 목록은 이 논문의 표시를 쪽 순서로 보여 주고 누르면 그 자리로, 밀면 지웁니다(실행 취소 가능). 기기에서 써 보기는 아직.
- 노트: 왼쪽 열 Notes(찾기·새 노트·Trash)와 리더의 이 논문 노트. 데스크톱이 이미 동기화하던 `notes`·`links` 표를 iPad도 읽고 씁니다(iPad 동기화 스키마 2: 처음 켤 때 기록을 다시 읽음). Mac의 sync_conformance가 iPad의 노트와 링크를 읽어 봅니다.
- AI: 리더 막대의 AI 패널에서 논문에 묻기·세 줄 요약, 고른 글자 Explain·Ask AI…. 데스크톱과 같은 프롬프트(언어·수준·쪽 인용)이고 인용을 누르면 그 쪽으로. Claude API·OpenAI API 키(iPad 키체인). 기기에서 써 보기는 아직(키가 있어야 함).
- 라이브러리 정리: 왼쪽 열에 Favorites·Reading·Annotated, 논문을 밀어 Favorites, 길게 눌러 읽기 상태·Tags·Collections(새로 만들기 포함). 바뀐 것은 데스크톱이 쓰는 열·표로 보내고 Mac의 sync_conformance가 읽어 봅니다.
- 펜: 그리는 동안의 잉크도 다 그린 표시와 같은 벡터 도형이라 확대해도 그리는 내내 선명합니다(PencilKit 대신 리더 자체 Pencil 제스처).
- 형광펜: Draw의 아래 막대에서 펜과 형광펜을 고르고, 형광펜으로 글줄을 따라가면 지나간 글자가 하이라이트됩니다(데스크톱과 같은 글자 하이라이트). Draw 중에도 손가락으로 쪽을 끌 수 있습니다.
- Apple Pencil 펜: Draw를 켜면 Pencil로 그리고 지우고(손가락은 스크롤·확대), 데스크톱 표시 색 여섯 가지·획 지우개·실행 취소(두 손가락 탭)·다시 실행, Pencil 두 번 탭·Pencil Pro 쥐기는 설정대로. 한 획이 데스크톱의 Pen 표시 하나로 가고, Mac에서 그린 획도 지울 수 있습니다. 표시(하이라이트·코멘트·영역·펜)는 쪽 위 층에 벡터로 그려 확대해도 선명하고, PencilKit 캔버스는 Draw 중에만 화면에 보이는 쪽에 둡니다. Draw 버튼은 켜지면 Preview의 Markup처럼 accent로 채운 원이 됩니다. 쪽 그림·돌아가기 버튼은 각자의 유리 원이고, 고른 글자는 accent로 칠합니다(다크 모드에서 흰 쪽 위에 흰색으로 골라져 보이지 않던 것). 획을 긋거나 쪽을 넘기거나 확대할 때 화면이 현재 쪽 맨 위로 튀던 것은 PDFKit 쪽 미리보기(`PDFThumbnailView`) 탓이라 쪽 그림 목록을 직접 만들었습니다. 오른쪽 아래 쪽 번호는 Draw 중에도 보이고, 누르면 쪽 번호로 이동합니다. 쪽 그림 버튼은 Preview처럼 왼쪽 위(돌아가기 앞)에 있고, 쪽은 위쪽 바 아래까지 이어지고, 바 아래 띠가 Liquid Glass의 hard 가장자리 효과로 지나가는 쪽을 흐리게 비추며 바를 구분합니다(Preview처럼). 라이브러리의 동기화 폴더·상태는 왼쪽 위 Settings(톱니바퀴) 안으로 옮겼고(동기화 중이거나 실패하면 왼쪽 열 아래에 알림), Recent는 기본 정렬(마지막으로 연 순서)과 같아서 뺐습니다. 기기에서 써 보기는 아직.
- 동기화(데스크톱): 완전히 삭제한 논문의 PDF는 쓰는 논문이 Library·Trash에 없으면 공유 폴더에서도 지웁니다(다른 컴퓨터가 그 일을 들으면 다시 확인). Library 논문의 PDF가 폴더에 없으면 가진 컴퓨터가 다시 넣습니다. 완전히 삭제하면 같은 PDF의 숨은 항목(Library에서 빼거나 합친 사본)도 함께 지워져, 같은 PDF를 다시 받으면 새 논문으로 시작합니다.
- 외부 패키지 없이 시스템 프레임워크만 씁니다. `project.pbxproj`는 손으로 쓴 파일(폴더 동기화 그룹)이고 `xcodebuild`로 빌드합니다.
- 두 구현이 어긋나지 않게: 데스크톱 코드가 만든 동기화 폴더(`tests/data/sync/mac`)를 iPad XCTest가 읽고, iPad 코드가 쓴 변경 파일(`tests/data/sync/ipad`)을 데스크톱 테스트 `sync_conformance`가 읽습니다. iPad XCTest(iOS 27 시뮬레이터)는 그 밖에 나중 변경 우선·256KB 파일 나누기·끝나지 않은 줄·회전한 쪽의 좌표·주석이 그려지는 자리·읽던 위치로 돌아가기, 논문 추가(같은 PDF·되살리기·폴더가 없을 때)와 웹에서 PDF 받기(이 기기의 작은 웹 서버로), 펜 캔버스 좌표가 PDFKit과 맞는지(돌린 쪽·옮긴 크롭 박스)와 획 ↔ 표시(그리기·지우기·실행 취소)와 그리는 중인 획까지 4배 확대에서 선명한지, 4배 확대에서 펜 선의 가장자리가 선명한지, Draw 중 Pencil이 PDFKit 제스처에 쓰이지 않는지, 옆 쪽 그림 목록(쪽마다 하나, 현재 쪽 표시, 탭하면 그 쪽으로), 쪽이 바 아래까지 이어지고 첫 쪽이 바 바로 아래에서 시작하는지를 고른 글자가 데스크톱과 같은 행이 되는지, 글자 메뉴의 Highlight·Comment…, 하이라이트·지우기·색과 노트 바꾸기가 실행 취소 한 단계씩인지를 확인합니다(32개). 데스크톱 테스트는 iPad에서 추가한 논문이 원래 파일 이름·PDF·Collection·Tag와 함께 들어오는지, iPad에서 그린 획과 지운 Mac 획이 그대로 들어오는지 봅니다.

## 지난 단계 (2026-10-18): 읽기 편의

- 1단계 구현 완료: macOS 스와이프, 코드 링크, 선택적 Library 요약·인용 수. 실제 트랙패드와 외부 서비스의 결과 확인은 NEXT에 남겼습니다.
- Settings › Library › Summaries and citation counts(기본 끔): 켠 경우에만 DOI/arXiv ID를 Semantic Scholar batch API로 최대 500편씩 보냅니다. PDF·노트는 보내지 않습니다. 하루 한 번 확인하고(실행 직후 창이 열리는 동안은 기다림) 받은 결과는 30일 동안 재사용하며, 데이터 폴더의 `library-insights.json`에 원자적으로 저장합니다(DB 스키마 변경 없음). 설정을 끄면 진행 중 조회와 표시가 중지됩니다. Library 메타 줄에는 인용 수, 셋째 줄에는 TL;DR을 표시하고 요약이 있는 행만 높아집니다. 주소는 인용 목록과 같은 `citations.baseUrl` 설정을 씁니다.

- Code links: PDF 본문과 링크에서 GitHub·GitLab·Hugging Face 저장소를 로컬에서 찾습니다. References 이후는 제외하고 저장소별로 합쳐 최대 3개를 도구 막대와 ⋯ 메뉴에 표시합니다. 호버 요청이 검색을 취소하지 않습니다.

- macOS 두 손가락 스와이프: 시스템의 페이지 간 쓸어넘기 설정을 따르며, 가장자리 원형 화살표가 차면 손을 뗄 때 뒤로/앞으로 이동합니다. 방향 판단 전 스크롤은 통과하며, 가로로 이동할 수 있는 PDF·웹 탭·보조 패널에서는 시작하지 않습니다. 관성은 다시 이동시키지 않습니다.

- 참조 미리보기 카드(인용·그림·표·수식에 포인터를 올렸을 때)에 테두리가 보입니다. 카드 안의 페이지가 테두리를 덮던 것을 고쳐, 테두리를 내용 위에 그리고 페이지는 둥근 모서리 안쪽에 둡니다.
- Match System(Settings › Appearance › Theme): 켜면 시스템이 밝은 모드·어두운 모드로 바뀔 때 테마가 따라 바뀝니다. 밝을 때·어두울 때 쓸 테마를 따로 고르고(기본 Neutral·Dark), 켜 둔 채 위의 테마를 고르면 지금 모드의 테마가 됩니다. 창이 열리기 전에 맞추므로 다른 모드의 테마로 잠깐 열리지 않습니다. 시스템 모드는 Qt가 알려 주는 값(macOS·Windows·Linux GNOME·KDE)이고, 알려 주지 않는 데스크톱에서는 고른 테마를 그대로 둡니다.

## 지난 단계 (2026-10-17): For You 팔로우, 키, 설치

- For You 연구자·기관 팔로우: Settings › For You › Researchers and institutions에서 이름으로 찾아(OpenAlex, Return이나 Search를 눌렀을 때만 요청) Follow. 그들의 새 논문(논문·프리프린트, 오늘까지)도 다른 논문처럼 AI 점수 순으로 놓이고(Following 보기는 최신순), AI가 한 줄 요약을 붙입니다. Library › For You 출처 메뉴의 "Researchers and institutions you follow"로 그들 것만 봅니다. 선택 입력인 OpenAlex 무료 키는 키 저장소에 둡니다(없으면 같은 네트워크가 하루 무료 한도를 나눠 씀). 팔로우 목록은 동기화됩니다(스키마 19).
- For You는 `Papers | Following` 두 칸: Following은 팔로우한 연구자·기관의 새 논문만 최신순으로 보여 주고, 왼쪽 열에 새 논문이 있는 사람·기관과 편수(맨 위 Everyone, 누르면 그 사람만)를 둡니다. 좁을 때는 왼쪽 열 대신 출처 메뉴. ⚙는 Manage Following: 입력란 하나로 주제(단어, `cs.RO` 같은 분야)는 바로, 연구자·기관은 Return을 눌러 OpenAlex에서 찾아 팔로우하고, 줄마다 새 논문 수·확인당 개수·끄기·삭제, 맨 아래 Checking and AI 설정으로 가는 줄. Settings › For You는 확인 방식·AI·OpenAlex 키와 Manage Following으로 가는 버튼만 남았습니다.
- Follow Author: 논문 우클릭(Library·Home·Library 패널)과 For You 논문에서, OpenAlex에 있는 그 논문의 저자 목록(마지막·교신 저자를 먼저, 소속과 함께)과 소속 기관을 골라 팔로우합니다. DOI → arXiv ID → 정확히 같은 제목 순으로 찾고, 없으면 이름으로 찾기로 넘어갑니다.
- 집중 모드(⌘⇧F, Ctrl+Shift+F, View 메뉴·명령 팔레트): 상단 바·탭 줄·리더 도구 막대·아래 상태 막대를 숨기고 기본으로 전체 화면(Settings › Reading › Focus mode에서 끔). 맨 위 끝에 포인터를 대면 숨긴 것이 한 막대에 모여 페이지 위에 잠깐 나타남: 양 끝에 상태 막대와 같은 패널 아이콘, ←/→·검색, 가운데 지금 탭(누르면 열린 탭 목록·⌘1~9·New Tab), Exit Focus. macOS 전체 화면에서는 제목 막대의 빈 도구 막대 띠를 숨김. 막대는 macOS 메뉴 막대가 내려오는 24pt(노치가 있으면 노치 높이) 아래에 나오고, 나와 있는 동안 그 위 띠도 막대 색으로 칠함. 막대 오른쪽 핀을 누르면 막대가 계속 보이고 페이지가 그만큼 내려가 가리지 않음(다시 누르면 숨김, 이 컴퓨터에 기억). 앱을 다시 켜면 보통 화면.
- Windows·Linux 상단 바: Settings › General › Tabs › Top bar(기본 끔). 끄면 창이 한 줄 줄어 검색창은 Home 맨 위(다른 화면은 Ctrl+K로 가운데에), ←/→는 위 왼쪽 탭 줄 왼쪽 끝, 검색 버튼과 ≡는 위 오른쪽 탭 줄 오른쪽 끝, 창을 채운 Home은 자기 줄에 함께. 세로 탭일 때는 상단 바를 유지. macOS는 상단 바가 제목 막대라 그대로.
- 메뉴 정리: File(새 탭·열기·웹·노트·닫기·다시 열기·Settings·Quit)과 View(Home·Library·확대·맞춤·Dark Pages·패널)만 남기고, 나머지는 단축키와 명령 팔레트로. Windows·Linux의 ≡는 하위 메뉴 없는 한 목록.
- 명령 팔레트(⌘⇧P, Ctrl+Shift+P): 종류별로 68개 — File·Tab(다음·이전 탭, AI로 정리)·Split·View(Back·Forward, 집중 모드·Dark Pages 켜고 끔)·Window(Minimize)·Panel(Library·Document·AI Chat·Threads·세로 탭 켜고 끔, Document 패널의 Contents·Annotations·Symbols·Related·Figures)·Library(For You·Notes·Words·Trash)·Search·Web·PDF(확대·맞춤·형광펜·코멘트·그리기·텍스트 상자·Code Links·인쇄·내보내기)·Paper(읽음 표시·Details)·Note·AI(묻기·Gloss·쪽 번역·라이브러리에 묻기)·Settings(Customize Home과 주요 쪽). 지금 쓸 수 없는 명령은 흐리게.
- Gloss 단어장: Gloss 창의 ☆(단어·짧은 구에만)로 단어, 그 문맥의 뜻(Gloss 답), 들어 있던 문장, 논문, 쪽 위치를 `vocabulary`(스키마 21, 업그레이드 전 백업)에 저장합니다. 같은 논문의 같은 단어는 뜻만 새것으로. 문장과 위치는 PDF에서 백그라운드로 읽습니다. Library의 Words 탭: 검색(단어·뜻·문장·논문 이름), 누르면 그 논문의 그 쪽으로 가서 단어를 밝힘, 우클릭으로 뜻 고치기·지우기, 지운 뒤 8초 동안 Undo. 동기화되고(나중 변경 우선), 논문이 합쳐지면 따라갑니다. Words의 Export…: CSV(스프레드시트, UTF-8 BOM, 단어·뜻·문장·논문·쪽·저장일)와 Anki용 카드(탭 구분 앞면·뒷면, HTML, `#separator:tab`·`#html:true` 머리줄; 뒷면은 뜻·문장·논문과 쪽). 지금 검색에 맞는 단어만 내보냅니다. 복습(플래시카드)은 다음 버전.
- 논문 정보 읽기(첫 쪽): 제목 아래 저자 줄이 위첨자(소속 번호) 때문에 제목만큼 높아 보여도 제목에 붙이지 않습니다(제목 줄 사이보다 넓은 간격이면 저자). 예전에 저자를 못 찾은 논문은 다음 시작 때 컴퓨터마다 한 번 다시 읽습니다(`metadata.reader`).
- 다 읽은 뒤 3줄 정리: 논문 하나를 읽음으로 표시하면(Library·논문 메뉴·명령 팔레트, 여러 편을 한 번에 표시할 때는 제외) 위에 "Marked as read. Keep three lines about it?" 막대가 12초 뜹니다. Write Note는 "- Key idea / - Method / - Limits" 틀이 든 노트("제목 · Summary", 논문 링크 포함)를 논문 옆에(열려 있지 않으면 새 탭으로) 열고, Draft with AI는 같은 노트를 열고 AI가 논문 전체를 읽어 쓴 세 줄(Settings › AI의 답변 언어)로 빈 틀을 채우며 대화 링크를 덧붙입니다(그사이 노트를 고쳤으면 틀 자리 대신 끝에 붙임). 대화는 "Summary · 논문" 제목으로 Threads에 남습니다.
- 다음 질문 제안: 질문(ask)과 라이브러리 질문의 답 끝에 AI가 이어서 물을 만한 질문 2~3개를 함께 쓰고(따로 요청하지 않음), Owelk가 저장할 때 떼어 답의 context에 둡니다. 마지막 답 아래 칩으로 보이고 누르면 바로 묻습니다. 복사·노트·다시 보내는 대화에는 들어가지 않으며, 쓰는 중에는 숨깁니다. Settings › AI › Suggest next questions로 끕니다(번역·요약·기호 목록에는 없음).
- 대화 전체를 노트로: AI 패널 헤더의 노트 아이콘(Save chat as note)이 대화의 질문(인용)과 답을 차례로 담고 대화·논문 링크를 붙인 노트를 만들어 논문 옆에(열려 있지 않으면 새 탭으로) 엽니다. 다시 쓰기는 노트의 AI 버튼으로("다시 정리해 줘" → 수정안 Apply, Undo 가능).
- AI 답 글자(Settings › Appearance › Text): 크기(기본은 앱 글자 크기 + 2, 앱 크기를 따라감), 줄 간격(Compact 약 1.2em·Comfortable 약 1.5em·Relaxed 약 1.75em, 문단 사이와 제목 위 여백도 함께), 줄 길이 제한(넓은 채팅 탭에서 대화·입력창이 글자 크기의 48배 폭으로 가운데), 또렷한 글자(시스템 글자 그리기, NativeRendering) 모두 기본으로 켜져 있고 미리보기로 바로 보입니다. 질문 말풍선과 입력창은 답보다 1px 작습니다. Markdown 리치 텍스트(답·노트 미리보기 등)는 이제 각 화면이 정한 글자 크기를 따릅니다(Qt가 `<body>`에 넣던 앱 기본 글꼴 크기를 뺌).
- 이미 있는 논문을 다시 받았을 때의 알림: 제목 "You already have this paper", 할 일을 한 줄로 설명하고 Open My Copy를 주 버튼으로 둡니다(Keep Both는 보조, ×는 Not Now로 Owelk를 닫을 때까지 그 파일을 묻지 않음). Open My Copy·Keep Both의 답은 그 파일 버전의 모든 사본에 적용되어, 남긴 사본을 다시 열 때 방금 치운 사본을 거꾸로 묻던 문제(알림이 안 꺼지는 것처럼 보임)가 없어졌습니다.
- 읽기 상태의 "읽는 중": 파일을 열기만 해서는 바뀌지 않고, 실제로 읽은 시간(읽기 시계: 스크롤·클릭·키가 3분 안에 이어질 때만 셈)이 모든 날·컴퓨터를 합쳐 5분이 되거나 처음 주석을 달면 읽지 않음 → 읽는 중이 됩니다(`ResearchStore::readingAfterSeconds`). 이미 정해진 상태는 그대로 둡니다.
- Library 탭은 다른 탭(논문, Open Page로 연 웹 탭 등)을 보다 돌아와도 그대로입니다: 정렬, 검색어, For You 미리보기·펼친 논문·기간, 목록 스크롤 위치. 탭이 그 그룹에 있는 동안 화면을 숨겨 두기만 하고(처음 보일 때 만듦), 숨어 있는 동안에는 목록을 읽지 않다가 다시 보일 때 한 번 새로 읽습니다. 정렬은 앱을 다시 켜면 Last opened로 돌아갑니다. Home·검색에서 새로 열면 그 링크가 가리키는 논문만 펼칩니다.
- AI 패널·채팅 탭 머리의 제목을 누르면 그 자리에서 이름을 바꿉니다(Return이나 다른 곳 클릭은 저장, Escape는 취소). 패널에서 끌면 지금처럼 분할 화면으로 엽니다.
- 새 대화의 이름은 AI가 짓습니다: 첫 답과 같은 요청에서 질문 언어로 2~6단어 이름을 받아(`<chat_title>`, 답에서는 빼고 쓰는 동안에도 안 보임) 질문으로 붙였던 임시 이름을 바꿉니다. 요청이 늘지 않습니다. 그 사이 직접 바꾼 이름, 번역·요약 대화, 이후 질문에서는 바꾸지 않습니다.
- AI 대화 고치기: 마지막 답 아래 ↻(Ask again)는 마지막 질문을 그때 보낸 그대로(선택·쪽·그림 포함) 다시 보내 그 답을 바꾸고, 마지막 질문에 포인터를 올리면 나오는 연필(Edit question)은 질문과 함께 보냈던 것을 입력창에 되돌려 고쳐 보내면 그 질문과 답을 바꿉니다. 새 답이 실패하거나 아무것도 오기 전에 멈추면 원래 질문과 답이 돌아옵니다. 답마다 +(New chat from here)는 그 답까지를 복사한 새 대화("Branch · 제목", 같은 Thread)를 만들고 원래 대화는 그대로 둡니다. 답이 오는 중이거나 기다리는 질문이 있으면 앞의 둘은 숨습니다.
- AI 대화를 탭으로: Threads 패널에서 대화를 우클릭 › Open in New Tab(대화마다 탭 하나, 이미 있으면 그 탭으로). AI 패널 제목 옆 Open in New Tab 버튼(external)은 그 대화를 새 탭으로 열고 패널을 닫습니다(같은 대화를 두 번 보이지 않게, 패널을 다시 열면 같은 대화). 탭과 AI 패널에서 같은 대화를 열면 진행 중인 답·기다리는 질문·저장된 대화가 함께 보이고 어느 쪽에서든 물을 수 있습니다(AiRuns가 답을 한 곳에서 받아 모든 화면에 나눔). 쓰다 만 질문과 붙이는 중인 첨부는 화면마다 따로. 탭에서는 Threads·New chat 버튼이 없고, 탭 제목은 대화 제목을 따라가며 대화가 지워지면 탭도 닫힙니다. 화면 분할로 논문 옆에 둘 수 있고, 세션과 함께 복원됩니다. AI 패널 헤더의 대화 제목이나 Threads 목록의 대화(하나)를 문서 영역으로 끌면 탭을 끌 때처럼 분할(가장자리)이나 탭 줄 사이에 그 대화의 탭이 생기고(이미 탭이 있으면 그 탭이 옮겨짐), Home 위에 놓으면 새 탭으로 열립니다. 채팅 탭의 This Paper·Region of the PDF는 다른 분할 앞에 있는 논문(그중 가장 최근에 앞이던 것)이고, 그 논문에서 선택·그림을 AI에 물으면 옆 채팅 탭으로 갑니다(영역은 영역을 요청한 쪽으로).
- 답 중에 이어서 질문: 답이 오는(생각하는) 동안 질문을 쓰고 Return(또는 전송 버튼, 글이 있으면 Stop 대신 "Ask next")을 누르면 그 아래 "Next"로 기다렸다가 답이 끝나면 차례로 갑니다(그때 고른 모델로, 다른 대화를 보고 있어도). ×로 취소, 옆의 Send now는 지금 오는 답을 멈추고(Stop처럼 쓰인 데까지 남음, 아직 한 글자도 없으면 그 질문은 빠짐) 그 질문을 먼저 보내며 나머지는 그 뒤에 차례로 갑니다. Stop이나 실패 뒤에는 "Waiting"으로 남아 Send를 눌러야 갑니다. Owelk를 끄면 기다리던 질문은 남지 않습니다.
- AI 답변 여러 개 동시에: 답이 쓰이는 중에 다른 대화를 열거나 새 대화를 시작해도 멈추지 않고 이어서 쓰여 그 대화에 저장됩니다(끝나면 "답 도착" 카드). Threads 패널에서 답을 쓰는 중인 대화 옆에 돌아가는 표시, 그 대화를 다시 열면 쓰이는 답이 그대로 이어서 보입니다. 다른 대화에 있는 동안 실패하면 그 대화를 열 때 알려 줍니다. Stop은 보고 있는 답만 멈춥니다. Owelk를 끄면(⌘Q) 쓰던 답은 받은 데까지 그 대화에 남고 "Owelk was closed before the answer finished."로 표시, 아직 아무것도 오지 않았으면 질문만 남고 "…before the answer came."(그 질문은 다음 질문 때 AI에 다시 보내지 않음). 끈 뒤 자동으로 이어서 묻지는 않습니다.
- 하단 상태 막대의 진행 중 작업: 글자가 잘렸거나 작업이 여러 개면 올렸을 때 전체 문장. 누르면 그 작업이 보이는 곳으로(For You 작업 → Library › For You, 빈 정보 찾기 → Missing Details, 다운로드·폴더 가져오기·PDF 복사 → Library, 색인 → Settings › Search, 동기화·백업 → Settings › Sync & Backup), 여러 개면 목록에서 고름.
- Library › Missing Details(제목·저자·연도 중 빈 것이 있는 논문이 있을 때만 보임, 명령 팔레트 "Papers with Missing Details"): Look Up Details를 누르면 DOI나 arXiv ID가 있는 논문만 하나씩 Crossref·arXiv에 그 ID를 보내(요청 사이 1초, arXiv 뒤 3초) 빈 칸만 채우고 Paper Details에서 Save한 것처럼 사용자 정보로 둡니다. 제목만 있는 논문은 다른 논문을 찾을 수 있어 묻지 않습니다. 하단 상태 막대에 진행이 보이고 Stop으로 멈춤, 연속 3번 연결 실패면 멈춤(`fillMissingDetails`).
- arXiv 새 버전 알림(기본 꺼짐, Settings › Library › Newer arXiv versions): 하루 한 번 arXiv ID만 arxiv.org API(export.arxiv.org, 100개씩, 요청 사이 3초 이상)에 보내 최신 버전을 확인합니다. 내 사본의 버전은 arXiv ID의 vN, 없으면 첫 쪽 여백의 `arXiv:…vN` 표시를 논문마다 한 번 읽어 압니다(낮은 우선순위 스레드). 더 새 버전이 있으면 Library 행에 "v3 available" 칩과 논문 메뉴의 Get v3…: 묻고 나서 새 PDF를 별도 논문으로 받아 원래 논문과 링크하고, 원본 PDF와 주석은 그대로입니다. 받은 뒤 칩은 "Newer version in Library"(누르면 엶). 같은 응답의 출판 정보(`arxiv:journal_ref`, `arxiv:doi`)는 DOI가 없는 논문에 "Published" 칩과 Paper Details의 "Published in …"으로 제안만 하고, Apply는 DOI 칸만 채우며 Save해야 저장됩니다(몰래 바꾸지 않음). 결과는 데이터 폴더의 `arxiv-versions.json`(스키마·동기화 밖).
- Match System과 Custom: Match System이 켜져 있으면 밝음·어두움은 시스템이 정하므로 Custom theme의 Dark 스위치는 잠기고("Set by Match System. Turn it off to change this."), 바꾸려면 Match System을 끕니다.
- 논문 그림 모아 보기: Document 패널의 다섯째 탭 Figures(아이콘 image)에 그림·표가 격자로(보이는 칸만 만들고, 쪽을 작게 그려 그 영역만 보여 줌). 누르면 그 위치로 가서 깜빡이고, 우클릭은 Ask AI·Pin over the pages. `ReferenceFinder::figures`가 낮은 우선순위 스레드에서 쪽마다 줄 첫머리의 캡션(Figure N, Fig. N, Table N)을 찾고 `floatRegion`과 같은 방법으로 영역을 구합니다. 쪽 글자는 참조 미리보기와 같은 캐시를 쓰고, 읽는 중(스크롤·확대)에는 기다리며, 같은 파일은 메모리에서 바로 답합니다. 같은 이름이 여럿이면 영역이 가장 큰 것("Table 2 shows …"로 시작하는 줄은 제외).
- 그림·표·수식 고정 카드: 미리보기 카드의 핀(Lucide `pin`)을 누르면 그 대상이 리더 위에 떠서 스크롤해도 남습니다. 막대를 끌어 옮기고, 오른쪽 아래 모서리로 크기를 바꾸고(180×120~리더의 80%, 종류별 크기는 `reader.pinSize.<kind>`에 기억), 카드 안에서 확대하며(핀치·Ctrl+휠·−/+), 누르면 그 위치로 갑니다. 탭마다 최대 3개(넷째는 가장 오래된 것을 대신)이고 탭을 닫으면 사라집니다. Dark pages에서는 미리보기와 같은 반전 셰이더. 미리보기 안쪽은 `PreviewContent.qml`로 나눠 둘이 함께 씁니다.
- 읽기 달력·읽은 시간: Home에 하루 한 칸 달력(카드 너비에 들어가는 만큼, 12주~1년; 위에 월, 옆에 요일, 아래 Less–More 범례; 강조색 진하기 4단계: 15·30·60분), 연속 기록(하루 1분 이상, 오늘 아직이면 어제까지), 오늘·최근 7일 시간과 그 앞 7일과의 차이. 칸에 올리면 날짜·읽은 시간·논문 수. 칸을 누르면 그날 읽은 논문과 시간(긴 순, 5편까지, 목록 높이는 편 수만큼, 누르면 읽던 곳에서 열림), 아니면 최근 7일에 많이 읽은 논문. 고른 날은 ↑↓로 하루, ←→로 한 주씩 옮기고 Esc로 풉니다(`readingPapers`). Library 행(오른쪽 끝, 저자·연도 줄과 따로)과 Paper Details에 논문별 읽은 시간("Read for 1 h 5 min"). 리더 탭이 앞에 있고 창이 열려 있으면(최소화 아님) 다른 앱이 활성이어도 세고(macOS는 포인터 아래 창을 스크롤), 3분 넘게 스크롤·키·클릭이 없으면 멈춥니다(`ReadingClock`, 시각 기준이라 읽는 동안 매초 도는 타이머 없음). 1분에 한 번 모아 `reading_days`(컴퓨터·논문·날짜, 스키마 20, 업그레이드 전 백업)에 씁니다. 컴퓨터마다 따로 기록해 동기화하고 합산합니다.
- macOS 창 닫기: 빨간 버튼·⌘W(탭 없음)는 창만 닫고 앱은 Dock에 남습니다(전체 화면이면 먼저 끝냄). Dock 아이콘 클릭·메뉴 막대 명령·Finder에서 연 PDF로 창이 그대로 돌아오고, ⌘Q만 앱을 끝냅니다. 닫힌 동안 Close는 꺼집니다. Window › Minimize(⌘M)로 창을 Dock에 내립니다.
- 로그인 시 열기: Settings › General › Launch › Open at login(기본 끔). macOS 13+는 로그인 항목(`SMAppService`, System Settings › General › Login Items에도 보임; 거기서 꺼 둔 경우 그 화면을 열고 "Allow Owelk…" 안내), Windows는 `HKCU\…\Run`(작업 관리자에서 끈 표시도 켤 때 지움), Linux는 `~/.config/autostart/owelk.desktop`(AppImage면 그 파일). 상태는 시스템에만 두고 Settings를 볼 때·Owelk가 앞으로 올 때 다시 읽음.
- PDF 선택 띠: 줄 상자가 줄 간격보다 큰 PDF에서 위아래 띠가 겹치던 것을 줄 사이 가운데에서 나눔(Library의 논문 24편, 3줄 드래그 262번 기준 겹침 127 → 2).
- For You 개수: 주제·연구자·기관·Collection마다 확인 한 번에 가져올 최대 편수(5·10·20·50)를 따로 정하고, 정하지 않은 것은 공통 값을 따릅니다("Usual (10)"처럼 숫자와 함께 보임). 공통 값과 출처별 값 모두 Library › For You › Following 한 곳에서 정하고(Settings › For You에는 없음), 이 컴퓨터의 설정입니다. Settings › For You의 Look back은 확인할 때 거슬러 찾는 기간이고, For You의 Today·This week 칩은 찾은 논문을 거를 뿐입니다.
- PDF 선택: 더블클릭은 단어, 세 번 클릭은 문장(약어·소수점은 넘기고, 제목이나 문단 끝의 짧은 줄에서 끝남). 보통 선택과 같아서 복사·형광펜·AI 묻기가 그대로 됩니다.
- 키: PDF는 ←/→로 쪽을 넘깁니다(확대해 쪽이 화면보다 넓으면 먼저 옆으로 끝까지 스크롤). Back·Forward는 macOS ⌘[ / ⌘], Linux·Windows Alt+← / Alt+→. 모두 Settings › Shortcuts에서 바꿉니다.
- Library 읽기 표시: 열지 않은 논문은 강조색 점, 연 논문(Reading)은 강조색 테두리, 읽음으로 표시한 논문은 표시 없음.
- 웹 탭: PDF만 바로 받고 다른 파일은 Save·Cancel을 묻습니다. 페이지가 스스로 여는 팝업은 막고, 클릭으로 연 새 창만 탭으로 엽니다.
- 받은 PDF는 그 웹 탭이 아직 앞에 있을 때만 앞으로 나옵니다. 받는 동안 다른 탭이나 Home으로 옮겼으면 그 화면을 그대로 두고, PDF는 웹 탭 옆에 조용히 열립니다(포커스도 그대로).
- PDF 프레임이 페이지를 거의 다 채우는 페이지(IEEE `stamp.jsp`)에서 Open in Reader: 받는 동안은 페이지를 그대로 두고, 다 받으면 PDF가 그 탭 자리를 대신합니다. 페이지 일부에 PDF가 있는 페이지는 옆에 엽니다.
- 설치: `tools/qt.txt`의 Qt 하나를 모든 시스템이 씁니다. macOS도 공식 Qt를 `~/Qt`에 받고 Homebrew의 Qt는 쓰지 않으며(Homebrew는 cmake·ninja·qpdf만), Command Line Tools·Homebrew 설치를 안내합니다. Linux는 컨테이너와 이름이 바뀐 패키지(t64)도 처리합니다. `Dockerfile`로 Linux 빌드·전체 테스트(`docker run --rm owelk`).
- 코드 리뷰 수정 묶음: 데이터 경계 사례(같은 초 백업, 손상된 인용 캐시, 노트 링크 풀기, 중복본의 Collection, OCR 잔여 행), 동기화 가져오기를 200개씩 나눠 저장·이어 읽기, 번역 누락·Theme 색, 첨부 그림 정리, Ollama 16k 컨텍스트, macOS 누수, Windows 파일 이름·파일 지문.

## 지난 단계 (2026-10-14): For You와 Settings 개편

- For You: 따라가는 주제(단어 + arXiv 분야)는 arXiv에서, 따라가는 Collection은 Semantic Scholar 추천에서 새 논문을 찾습니다(기간 1일·7일·30일, 출처당 최대 편수). 이미 Library에 있거나 Dismiss한 논문, 기간보다 오래된 논문은 뺍니다. 요청할 때와(켜져 있으면) 하루 한 번 Owelk를 연 뒤 확인하며, arXiv 요청은 몇 초 간격을 둡니다.
- Home: 이어 읽기 아래 For You(새 논문 5편, 제목 → Library › For You, 톱니 → 설정). 따라가는 것이 없으면 설정으로 가는 한 줄, 새 논문이 없으면 숨김.
- Library › For You: 전체 목록, 출처별 보기, 다시 확인, 선택해 Add·Dismiss. Add는 PDF를 받아 Paper names 규칙으로 이름 붙이고, Collection에서 온 논문은 그 Collection에 넣고, arXiv·Semantic Scholar의 제목·저자·연도·DOI를 채웁니다. PDF가 없으면 논문 페이지를 웹 탭으로 엽니다. Collection 우클릭 › Follow in For You.
- For You AI(2단계): 확인 뒤 새 논문을 AI가 따라가는 것과 얼마나 맞는지 점수(0–100, 같은 점수가 몰리지 않게 범위 전체를 쓰라고 요청)로 매겨 관련도 순으로 놓고(점수가 같으면 최신순, 연구자·기관 논문도 같은 순서) 논문마다 내용 한 줄 요약을 붙입니다(관심사와의 관계는 쓰지 않음, 관련도는 순서로만). 요약 이전에 쓴 문장(관심사와의 관계)은 라이브러리마다 한 번, 동기화가 끝난 뒤 40편씩 이어서 다시 씁니다(`foryou_meta` summaries: 도는 중 started, 끝나면 1; 도중에 끄면 다음 실행 때 남은 것부터)(Home·Library에 표시, Library의 AI 버튼으로 다시). Settings › For You › Explain with AI(켜는 것이 보내기 동의, AI가 설정돼 있어야 함). 보내는 것: 새 논문의 제목·초록, 주제, 따라가는 Collection의 논문 제목 몇 개.
- For You 동기화와 정리: 주제·따라가는 Collection·찾은 논문(AI 요약 포함)·Dismiss/Add 기록·마지막 확인 시각이 라이브러리 표(스키마 18, `foryou_*`)로 옮겨져 동기화됩니다. 한 컴퓨터가 확인하고 AI가 요약을 붙인 논문은 다른 컴퓨터에서 다시 찾거나 보내지 않습니다(동기화가 끝난 뒤 확인). 기간·자동 확인·목록 유지 기간(7·15·30·60일·항상, 기본 30일)은 컴퓨터마다. Library › For You는 가운데 920px 열, 제목 옆 논문 수, All·Today·This week·This month 칩, 제목 → AI 요약 → 짧은 정보(저자 et al.·"3 days ago"·출처), 초록은 펼쳤을 때만.
- 마우스 앞·뒤 버튼: 창 어디서나 Back·Forward(웹 탭의 페이지 → 리더의 이동 → 장소 순).
- Settings: 하는 일별로 General(Launch·Home·Tabs·Language) · Appearance(Theme·Custom theme·Accent·Text·App icon) · Shortcuts / Reading(PDF pages·Focus mode·Symbols) · Library(Files·Paper names·Paper insights·Trash) · For You · Web(Links·Search engines) · Search / AI(Provider·Gloss·Answers) · Sync & Backup(설정 키는 그대로). 겹치던 곳은 하나로: 언어(인터페이스·AI 답)는 General › Language, 글자 크기(앱·AI 답의 크기·줄 간격·줄 길이·또렷한 글자)는 Appearance › Text, PDF 폴더와 다운로드 폴더는 Library › Files, 논문 이름과 다운로드 PDF 이름은 Library › Paper names. 사이드바 검색은 설정 이름과 관련 단어로 찾고(결과에 페이지 › 그룹), 고르면 그 페이지의 그 설정으로 스크롤해 잠깐 표시합니다. 단축키도 동작 이름으로 찾습니다. 모든 그룹과 줄이 검색에 들어가 있는지 테스트가 확인합니다(SettingsIndex.js).

## 지난 단계 (2026-10-10): 구조 단순화

- Workspaces 제거: 논문이 있던 워크스페이스는 같은 이름의 Collection이 됩니다(스키마 14, 업그레이드 전 백업).
- Captures를 주석으로 통합: 문장 캡처는 하이라이트, 영역 캡처는 새 영역 주석(캡션·메모 유지), 웹 캡처는 그림이 든 노트가 됩니다(스키마 15, 같은 ID·링크 유지). 새 `Mark Region` 도구, AI의 PDF·웹 영역 첨부는 저장하지 않는 그림.
- Document 패널 네 칸: Contents(Outline·Pages), Annotations(이 논문에 대한 노트 + 모든 주석; 리더 옆 메모 열을 대신함), Symbols, Related(Library·Cites·Cited by). 새 노트는 논문 옆 분할에 링크와 함께 열림.
- AI 답변 Save as Note: 질문 인용, 이 논문의 노트에 덧붙이기. 노트의 AI 링크는 휴지통이면 Restore 안내, 영구 삭제면 회색 `Deleted conversation`.
- Library: Papers · Notes · Trash, 논문·노트·AI 대화를 함께 담는 휴지통(지울 항목을 링크한 노트가 있으면 먼저 알림, 기간이 지나면 노트도 자동 삭제). Library 패널은 Open Library·펼쳐지는 Favorites·Collections·Tags·Notes(+).
- Home: 검색과 웹 검색, 이어 읽기 카드, Collections | Recent Papers, Notes | AI Conversations(마지막으로 연 순서, 상자는 항목 수만큼). 이어 읽기 아래 여섯 칸(For You, Reading, Collections, Recent Papers, Notes, AI Conversations)은 Settings › General › Home에서 켜고 끄고 ↑↓로 순서를 바꿉니다(배치 미리보기, Reset; Home 맨 아래 Customize Home…이 그 설정으로 감). For You·Reading은 한 줄씩, 나머지는 왼쪽부터 두 개씩 채우고 짝이 없으면 한 줄 전체. 나란한 두 상자는 긴 쪽 줄 수만큼 보이고 높이는 항목이 더 많은 쪽에 맞춤(혼자면 제 항목 수만큼). 끈 칸은 읽지 않습니다. 컴퓨터마다 따로 저장(`home.sections`, `HomeLayout.js`). 본문 색인 상태는 색인 중·실패일 때만 보이고 Settings → Search로 옮김.

## 지난 단계 (2026-10-09): 어려운 부분 읽기 돕기

- 그림·표·알고리즘·수식 위에서 우클릭하면 `Ask AI about Figure 3`처럼 그 대상을 찾아(캡션·번호·영역, 2단 쪽은 단 단위) 이미지와 이름을 AI 대화에 첨부합니다. 열려 있는 대화가 있으면(패널이 숨겨져 있어도) 거기에, 없으면 그 논문으로 새 대화를 엽니다. 선택한 글과 PDF·웹 영역도 같습니다.
- 우클릭은 상황별로 필요한 것만 보여 줍니다(선택 / 대상 위 / 빈 본문). 채팅 첨부 메뉴는 This Paper · Region of the PDF · Image.
- Gloss: 선택한 단어는 문맥상 뜻과 번역, 문장은 번역을 옆 팝업에 바로 보여 줍니다(빠른 모델, 대화에 남기지 않음).
- Document 패널 Symbols 칸: 논문의 기호 목록(뜻, 정의된 쪽 / Background, 누르면 정의 문장으로 이동·강조·Back). 목록이 있으면 기호에 마우스를 올릴 때 뜻이 뜹니다(글리프 어디서나 인식). Related에 연결된 노트를 합쳤습니다.
- Settings → AI: 기본 모델·추론 강도를 목록에서 고름, 설명 수준(쉽게·예시 / 간단히), 모든 질문에 붙는 추가 지시, Gloss 모델·추론 강도(Gloss 창에서도 바꿈).
- AI 패널: 지난 질문 위에 함께 보낸 첨부(논문·선택·그림 이름과 미리보기, 마우스를 올리면 크게)가 보입니다. 대화는 여러 개 골라 휴지통으로 옮기고, Library의 Trash(논문·노트·AI 대화를 함께)에서 되살리거나 영구 삭제합니다(30일 뒤 자동 삭제).
- 논문 본문은 요청 맨 앞에 두고 캐시 표시를 붙여, 같은 논문에 대한 반복 질문 비용을 줄였습니다(Claude·OpenAI).
- 웹에서 받은 PDF는 `제목.pdf`로 저장합니다(Settings → Web에서 웹사이트 이름으로 되돌림).

## 지난 단계 (2026-10-08): 컴퓨터 간 동기화

- Settings → Data → Sync에서 공유 폴더(Google Drive·Dropbox·Syncthing 등)를 고르면 논문·PDF·주석·노트·Collection·Tag·읽기 위치·AI 대화를 다른 컴퓨터와 맞춥니다. 설정·세션·검색 색인은 각자 둡니다. 자세한 내용은 [SYNC.md](SYNC.md).
- 컴퓨터마다 자기 변경 기록만 쓰고(충돌 사본 없음), 항목별로 나중 변경이 남습니다. 양쪽에 같은 PDF가 있었다면 하나로 합칩니다. 동기화를 켜기 전에는 아무 비용이 없습니다.
- 그 밖에: 라이브러리 전체·Collection에 묻기(쪽 인용), 답변 도착 알림 카드, 웹 탭 상태 유지, 주석 크기 조절·텍스트 상자 글자 크기, 인용 미리보기 목록.
- PDF 보관(`문서/Owelk Library/Papers`, 원본은 그대로)과 Library 휴지통(되살리기, 7·30일 뒤 자동 비우기).
- AI 패널: 채팅형 질문 말풍선, 선택 가능한 답변, 질문으로·최신으로 이동, LaTeX 수식(MicroTeX), 생각 과정 요약(접힘), 답변 한도 64k와 잘림 표시.

## 지난 단계 (2026-10-06): 정리·읽기 편의

- 탭: 세로 탭(너비 조절, 그룹 접기·이름), 탭 영역 빈 곳 우클릭(새 탭·정렬·중복 닫기·AI 정리·가로/세로 전환), Edge식 그룹.
- Library 패널(Collections·Workspaces·Tags·Folder)과 Collection 만들기·이름 바꾸기·삭제, 끌어 놓기, Unsorted·넣을 곳 제안·여러 논문 선택.
- 논문 추가: Collection 안에 바로 추가, 폴더 한 번에(하위 폴더를 Collection 트리로). 삭제는 `Delete Paper` 하나(Library › Trash에서 되살리기, 7·30일 뒤 자동 비우기 또는 직접 비우기).
- AI 주제별 정리(기존 Collection 재사용·새로 만들기, Apply 전에는 아무것도 안 바뀜).
- 읽기: 인용·그림·표·수식 참조에 포인터를 올리면 대상 미리보기(링크가 없거나 깨진 출판사 PDF는 본문 글자에서 찾음), Fit Page 보기(툴바의 배율 표시를 누르면 바로 Fit Page, Fit Width는 View 메뉴·명령 팔레트), ←/→ 쪽 넘김, 페이지 옆 노트, 주석 실행 취소.
- AI 정리 제안(탭·Collection)은 Apply 전에 항목 단위로 고칠 수 있습니다(빼기·옮기기·새 그룹).
- 그림·표 미리보기는 그림/표 자체를 단에 맞춰 보여 주고 카드 안에서 스크롤. 인용 카드의 Find Paper(DOI·arXiv·검색).
- AI 논문 비교표(열 지정, 노트로 저장), Semantic Scholar 인용 관계(Cites·Cited by, Library 표시, 한 달 캐시).
- 앱: 아이콘(macOS·Windows·Linux), Finder에서 PDF 열기·실행 중인 창으로 넘기기, 닫을 탭이 없으면 ⌘W로 창 닫기.
- 참조: 여러 논문 인용(`[12–14]`)은 항목 목록, 링크 있는 PDF도 Find Paper, 링크·미리보기·목차로 이동한 뒤 `Back to p. N`·Back(macOS ⌘[, Linux·Windows Alt+←)으로 돌아가기.
- 두 줄짜리 글자 묶음을 주는 PDF에서 선택 영역 높이가 두 배가 되던 문제 수정. 선택 없이 우클릭: AI로 묻기·쪽별 번역·논문 요약.
- 설치: `tools/install-local.sh`(macOS·Ubuntu).
- 핀치 후 다시 그리는 동안 배경 PDF 작업(색인·논문 정보)이 기다리고, 이미 보이는 쪽에는 로딩 표시를 띄우지 않습니다(논문 추가 중 다시 그리기 250–305ms → 112–115ms).

## 지난 단계 (2026-10-05): 디자인 개편

- 테마 엔진(`Theme`, 기본 8종: 밝은 Neutral·Paper·Solarized Light·Sage, 어두운 Dark·Nord·Dracula·Espresso + 내 테마(Appearance › Theme의 +, 개수 제한 없음, 이름·색 바꾸기·지우기, 자기 강조색을 가질 수 있고 고르면 그 강조색으로; `appearance.themes`에 이 컴퓨터만), 강조색 7, 글자 크기 11–17, Dark pages). 예전 기본 One Dark를 쓰던 사람은 내 테마로 옮겨짐. + › From the Gallery…: 잘 알려진 테마 25개(밝은 10·어두운 15: Catppuccin·Rosé Pine·Gruvbox·Tokyo Night·Everforest·Kanagawa·GitHub·Ayu·One·Solarized Dark·Monokai와 Mist·Midnight)를 미리보기 그림으로, 이름·light/dark·warm·blue 같은 말로 검색해 고르면 그 강조색과 함께 내 테마로(`qml/ThemeGallery.js`). + › From a Photo…·From a Color…: 사진에서 뚜렷한 색을 뽑아(`Theme.photoColors`, 썸네일로 몇 ms) 고르거나 색 하나를 골라, 색 세기(Subtle–Vivid)와 이름을 정하면 밝은 판·어두운 판 미리보기가 나오고 하나 또는 둘 다 내 테마로(그 색이 강조색). 밝은 판은 세기를 올리면 바탕도 조금 어두워져 색이 보임(`tintedSeeds`의 strength, 1은 예전과 같음), 앱 전체 컨트롤 스타일 `OwelkStyle`(호버·선택·포커스·주요 버튼 한 가지씩), 아이콘 글꼴(Lucide 일부) 하나와 `IconButton`, 글자 대신 아이콘.
- 목록 행 구분선·둥근 그룹 카드·알약 탭·공통 칩, 잘린 글자 호버 툴팁, 메뉴 너비 자동.
- 우클릭 규칙 통일(논문 메뉴 하나, 탭 종류별 메뉴, 위험 동작은 맨 끝 빨강), 중복 ⋯ 제거, 형광펜·그리기 색은 도구 우클릭, 페이지 우클릭은 그 위치의 동작만.
- Settings 카테고리화(Appearance·Web·Search·AI·Shortcuts·Data). 인쇄: 프린터가 없으면 인쇄용 PDF 저장.
- 가만히 있어도 CPU를 쓰던 계정 확인 루프를 없앴습니다(시작 후 CPU 3.6초 → 0.7초, 메모리 −15MB).

## 지난 단계 (2026-10-04): v0.5와 v1 마무리

- 플랫폼: Linux·Windows 지원(키 저장소, 경로, Codex 실행, 글꼴, 단축키 기본값), CI 3종, 설치 규칙.
- iPadOS 준비: 웹 엔진(Qt WebEngine)·외부 프로그램(OCR·Codex)·macOS 전용 코드를 플랫폼별로 나눔. iOS 시뮬레이터용으로 컴파일·링크됨(`build-ios`, 실행 확인은 아직). iPad에서는 웹 탭이 시스템 브라우저로 열리고, ChatGPT 계정은 Sign in with ChatGPT만 씀. 인쇄 수정(한 번 검증·300dpi·대화상자 앞에).
- iPad 터치(실기기에서 PDF 열기·손가락 스크롤 확인): 손가락 크기 여유, 홈 막대·상태 막대 안전 영역, 두 손가락 확대·축소를 한 장의 그림으로(손 뗄 때 한 번 배치), 세로 화면에서 덮는 옆 패널, 길게 눌러 메뉴(`ContextTap`), 탭으로 참고문헌·기호 보기, 링크 길게 눌러 미리 보기, 집중 모드 막대 탭. Pencil은 도구를 기억하고(처음은 하이라이트) 손가락은 스크롤만 하며, Pencil Pro 쥐기는 도구 팔레트, 두 번 탭은 직전 도구 또는 지우개(`src/ui/Pencil*`). 지우개(획·하이라이트, 한 번에 실행 취소)와 터치용 실행 취소·다시 실행 버튼, 손가락으로 글자 길게 눌러 선택, 탭한 뒤 툴팁 숨김, 세로 화면에서 떠 있는 AI 채팅, iPad 홈 화면 아이콘(`ipad` 브랜치).
- v0.5: 검색 순위, 선택적 의미 검색, 관련 논문·노트, 이름 있는 탭 그룹, AI 탭 정리.
- v1: 암호 PDF, OCR(Tesseract), 백업·복원·비정상 종료 복구·편집 초안, Markdown·BibTeX·주석 PDF 내보내기, 단축키 변경, DocumentAnchor.

## 검증

C++ 테스트(저장·마이그레이션·색인·재연결·주석·인쇄·주석 PDF·AI·의미 검색)와 offscreen UI 테스트(리더·작업 공간·웹·라이브러리·노트·AI 패널·검색 등)를 실행합니다. 웹·AI·의미 검색·OCR은 로컬 서버와 가짜 실행 파일로 검증하며 실제 키·계정·엔진은 사용자 확인이 필요합니다. 색인 DB 2→4 업그레이드를 실제 데이터 사본으로 확인했습니다.

## 다음 단계

**iPad 앱 v1 기기 확인(Synctrain 폴더, Mac의 주석, Mac이 iPad 위치 이어 읽기) → iPad 펜 기기 확인 → Pencil 글자 하이라이트 → 실사용 확인(Mac↔Ubuntu 동기화, Linux·Windows CI 결과, 의미 검색·OCR 실제 엔진, 백업 복원).** 세부 항목은 [NEXT.md](NEXT.md)에 있습니다.
