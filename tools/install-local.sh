#!/usr/bin/env bash
# Builds Owelk from this checkout and installs it for the current user. Run it again after
# `git pull` to update; your library, notes and settings are kept (they live in the data folder).
#
#   tools/install-local.sh            build and install
#   tools/install-local.sh --clean    start the build from scratch
#   tools/install-local.sh --yes      do not ask before installing system packages (Linux)
#
# macOS: uses Homebrew's Qt (brew install qt qpdf cmake ninja) and installs ~/Applications/Owelk.app.
# Linux (Ubuntu 24.04 and similar): installs the build tools with apt (after asking), puts the
# official Qt 6.11 in ~/Qt (the system Qt is too old), and installs to ~/.local with a menu entry.
# Nothing is bundled: the app uses that Qt, so it stays small.
set -euo pipefail

QT_VERSION="${OWELK_QT_VERSION:-6.11.3}"
QT_MODULES="qtpdf qtwebengine qtwebchannel qtpositioning qtimageformats qtshadertools"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build-release"
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --clean) rm -rf "$BUILD" ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\nOwelk install: %s\n' "$*" >&2; exit 1; }
ask() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}
cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

configure_and_build() {
    say "Building Owelk (Release) in build-release/"
    cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF "$@"
    cmake --build "$BUILD" --parallel "$(cpu_count)"
}

install_macos() {
    command -v brew >/dev/null || fail "Homebrew is needed: https://brew.sh"
    local missing=()
    for formula in qt qpdf cmake ninja; do brew list --versions "$formula" >/dev/null 2>&1 || missing+=("$formula"); done
    if [ ${#missing[@]} -gt 0 ]; then
        say "Homebrew packages needed: ${missing[*]}"
        ask "Run: brew install ${missing[*]} ?" || fail "Install them and run this again."
        brew install "${missing[@]}"
    fi
    local qt
    qt="$(brew --prefix qt)"
    configure_and_build -DCMAKE_PREFIX_PATH="$qt"

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
    say "Done. Open Owelk from ~/Applications, Spotlight or Launchpad."
    echo "To open PDFs with it by default: Finder → a PDF → Get Info → Open with: Owelk → Change All."
}

install_linux() {
    local host arch
    case "$(uname -m)" in
        x86_64) host=linux; arch=linux_gcc_64; QT_DIR_NAME=gcc_64 ;;
        aarch64|arm64) host=linux_arm64; arch=linux_gcc_arm64; QT_DIR_NAME=gcc_arm64 ;;
        *) fail "Unsupported processor: $(uname -m)" ;;
    esac
    # Build tools and the libraries Qt and its web engine need at run time.
    local packages=(build-essential cmake ninja-build pkg-config python3-venv libgl1-mesa-dev libegl1
        libxkbcommon-dev libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1
        libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libfontconfig1 libnss3 libxcomposite1 libxdamage1
        libxrandr2 libxtst6 libasound2t64 libsecret-1-dev libqpdf-dev desktop-file-utils)
    local missing=()
    for package in "${packages[@]}"; do dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package"); done
    if [ ${#missing[@]} -gt 0 ]; then
        say "System packages needed: ${missing[*]}"
        ask "Run: sudo apt-get install -y ${missing[*]} ?" || fail "Install them and run this again."
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi

    # The official Qt, in ~/Qt (or OWELK_QT=/path/to/Qt/<version>/<compiler>).
    local qt="${OWELK_QT:-$HOME/Qt/$QT_VERSION/$QT_DIR_NAME}"
    if [ ! -x "$qt/bin/qmake" ] && [ ! -x "$qt/bin/qmake6" ]; then
        say "Downloading Qt $QT_VERSION into ~/Qt (about 1.5 GB, once)"
        local tools="$HOME/.local/share/owelk/tools"
        python3 -m venv "$tools/venv"
        "$tools/venv/bin/pip" install --quiet --upgrade aqtinstall
        "$tools/venv/bin/aqt" install-qt "$host" desktop "$QT_VERSION" "$arch" -m $QT_MODULES -O "$HOME/Qt"
    fi
    configure_and_build -DCMAKE_PREFIX_PATH="$qt"

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
    say "Done. Owelk is in the app menu, or run: owelk"
    case ":$PATH:" in *":$home/bin:"*) ;; *) echo "($home/bin is not on PATH; the menu entry works regardless.)" ;; esac
    echo "To open PDFs with it by default: xdg-mime default owelk.desktop application/pdf"
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux) install_linux ;;
    *) fail "This script covers macOS and Linux." ;;
esac
