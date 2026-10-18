# Owelk

A quiet place to read papers. Fast, light, and it stays on your machine.

PDFs, highlights, notes, a library, search, AI that cites the page, web tabs, sync across computers.
That's the short list.

## Install

```sh
tools/install-local.sh          # build and install; after git pull, run it again to update
tools/install-local.sh --clean  # rebuild from scratch
```

Owelk is built with one exact Qt, named in [`tools/qt.txt`](tools/qt.txt) (now 6.11.3). The script downloads that
official Qt once into `~/Qt` and never uses Homebrew's or the system's Qt: those update on their own, and Qt
modules of different versions crash. Your library, notes and settings live in the app data folder, so
reinstalling keeps them.

**macOS** 13 or newer, Apple silicon or Intel. Installs `~/Applications/Owelk.app`.

1. Apple's Command Line Tools (the compiler): `xcode-select --install`
2. [Homebrew](https://brew.sh), for cmake, ninja and qpdf:

   ```sh
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile   # Intel Macs: /usr/local/bin/brew
   eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

3. `tools/install-local.sh`. It offers to do steps 1 and 2 when they are missing, then installs cmake, ninja
   and qpdf with Homebrew and Qt into `~/Qt/6.11.3/macos` (about 1.5 GB, once).

**Linux** (Ubuntu 24.04, Debian 13 and similar; x86-64 or ARM64): `tools/install-local.sh` installs the build
packages with apt (after asking), Qt into `~/Qt` (about 1.5 GB, once), and Owelk into `~/.local` with a menu entry.

**Windows** 10 (1809 or newer) or 11, x64: `powershell -ExecutionPolicy Bypass -File tools\install-local.ps1`
(`-Clean` to rebuild). It sets up Visual Studio Build Tools and Python with winget (after asking), Qt into
`%USERPROFILE%\Qt` (about 2 GB, once), and adds a Start menu entry.

**Docker**: builds and tests the Linux version in a container, from any computer (the image follows the
processor, so Apple silicon builds for ARM64):

```sh
docker build -t owelk .    # the first build downloads Qt; later builds reuse it
docker run --rm owelk      # runs every test, offscreen
docker rmi owelk           # removes the image (several GB)
```

Reading in Owelk from a container needs a Linux desktop with X11
(`docker run --rm -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix -e QT_QPA_PLATFORM=xcb owelk owelk`, untested);
on macOS and Windows install it as above.

Nice to have: [Tesseract](https://github.com/tesseract-ocr/tesseract) for scanned PDFs,
[Ollama](https://ollama.com) for search by meaning, an API key or a ChatGPT account for AI.

## Develop

```sh
tools/install-local.sh --deps   # tools and Qt only
cmake -S . -B build -DCMAKE_PREFIX_PATH="$HOME/Qt/6.11.3/macos;$(brew --prefix qpdf)"   # Linux: ~/Qt/6.11.3/gcc_64
cmake --build build --parallel 6
ctest --test-dir build --output-on-failure
open -n build/owelk.app --args --data-dir "$PWD/build/manual-data"   # run with test data
```

C++20, Qt 6.11 (Quick, PDF, WebEngine), SQLite. macOS, Linux, Windows.

## Promises

- Your PDFs are never touched. Annotations live beside them, and export as a copy when you want one.
- Nothing leaves your computer except web tabs, lookups you ask for, and AI requests you agree to.
- Library summaries and citation counts stay off until you turn them on; then only DOI or arXiv IDs go to Semantic Scholar.
- Newer arXiv versions stay unchecked until you turn them on; then only arXiv IDs go to arxiv.org, once a day.
- Heavy work (indexing, OCR, backups) waits while you read.

## More

[Status](docs/STATUS.md) · [Next](docs/NEXT.md) · [Sync](docs/SYNC.md) · [Annotations](docs/HIGHLIGHTS.md) · [Search](docs/SEARCH.md) · [Relinking PDFs](docs/RELINK.md) · [Design](docs/DESIGN.md) · [Performance](docs/PERFORMANCE.md)
