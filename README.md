# Owelk

A quiet place to read papers. Fast, light, and it stays on your machine.

PDFs, highlights, notes, a library, search, AI that cites the page, web tabs, sync across computers.
That's the short list.

## Install

```sh
tools/install-local.sh          # build and install; after git pull, run it again to update
tools/install-local.sh --clean  # rebuild from scratch
```

- **macOS** uses the official Qt in `~/Qt/6.11.3/macos` when it is there (or `OWELK_QT=/path/to/Qt/<version>/macos`), otherwise Homebrew's Qt, and installs to `~/Applications/Owelk.app`. qpdf, cmake and ninja come from Homebrew.
- **Linux** (Ubuntu 24.04 and similar) fetches Qt 6.11 into `~/Qt` once (about 1.5 GB) and adds a menu entry.
- **Windows** (10/11, x64): `powershell -ExecutionPolicy Bypass -File tools\install-local.ps1` (`-Clean` to rebuild).
  It sets up the build tools with winget, fetches Qt 6.11 into `%USERPROFILE%\Qt` once, and adds a Start menu entry.
- Your library, notes and settings live in the app data folder, so reinstalling keeps them.

Nice to have: [Tesseract](https://github.com/tesseract-ocr/tesseract) for scanned PDFs,
[Ollama](https://ollama.com) for search by meaning, an API key or a ChatGPT account for AI.

## Develop

```sh
cmake -S . -B build -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build --parallel 6
ctest --test-dir build --output-on-failure
open -n build/owelk.app --args --data-dir "$PWD/build/manual-data"   # run with test data
```

C++20, Qt 6.11 (Quick, PDF, WebEngine), SQLite. macOS, Linux, Windows.

## Promises

- Your PDFs are never touched. Annotations live beside them, and export as a copy when you want one.
- Nothing leaves your computer except web tabs, lookups you ask for, and AI requests you agree to.
- Heavy work (indexing, OCR, backups) waits while you read.

## More

[Status](docs/STATUS.md) · [Next](docs/NEXT.md) · [Sync](docs/SYNC.md) · [Annotations](docs/HIGHLIGHTS.md) · [Search](docs/SEARCH.md) · [Relinking PDFs](docs/RELINK.md) · [Design](docs/DESIGN.md) · [Performance](docs/PERFORMANCE.md)
