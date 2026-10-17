#!/usr/bin/env bash
# Builds Owelk from this checkout and installs it for the current user. Run it again after
# `git pull` to update; your library, notes and settings are kept (they live in the data folder).
#
#   tools/install-local.sh               build and install
#   tools/install-local.sh --clean       start the build from scratch
#   tools/install-local.sh --yes         do not ask before installing tools
#   tools/install-local.sh --deps        only set up the tools and Qt (for development, and the Dockerfile)
#   tools/install-local.sh --with-tests  also build the tests (ctest --test-dir build-release)
#
# Qt is the official build of the one version in tools/qt.txt, downloaded once into ~/Qt with aqtinstall
# (OWELK_QT=/path/to/Qt/<version>/<platform> uses another). It is never Homebrew's or the system's Qt:
# those update on their own, and Qt modules of different versions crash.
# macOS 13 or newer (Apple silicon or Intel): Apple's Command Line Tools and Homebrew (cmake, ninja, qpdf);
#   missing ones are offered. Installs ~/Applications/Owelk.app.
# Linux (Ubuntu 24.04, Debian 13 and similar, x86-64 or ARM64): build packages with apt (after asking);
#   installs to ~/.local with a menu entry.
# Nothing is bundled: the app uses that Qt, so it stays small.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build-release"
qt_setting() { sed -n "s/^$1=//p" "$ROOT/tools/qt.txt"; }
QT_VERSION="${OWELK_QT_VERSION:-$(qt_setting version)}"
read -r -a QT_MODULES <<< "$(qt_setting modules)"
# What Owelk needs from Qt (CMake packages); a Qt without one of them is completed.
QT_PACKAGES=(Quick QuickControls2 Pdf PdfQuick Sql Concurrent PrintSupport Widgets Network WebEngineQuick
    WebChannel Positioning ShaderTools LinguistTools)
# The Qt downloader (and, where the system's is too old, CMake) live here, not in the system's Python.
TOOLS="$HOME/.local/share/owelk/tools"
ASSUME_YES=0
DEPS_ONLY=0
TESTS=OFF
for arg in "$@"; do
    case "$arg" in
        --clean) rm -rf "$BUILD" ;;
        --yes) ASSUME_YES=1 ;;
        --deps) DEPS_ONLY=1 ;;
        --with-tests) TESTS=ON ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
[ -n "$QT_VERSION" ] || { echo "tools/qt.txt names no Qt version." >&2; exit 1; }

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\nOwelk install: %s\n' "$*" >&2; exit 1; }
ask() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}
# OWELK_JOBS=<n> builds with fewer jobs (linking the web engine takes much memory, e.g. in a container).
cpu_count() { echo "${OWELK_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"; }
# Containers run as root without sudo.
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi }

# --- Qt ------------------------------------------------------------------------------------------------
qt_missing() {
    local qt="$1" missing=()
    for package in "${QT_PACKAGES[@]}"; do [ -d "$qt/lib/cmake/Qt6$package" ] || missing+=("$package"); done
    echo "${missing[*]:-}"  # (bash 3.2 on macOS: an empty array is "unset")
}
python_for_tools() {
    for python in python3 /usr/bin/python3; do
        command -v "$python" >/dev/null 2>&1 || continue
        "$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null && { echo "$python"; return 0; }
    done
    return 1
}
tools_venv() {
    # A virtual environment left by a Python that is gone (an upgrade) is made again.
    "$TOOLS/venv/bin/python" -c '' 2>/dev/null && return 0
    local python
    python="$(python_for_tools)" || fail "Python 3.9 or newer is needed once, to download Qt."
    rm -rf "$TOOLS/venv"
    mkdir -p "$TOOLS"
    "$python" -m venv "$TOOLS/venv" || fail "Could not set up Python for the Qt download (Linux: python3-venv)."
}
# Sets QT_PATH: the Qt of tools/qt.txt for this system ($1 host, $2 arch, $3 folder name), downloaded or
# completed when needed.
use_qt() {
    local qt="${OWELK_QT:-$HOME/Qt/$QT_VERSION/$3}" missing
    missing="$(qt_missing "$qt")"
    if [ -n "$missing" ]; then
        [ -n "${OWELK_QT:-}" ] && fail "The Qt in $OWELK_QT lacks: $missing"
        if [ -d "$qt/lib" ]; then
            say "Qt $QT_VERSION in $qt lacks: $missing. Adding them."
        else
            say "Downloading Qt $QT_VERSION into ~/Qt (about 1.5 GB, once)"
        fi
        tools_venv
        "$TOOLS/venv/bin/pip" install --quiet --upgrade aqtinstall || fail "Could not install aqtinstall (the Qt downloader)."
        # Run from the tools folder: aqtinstall leaves its log in the current folder.
        (cd "$TOOLS" && "$TOOLS/venv/bin/aqt" install-qt "$1" desktop "$QT_VERSION" "$2" -m "${QT_MODULES[@]}" -O "$HOME/Qt") \
            || fail "Could not download Qt $QT_VERSION."
        missing="$(qt_missing "$qt")"
        [ -z "$missing" ] || fail "Qt $QT_VERSION in $qt still lacks: $missing"
    fi
    local found
    found="$("$qt/bin/qmake" -query QT_VERSION 2>/dev/null || "$qt/bin/qmake6" -query QT_VERSION 2>/dev/null || true)"
    [ "$found" = "$QT_VERSION" ] || echo "(Note: $qt is Qt ${found:-of unknown version}; tools/qt.txt says $QT_VERSION.)"
    QT_PATH="$qt"
    say "Using Qt ${found:-$QT_VERSION} in $QT_PATH"
}

configure_and_build() {
    say "Building Owelk (Release) in build-release/"
    cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING="$TESTS" "$@"
    cmake --build "$BUILD" --parallel "$(cpu_count)"
}

# --- macOS ---------------------------------------------------------------------------------------------
homebrew() {
    command -v brew >/dev/null 2>&1 && return 0
    # Where Homebrew lives on this Mac: /opt/homebrew on Apple silicon, /usr/local on Intel.
    local prefix=/opt/homebrew
    [ "$(uname -m)" = arm64 ] || prefix=/usr/local
    # Installed, but this shell does not know it yet.
    if [ -x "$prefix/bin/brew" ]; then
        eval "$("$prefix/bin/brew" shellenv)"
        return 0
    fi
    cat <<EOF

Homebrew (https://brew.sh) installs cmake, ninja and qpdf. To install it yourself, run:

  /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

and then, so new Terminal windows find it:

  echo 'eval "\$($prefix/bin/brew shellenv)"' >> ~/.zprofile
  eval "\$($prefix/bin/brew shellenv)"
EOF
    # The installer asks for your password; it cannot run unattended.
    [ "$ASSUME_YES" = 1 ] && fail "Homebrew is needed (see above)."
    ask "Run the Homebrew installer now (and add it to ~/.zprofile)?" || fail "Install Homebrew and run this again."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [ -x "$prefix/bin/brew" ] || fail "Homebrew did not install."
    grep -qs "$prefix/bin/brew shellenv" "$HOME/.zprofile" \
        || printf '\neval "$(%s/bin/brew shellenv)"\n' "$prefix" >> "$HOME/.zprofile"
    eval "$("$prefix/bin/brew" shellenv)"
}

install_macos() {
    local macos
    macos="$(sw_vers -productVersion)"
    [ "${macos%%.*}" -ge 13 ] || fail "Qt $QT_VERSION needs macOS 13 or newer; this Mac has macOS $macos."
    say "macOS $macos on $(uname -m)"
    # Apple's Command Line Tools: the C++ compiler (also Python 3 for the Qt download).
    if ! xcode-select -p >/dev/null 2>&1; then
        say "Apple's Command Line Tools (the C++ compiler) are needed."
        xcode-select --install >/dev/null 2>&1 || true
        fail "Finish the installation in the window that opened (or run: xcode-select --install), then run this again."
    fi
    homebrew
    local formulas=(cmake ninja qpdf) missing=()
    for formula in "${formulas[@]}"; do brew list --versions "$formula" >/dev/null 2>&1 || missing+=("$formula"); done
    if [ ${#missing[@]} -gt 0 ]; then
        say "Homebrew packages needed: ${missing[*]}"
        ask "Run: brew install ${missing[*]} ?" || fail "Install them and run this again."
        brew install "${missing[@]}"
    fi
    use_qt mac clang_64 macos
    if brew list --versions qt >/dev/null 2>&1; then
        echo "(Homebrew's Qt is installed too. Owelk does not use it; remove it with 'brew uninstall qt' if nothing else needs it.)"
    fi
    if [ "$DEPS_ONLY" = 1 ]; then say "Tools and Qt are ready."; return; fi
    # Only qpdf from Homebrew: a Homebrew Qt in the same prefix must never mix with the official one.
    configure_and_build -DCMAKE_PREFIX_PATH="$QT_PATH;$(brew --prefix qpdf)"

    # A running Owelk would keep the old build and receive files meant for the new one.
    # Quitting it from here could catch a development build too, so ask for Cmd+Q.
    while pgrep -f "/Owelk.app/Contents/MacOS/owelk" >/dev/null 2>&1; do
        [ "$ASSUME_YES" = 1 ] && fail "Owelk is running. Quit it (Cmd+Q) and run this again."
        read -r -p "Owelk is running. Quit it (Cmd+Q), then press Return. " _
    done
    local target="${OWELK_APP_DIR:-$HOME/Applications}/Owelk.app"
    say "Installing $target"
    mkdir -p "$(dirname "$target")"
    rsync -a --delete "$BUILD/owelk.app/" "$target/"
    touch "$target"
    # Finder's Open With and the Dock pick up the new copy (and its icon).
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" || true
    say "Done."
}

# --- Linux ---------------------------------------------------------------------------------------------
# CMake 3.24 or newer; an older system one is replaced by one in the tools folder.
cmake_new_enough() {
    local version
    version="$(cmake --version 2>/dev/null | sed -n 's/^cmake version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    [ -n "$version" ] || return 1
    set -- $version
    [ "$1" -gt 3 ] || { [ "$1" -eq 3 ] && [ "$2" -ge 24 ]; }
}

install_linux() {
    local host arch folder
    case "$(uname -m)" in
        x86_64) host=linux; arch=linux_gcc_64; folder=gcc_64 ;;
        aarch64|arm64) host=linux_arm64; arch=linux_gcc_arm64; folder=gcc_arm64 ;;
        *) fail "Unsupported processor: $(uname -m)" ;;
    esac
    # Build tools and the libraries Qt and its web engine need at run time (a desktop has most of them).
    # "new|old": a library renamed in Ubuntu 24.04 and Debian 13 (t64); the name the system knows is used.
    local packages=(build-essential cmake ninja-build pkg-config python3-venv ca-certificates libgl1-mesa-dev libegl1
        libxkbcommon-dev libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1
        libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libfontconfig1 libnss3 libxcomposite1 libxdamage1
        libxrandr2 libxtst6 libxfixes3 libxkbfile1 libsm6 libice6 libdbus-1-3 libwayland-cursor0 libwayland-egl1
        liblcms2-2 libopus0 libsnappy1v5 libwebpdemux2 libwebpmux3 'libasound2t64|libasound2' 'libcups2t64|libcups2'
        'libminizip1t64|libminizip1' libsecret-1-dev libqpdf-dev desktop-file-utils)
    if command -v apt-get >/dev/null 2>&1; then
        local missing=() wanted
        for wanted in "${packages[@]}"; do
            local installed=0 name
            for name in ${wanted//|/ }; do dpkg -s "$name" >/dev/null 2>&1 && installed=1; done
            [ "$installed" = 1 ] || missing+=("$wanted")
        done
        if [ ${#missing[@]} -gt 0 ]; then
            say "System packages needed: ${missing[*]//|/ or }"
            ask "Install them with sudo apt-get?" || fail "Install them and run this again."
            as_root apt-get update
            # After the update the package lists say which of two names this system has.
            local install=()
            for wanted in "${missing[@]}"; do
                local chosen="${wanted##*|}"
                for name in ${wanted//|/ }; do
                    if apt-cache show "$name" >/dev/null 2>&1; then chosen="$name"; break; fi
                done
                install+=("$chosen")
            done
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${install[@]}"
        fi
    else
        say "No apt here: install these (or your system's names for them) yourself if the build stops:"
        echo "  a C++20 compiler, CMake 3.24+, Ninja, pkg-config, Python 3 with venv, OpenGL/EGL, xkbcommon,"
        echo "  xcb-cursor, D-Bus, NSS, ALSA, CUPS, libsecret and qpdf development files"
    fi
    if ! cmake_new_enough; then
        say "CMake 3.24 or newer is needed; adding one to $TOOLS"
        tools_venv
        "$TOOLS/venv/bin/pip" install --quiet --upgrade cmake ninja || fail "Could not install CMake."
        export PATH="$TOOLS/venv/bin:$PATH"
    fi
    use_qt "$host" "$arch" "$folder"
    if [ "$DEPS_ONLY" = 1 ]; then say "Tools and Qt are ready."; return; fi
    configure_and_build -DCMAKE_PREFIX_PATH="$QT_PATH"

    # The program keeps its build path to Qt in ~/Qt; a launcher in ~/.local/bin starts it.
    local home="${OWELK_PREFIX:-$HOME/.local}"
    say "Installing into $home"
    install -Dm755 "$BUILD/owelk" "$home/lib/owelk/owelk"
    mkdir -p "$home/bin"
    cat > "$home/bin/owelk" <<EOF
#!/bin/sh
exec "$home/lib/owelk/owelk" "\$@"
EOF
    chmod 755 "$home/bin/owelk"
    install -Dm644 "$ROOT/resources/app/owelk.png" "$home/share/icons/hicolor/512x512/apps/owelk.png"
    mkdir -p "$home/share/applications"
    sed "s|^Exec=.*|Exec=$home/bin/owelk %F|" "$ROOT/resources/app/owelk.desktop" > "$home/share/applications/owelk.desktop"
    update-desktop-database "$home/share/applications" >/dev/null 2>&1 || true
    gtk-update-icon-cache -q "$home/share/icons/hicolor" >/dev/null 2>&1 || true
    say "Done."
    case ":$PATH:" in *":$home/bin:"*) ;; *) echo "($home/bin is not on PATH; the menu entry works regardless.)" ;; esac
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux) install_linux ;;
    *) fail "This script covers macOS and Linux; on Windows use tools\\install-local.ps1." ;;
esac
