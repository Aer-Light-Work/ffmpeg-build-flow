#!/usr/bin/env bash
# Windows (MSYS2 / MINGW64)：共享库（DLL）形式的 FFmpeg 构建。
#
# 之所以是 shared：下游以 LGPL 分发并声明“用户可自行替换兼容 DLL 再链接”，
# 这要求 Windows 包携带 DLL（见下游 THIRD_PARTY_NOTICES 的合规表述）。
# 依赖直接用 MSYS2 的 mingw-w64 包，因此必须把 ffmpeg 自身依赖之外的全部
# 运行时 DLL 一起收进 bin/，否则用户机器上缺 libwinpthread / libx264 就跑不起来。
#
# 用法：FFMPEG_REF=n7.1 VARIANT=lgpl|gpl FFMPEG_SRC=<abs> OUT=<abs> WORK=<abs> \
#       bash scripts/build-ffmpeg-msys2.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/finalize.sh
. "$HERE/finalize.sh"

: "${FFMPEG_REF:?需要 FFMPEG_REF}"
: "${VARIANT:?需要 VARIANT}"
: "${FFMPEG_SRC:?需要 FFMPEG_SRC}"
: "${OUT:?需要 OUT}"
WORK="${WORK:-$PWD/work}"
PLATFORM="win64"
[ "$VARIANT" = lgpl ] || [ "$VARIANT" = gpl ] || die "不支持的变体：$VARIANT"

ensure_src

JOBS="$(nproc 2>/dev/null || echo 4)"
TOP="$WORK/install/ffmpeg-${FFMPEG_REF}-${PLATFORM}-${VARIANT}"
BUILD="$WORK/build-$PLATFORM-$VARIANT"
rm -rf "$TOP" "$BUILD"; mkdir -p "$TOP" "$BUILD" "$OUT"

ARGS=(
  --prefix="$TOP"
  --enable-shared --disable-static
  --disable-doc --disable-ffplay --disable-autodetect
  --enable-libmp3lame
)
if [ "$VARIANT" = gpl ]; then
  ARGS+=(
    --enable-gpl --enable-version3
    --enable-libx264 --enable-libx265
    --enable-libvpx --enable-libopus --enable-libvorbis --enable-libdav1d
  )
fi

CONFIGURE_ARGS="${ARGS[*]}"
export CONFIGURE_ARGS
if [ "$VARIANT" = gpl ]; then
  DEPS_NOTE="MSYS2 mingw-w64-x86_64: lame x264 x265 libvpx opus libvorbis dav1d zlib bzip2（共享 DLL，已全部收进 bin/）"
else
  DEPS_NOTE="MSYS2 mingw-w64-x86_64: lame（共享 DLL，运行时依赖已全部收进 bin/）"
fi
export DEPS_NOTE

echo "=== configure（$PLATFORM / $VARIANT）==="
( cd "$BUILD" && "$FFMPEG_SRC/configure" "${ARGS[@]}" ) || {
  echo "===== configure 失败，尾部 config.log =====" >&2
  tail -80 "$BUILD/ffbuild/config.log" >&2 || true
  exit 1
}

( cd "$BUILD" && make -j"$JOBS" && make install )

echo "=== 收集运行时 DLL ==="
mapfile -t extra < <(
  ldd "$TOP/bin/ffmpeg.exe" "$TOP/bin/ffprobe.exe" 2>/dev/null \
    | grep -oE '/mingw64/bin/[^ ]+\.dll' | sort -u
)
for d in "${extra[@]}"; do
  cp -v "$d" "$TOP/bin/"
done

selfcheck_ffmpeg "$TOP" "$VARIANT"

package --dir "$TOP" --variant "$VARIANT" --platform "$PLATFORM" --shared --zip --out "$OUT"
