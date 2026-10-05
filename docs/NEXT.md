# 다음 개발

구현 이력은 git 로그와 [STATUS.md](STATUS.md)를 참고하세요. 아래는 남은 작업만 적습니다. 가볍고 빠름을 먼저 지키고, 실사용 불편을 기획서 순서보다 먼저 처리합니다.

## 1. 실사용 확인 (사용자)

- GitHub에 push해 CI(Ubuntu·Windows·macOS) 결과 확인 → 실패 로그를 주면 고칩니다.
- Linux·Windows에서 실제 실행: 키 저장(키링·자격 증명 관리자), 파일 대화상자, 단축키 기본값.
- 인쇄(실제 프린터·PDF로 저장), 주석 포함 PDF를 미리보기·Acrobat·Okular에서 열어 보기.
- 의미 검색: Ollama `nomic-embed-text` 또는 OpenAI 키로 켜고 검색·관련 논문 확인.
- OCR: Tesseract 설치 후 스캔 PDF 검색.
- 백업 → 복원 → 재시작, 암호 PDF 열기·기억.
- 실제 AI 키로 답변·추론 강도·Fast, 기관 PDF 다운로드, 트랙패드·마우스 버튼.

## 2. 디자인 손질

- 진행 중: 테마 엔진(7종·강조색·글자 크기) → 아이콘 → 공통 컨트롤·목록 → 우클릭 통일 → Settings 재구성 → 화면 다듬기.

## 3. 읽기 품질

- 실제 큰 PDF·여러 분할에서 초기 표시·스크롤·선택 지연, GPU 프레임, 메모리 측정.
- 웹 탭 전환 시 페이지 상태 유지, Reader Mode.
- 테스트 중 리더가 닫힌 뒤 실행되는 지연 호출 경고(`PdfCanvas.qml` `refreshHighlights`) 정리.

## 4. 연구 지능 (v0.6)

- 여러 논문 비교·워크스페이스 요약, 인용 그래프, 라이브러리 전체에 묻기(의미 검색 결과를 근거로).

## 5. 남은 v1 세부

- 설치 패키지(macOS dmg, Windows 설치본, Linux AppImage)와 서명.
- 앵커를 저장 형식으로도 통합(현재는 읽을 때 구성), Figure 자동 캡처, Smart Collection.
