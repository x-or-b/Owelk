# 컴퓨터 사이 동기화

Mac과 Ubuntu처럼 여러 컴퓨터에서 같은 라이브러리를 씁니다. 서버나 계정은 따로 없습니다. Google Drive, Dropbox, Syncthing, 네트워크 공유처럼 **다른 프로그램이 컴퓨터끼리 맞춰 주는 폴더**를 하나 고르면, Owelk는 그 폴더에 변경 기록과 PDF를 놓고 읽어 옵니다.

## 켜기

1. 각 컴퓨터에서 공유 폴더 프로그램을 설치하고, 같은 폴더가 양쪽에 보이게 합니다(아래 Google Drive 참고).
2. Owelk **Settings → Data → Sync → Choose Folder…**에서 그 폴더를 고릅니다.
   - 빈 폴더를 고르면 그대로 쓰고, 다른 파일이 있는 폴더(예: Google Drive의 `My Drive`)를 고르면 그 안에 `Owelk` 폴더를 만들어 씁니다. 그래서 두 컴퓨터에서 모두 `My Drive`를 골라도 같은 곳을 씁니다.
3. 다른 컴퓨터에서도 같은 폴더를 고릅니다. 처음 한 번은 라이브러리 전체와 PDF를 옮기므로 시간이 걸립니다.

이후에는 실행 중 30초마다, 종료할 때 자동으로 맞춥니다. **Sync Now**로 바로 맞출 수도 있습니다. 같은 행에 마지막 동기화 시각, 아직 도착하지 않은 파일 수, 함께 쓰는 컴퓨터 이름이 보입니다.

### Google Drive

- **macOS**: [Google Drive for desktop](https://www.google.com/drive/download/)을 설치하면 Finder에 `Google Drive/My Drive`가 생깁니다. 그 안의 `Owelk` 폴더(또는 `My Drive`)를 고릅니다. 오프라인에서도 쓰려면 해당 폴더를 우클릭 → *Available offline*을 켭니다.
- **Ubuntu**: Google의 공식 앱이 없으므로 둘 중 하나를 씁니다.
  - **rclone**(무료): `sudo apt install rclone` → `rclone config`로 `gdrive` 원격 추가 → `rclone mount gdrive: ~/GoogleDrive --vfs-cache-mode full --daemon`. 로그인할 때마다 켜지도록 systemd 사용자 서비스나 시작 프로그램에 같은 명령을 넣습니다. Owelk에서는 `~/GoogleDrive/Owelk`(또는 `~/GoogleDrive`)를 고릅니다.
  - **Insync**(유료, 설정이 쉬움): 동기화할 폴더에 `Owelk`를 넣고 그 로컬 폴더를 고릅니다.
  - GNOME 온라인 계정의 Google Drive는 파일 하나하나가 느려서 권하지 않습니다.
- rclone 마운트가 꺼져 있으면 빈 폴더만 남는데, Owelk는 폴더 안의 `owelk-sync.json` 표식이 처음 고른 것과 같을 때만 읽고 쓰므로 그 상태에서는 아무것도 하지 않고 "The sync folder is not available"을 보여 줍니다.

### 다른 방법

- **Syncthing**: 두 컴퓨터가 직접 주고받습니다(클라우드 없음, 무료). 양쪽 모두 켜져 있을 때 옮겨집니다.
- **Dropbox**: macOS·Ubuntu 모두 공식 앱이 있습니다.

## 옮겨지는 것

| 옮김 | 각 컴퓨터에 남음 |
| --- | --- |
| 논문 목록과 정보(제목·저자·읽기 상태·즐겨찾기), PDF 파일 | 설정(테마·단축키·AI 키·다운로드 폴더 등) |
| 하이라이트·코멘트·텍스트·그림·펜 주석, 캡처(이미지·노트·휴지통 상태) | 지금 열린 탭(세션), 편집 중 초안 |
| 노트와 링크, Collection·Tag, 워크스페이스 | 검색 색인·의미 벡터(각자 PDF로 다시 만듦) |
| 최근 논문·읽던 위치, AI 대화 | 원본 재연결 기록 |

- 다른 컴퓨터에서 온 PDF는 데이터 폴더의 `papers/`에 원래 파일 이름으로 복사됩니다. 원래 컴퓨터의 PDF 위치는 바뀌지 않습니다.
- PDF가 아직 공유 폴더에 도착하지 않았으면 논문은 먼저 목록에 나타나고, 파일은 도착하는 대로 복사됩니다("waiting for N files").
- 양쪽에 **같은 PDF**(바이트가 같은 파일)가 이미 있었다면 하나의 논문으로 합치고 양쪽 주석을 모두 남깁니다. 이름이 같은 Tag도 하나로 합칩니다.

## 충돌

같은 항목(노트 하나, 주석 하나, 논문 정보 하나)을 두 컴퓨터에서 고쳤다면 **나중에 고친 쪽**이 남습니다. 서로 다른 항목은 모두 유지됩니다. 한쪽에서 지우고 다른 쪽에서 고친 경우에도 나중 쪽이 남습니다. 컴퓨터 시계가 크게 틀리면 순서가 어긋날 수 있으니 자동 시간 맞춤을 켜 둡니다.

## 폴더 구조

```
Owelk/
  owelk-sync.json          라이브러리 표식
  devices/<컴퓨터 ID>/       컴퓨터마다 자기 변경 기록(*.jsonl)만 씀
  Papers/<SHA-256>.pdf     PDF
  Files/captures, Files/annotations   캡처·그림 주석 이미지
```

각 컴퓨터가 자기 폴더에만 쓰므로 Drive가 "충돌 사본"을 만들 일이 없습니다. 이 폴더의 파일을 직접 고치거나 지우지 마세요. 동기화를 끄려면 **Turn Off**를 누릅니다(공유 폴더와 데이터는 그대로). 다시 켜면 그동안의 변경도 함께 옮깁니다.

## 한계

- 변경 기록은 지우지 않고 쌓입니다(텍스트라 작음). 정리 기능은 후속 범위입니다.
- 원래 컴퓨터에서 PDF를 다른 버전으로 재연결해도 다른 컴퓨터의 사본은 바꾸지 않습니다.
- iPad 앱은 아직 없습니다.
