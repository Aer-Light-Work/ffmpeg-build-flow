#!/usr/bin/env bash
# 把 FFmpeg 的外部依赖从源码静态安装进独立 PREFIX（Linux / macOS）。
#
# 为什么要自己静态编：发行版与 Homebrew 的 x264/x265/libvpx/opus/vorbis 基本只发
# .so/.dylib，直接链上去会得到依赖系统库的“假静态”二进制 —— 下游把二进制分发到
# 没装这些库的机器上就跑不起来。
#
# 用法：PREFIX=<abs> VARIANT=lgpl|gpl OS=linux|macos [WORK=<abs>] bash scripts/build-deps.sh
# 产出：$PREFIX/{lib,include,lib/pkgconfig}
set -euo pipefail

: "${PREFIX:?需要 PREFIX}"
: "${VARIANT:?需要 VARIANT}"
: "${OS:=linux}"
WORK="${WORK:-$PWD/deps-work}"

mkdir -p "$PREFIX" "$WORK"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export CFLAGS="-O2 -fPIC ${CFLAGS:-}"
export CXXFLAGS="-O2 -fPIC ${CXXFLAGS:-}"

JOBS="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null | head -1 )"

fetch() { # fetch <dest> <url...>
  local dest="$1"; shift
  local u
  for u in "$@"; do
    echo "  尝试 $u"
    if curl -fsSL --retry 2 --connect-timeout 20 -o "$dest" "$u"; then return 0; fi
    echo "  失败，换源"
  done
  return 1
}

unpack() { # unpack <name> <dest> <url...> -> 把唯一顶层目录路径写到 stdout
  local name="$1" dest="$2"; shift 2
  local arc="$WORK/$name.tar.gz"
  fetch "$arc" "$@" || { echo "build-deps: $name 所有源都失败" >&2; return 1; }
  local dir="$WORK/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xf "$arc" -C "$dir" --strip-components=1
  printf '%s\n' "$dir"
}

autotools_static() { # autotools_static <dir> [额外 configure 参数...]
  local dir="$1"; shift
  ( cd "$dir"
    [ -x ./configure ] || { sh ./autogen.sh || ./bootstrap; }
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-doc "$@"
    make -j"$JOBS"
    make install
  )
}

build_lame() {
  local dir; dir="$(unpack lame "$WORK/lame" \
    https://downloads.sourceforge.net/lame/lame-3.100.tar.gz \
    https://ftp.osuosl.org/pub/blfs/conglomeration/lame/lame-3.100.tar.gz)"
  # lame 3.100 的 SSE 向量源文件漏了 xmmintrin.h，clang（macOS 默认）会直接编译失败。
  local f="$dir/libmp3lame/vector/xmm_quantize_sub.c"
  [ -f "$f" ] && ! grep -q 'xmmintrin.h' "$f" && sed -i.bak '1i #include <xmmintrin.h>' "$f"
  autotools_static "$dir" --disable-frontend
}

build_x264() {
  rm -rf "$WORK/x264"
  if ! git clone --depth 1 --branch stable https://code.videolan.org/videolan/x264.git "$WORK/x264"; then
    git clone --depth 1 --branch stable https://github.com/mirror/x264.git "$WORK/x264"
  fi
  ( cd "$WORK/x264"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-cli \
      --extra-cflags="-fPIC"
    make -j"$JOBS"
    make install
  )
}

build_x265() {
  rm -rf "$WORK/x265"
  if ! git clone --depth 1 --branch Release_3.5 https://bitbucket.org/multicoreware/x265_git.git "$WORK/x265"; then
    echo "build-deps: x265 克隆失败（bitbucket 不可达）" >&2
    return 1
  fi
  local extra=""
  [ "$OS" = linux ] && extra="-DEXTRA_LIB=dl"
  ( cd "$WORK/x265/source"
    cmake . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DENABLE_PIC=1 \
      -DENABLE_CLI=0 -DEXTRA_LINK_FLAGS="" $extra
    make -j"$JOBS"
    make install
  )
}

build_libvpx() {
  local dir; dir="$(unpack libvpx "$WORK/libvpx" \
    https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz)"
  ( cd "$dir"
    mkdir -p b && cd b
    ../configure --prefix="$PREFIX" --disable-examples --disable-unit-tests \
      --disable-tools --disable-docs --enable-static --disable-shared --enable-pic \
      --enable-vp9-highbitdepth
    make -j"$JOBS"
    make install
  )
}

build_opus()  { autotools_static "$(unpack opus  "$WORK/opus"  https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz)" --disable-tests --disable-examples; }
build_ogg()   { autotools_static "$(unpack ogg   "$WORK/ogg"   https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz https://github.com/xiph/ogg/archive/refs/tags/v1.3.5.tar.gz)" --disable-tests --disable-examples; }
build_vorbis() { autotools_static "$(unpack vorbis "$WORK/vorbis" https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz https://github.com/xiph/vorbis/archive/refs/tags/v1.3.7.tar.gz)" --disable-tests --disable-examples; }

build_dav1d() {
  local dir; dir="$(unpack dav1d "$WORK/dav1d" \
    https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.gz \
    https://github.com/videolan/dav1d/archive/refs/tags/1.5.1.tar.gz)"
  ( cd "$dir"
    meson setup b --prefix="$PREFIX" --default-library=static --buildtype=release \
      -Dtests=disabled -Dexamples=disabled
    ninja -C b
    meson install -C b
  )
}

case "$VARIANT" in
  lgpl) DEPS=(lame) ;;
  gpl)  DEPS=(lame ogg vorbis x264 x265 libvpx opus dav1d) ;;
  *) echo "build-deps: 未知变体 $VARIANT" >&2; exit 1 ;;
esac

for d in "${DEPS[@]}"; do
  echo "=== 构建依赖：$d（$VARIANT / $OS）==="
  "build_$d"
done

echo "依赖就绪：$PREFIX"
ls "$PREFIX/lib/pkgconfig"
