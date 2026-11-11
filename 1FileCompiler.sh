#!/usr/bin/env bash
# CompilerExe.sh - Cross-compile C / C++ / Rust source files into Windows .exe (from Linux)
#
# Usage:
#   ./CompilerExe.sh -f file.cpp -l cpp  -o output.exe
#   ./CompilerExe.sh -f file.c   -l c    -o output.exe
#   ./CompilerExe.sh -f file.rs  -l rust -o output.exe
#   ./CompilerExe.sh --install          (install all required tools)

set -u

SCRIPT_NAME="$(basename "$0")"

# ---------- Helpers ----------
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -f <source_file> -l <language> -o <output.exe> [-a <arch>]
       $SCRIPT_NAME --install
       $SCRIPT_NAME --shortcut
       $SCRIPT_NAME --remove-shortcut

Options:
  -f                 Source file (.c, .cpp, .rs)
  -l                 Language: c | cpp | rust   (optional, auto-detected from file extension)
  -o                 Output file name (default: <source name>.exe)
  -a                 Target architecture: 64 | 32 (default: 64)
  --install          Detect your distro and install mingw-w64 (and Rust if missing)
  --shortcut         Create a global command '1Filecompiler' (works from anywhere)
  --remove-shortcut  Remove the global command
  -h, --help         Show this help

Examples:
  $SCRIPT_NAME -f main.cpp -l cpp  -o app.exe
  $SCRIPT_NAME -f main.c   -l c    -o app.exe
  $SCRIPT_NAME -f main.rs  -l rust -o app.exe -a 32
  $SCRIPT_NAME --install
EOF
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

info() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1" >&2
}

# ---------- Distro / package manager detection ----------
DISTRO_NAME="Unknown"
PKG_MANAGER=""
SUDO=""

detect_distro() {
    if [ -r /etc/os-release ]; then
        DISTRO_NAME="$( . /etc/os-release; echo "${PRETTY_NAME:-${NAME:-Unknown}}" )"
    fi

    if   command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    elif command -v apk     >/dev/null 2>&1; then PKG_MANAGER="apk"
    elif command -v xbps-install >/dev/null 2>&1; then PKG_MANAGER="xbps"
    else PKG_MANAGER=""
    fi

    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            SUDO="__nosudo__"
        fi
    fi
}

run_root() {
    if [ "$SUDO" = "__nosudo__" ]; then
        error "Root privileges are required but 'sudo' is not installed. Run this script as root."
    fi
    # shellcheck disable=SC2086
    $SUDO "$@"
}

install_mingw() {
    detect_distro
    info "Detected distribution: $DISTRO_NAME"

    if [ -z "$PKG_MANAGER" ]; then
        error "No supported package manager found (apt, dnf, yum, pacman, zypper, apk, xbps). Install mingw-w64 manually."
    fi

    info "Detected package manager: $PKG_MANAGER"
    info "Installing mingw-w64..."

    case "$PKG_MANAGER" in
        apt)
            run_root apt-get update && run_root apt-get install -y mingw-w64
            ;;
        dnf)
            run_root dnf install -y mingw64-gcc mingw64-gcc-c++ mingw32-gcc mingw32-gcc-c++
            ;;
        yum)
            run_root yum install -y mingw64-gcc mingw64-gcc-c++ mingw32-gcc mingw32-gcc-c++
            ;;
        pacman)
            run_root pacman -S --needed --noconfirm mingw-w64-gcc
            ;;
        zypper)
            run_root zypper --non-interactive install mingw64-cross-gcc mingw64-cross-gcc-c++ mingw32-cross-gcc mingw32-cross-gcc-c++
            ;;
        apk)
            run_root apk add mingw-w64-gcc
            ;;
        xbps)
            run_root xbps-install -Sy cross-x86_64-w64-mingw32 cross-i686-w64-mingw32
            ;;
    esac

    [ $? -eq 0 ] || error "Failed to install mingw-w64 using '$PKG_MANAGER'."
    info "mingw-w64 installed successfully."
}

load_cargo_env() {
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
}

install_rust() {
    load_cargo_env
    if command -v rustc >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
        info "Rust (rustup) is already installed."
        return 0
    fi

    command -v curl >/dev/null 2>&1 || error "'curl' is required to install Rust. Install curl first."
    info "Installing Rust using rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
        || error "Failed to install Rust."
    load_cargo_env
    info "Rust installed successfully."
}

# ---------- Dependency checks ----------
# A tool counts as "working" only if it exists AND runs correctly.
tool_works() {
    command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
}

# Prints the list of missing tools for the selected language/arch
find_missing() {
    local lang="$1" prefix="$2"
    MISSING=()

    case "$lang" in
        c)    tool_works "${prefix}-gcc" || MISSING+=("${prefix}-gcc") ;;
        cpp)  tool_works "${prefix}-g++" || MISSING+=("${prefix}-g++") ;;
        rust)
            load_cargo_env
            tool_works "${prefix}-gcc" || MISSING+=("${prefix}-gcc (linker)")
            tool_works rustc           || MISSING+=("rustc")
            ;;
    esac
}

ensure_dependencies() {
    local lang="$1" prefix="$2"

    info "Checking required tools..."
    find_missing "$lang" "$prefix"

    if [ ${#MISSING[@]} -eq 0 ]; then
        info "All required tools are available."
        return 0
    fi

    warn "Missing or not working: ${MISSING[*]}"

    if [ ! -t 0 ]; then
        error "Missing tools and no interactive terminal. Run: $SCRIPT_NAME --install"
    fi

    detect_distro
    info "Detected distribution: $DISTRO_NAME (package manager: ${PKG_MANAGER:-none})"
    read -r -p "[INPUT] Install the missing tools now? [Y/n]: " ANSWER
    case "${ANSWER:-Y}" in
        [Yy]*) ;;
        *) error "Required tools are missing. Run: $SCRIPT_NAME --install" ;;
    esac

    # Install what is needed
    local need_mingw=0 need_rust=0 m
    for m in "${MISSING[@]}"; do
        case "$m" in
            *mingw32-*) need_mingw=1 ;;
            rustc)      need_rust=1 ;;
        esac
    done
    [ $need_mingw -eq 1 ] && install_mingw
    [ $need_rust  -eq 1 ] && install_rust

    # Re-check after installation
    find_missing "$lang" "$prefix"
    if [ ${#MISSING[@]} -ne 0 ]; then
        error "Still missing after installation: ${MISSING[*]}. Check your PATH or install them manually."
    fi
    info "All required tools are now available."
}

# ---------- Shortcut (global command) ----------
SHORTCUT_NAME="1Filecompiler"

install_shortcut() {
    local target dir
    target="$(readlink -f "$0")"
    [ -f "$target" ] || error "Cannot resolve the script path."
    chmod +x "$target" 2>/dev/null

    detect_distro

    # Try system-wide first (/usr/local/bin), fall back to ~/.local/bin
    if [ "$SUDO" != "__nosudo__" ]; then
        dir="/usr/local/bin"
        info "Creating shortcut: $dir/$SHORTCUT_NAME -> $target"
        if run_root ln -sf "$target" "$dir/$SHORTCUT_NAME"; then
            info "Done. You can now run '$SHORTCUT_NAME --help' from anywhere."
            return 0
        fi
        warn "Could not write to $dir. Falling back to ~/.local/bin"
    fi

    dir="$HOME/.local/bin"
    mkdir -p "$dir" || error "Cannot create directory '$dir'."
    ln -sf "$target" "$dir/$SHORTCUT_NAME" || error "Failed to create shortcut in '$dir'."
    info "Shortcut created: $dir/$SHORTCUT_NAME -> $target"

    case ":$PATH:" in
        *":$dir:"*) info "Done. You can now run '$SHORTCUT_NAME --help' from anywhere." ;;
        *) warn "'$dir' is not in your PATH. Add this line to ~/.bashrc then restart the terminal:"
           echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

remove_shortcut() {
    local removed=0
    detect_distro
    if [ -L "/usr/local/bin/$SHORTCUT_NAME" ]; then
        run_root rm -f "/usr/local/bin/$SHORTCUT_NAME" && removed=1
    fi
    if [ -L "$HOME/.local/bin/$SHORTCUT_NAME" ]; then
        rm -f "$HOME/.local/bin/$SHORTCUT_NAME" && removed=1
    fi
    if [ $removed -eq 1 ]; then
        info "Shortcut '$SHORTCUT_NAME' removed."
    else
        error "Shortcut '$SHORTCUT_NAME' was not found."
    fi
}

# ---------- Long options (--install, --shortcut, --remove-shortcut, --help) ----------
for arg in "$@"; do
    case "$arg" in
        --install)
            info "Installing all required tools..."
            install_mingw
            install_rust
            info "Done. You can now use $SCRIPT_NAME."
            exit 0
            ;;
        --shortcut)
            install_shortcut
            exit 0
            ;;
        --remove-shortcut)
            remove_shortcut
            exit 0
            ;;
        --help)
            usage
            exit 0
            ;;
        --*)
            echo "[ERROR] Invalid option: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

# ---------- Parse arguments ----------
FILE=""
LANG_OPT=""
OUTPUT=""
ARCH="64"

while getopts ":f:l:o:a:h" opt; do
    case "$opt" in
        f) FILE="$OPTARG" ;;
        l) LANG_OPT="$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]')" ;;
        o) OUTPUT="$OPTARG" ;;
        a) ARCH="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "[ERROR] Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
        \?) echo "[ERROR] Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    esac
done

# ---------- Validate input ----------
[ -z "$FILE" ] && { echo "[ERROR] Missing source file (-f)." >&2; usage; exit 1; }
[ -e "$FILE" ] || error "File '$FILE' does not exist."
[ -f "$FILE" ] || error "'$FILE' is not a regular file."
[ -r "$FILE" ] || error "File '$FILE' is not readable."

EXT="${FILE##*.}"
EXT="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"

# Auto-detect language if not provided
if [ -z "$LANG_OPT" ]; then
    case "$EXT" in
        c)               LANG_OPT="c" ;;
        cpp|cc|cxx)      LANG_OPT="cpp" ;;
        rs)              LANG_OPT="rust" ;;
        *) error "Cannot detect language from extension '.$EXT'. Use -l c|cpp|rust." ;;
    esac
    info "Language auto-detected: $LANG_OPT"
fi

case "$LANG_OPT" in
    c|cpp|rust) ;;
    rs)  LANG_OPT="rust" ;;
    c++) LANG_OPT="cpp" ;;
    *) error "Invalid language '$LANG_OPT'. Allowed values: c, cpp, rust." ;;
esac

# Check that extension matches the language
case "$LANG_OPT" in
    c)    [[ "$EXT" == "c" ]] || error "Language is 'c' but file extension is '.$EXT' (expected .c)." ;;
    cpp)  [[ "$EXT" =~ ^(cpp|cc|cxx)$ ]] || error "Language is 'cpp' but file extension is '.$EXT' (expected .cpp/.cc/.cxx)." ;;
    rust) [[ "$EXT" == "rs" ]] || error "Language is 'rust' but file extension is '.$EXT' (expected .rs)." ;;
esac

case "$ARCH" in
    64|32) ;;
    *) error "Invalid architecture '$ARCH'. Allowed values: 64, 32." ;;
esac

# Output name
if [ -z "$OUTPUT" ]; then
    BASENAME="$(basename "${FILE%.*}")"
    OUTPUT="${BASENAME}.exe"
    info "No output name given, using: $OUTPUT"
fi
[[ "$OUTPUT" == *.exe ]] || OUTPUT="${OUTPUT}.exe"

OUT_DIR="$(dirname "$OUTPUT")"
[ -d "$OUT_DIR" ] || error "Output directory '$OUT_DIR' does not exist."

# ---------- Targets ----------
if [ "$ARCH" = "64" ]; then
    MINGW_PREFIX="x86_64-w64-mingw32"
    RUST_TARGET="x86_64-pc-windows-gnu"
else
    MINGW_PREFIX="i686-w64-mingw32"
    RUST_TARGET="i686-pc-windows-gnu"
fi

# ---------- Check dependencies BEFORE compiling ----------
ensure_dependencies "$LANG_OPT" "$MINGW_PREFIX"

# ---------- Compile ----------
case "$LANG_OPT" in
    c)
        info "Compiling C file '$FILE' -> '$OUTPUT' (${ARCH}-bit)..."
        "${MINGW_PREFIX}-gcc" "$FILE" -o "$OUTPUT" -O2 -static
        ;;
    cpp)
        info "Compiling C++ file '$FILE' -> '$OUTPUT' (${ARCH}-bit)..."
        "${MINGW_PREFIX}-g++" "$FILE" -o "$OUTPUT" -O2 -static -static-libgcc -static-libstdc++
        ;;
    rust)
        if command -v rustup >/dev/null 2>&1; then
            if ! rustup target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
                info "Rust target '$RUST_TARGET' is not installed. Installing..."
                rustup target add "$RUST_TARGET" || error "Failed to install Rust target '$RUST_TARGET'."
            fi
        fi
        info "Compiling Rust file '$FILE' -> '$OUTPUT' (${ARCH}-bit)..."
        rustc "$FILE" --target "$RUST_TARGET" -C opt-level=2 \
              -C linker="${MINGW_PREFIX}-gcc" -o "$OUTPUT"
        ;;
esac

STATUS=$?
if [ $STATUS -ne 0 ]; then
    error "Compilation failed (exit code $STATUS). Check your source code for errors."
fi

[ -f "$OUTPUT" ] || error "Compilation finished but output file '$OUTPUT' was not created."

info "Success! Output file: $OUTPUT"
exit 0