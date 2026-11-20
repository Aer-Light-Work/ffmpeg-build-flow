#!/usr/bin/env bash
# Linux / macOS：静态自包含 FFmpeg 构建（依赖由 build-deps.sh 预先静态装进 PREFIX）。
#
# 用法：FFMPEG_REF=n7.1 VARIANT=lgpl|gpl OS=linux|macos \
#       FFMPEG_SRC=<abs> PREFIX=<abs> OUT=<abs> WORK=<abs> \
#       bash scripts/build-ffmpeg.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/finalize.sh
. "$HERE/finalize.sh"

: "${FFMPEG_REF:?需要 FFMPEG_REF}"
: "${VARIANT:?需要 VARIANT}"
: "${OS:?需要 OS}"
: "${FFMPEG_SRC:?需要 FFMPEG_SRC}"
: "${PREFIX:?需要 PREFIX}"
: "${OUT:?需要 OUT}"
WORK="${WORK:-$PWD/work}"

case "$OS" in
  linux) PLATFORM="linux64" ;;
  macos) PLATFORM="macos-arm64" ;;
  *) die "不支持的 OS：$OS" ;;
esac
[ "$VARIANT" = lgpl ] || [ "$VARIANT" = gpl ] || die "不支持的变体：$VARIANT"

ensure_src

JOBS="$( { nproc || sysctl -n hw.ncpu; } 2>/dev/null | head -1 )"
JOBS="${JOBS:-2}"
TOP="$WORK/install/ffmpeg-${FFMPEG_REF}-${PLATFORM}-${VARIANT}"
BUILD="$WORK/build-${PLATFORM}-${VARIANT}"
rm -rf "$TOP" "$BUILD"; mkdir -p "$TOP" "$BUILD" "$OUT"

ARGS=(
  --prefix="$TOP"
  --enable-static --disable-shared
  --disable-doc --disable-ffplay --disable-autodetect
  --pkg-config-flags=--static
  --enable-libmp3lame
  # lame 不提供 .pc —— FFmpeg 的 configure 用
  #   require "libmp3lame >= 3.98.3" lame/lame.h lame_set_VBR_quality -lmp3lame
  # 这种纯头文件+库路径的方式探测它，完全不经过 pkg-config。依赖装在独立 $PREFIX 里，
  # 不在编译器默认搜索路径上，所以必须显式给 -I/-L，否则 configure 会报找不到 libmp3lame
  # （即便 PKG_CONFIG_PATH 已经指对）。其余依赖有 .pc，这两项对它们无害。
  --extra-cflags="-I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib"
)
if [ "$VARIANT" = gpl ]; then
  ARGS+=(
    --enable-gpl --enable-version3
    --enable-libx264 --enable-libx265
    --enable-libvpx --enable-libopus --enable-libvorbis --enable-libdav1d
  )
fi
# 静态链 x265/vorbis 时它们自身的系统依赖需要手工补齐。
if [ "$OS" = linux ]; then
  ARGS+=(--extra-libs="-lpthread -lm -ldl")
else
  ARGS+=(--extra-libs="-lm")
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PREFIX/bin:$PATH"

CONFIGURE_ARGS="${ARGS[*]}"
export CONFIGURE_ARGS
if [ "$VARIANT" = gpl ]; then
  DEPS_NOTE="lame(static) x264(static) x265(static) libvpx(static) opus(static) ogg/vorbis(static) dav1d(static)"
else
  DEPS_NOTE="lame(static)"
fi
export DEPS_NOTE

echo "=== configure（${PLATFORM} / ${VARIANT}）==="
( cd "$BUILD" && "$FFMPEG_SRC/configure" "${ARGS[@]}" ) || {
  echo "===== configure 失败，尾部 config.log =====" >&2
  grep -i -B3 -A15 'error\|cannot\|not found' "$BUILD/ffbuild/config.log" >&2 | tail -80 || true
  exit 1
}

( cd "$BUILD" && make -j"$JOBS" && make install )

selfcheck_ffmpeg "$TOP" "$VARIANT"

package --dir "$TOP" --variant "$VARIANT" --platform "$PLATFORM" --out "$OUT"
