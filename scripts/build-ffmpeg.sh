#!/bin/bash
# Builds FFmpeg from source (shared libraries) with libx264, librubberband,
# zlib, the encoders of the voiceover takes (libmp3lame, libopus, libvorbis)
# and the platform hardware encoder and decoders (NVENC, NVDEC and Vulkan
# video on Linux, VideoToolbox on macOS) into a local prefix. Used by build-appimage.sh,
# build-macos.sh and build-windows.sh.
#
# Usage: scripts/build-ffmpeg.sh <prefix>
set -euo pipefail

# No `realpath -m`: macOS has the BSD one.
mkdir -p "$1"
PREFIX="$(cd "$1" && pwd)"

FFMPEG_TAG="n9.0.1"
# NVENC SDK 12.2: an NVIDIA driver >= 550 is enough.
NV_HEADERS_TAG="n12.2.72.0"
X264_BRANCH="stable"
RUBBERBAND_TAG="v4.0.0"
LAME_VERSION="3.100"
OGG_VERSION="1.3.5"
VORBIS_VERSION="1.3.7"
OPUS_VERSION="1.5.2"
AUDIO_CODECS="lame-$LAME_VERSION ogg-$OGG_VERSION vorbis-$VORBIS_VERSION opus-$OPUS_VERSION"

OS="${FFMPEG_OS:-$(uname -s)}"
case "$OS" in
    Darwin)
        WANT="$FFMPEG_TAG videotoolbox $X264_BRANCH $RUBBERBAND_TAG $AUDIO_CODECS ${MACOSX_DEPLOYMENT_TARGET:-}"
        JOBS="$(sysctl -n hw.ncpu)"
        HW_FLAGS=(--enable-videotoolbox)
        ;;
    Windows*|MINGW*|MSYS*|CYGWIN*)
        # Windows MinGW-w64 build
        WANT="$FFMPEG_TAG mingw-no-d3dva $X264_BRANCH $RUBBERBAND_TAG $AUDIO_CODECS"
        JOBS="${NCPU:-$(nproc 2>/dev/null || echo 4)}"
        HW_FLAGS=()  # No hardware encoders for Windows cross-compile
        ;;
    *)
        WANT="$FFMPEG_TAG $NV_HEADERS_TAG nvdec vulkan $X264_BRANCH $RUBBERBAND_TAG $AUDIO_CODECS"
        JOBS="$(nproc)"
        # No VA-API: libva would be linked, not loaded with dlopen like CUDA and
        # Vulkan, and the AppImage would not start on a system without it.
        HW_FLAGS=(--enable-ffnvcodec --enable-nvenc --enable-cuda --enable-nvdec --enable-vulkan)
        ;;
esac

STAMP="$PREFIX/.build-stamp"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
    echo "Using cached FFmpeg build"
    exit 0
fi

# Check for MinGW-w64 toolchain if building for Windows
case "$OS" in
    Windows*|MINGW*|MSYS*|CYGWIN*)
        echo "Building FFmpeg for Windows with MinGW-w64..."
        if ! command -v x86_64-w64-mingw32-gcc &>/dev/null; then
            echo "MinGW-w64 toolchain (x86_64-w64-mingw32-gcc) not found." >&2
            echo "Please install it:" >&2
            echo "  On Debian/Ubuntu: sudo apt install gcc-mingw-w64-x86-64" >&2
            echo "  On Fedora: sudo dnf install mingw64-gcc" >&2
            echo "  On MSYS2: pacman -S mingw-w64-x86_64-toolchain" >&2
            exit 1
        fi
        ;;
    Darwin)
        echo "Building FFmpeg for macOS..."
        ;;
    *)
        echo "Building FFmpeg for Linux..."
        ;;
esac

rm -rf "$PREFIX"
SRC="$PREFIX/src"
mkdir -p "$SRC"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

case "$OS" in
    Darwin) ;;
    Windows*|MINGW*|MSYS*|CYGWIN*) ;;
    *)
        git clone --depth 1 --branch "$NV_HEADERS_TAG" \
            https://github.com/FFmpeg/nv-codec-headers.git "$SRC/nv-codec-headers"
        make -C "$SRC/nv-codec-headers" PREFIX="$PREFIX" install
        ;;
esac

git clone --depth 1 --branch "$X264_BRANCH" \
    https://code.videolan.org/videolan/x264.git "$SRC/x264"
(
    cd "$SRC/x264"
    case "$OS" in
        Windows*|MINGW*|MSYS*|CYGWIN*)
            HOST_OPT="--host=x86_64-w64-mingw32 --cross-prefix=x86_64-w64-mingw32-"
            ;;
        *)
            HOST_OPT=""
            ;;
    esac
    ./configure --prefix="$PREFIX" --enable-shared --enable-pic --disable-cli $HOST_OPT
    make -j"$JOBS"
    make install
)

# Needed by the `rubberband` filter of the fast playback audio.
# --libdir=lib: Debian's meson would pick lib/<triplet>.
git clone --depth 1 --branch "$RUBBERBAND_TAG" \
    https://github.com/breakfastquay/rubberband.git "$SRC/rubberband"
(
    cd "$SRC/rubberband"
    cat > "$SRC/mingw-cross.txt" <<'EOF'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    if [ "$OS" = Darwin ]; then
        # v4.0.0 uses size_t without <cstddef>; recent libc++ no longer
        # pulls it in transitively.
        export CXXFLAGS="${CXXFLAGS:-} -include cstddef"
    fi
    if [[ "$OS" == Windows* || "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]]; then
        # For MinGW-w64 cross-compile
        meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
            -Ddefault_library=shared -Dresampler=builtin \
            -Djni=disabled -Dladspa=disabled -Dvamp=disabled \
            -Dcmdline=disabled -Dtests=disabled \
            --cross-file="$SRC/mingw-cross.txt"
    else
        meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
            -Ddefault_library=shared -Dresampler=builtin \
            -Djni=disabled -Dladspa=disabled -Dvamp=disabled \
            -Dcmdline=disabled -Dtests=disabled
    fi
    meson install -C build
)

# The release tarballs, not the git repositories: they ship a ready
# `configure`, so no autotools are needed.
tarball() {
    curl -fsSL "$1" | tar xz -C "$SRC"
}
autotools_install() {
    (
        cd "$SRC/$1"
        shift
        case "$OS" in
            Windows*|MINGW*|MSYS*|CYGWIN*)
                HOST_OPT="--host=x86_64-w64-mingw32"
                ;;
            *)
                HOST_OPT=""
                ;;
        esac
        ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --enable-shared --disable-static $HOST_OPT "$@"
        make -j"$JOBS"
        make install
    )
}

tarball "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
# Exported but not defined in 3.100 (the decoder ones once it is disabled):
# the macOS linker refuses them.
sed -i.orig -E '/^(lame_init_old|hip_.*|lame_decode.*)$/d' \
    "$SRC/lame-$LAME_VERSION/include/libmp3lame.sym"
autotools_install "lame-$LAME_VERSION" --disable-frontend --disable-decoder

tarball "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz"
autotools_install "libogg-$OGG_VERSION"

tarball "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.gz"
# A PowerPC-era flag Apple's clang no longer knows.
sed -i.orig 's/-force_cpusubtype_ALL//g' "$SRC/libvorbis-$VORBIS_VERSION/configure"
autotools_install "libvorbis-$VORBIS_VERSION" --disable-examples

tarball "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
autotools_install "opus-$OPUS_VERSION" --disable-doc --disable-extra-programs

git clone --depth 1 --branch "$FFMPEG_TAG" \
    https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg"
(
    cd "$SRC/ffmpeg"
    if [ "$OS" = Darwin ]; then
        # configure links rubberband with -lstdc++, absent from the macOS SDK.
        sed -i '' 's/-lstdc++/-lc++/g' configure
    fi
    # --disable-autodetect: no dependencies picked up at random from the build
    # machine; the ones we need are enabled explicitly.
    # LAME has no pkg-config file: its headers and library are found by path.
    
    # Windows MinGW-w64 specific configuration
    if [[ "$OS" == Windows* || "$OS" == MINGW* || "$OS" == MSYS* || "$OS" == CYGWIN* ]]; then
        ./configure --prefix="$PREFIX" --enable-shared --disable-static \
            --enable-gpl --disable-autodetect --disable-programs --disable-doc \
            --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
            --enable-libx264 --enable-librubberband --enable-zlib \
            --enable-libmp3lame --enable-libopus --enable-libvorbis \
            --disable-d3d11va \
            --disable-d3d12va \
            --disable-dxva2 \
            --target-os=mingw32 --arch=x86_64 \
            --cross-prefix=x86_64-w64-mingw32- \
            --pkg-config=pkg-config
    else
        ./configure --prefix="$PREFIX" --enable-shared --disable-static \
            --enable-gpl --disable-autodetect --disable-programs --disable-doc \
            --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
            --enable-libx264 --enable-librubberband --enable-zlib \
            --enable-libmp3lame --enable-libopus --enable-libvorbis "${HW_FLAGS[@]}"
    fi
    make -j"$JOBS"
    make install
)

rm -rf "$SRC"
echo "$WANT" > "$STAMP"
