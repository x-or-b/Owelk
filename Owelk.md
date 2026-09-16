# Research Workspace 앱 제품·개발 기획서

**문서 상태:** 초기 개발 기획 / Team Kickoff Draft  
**대상 플랫폼:** Desktop — macOS 최우선, Linux / Windows 지원  
**장기 확장:** iPad / Apple Pencil 지원  
**제품 유형:** Local-first Research Workspace / Paper Reader / Research Browser

---

# 1. 프로젝트 개요

## 1.1 한 문장 정의

**논문, 웹, 메모, 캡처, 아이디어를 한 공간에서 읽고 검색하고 연결하고 정리할 수 있는 연구자용 Research Workspace.**

단순한 PDF Reader나 AI PDF Chat 서비스가 아니다.

사용자가 논문을 발견하고, 읽고, 인용된 다른 자료를 따라가고, 관련 내용을 검색하고, 중요 내용을 저장하고, 메모하고, 서로 연결하고, 이후 다시 찾아보는 **연구 자료 소비의 전체 흐름**을 하나의 프로그램 안에서 처리하는 것을 목표로 한다.

핵심 개념은 다음과 같다.

**Read → Search → Connect → Organize → Browse → AI**

AI는 앱의 기반이 아니라 이 모든 작업을 가속하는 보조 계층으로 설계한다.

개발 목적은 제작자 본인과 주변 동료가 대학원 연구 과정에서 직접 사용하는 도구를 만드는 것이다. 판매와 경쟁 제품 대비 차별화를 개발 목표로 삼지 않는다.

주요 사용자는 대학원생 및 대학원 진학을 준비하는 학부연구생이다. 여러 논문 비교, 그림·문장 수집, 저장한 근거의 검색을 중점적으로 개선한다. **사용 중의 편의성과 반응 속도**를 최우선으로 판단하며, 실제 사용 평가는 제작자와 동료가 수행한다.

---

# 2. 제품이 해결하려는 문제

현재 논문을 읽는 일반적인 흐름은 여러 프로그램에 분산되어 있다.

예를 들어 사용자는 다음과 같은 작업을 반복한다.

1. 브라우저에서 arXiv / Google Scholar / 논문 검색
2. PDF 다운로드
3. PDF Viewer에서 읽기
4. 인용 논문을 보기 위해 다시 브라우저로 이동
5. 메모 앱에 내용 기록
6. 중요한 그림은 Screenshot
7. PDF 폴더 또는 Zotero 등에 논문 정리
8. 며칠 뒤 해당 내용을 어디서 봤는지 다시 검색
9. ChatGPT 등에 필요한 문장이나 이미지를 복사하여 질문

문제는 각 작업이 서로 연결되어 있지 않다는 것이다.

특히 연구 자료가 많아질수록 다음 문제가 커진다.

- 이전에 읽은 내용을 어디에서 봤는지 찾기 어렵다.
- 논문 제목은 기억나지 않지만 내용 일부만 기억나는 경우 검색하기 어렵다.
- PDF 메모와 별도 메모 앱의 내용이 분리된다.
- Screenshot은 원본 논문의 위치와 연결되지 않는다.
- 참고문헌을 따라가면서 브라우저 탭이 과도하게 늘어난다.
- 여러 논문을 특정 연구 주제로 묶어 관리하기 어렵다.
- 어제 하던 연구 작업을 다음 날 그대로 이어가기 어렵다.
- AI에게 질문할 때 현재 보고 있는 문맥을 다시 전달해야 한다.

Research Workspace는 이 문제들을 하나의 데이터 모델과 UI 안에서 해결한다.

---

# 3. 제품 핵심 원칙

## 3.1 Search is Core

검색은 부가기능이 아니다.

PDF Viewer와 동급의 **핵심 기능**으로 취급한다.

사용자는 몇 개월 전에 읽었던 내용도 기억나는 단어나 개념만으로 빠르게 찾아낼 수 있어야 한다.

검색 대상은 장기적으로 다음을 포함한다.

- 논문 제목
- 저자
- Abstract
- 논문 전체 본문
- 사용자가 작성한 Note
- Highlight
- Excerpt
- Capture
- Figure caption
- AI 답변
- Collection
- Workspace
- Tag
- Web resource

AI가 없어도 기본 검색은 빠르고 완전하게 동작해야 한다.

Semantic Search는 이후 추가되는 검색 강화 기능이다.

---

## 3.2 Reading must feel instant

Zed의 UI를 복제하는 것이 목표가 아니다.

다만 Zed를 사용할 때 느껴지는 것처럼 **입력에 즉각 반응하는 앱**을 목표로 한다.

제품의 중요한 성능 원칙:

> Every interaction should feel instant. Heavy work must be deferred.

PDF 전체 분석, Thumbnail 생성, 검색 Indexing, Embedding 생성 등의 무거운 작업 때문에 사용자가 문서를 여는 것을 기다려서는 안 된다.

문서를 열면 현재 필요한 부분을 우선 표시하고 나머지는 background에서 처리한다.

---

## 3.3 Local-first

논문, 메모, Highlight, Workspace 등의 기본 데이터는 로컬에서 관리한다.

AI 사용 여부와 관계없이 앱의 핵심 기능이 동작해야 한다.

장점:

- 인터넷 없이도 논문 읽기 가능
- 연구 자료를 외부 서버로 전송할 필요 없음
- 빠른 검색
- 사용자가 자신의 연구 자료를 직접 소유
- 향후 연구실 내부 모델 / Ollama 등의 Local AI와 쉽게 연결 가능

Cloud Sync는 이후 별도 기능으로 고려한다.

---

## 3.4 Source-aware Knowledge

사용자가 저장한 내용은 가능한 한 항상 **원본 Source와 연결**되어 있어야 한다.

예를 들어 논문의 문장을 Workspace에 저장했다면 단순 문자열을 저장하는 것으로 끝나면 안 된다.

해당 항목을 클릭하면 다시:

**논문 → 해당 페이지 → 해당 문장**

으로 이동할 수 있어야 한다.

Figure Capture도 마찬가지다.

Screenshot 이미지만 저장하는 것이 아니라:

- 어떤 Document인지
- 어느 페이지인지
- 어느 영역인지
- 주변 텍스트가 무엇인지

를 함께 기억해야 한다.

---

# 4. 핵심 객체 모델

앱 전체를 PDF 중심으로 설계하지 않는다.

모든 연구 자료를 `Document` 또는 `Knowledge Object`로 취급한다.

```text
Document
├─ PDF
├─ arXiv HTML
├─ Web Page
└─ Saved Web Resource

Knowledge Object
├─ Note
├─ Highlight
├─ Excerpt
├─ Capture
├─ Figure
├─ AI Response
└─ Link

Organization
├─ Collection
├─ Workspace
├─ Session
├─ Tab Group
└─ Tag
```

이 구조를 기준으로 PDF와 HTML에서 가능한 기능을 최대한 동일하게 제공한다.

---

# 5. 기본 사용자 경험

## 5.1 프로그램 실행

기본적으로 사용자가 어제 하던 연구 작업을 그대로 이어갈 수 있어야 한다.

최근 Session이 존재하는 경우:

```text
App Start

        ↓

Restore Last Session

        ↓

열려 있던 Tab
현재 Workspace
Split Layout
문서별 Scroll 위치
현재 읽던 Page
```

앱을 종료하기 전에 저장 버튼을 누를 필요는 없다.

Session은 자동 저장한다.

---

# 6. Home 화면

새 창을 열었거나 복원할 Session이 없는 경우 Home 화면을 표시한다.

검색은 중요한 기능이므로 **화면 중앙의 시각적 중심**에 배치한다.

예시:

```text
┌─────────────────────────────────────────────────────┐
│                                                     │
│               Search your research                  │
│         papers, notes, highlights, web...           │
│                                                     │
├─────────────────────────────────────────────────────┤
│ Continue Reading                                    │
│                                                     │
│ OVIP-SG       3.2 FAV-Gate              Continue → │
│                                                     │
├─────────────────────────┬───────────────────────────┤
│ Recent Workspaces       │ Recent Papers             │
│                         │                           │
│ Semantic Mapping        │ Gaussian Splatting        │
│ OVIP-SG Study           │ FAST-LIO2                 │
│ RL Study                │ ConceptGraphs             │
└─────────────────────────┴───────────────────────────┘
```

Home 구성:

- 중앙 Global Search
- Continue Reading
- Recent Workspaces
- Recent Papers

검색창만 있는 Launcher 형태는 지양한다.

이 앱의 일반적인 사용자는 매번 새로운 것을 검색하기보다 **어제 보던 자료를 계속 보는 상황이 많기 때문**이다.

---

# 7. Document / Browser 시스템

앱 가운데의 콘텐츠 영역은 하나의 타입으로 고정하지 않는다.

```text
Content Surface

├─ PdfSurface
├─ ArticleSurface
├─ WebSurface
├─ NoteSurface
└─ SearchSurface
```

사용자 입장에서는 모두 Tab으로 보인다.

예:

```text
[OVIP-SG.pdf]
[ConceptGraphs - arXiv HTML]
[Google Scholar]
[GitHub]
[My Note]
```

내부적으로 Resource Router가 URL 또는 파일 타입에 따라 적절한 Surface를 선택한다.

```text
Local PDF
    → PdfSurface

Remote PDF
    → PdfSurface

arXiv HTML
    → ArticleSurface 또는 WebSurface

일반 URL
    → WebSurface
```

---

# 8. PDF

초기 PDF 구현은 Qt PDF를 1순위 후보로 한다. Qt Quick의 PdfMultiPageView와 하위 구성요소를 활용하여 선택·검색·페이지 이동을 구현한다.

Annotation 저장, Source Anchor, Region Capture는 앱에서 구현한다. 본격적인 기능 개발 전에 실제 논문의 스크롤·확대·선택·분할 화면을 확인하여 채택을 확정한다. 기술 스택의 선택 근거와 대안은 31절을 따른다.

필수 기능:

- 빠른 Open
- Page virtual rendering
- Text selection
- Text search
- Zoom
- Thumbnail
- Link handling
- 페이지 이동
- 마지막 읽은 위치 저장
- Highlight
- Capture
- Split View

중요한 원칙:

PDF 전체 페이지를 처음부터 렌더링하지 않는다.

현재 Viewport 주변을 우선 처리한다.

```text
현재 Page 150

148 preload
149 render
150 render
151 render
152 preload
```

Text indexing 등의 부가 작업도 가능하면 background 처리한다.

---

# 9. HTML / Web

PDF뿐 아니라 HTML 논문도 동일한 연구 자료로 취급한다.

대표적인 사용 예:

- arXiv HTML
- DOI 페이지
- Semantic Scholar
- Google Scholar
- 논문 프로젝트 페이지
- GitHub
- 일반 연구 관련 웹페이지

링크를 클릭할 때 가능하면 앱 밖의 브라우저로 튕겨나가지 않고 새로운 Tab에서 연다.

예:

```text
OVIP-SG
    ↓ citation
CLIP paper
    ↓ project page
GitHub
```

이 연구 흐름을 하나의 Session으로 유지한다.

---

# 10. Tab과 Split View

연구 중 여러 자료를 동시에 비교하는 상황을 지원한다.

예:

```text
┌──────────────────┬──────────────────┐
│                  │                  │
│     Paper A      │     Paper B      │
│                  │                  │
└──────────────────┴──────────────────┘
```

또는:

```text
┌──────────────────┬──────────────────┐
│                  │                  │
│      Paper       │      Notes       │
│                  │                  │
└──────────────────┴──────────────────┘
```

Tab은 단순 URL 목록이 아니라 Session 및 Workspace와 연결 가능한 객체로 본다.

---

# 11. Collection / Workspace / Session / Tab Group

이 네 개념은 서로 명확하게 분리한다.

## Collection

장기적인 논문 정리 구조.

쉽게 말하면 **연구자의 책장**이다.

```text
Robotics
├─ SLAM
├─ Semantic Mapping
└─ Manipulation

AI
├─ Vision
├─ VLM
└─ Foundation Models
```

하나의 논문이 여러 Collection에 들어갈 수 있다.

파일을 복사하지 않고 Reference만 추가한다.

---

## Workspace

특정 연구 주제나 조사를 진행하기 위한 **작업 공간**이다.

예:

```text
Workspace
"Semantic Mapping 조사"

Papers
├─ OVIP-SG
├─ ConceptGraphs
└─ OpenScene

Notes
├─ 주요 아이디어
└─ 비교 내용

Captures
Figures
Excerpts
Web Links
```

Collection이 자료 정리라면 Workspace는 **현재 연구 활동의 Context**다.

---

## Session

특정 시점의 UI 및 작업 상태.

자동 저장한다.

Session에는 다음 등이 포함된다.

```text
Open Tabs
Active Tab
Scroll Position
Split Layout
Active Workspace
Tab Groups
```

Session 덕분에 사용자는 프로그램을 다시 켰을 때 이전 작업을 그대로 이어갈 수 있다.

---

## Tab Group

현재 열려 있는 Tab의 임시 그룹.

```text
Semantic Mapping
├─ OVIP-SG
└─ ConceptGraphs

Models
├─ CLIP
└─ SAM2

Implementation
├─ GitHub
└─ Project Page
```

사용자가 직접 정리하거나 AI에게 분류를 요청할 수 있다.

유용한 Tab Group은 이후:

- Workspace로 저장
- Collection으로 저장

할 수 있다.

---

# 12. Global Search

검색은 앱 어디에서든 즉시 접근 가능해야 한다.

검색 대상:

```text
Paper title
Author
Abstract
Paper full text

Notes
Highlights
Excerpts
Captures
Figure captions

Collections
Workspaces
Tags

Open Tabs
Recent Resources
```

초기 검색은 SQLite FTS 기반의 빠른 lexical search를 사용한다.

검색 결과는 객체 타입별로 구분한다.

예:

```text
Search: occlusion

PAPERS
OVIP-SG
  Section 3.2 ...

NOTES
OVIP-SG / FAV-Gate
  "multi-frame으로 occlusion..."

HIGHLIGHTS
OVIP-SG p.6
  "...occluded object..."

CAPTURES
Figure 3 · OVIP-SG

WORKSPACES
Semantic Mapping
```

검색 결과를 클릭하면 가능한 경우 **해당 Document의 정확한 원본 위치**로 이동한다.

---

# 13. Semantic Search

AI 버전 이후 추가한다.

정확한 단어를 기억하지 않아도 내용을 찾을 수 있게 한다.

예:

```text
"책상 뒤에 물체가 가려진 경우 처리했던 내용"
```

검색 결과:

```text
occlusion
containment
multi-view aggregation
FAV-Gate
관련 Note
관련 Highlight
```

Semantic Search 대상:

- Paper sections
- Notes
- Highlights
- Excerpts
- Captures metadata
- AI Responses

Semantic Search는 기본 검색을 대체하지 않는다.

FTS Search + Semantic Search를 병행한다.

---

# 14. Command Palette

Command Palette는 단순 명령 실행기가 아니라:

**검색 + 이동 + 명령 + 입력**

을 담당하는 Universal Input으로 설계한다.

예상 단축키:

```text
Cmd/Ctrl + K
```

일반 문자열을 입력하면 전체 검색.

```text
gaussian splatting
```

`/`로 시작하면 Command Mode.

```text
/open paper
/new workspace
/open workspace
/search arxiv
/ask ai
/split right
/organize tabs
```

---

# 15. Slash Command UX

명령어는 argument를 받을 수 있다.

예:

```text
/open paper gau
```

입력 중 실시간으로:

```text
Gaussian Splatting for Real-Time...
Gaussian-SLAM...
SplaTAM...
```

자동완성 후보를 표시한다.

Tab 키:

```text
Tab → 현재 추천값 자동완성
```

Enter:

```text
Enter → 명령 실행
```

---

## Command별 Argument Provider

명령마다 argument 타입이 다르다.

예:

```text
/open paper <paper search>

/open workspace <workspace search>

/new workspace <plain text>

/add collection <collection search>

/search arxiv <search query>
```

Command Palette 엔진은 각 명령이 자신의 argument search provider를 등록할 수 있도록 설계한다.

---

# 16. `/ask ai`

`/ask ai`는 다른 명령보다 복잡하므로 일반 한 줄 명령으로 제한하지 않는다.

실행하면 작은 AI Composer 형태로 확장될 수 있다.

예:

```text
/ask ai
────────────────────────────────

[OVIP-SG p.6 selected text] ×
[Figure 3] ×
[My Note] ×

왜 여기서 이 방법이 필요한 거야?

+ Attach                       Ask
```

AI Context로 첨부 가능한 항목:

- 선택된 Text
- Capture
- Figure
- 현재 Page
- 현재 Section
- Note
- 다른 Paper
- Image
- File

향후 AI 질문 기능은 이 Composer를 공통 UI로 사용하는 방향을 고려한다.

---

# 17. Capture 시스템

Capture는 앱의 핵심 기능으로 취급한다.

일반 Screenshot보다 중요한 개념이다.

목표:

> 사용자가 논문 또는 웹에서 중요하다고 판단한 내용을 떼어내어 메모, Workspace, AI와 연결할 수 있게 한다.

Capture는 가능한 한 Source 위치를 기억한다.

---

# 18. Capture 종류

## Text Capture

텍스트를 선택하여 저장.

```text
selected text
document
page / position
source anchor
```

사용자가 Text Capture를 클릭하면 원문 위치로 이동한다.

텍스트로 저장되므로:

- 검색 가능
- Copy 가능
- Semantic Search 가능
- AI Context로 바로 사용 가능

---

## Region Capture

사용자가 화면 또는 Document의 특정 사각 영역을 지정한다.

주 사용처:

- Figure
- Table
- Equation
- 여러 요소가 섞인 영역

저장 정보:

```text
Document
Page
Bounding Box
Rendered Image
Nearby Text
Caption
Source Anchor
```

단순 PNG가 아니다.

---

## Object Capture

향후 Document 분석이 충분히 안정적일 경우 제공한다.

예:

사용자가 Figure 위에 마우스를 올리면:

```text
Figure 3
[Capture Figure]
```

자동으로 Figure 전체 + Caption을 저장한다.

Table / Equation 등으로 확장 가능.

---

## Screen Capture

Document 구조와 무관하게 현재 화면 영역을 캡처한다.

주로:

- Web UI
- GitHub
- Diagram
- 일반 웹페이지

등에서 사용한다.

---

# 19. Capture 후 Action

Capture 직후 작은 Action UI를 제공한다.

예:

```text
Note
Add to Workspace
Ask AI
Link
Copy
Save
```

Capture는 Workspace 내 객체로 들어갈 수 있다.

예:

```text
[Captured Figure]
        │
        ▼
[My Note]
        │
        ▼
[Another Paper Excerpt]
```

---

# 20. Highlight / Excerpt / Capture 차이

Highlight:

> 원문 내부에서 중요한 부분 표시

Excerpt:

> 원문의 일부를 작업 공간으로 꺼내어 독립적인 Knowledge Object로 사용

Capture:

> Text / Region / Figure / Screen 등을 Source-aware Object로 저장

이 세 개념을 구분한다.

특히 Excerpt는 LiquidText 계열 UX처럼 **원문과의 연결을 유지한 채 Workspace에 배치하는 객체**로 사용한다.

---

# 21. Workspace Linking

Workspace에서는 Knowledge Object 사이의 관계를 표현할 수 있어야 한다.

예:

```text
[FAV-Gate Excerpt]
        │
        │ related
        ▼
[My Note: occlusion]
        │
        ▼
[Figure 3]
        │
        ▼
[ConceptGraphs Paper]
```

초기에는 단순 Link로 시작하고 이후:

- directional edge
- relationship type
- backlinks

등을 확장할 수 있다.

---

# 22. Notes

Note는 특정 PDF에 종속되지 않는다.

Markdown 기반 저장을 우선 고려한다.

Note는 다음과 연결 가능해야 한다.

```text
Paper
Excerpt
Capture
Figure
Workspace
Other Note
Web Page
```

Note에서 연결된 Source를 클릭하면 해당 원문으로 이동한다.

---

# 23. AI Architecture

AI는 Provider abstraction으로 설계한다.

예:

```text
AI Provider

├─ Ollama
├─ OpenAI API
├─ Gemini API
├─ Anthropic API
└─ Future Provider
```

초기부터 특정 AI 회사에 Core Architecture를 종속시키지 않는다.

초기에는 실제로 사용할 Provider 하나만 구현한다. 후보:

1. Ollama
2. OpenAI API

두 후보의 동시 지원은 초기 완료 조건이 아니다. 작은 공통 인터페이스만 두고, 두 번째 Provider는 실제 필요가 생기면 추가한다.

ChatGPT 계정 기반 모델 호출은 현재 Core Requirement로 두지 않는다.

향후 공식적인 integration 방식이 제공되면 별도 Provider로 추가할 수 있도록 구조만 준비한다.

---

# 24. AI Reader 기능

AI 초기 기능:

```text
Explain Selection
Translate Selection
Summarize Section
Ask about Selection
Ask about Page
Ask about Paper
Explain Figure
```

AI가 질문 Context를 자동으로 구성할 수 있어야 한다.

예:

```text
Current Document
Current Section
Visible Context
Selected Text
Attached Capture
Related Note
```

사용자가 매번 논문의 배경을 설명할 필요가 없어야 한다.

---

# 25. AI Response 역시 Knowledge Object

AI 답변은 일회성 Chat History로만 남기지 않는다.

사용자가 원하면:

```text
AI Response
    ↓
Save to Workspace
Save as Note
Link to Excerpt
```

가 가능해야 한다.

검색 Index에도 포함할 수 있다.

---

# 26. AI Tab Organization

연구 중 Tab이 많이 쌓였을 때 AI에게 정리를 요청할 수 있다.

예:

```text
Organize 23 Tabs
```

AI 분석 대상:

```text
Tab title
URL
Paper metadata
Abstract
현재 Section
```

결과 예:

```text
Semantic Mapping (7)
Gaussian Splatting (5)
SLAM (6)
Implementation (3)
Misc (2)
```

중요 원칙:

AI가 사용자 데이터를 자동으로 재배치하지 않는다.

```text
Suggested Groups
       ↓
     Apply
```

형태로 사용자 승인을 거친다.

---

# 27. Smart Organization

장기적으로 AI를 사용해 다음 작업을 지원할 수 있다.

```text
"이 탭들 주제별로 정리"
"내 Library의 LiDAR SLAM 논문만 모아줘"
"이 Workspace와 관련된 기존 논문 찾아줘"
"읽지 않은 Semantic Mapping 논문 보여줘"
```

AI는 Organization assistant 역할을 수행한다.

---

# 28. 데이터 모델 초안

핵심 Entity:

```text
Document

PaperMetadata

DocumentAnchor

Annotation
├─ Highlight
├─ Comment
└─ Future Ink

Capture
├─ TextCapture
├─ RegionCapture
├─ ObjectCapture
└─ ScreenCapture

Note

Excerpt

Link

Collection

Workspace

Session

Tab

TabGroup

Tag

AIResponse
```

---

# 29. Anchor 구조

Note와 Capture를 PDF 좌표에 직접 종속시키지 않는다.

공통 Anchor abstraction을 둔다.

예:

```text
DocumentAnchor
```

구현:

```text
PdfAnchor
├─ page
├─ rectangles
└─ selected text

HtmlAnchor
├─ url
├─ text quote
├─ selector
└─ position

ArticleAnchor
├─ section
├─ paragraph
└─ text range
```

이를 통해 PDF와 HTML에서 동일한 Annotation 시스템을 사용할 수 있다.

---

# 30. iPad v2를 위한 데이터 설계

Desktop v1에서는 iPad UI를 구현하지 않는다.

다만 데이터 모델이 future Ink Annotation을 수용할 수 있게 한다.

예:

```text
InkAnnotation

points[]
pressure[]
timestamp[]
source anchor
```

향후 iPad에서는:

```text
SwiftUI
+
PencilKit
```

등 Native UI를 별도로 구현하는 방향을 고려한다.

Desktop UI를 iPad에 억지로 재사용하지 않는다.

공유 대상은 UI보다 **데이터 모델 및 Sync Protocol**이다.

---

# 31. 기술 스택 — 초기 권장안

사용 중의 편의성과 반응 속도를 최우선으로 하며, macOS에서 먼저 완성하고 Linux / Windows에서도 동작하도록 설계한다.

**1순위 후보는 Qt 6 + Qt Quick/QML + C++ + Qt PDF다.** 이는 요구 기능과 통합 부담에 따른 권장안이며, 다른 구현보다 빠르다는 실측 결과는 아니다. 작은 읽기 프로토타입에서 체감 품질을 확인한 뒤 채택을 확정한다.

```text
Desktop
Qt 6

Language
C++ / QML

UI
Qt Quick / Qt Quick Controls

PDF
Qt PDF
PdfMultiPageView 및 하위 구성요소

Database
SQLite

Full Text Search
SQLite FTS5

Web
Qt WebEngine / WebEngineView
웹 화면이 필요할 때 생성

Background Work
Qt 작업 스레드 / 작업 큐
취소 가능한 렌더링·텍스트 추출·인덱싱 작업

Build
CMake

AI
작은 Provider interface
실제로 사용하는 공급자 하나부터 구현
```

Qt를 우선 검토하는 이유:

- macOS / Linux / Windows용 공통 구현이 가능하다.
- 앱 UI는 Qt Quick으로 렌더링하며, 웹 콘텐츠는 별도 WebEngineView에서 처리한다.
- Qt PDF의 선택·검색·링크·페이지 이동 기능을 재사용할 수 있다.
- PDF, 메모, 캡처, 분할 화면을 하나의 UI 체계에서 구성할 수 있다.
- PDF 리더의 기본 상호작용을 직접 만드는 부담을 줄이고 연구 기능에 집중할 수 있다.

고려할 비용:

- C++ / QML 학습과 Qt 빌드 환경 관리가 필요하다.
- Qt WebEngine은 Chromium 기반이므로 웹 탭의 메모리·프로세스 비용은 별도로 관리해야 한다.
- Qt를 사용해도 캐시, 작업 우선순위, 지연 생성이 부적절하면 느려질 수 있다.
- macOS의 입력·트랙패드·고해상도 화면 동작과 Linux / Windows의 기본 동작을 실제로 확인한다.

대안:

- **Tauri 2 + Rust + 웹 UI + PDF.js:** 웹 UI와 Rust를 선호할 때의 대안이다. OS별 WebView를 사용하므로 엔진 차이를 확인해야 한다. PDF.js 기반 읽기 속도가 Rust 사용만으로 개선되는 것은 아니다. 같은 창의 여러 웹 화면과 분할 배치도 초기 검증 대상이다.
- **Rust + GPUI + 별도 PDF 엔진:** GPU 기반 UI를 직접 제어할 수 있으나 PDF 선택·주석·웹 통합 부담이 크다. GPUI와 PDF 엔진을 연결하는 개발 자체가 우선 목표가 될 때 재검토한다.
- **Electron:** 필수 조건으로 두지 않는다. 다른 후보가 필요한 웹 동작을 충족하지 못하는 경우에만 재검토한다.

초기부터 Qt와 Rust를 함께 도입하지 않는다. 명확한 필요가 생기기 전에는 C++ / QML로 구현 언어와 경계를 단순하게 유지한다.

채택 전 읽기 프로토타입:

1. 실제 사용하는 PDF 두 편을 분할 화면으로 연다.
2. 빠른 스크롤, 확대, 텍스트 선택·복사, 검색 결과 이동을 확인한다.
3. 영역 캡처와 원문 위치 재이동을 구현한다.
4. 백그라운드 텍스트 추출 중에도 위 상호작용이 부드러운지 확인한다.
5. 웹 탭을 추가하고 전환·포커스·메모리 사용을 확인한다.
6. macOS에서 일상 사용 품질을 판단하고 Linux / Windows에서 핵심 경로를 확인한다.

참고 문서:

- [Qt PDF](https://doc.qt.io/qt-6/qtpdf-index.html)
- [Qt Quick PDF 뷰어](https://doc.qt.io/qt-6/qml-qtquick-pdf-pdfmultipageview.html)
- [Qt Quick 렌더링 구조](https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html)
- [Qt WebEngine 플랫폼 요구사항](https://doc.qt.io/qt-6/qtwebengine-platform-notes.html)
- [Tauri 프로세스 모델](https://v2.tauri.app/concept/process-model/)
- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui)

---

# 32. Performance Requirements

성능은 제품 기능으로 취급한다.

주요 원칙:

```text
UI thread에서 heavy computation 금지

PDF lazy rendering

Virtualized lists

Background indexing

Thumbnail lazy generation

Search incremental update

AI request async

Large Library startup scan 최소화

Session restore 우선
Background data refresh 후처리
```

특히 앱 실행 시 전체 Library를 재분석해서는 안 된다.

---

# 33. Version Roadmap

## v0.1 — Daily Reader

목표:

> 기존 PDF Viewer + Browser 대신 실제로 사용 가능한 수준.

기능:

```text
Desktop app
PDF open
Fast PDF rendering
Web browsing
arXiv browsing
Tabs
Back / Forward
Split view
PDF text search
Recent documents
Reading position save
Session restore
Basic Command Palette
Home
```

성공 기준:

**사용자가 실제 논문을 읽을 때 기존 PDF Reader 대신 이 앱을 자연스럽게 선택한다.**

---

# 34. v0.2 — Research Library & Search

목표:

> 논문이 쌓여도 쉽게 찾고 관리할 수 있다.

추가:

```text
Library
Paper metadata
Title
Authors
Year
DOI
arXiv ID
Abstract

Collection
Tag
Favorite

Reading State
Unread / Reading / Read

Duplicate detection

Full-text indexing

Global Search 1.0
```

검색 대상:

```text
Title
Author
Abstract
Paper text
Collection
Tag
```

---

# 35. v0.3 — Notes & Workspace

목표:

> 논문을 단순히 읽는 것을 넘어 연구 내용을 정리할 수 있다.

추가:

```text
Highlight
Note
Excerpt

Text Capture
Region Capture
Screen Capture

Workspace

Object Linking

Paper ↔ Note
Excerpt ↔ Source
Capture ↔ Source

Backlinks
```

Global Search 2.0:

```text
Papers
Notes
Highlights
Excerpts
Captures
Figure captions
```

---

# 36. v0.4 — AI Reader

목표:

> Moonlight류 AI 기능을 연구 흐름 안에 자연스럽게 통합한다.

추가:

```text
Ollama 또는 OpenAI API — 초기에는 하나
Provider abstraction

Explain
Translate
Summarize
Ask Selection
Ask Section
Ask Paper
Explain Figure

AI Composer

Context Attachment

AI Response → Workspace / Note
```

---

# 37. v0.5 — Smart Search & Organization

목표:

> 쌓여 있는 연구 지식을 쉽게 다시 찾고 정리한다.

추가:

```text
Semantic Search

Hybrid Search
FTS + Semantic

AI Tab Organization

Smart Collection

Related Notes

Related Papers in Library

Search ranking improvements
```

예:

```text
"전에 컵이 책상 뒤에 가려지는 내용"
```

만으로 관련 논문, Note, Highlight를 찾을 수 있어야 한다.

---

# 38. v0.6 — Research Intelligence

목표:

> 개별 논문이 아니라 Research Library 전체를 대상으로 AI를 사용한다.

추가:

```text
Multi-paper Q&A
Paper comparison
Workspace summary
Citation graph
Related paper discovery
Library-aware AI
Research timeline
Topic extraction
```

예:

```text
"이 세 논문의 방법 차이 정리"

"내가 읽었던 Semantic Mapping 논문에서
CLIP 사용 방법 비교"

"OVIP-SG와 비슷한 내 Library 논문"
```

---

# 39. v0.7 — Research Browser 강화

목표:

> 논문 탐색부터 Library 저장까지의 흐름을 개선한다.

기능 후보:

```text
Citation hover preview

Reference → Paper preview

Add to Library

arXiv Reader Mode

DOI handling

Paper metadata auto import

Web resource save

BibTeX
```

예:

```text
[12]

ConceptGraphs
Gu et al.

Abstract ...

Open
PDF
Add to Library
```

---

# 40. v1.0 — Daily Research Workspace

새 기능보다는 품질과 안정성에 집중한다.

우선순위:

```text
Startup speed
PDF scrolling
Instant search
Memory usage
Crash recovery
Session restore
Keyboard navigation
Shortcut customization
UI polish

Library migration
Backup
Export

BibTeX
Markdown export

Stable annotation
Reliable indexing
```

v1.0 성공 기준:

> 사용자가 논문을 읽고 정리하고 찾기 위해 다른 앱을 켤 이유가 크게 줄어든다.

---

# 41. v2 — iPad / Apple Pencil

Desktop v1 안정화 이후 진행한다.

Desktop과 iPad의 역할은 다르게 본다.

Desktop:

```text
Search
Web research
Organization
AI
Multi-paper comparison
```

iPad:

```text
Reading
Highlight
Handwriting
Apple Pencil
Capture
Excerpt
Workspace
```

추가 기능:

```text
Apple Pencil

Ink annotation

Circle / underline

Free handwriting

Margin note

Ink selection

Handwriting → Text

Desktop Sync
Workspace Sync
```

iPad UI는 별도로 설계한다.

---

# 42. MVP에서 하지 않을 것

초기 Scope를 관리하기 위해 다음은 v0.1에서 제외한다.

```text
완전한 Zotero 대체

Cloud Sync

Collaboration

iPad

Handwriting

Citation Graph

Semantic Search

AI Knowledge Agent

Reference Manager의 모든 기능

AI 자동 파일 이동

모든 사이트에 대한 완벽한 Reader Mode
```

---

# 43. 개발 우선순위

전체 기능 중 실제 사용성을 가장 크게 결정하는 순서는 다음으로 본다.

```text
1. 빠르게 읽기
2. 하던 작업 이어가기
3. 정확하게 검색
4. 편하게 정리
5. 내용 연결
6. Capture
7. AI
8. AI 자동 정리
9. iPad
```

AI는 의도적으로 후순위에 둔다.

좋은 AI 기능보다 먼저 **좋은 Research Workspace**가 만들어져야 한다.

---

# 44. 초기 개발 Workstream 제안

팀 개발을 시작할 때 다음 단위로 병렬 작업할 수 있다.

### A. Application Shell

담당:

```text
Window
Tabs
Split View
Navigation
Home
Session
Command Palette
```

### B. Document Engine

담당:

```text
Qt PDF integration
PDF rendering
Text selection
PDF search
Document Anchor
WebSurface
```

### C. Library & Search

담당:

```text
SQLite schema
Document DB
Metadata
Collection
Tag
FTS
Global Search
```

### D. Knowledge Workspace

v0.3부터:

```text
Note
Highlight
Excerpt
Capture
Workspace
Link
```

### E. AI Layer

v0.4부터:

```text
Provider interface
선택한 Provider 하나
Context Builder
AI Composer
```

---

# 45. v0.1 개발 순서 제안

팀이 바로 시작한다면 다음 순서가 적절하다.

아래 단계에 앞서 31절의 작은 읽기 프로토타입으로 기술 스택을 검증한다. 성능 검토는 마지막 단계에만 수행하지 않고 PDF·분할 화면·검색이 추가될 때마다 실제 사용으로 확인한다.

```text
Step 1
Qt Quick Application Shell

Step 2
Tab / Navigation 구조

Step 3
Qt PDF integration

Step 4
Qt WebEngine 기반 WebSurface

Step 5
Resource Router

Step 6
Split View

Step 7
Session model

Step 8
Reading position restore

Step 9
Home

Step 10
Command Palette

Step 11
Basic Search

Step 12
성능 개선 및 Daily Usage 테스트
```

첫 목표는 기능 수가 아니다.

**실제로 논문 한 편을 처음부터 끝까지 이 앱으로 읽을 수 있는가**를 확인한다.

---

# 46. UX 검증 시나리오

초기 버전 테스트는 다음 실제 사용 흐름으로 진행한다.

```text
1. 앱 실행

2. 어제 읽던 논문이 자동으로 열린다.

3. 읽던 위치부터 계속 읽는다.

4. 논문의 Citation을 클릭한다.

5. 관련 논문이 새로운 Tab에 열린다.

6. arXiv HTML을 읽는다.

7. PDF가 필요해 PDF Tab을 연다.

8. 두 논문을 Split View로 비교한다.

9. Command Palette를 열어 다른 논문을 검색한다.

10. 앱을 종료한다.

11. 다음 날 다시 실행한다.

12. 모든 작업 상태가 복원된다.
```

v0.1은 이 흐름을 매우 안정적이고 빠르게 수행해야 한다.

---

# 47. v0.3 이후 UX 검증 시나리오

```text
1. 논문 문장을 Highlight한다.

2. 중요한 문장을 Excerpt로 Workspace에 가져온다.

3. Figure를 Region Capture한다.

4. Excerpt와 Figure 사이에 Link를 만든다.

5. 옆에 내 Note를 작성한다.

6. 다른 논문에서 관련 내용을 가져온다.

7. 며칠 뒤 검색창에 기억나는 단어를 입력한다.

8. 내 Note, Paper, Highlight, Capture가 함께 검색된다.

9. 검색 결과를 클릭한다.

10. 원 논문의 정확한 위치가 열린다.
```

이 흐름이 Research Workspace의 핵심 가치다.

---

# 48. 제품 성공 기준

최종적으로 이 앱이 제공해야 하는 경험은 다음과 같다.

사용자가 어제 읽던 논문을 바로 이어서 읽을 수 있다.

논문을 읽다가 Reference를 따라 다른 논문과 웹페이지를 탐색할 수 있다.

중요한 내용은 Highlight, Excerpt, Capture, Note 형태로 저장할 수 있다.

저장된 모든 항목은 원본 Source와 연결되어 있다.

수개월 뒤에도 기억나는 단어나 개념만으로 해당 내용을 빠르게 찾을 수 있다.

여러 자료를 Workspace 안에서 연결하며 연구 아이디어를 정리할 수 있다.

AI는 현재 보고 있는 Document와 Workspace의 문맥을 이해하고 사용자의 읽기와 정리를 보조한다.

많이 열린 Tab은 AI가 주제별 그룹을 제안할 수 있다.

그리고 이 모든 기능은 앱이 무거워졌다는 느낌 없이 빠르게 동작해야 한다.

---

# 49. 제품 핵심 문장

이 프로젝트를 개발하면서 판단이 애매할 때는 다음 기준을 사용한다.

> **이 기능이 사용자가 논문을 읽고, 다시 찾고, 연결하고, 정리하는 과정을 더 빠르고 자연스럽게 만드는가?**

그렇지 않다면 우선순위를 낮춘다.

제품은 기능이 많은 연구 플랫폼이 되는 것이 목표가 아니다.

**연구자가 실제로 매일 켜놓고 사용하는 Research Workspace가 되는 것이 목표다.**
