#!/bin/bash
# Portable Windows build with FFmpeg (shared libraries) bundled alongside
# the executable. Creates a standalone directory and a .zip archive.
#
# Usage: scripts/build-windows.sh
# Note: Must run on a system with MinGW-w64 toolchain (Linux cross-compile
# or Windows MSYS2) for FFmpeg compilation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TARGET="${CARGO_BUILD_TARGET:-x86_64-pc-windows-gnu}"

# Validate Windows target
case "$TARGET" in
    *-pc-windows-*) ;;
    *)
        echo "build-windows.sh: CARGO_BUILD_TARGET must be a Windows target" >&2
        echo "  e.g. x86_64-pc-windows-gnu or x86_64-pc-windows-msvc" >&2
        exit 1
        ;;
esac

# Extract architecture from target triplet
case "$TARGET" in
    x86_64-*) ARCH="x64" ;;
    i686-*) ARCH="x86" ;;
    aarch64-*) ARCH="arm64" ;;
    arm64-*) ARCH="arm64" ;;
    *) ARCH="x64" ;;
esac

mkdir -p "${CARGO_TARGET_DIR:-target}"
TARGET_DIR="$(cd "${CARGO_TARGET_DIR:-target}" && pwd)"
FFMPEG_PREFIX="$TARGET_DIR/ffmpeg-shared"
OUT_DIR="$TARGET_DIR/windows"
BUNDLE_DIR="$OUT_DIR/Venturi-$ARCH"
ZIP_FILE="$OUT_DIR/Venturi-$ARCH.zip"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

# Build FFmpeg for Windows
FFMPEG_OS=MINGW scripts/build-ffmpeg.sh "$FFMPEG_PREFIX"

export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig"

# Build the application for Windows
cargo clean --release -p ffmpeg-sys-next -p vv-media -p vv-app 2>/dev/null || true
cargo build -p vv-app --release --target "$TARGET"

echo "Building portable bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Copy the executable
EXE="$TARGET_DIR/$TARGET/release/vv-app.exe"
cp "$EXE" "$BUNDLE_DIR/"

# Copy FFmpeg DLLs needed by the application
FFMPEG_BIN="$FFMPEG_PREFIX/bin"
REQUIRED_DLLS=(
    avcodec avdevice avfilter avformat avutil postproc swresample swscale
)

for dll in "${REQUIRED_DLLS[@]}"; do
    find "$FFMPEG_BIN" -maxdepth 1 -name "${dll}-*.dll" -exec cp {} "$BUNDLE_DIR/" \;
done

# Also copy codec libraries
CODEC_DLLS=(
    libx264 libmp3lame libopus libvorbis libogg rubberband
)

for dll in "${CODEC_DLLS[@]}"; do
    find "$FFMPEG_BIN" -maxdepth 1 \( -name "${dll}-*.dll" -o -name "${dll}.dll" \) \
        -exec cp {} "$BUNDLE_DIR/" \;
done

# MinGW runtime DLLs (winpthreads; libgcc/libstdc++ needed by rubberband)
for rt in libwinpthread-1 libgcc_s_seh-1 libstdc++-6; do
    if [ -f "/usr/x86_64-w64-mingw32/lib/$rt.dll" ]; then
        cp "/usr/x86_64-w64-mingw32/lib/$rt.dll" "$BUNDLE_DIR/"
    else
        find /usr/lib/gcc/x86_64-w64-mingw32/ -name "$rt.dll" -exec cp {} "$BUNDLE_DIR/" \;
    fi
done

# Verify all required DLLs are present in the bundle
MISSING_DLLS=0
ALL_DLLS=("${REQUIRED_DLLS[@]}" "${CODEC_DLLS[@]}" libwinpthread-1 libgcc_s_seh-1 libstdc++-6)
for dll in "${ALL_DLLS[@]}"; do
    if ! ls "$BUNDLE_DIR"/${dll}-*.dll >/dev/null 2>&1 \
        && ! ls "$BUNDLE_DIR"/${dll}.dll >/dev/null 2>&1; then
        echo "Missing required DLL: $dll" >&2
        MISSING_DLLS=1
    fi
done

if [ "$MISSING_DLLS" -ne 0 ]; then
    echo "Some required DLLs are missing from the bundle" >&2
    exit 1
fi

# Copy Windows icon
if [ -f "media/icons/windows/venturi-video.ico" ]; then
    cp "media/icons/windows/venturi-video.ico" "$BUNDLE_DIR/venturi.ico"
fi

# Create a simple README for the portable version
cat > "$BUNDLE_DIR/README.txt" <<EOF
Venturi $VERSION - Portable Windows Version
===========================================

This is a portable version of Venturi. Simply extract the archive and
run vv-app.exe to start the application.

All required DLLs are included in this directory.

For more information, visit: https://github.com/morrolinux/venturi
EOF

# Create ZIP archive
ZIP_CMD=""
for cmd in 7z zip; do
    if command -v $cmd &>/dev/null; then
        ZIP_CMD="$cmd"
        break
    fi
done

if [ -n "$ZIP_CMD" ]; then
    echo "Creating ZIP archive..."
    rm -f "$ZIP_FILE"
    case "$ZIP_CMD" in
        7z) 7z a -tzip "$ZIP_FILE" "$BUNDLE_DIR" >/dev/null ;;
        zip) (cd "$OUT_DIR" && zip -r "$(basename "$ZIP_FILE")" "$(basename "$BUNDLE_DIR")" >/dev/null) ;;
    esac
else
    # Try PowerShell on Windows
    IS_WINDOWS=0
    case "$(uname -s 2>/dev/null || echo Windows)" in
        Windows*|MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
    esac
    if [ "$IS_WINDOWS" -eq 1 ]; then
        echo "Creating ZIP archive using PowerShell..."
        powershell -Command "Compress-Archive -Path '$BUNDLE_DIR' -DestinationPath '$ZIP_FILE' -Force"
    else
        echo "Warning: No zip tool found. Bundle created at: $BUNDLE_DIR" >&2
        ZIP_FILE=""
    fi
fi

# Output the results
echo ""
echo "=== Build Complete ==="
if [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ]; then
    echo "ZIP: $ZIP_FILE"
    if command -v du &>/dev/null; then
        SIZE="$(du -h "$ZIP_FILE" | cut -f1)"
    else
        SIZE="unknown size"
    fi
    echo "Size: $SIZE"
fi
echo "Portable bundle: $BUNDLE_DIR"
