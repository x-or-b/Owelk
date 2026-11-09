# 다음 개발

구현 이력은 git 로그와 [STATUS.md](STATUS.md)를 참고하세요. 아래는 남은 작업만 적습니다. 가볍고 빠름을 먼저 지키고, 실사용 불편을 기획서 순서보다 먼저 처리합니다.

## 1. 실사용 확인 (사용자)

- Gloss 단어장: 실제 논문에서 단어를 Gloss → ☆ → Library › Words에 문장과 함께 나오는지, 누르면 그 쪽으로 가서 밝혀지는지, 두 컴퓨터에서 오가는지. Export한 CSV를 Excel·Numbers에서(한글 깨짐 없이), Anki 카드를 Anki에서 가져와 앞면·뒷면이 맞는지.
- arXiv 새 버전: Settings › Library에서 켜고 예전 버전 arXiv PDF(첫 쪽 여백에 arXiv:…vN)를 넣어 다음 날(또는 처음 켤 때) "vN available"이 뜨는지, Get vN…으로 받은 논문이 원래 논문과 따로 생기고 원본·주석이 그대로인지, 실제 arxiv.org 응답 속도. 학회·저널에 실린 arXiv 논문에서 "Published" 칩과 Paper Details 제안이 맞는지.
- Figures 탭: 여러 출판사 PDF(IEEE·ACM·arXiv 2단, 쪽 전체 그림, 표 캡션이 위에 있는 경우)에서 그림·표가 빠짐없이·잘못된 것 없이 나오는지, 썸네일이 그림 부분을 보여 주는지, 긴 논문에서 탭을 열 때 읽기가 끊기지 않는지.
- 고정 카드: 그림·표·수식 미리보기에서 핀을 눌러 띄우고 스크롤·막대 끌기·모서리 크기 조절·트랙패드 핀치 확대·누르면 이동이 자연스러운지, Dark pages에서 반전되는지, 탭을 바꾸면 그 탭 것만 보이는지.
- 읽은 시간: 논문을 10분쯤 읽고 Home으로 가서(1분 안에 저장) 달력 오늘 칸·Today·Library 행·Paper Details가 맞는지, 3분 동안 스크롤·키·클릭이 없으면 멈추는지, 다른 앱이 앞에 있어도 Owelk 창이 열려 있고 논문이 앞에 있으면 세는지(최소화하면 멈춤). 두 컴퓨터에서 같은 날 읽은 시간이 동기화 후 합쳐지는지.

- Settings › Library의 요약·인용 수를 직접 켜 Semantic Scholar의 실제 응답·요약 유무·속도 제한을 확인. 끄면 추가 요청·표시가 멈추는지 확인.

- 여러 출판사 PDF의 Code links: 본문 URL·클릭 가능한 링크·References 제외 결과 확인.

- macOS 트랙패드: 자연스러운 스크롤 켬/끔에서 오른쪽 손가락 이동이 뒤로인지, 확대 PDF 가장자리·취소·관성·시스템 페이지 간 쓸어넘기 끔을 확인.

- GitHub에 push해 CI(Ubuntu·Windows·macOS) 결과 확인 → 실패 로그를 주면 고칩니다.
- Linux·Windows에서 실제 실행: 키 저장(키링·자격 증명 관리자), 파일 대화상자, 단축키 기본값.
- 인쇄(실제 프린터·PDF로 저장), 주석 포함 PDF를 미리보기·Acrobat·Okular에서 열어 보기.
- 의미 검색: Ollama `nomic-embed-text` 또는 OpenAI 키로 켜고 검색·관련 논문 확인.
- OCR: Tesseract 설치 후 스캔 PDF 검색.
- 백업 → 복원 → 재시작, 암호 PDF 열기·기억.
- 실제 AI 키로 답변·추론 강도·Fast, 기관 PDF 다운로드, 트랙패드·마우스 버튼.
- ChatGPT 계정(새 방식): Settings › AI에서 ChatGPT account → Continue with ChatGPT로 개인 계정 로그인, 모델 목록·답변·한 시간 뒤 다시 답변(토큰 갱신)·Sign Out이 되는지. 실패하면 Account 줄에 이유가 남습니다. 조직(학교·회사) 계정은 이 방식을 쓸 수 없을 수 있어 ChatGPT account (Codex)는 계속 둡니다.
- Match System: macOS·Windows·Linux에서 시스템의 밝은/어두운 모드를 바꿀 때 테마가 바로 따라가는지(Linux는 데스크톱에 따라 알려 주지 않을 수 있음).
- 동기화: Mac(Google Drive for desktop)과 Ubuntu(rclone·Insync)에서 같은 폴더를 골라 논문·주석·노트가 오가는지, 같은 노트를 양쪽에서 고쳤을 때 나중 것이 남는지.

- iPad 앱(사용자): 보기·주석·다시 열면 읽던 쪽은 기기에서 확인됨(2026-11-05). 남은 것: iPad가 쓴 파일이 Mac에 오는지(Synctrain 폴더가 Send & Receive인지, 안 오면 Synctrain에서 Rescan) → Mac에서 Sync Now 후 iPad에서 읽던 쪽으로 가는지, Settings › Sync에 iPad가 보이는지. 논문 추가: + › Add PDFs from Files…, 파일 앱에서 끌어다 놓기, + › Search the Web…(Google Scholar·arXiv에서 Add to Library, 학교 로그인으로 출판사 PDF) → Mac Library에 원래 파일 이름으로 들어오는지, 저자·연도가 Mac을 다시 켜거나 그 논문을 열면 채워지는지, Collection을 보던 중 추가하면 그 Collection에 들어가는지.

## 1-0. For You 후속

- 실사용 확인: 실제 arXiv·Semantic Scholar로 주제·Collection 결과가 적당한지, 하루 한 번 확인이 거슬리지 않는지.
- AI 정리 실사용 확인: 실제 모델의 점수·이유가 쓸 만한지, 비용이 적당한지(새 논문이 많으면 40편씩).
- 주제에 넣을 Collection 고르기(지금은 Unsorted), Semantic Scholar 키(속도 제한 완화) 선택 입력.
- 연구자·기관 팔로우 실사용 확인: 실제 이름 검색과 동명이인 구분, 기관 하나가 가져오는 양(서울대는 일주일에 160편 안팎이라 개수를 작게), 학교 네트워크에서 OpenAlex 무료 한도.
- 기관에 단어 거르기(예: 이 기관의 robotics 논문만). Linux·Windows 상단 바 끄기 실사용 확인(탭 줄 양 끝 버튼, Home 검색).

## 1-1. 구조 단순화 후속

- 실사용 확인: 업그레이드 후 예전 Workspaces·Captures가 Collection·주석·노트로 잘 바뀌었는지, Document 패널 Annotations에서 코멘트 쓰기, 논문 옆 새 노트, Library Trash.
- Library 패널의 폴더 탐색을 남길지(사용자 결정 대기). Annotations 목록에 영역 주석의 작은 그림 보여 주기.
- 세션 버전 1(분할 두 개 시절) 변환 코드 정리 여부.

## 2. 디자인 후속

- 실제 화면에서 테마 7종·글자 크기 11/17·Dark pages 확인 후 색 미세 조정.
- 웹 페이지 자체의 다크 모드(WebEngine), 썸네일의 Dark pages, 검색 결과 행의 우클릭(논문 메뉴).

## 3. 읽기 품질

- 실제 큰 PDF·여러 분할에서 초기 표시·스크롤·선택 지연, GPU 프레임, 메모리 측정.
- Reader Mode.
- 테스트 `Notes::test_newNoteAutosavesLinksAndTrash`가 Document 패널이 왼쪽에 열리기를 기다리다 실패합니다(이번 세션 전 QML로도 같음, 원인 미확인).

## 3-1. 정리·보기 다음 단계

- Smart Collection(조건 저장). AI 정리를 의미 검색 벡터로 먼저 묶고 AI에는 이름 짓기만 맡기기(보내는 양 감소).
- 좁은 창: 세로 탭 + 양쪽 패널 + 분할 2개일 때 문서 영역이 일정 폭 아래로 줄면 패널을 자동으로 접기(사용자 결정 대기).
- 두 쪽 보기(spread): 페이지 목록·선택·주석 좌표가 모두 "한 줄 한 쪽"을 전제하므로 위험이 커서 보류. 필요하면 별도 단계로 설계(사용자 결정 대기).
- 참조 미리보기 보강: 저자·연도 인용 정확도, 스캔 PDF(OCR 글자 사용).

## 4. 연구 지능 (v0.6)

- 라이브러리 묻기에 의미 검색 결과도 근거로 쓰기, Zotero·BibTeX 가져오기(보류 중).

## 4-1. 동기화 다음 단계

- 변경 기록 정리(오래된 `devices/*.jsonl`을 한 파일로 합치기), 공유 폴더의 쓰이지 않는 그림 주석 이미지 정리(PDF는 완전히 삭제할 때 지움, 2026-11-05).
- 일부 설정(테마·AI 언어 등)도 옮길지 결정(사용자 결정 대기).
- iPad 앱(네이티브, `ios/`) 다음 단계: 펜·지우개·실행 취소(PencilKit, 2026-11-06)는 기기에서 써 보기(Pencil은 그리고 손가락은 스크롤, Draw를 끄면 Pencil도 손가락처럼, Mac 획 지우기, 두 손가락 탭 실행 취소, 두 번 탭·쥐기, 획 굵기가 Mac과 같고 펜을 뗄 때 굵기가 바뀌지 않는지. 2026-11-06 첫 확인에서 받은 획이 흐리고 가늘게, 그리는 획은 굵게, 확대하면 흐리게 보여서 끝난 획은 PDFKit 표시로 그리도록 고침. 두 번째 확인에서 PDFKit 표시도 확대하면 계단처럼 깨지고, 드래그가 가끔 튀며, 그리기를 시작할 때 화면이 위로 튀어서 표시를 쪽 위 층의 벡터로, 캔버스는 Draw 중에만, Draw 중 PDFKit 제스처는 손가락만 받게 고침. 기기에서 다시 볼 것: 확대해도 선명한지, 읽을 때 스크롤이 매끄러운지, 그리기 시작할 때 튀지 않는지, Draw 버튼이 켜진 게 보이는지. 세 번째 확인에서도 튀어서 기기 진단 기록으로 원인이 PDFKit 쪽 미리보기임을 찾아 직접 만든 쪽 목록으로 바꿈. 기기에서 볼 것: 획을 긋고 쪽을 넘기고 확대해도 화면이 그대로인지, 옆 쪽 그림과 쪽 번호 누르기로 이동이 되는지, 위쪽 바가 지나가는 쪽을 흐리게 비추는지(Liquid Glass), Settings의 Sync Now·Change Folder…). 그다음 ① Pencil로 글줄을 그어 글자 하이라이트(PDF 글자에 붙어 Mac에서 검색·인용·AI) ② 영역 표시·코멘트(Scribble) ③ 필압 굵기(굵기 열과 데스크톱 그리기를 함께) ④ 노트 읽기·쓰기 ⑤ AI·Gloss·인용 ⑥ 다른 앱 공유 시트의 "Owelk에서 열기"(`CFBundleDocumentTypes`, 지금은 끌어다 놓기·파일 앱으로 추가). Qt iPad 빌드(`ipad` 브랜치)는 네이티브 앱이 기기에서 자리 잡을 때까지 예비로 둡니다.

## 4-2. AI 답변 다음 단계

- 실사용 확인: 여러 출판사 PDF에서 그림·표·알고리즘·수식 인식, 기호 힌트가 본문 단어에 잘못 뜨지 않는지, Gloss 속도. 스캔 PDF(글자 없음)는 인식할 수 없어 Region of the PDF로 첨부합니다.
- 그림·표 영역 인식 개선: 캡션(제목) 위에서는 잘 맞지만, 한 단에 그림과 표가 붙어 있거나 글 없는 그림이 이어질 때 본문 쪽 영역이 엇갈릴 수 있음. 쪽을 낮은 해상도로 그려 빈 가로 띠로 그림 경계를 찾는 방법을 검토.
- 코드 저장소(GitHub) 코드 설명은 보류.

- 답이 인용한 쪽·그림의 썸네일 줄(내 PDF에서, 누르면 그 쪽으로). 수식 이미지의 복사(지금은 선택 복사 시 수식이 빠짐)와 매우 넓은 수식의 가로 넘침 처리.

## 5. 남은 v1 세부

- 배포 패키지(macOS dmg, Linux AppImage, Windows 설치본)와 서명: 다른 사람에게 나눠 줄 때. 지금은 `tools/install-local.sh`.
- 앵커를 저장 형식으로도 통합(현재는 읽을 때 구성), Figure 자동 인식, Smart Collection.

## 6. 읽기 편의 다음 단계

- 2·3단계(읽기 달력, 고정 카드, Figures, arXiv 새 버전 알림, Gloss 단어장)는 끝났습니다(STATUS.md).
- 다음 후보: Words 단어장 복습 카드(플래시카드).
