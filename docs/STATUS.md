# 기획서 대비 구현 현황

2026-10-01 기준. 현재는 **PDF 리더 + 웹 탭 + 라이브러리(Collection·Tag·읽기 상태) + 캡처·주석·독립 노트와 연결 + 본문/저장 항목 검색 + AI 읽기 보조**를 갖춘 개발용 Research Workspace입니다. 기획서 v0.1–v0.4 범위를 대부분 구현했습니다. macOS에서 빌드·자동 검증했고 Linux/Windows 실기기 검증은 남아 있습니다.

| 기획서 | 현재 구현 | 남은 범위 |
| --- | --- | --- |
| 1–3. 개요·원칙 | 로컬 저장, 원본 PDF 불변, 출처 검증(SHA-256·파일 스탬프 캐시), 동일 원본 재연결, 외부 전송은 웹 탭·명시적 조회·동의한 AI 요청만 | 성능 실측, 버전별 재연결 |
| 4. 객체 모델 | 공통 Document ID(PDF·웹 페이지), 논문 정보, 캡처·주석·노트·AI 답변·링크 | 탭·세션 JSON은 URL 기반, `DocumentAnchor` 일반화 |
| 5–6. 실행·Home | 세션·워크스페이스 자동 복원, Home 검색·이어 읽기·최근 논문·워크스페이스(삭제 복원), Library 진입 | 손상 복구 UI |
| 7–10. 문서·웹·탭 | PDF 읽기·뒤로/앞으로 기록·다중 분할·탭/분할 단축키·드래그 자동 스크롤, 웹 탭(주소/검색, arXiv Open PDF, PDF 다운로드→리더), Settings | Reader Mode, 웹 탭 상태 유지, OS 창 분리 |
| 11. 정리 | 워크스페이스, 라이브러리(중첩 Collection·Tag·즐겨찾기·Unread/Reading/Read·중복 표시·본문 검색 제외) | 이름 있는 Tab Group, AI 탭 정리 |
| 12–16. 검색·커맨드 | FTS5 본문, 논문 정보·캡처(그림 캡션 포함)·주석·노트·AI 답변·Collection·Tag 검색, 라이브러리 범위 필터, 명령 팔레트 | 의미 검색(v0.5) |
| 17–21. 캡처·연결 | 영역(캡션)·텍스트(여러 페이지)·웹 페이지 캡처, 휴지통 복원·영구 삭제, 5색 주석·코멘트, 노트 `[[` 링크·역링크, Link to Note | 객체(Figure 자동) 캡처, 주석 PDF 내보내기 |
| 22–27. 노트·AI | 독립 Markdown 노트(자동 저장·휴지통), AI 제공자 4종(Claude API, OpenAI API, ChatGPT 계정/Codex, Ollama), Explain/Translate/Summarize/Ask·그림 설명, 동의·Keychain, 답변 저장·노트화 | AI 탭 정리·스마트 정리(v0.5+), 여러 논문 비교(v0.6) |
| 28–32. 데이터·기술 | C++20 + Qt Quick/PDF/WebEngine, SQLite 스키마 8(업그레이드 전 자동 백업), 비동기 작업, 자동 테스트 6묶음 | 실제 PDF·GPU·메모리 측정, Linux/Windows |

## 우선순위

기획서 순서보다 실제 사용 중 불편한 부분을 먼저 고칩니다. 기능별 사용법은 [README](../README.md)와 각 문서(HIGHLIGHTS, SEARCH, RELINK, WORKSPACES, CAPTURE_NOTES, CAPTURE_TRASH)에, 변경 이력은 git 로그에 있습니다.

## 이번 단계 (2026-10-01): v0.1–v0.4 남은 범위

- Trash 카드 정리, 읽기 뒤로/앞으로, 읽기 상태·즐겨찾기·중복 파일 안내, 드래그 자동 스크롤, 제목·저자 추출 개선과 `Look up online`(arXiv·Crossref, 버튼을 누를 때만).
- 웹 탭과 PDF 다운로드, Settings. 라이브러리 탭(Collection·Tag·필터)과 범위 검색.
- 독립 노트·링크·역링크, 그림 캡션, 웹 캡처, 여러 페이지 선택, 삭제 워크스페이스 복원.
- AI: 제공자 계층·Keychain·동의, 작성 창·답변 저장. Claude.ai 계정 로그인은 Anthropic이 제삼자 앱에 허용하지 않아 제외했습니다(Claude는 API 키로 사용).

## 검증

C++ 테스트(저장·마이그레이션·인덱스·재연결·텍스트 캡처·AI 제공자)와 Qt offscreen UI 테스트(리더·작업 공간·웹·라이브러리·노트·AI 작성 창 등)를 실행합니다. 웹과 AI는 로컬 HTTP 서버와 가짜 Codex app server로 검증하며 실제 키·계정 호출은 사용자 확인이 필요합니다. 마이그레이션은 실제 데이터 사본으로 0→8 업그레이드를 확인했습니다.

## 다음 단계

**실사용 확인(웹·AI 실제 계정, 트랙패드) → 의미 검색(v0.5) → 여러 논문 비교(v0.6).** 세부 항목은 [NEXT.md](NEXT.md)에 있습니다.
