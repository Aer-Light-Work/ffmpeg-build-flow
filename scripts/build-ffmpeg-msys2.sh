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
# shellcheck source=scripts/build-deps.sh
. "$HERE/build-deps.sh"   # 只借用 build_x265 / ensure_cmake3 / fetch / unpack

: "${FFMPEG_REF:?需要 FFMPEG_REF}"
: "${VARIANT:?需要 VARIANT}"
: "${FFMPEG_SRC:?需要 FFMPEG_SRC}"
: "${OUT:?需要 OUT}"
WORK="${WORK:-$PWD/work}"
OS=windows
PREFIX="${PREFIX:-$WORK/deps-x265}"
PLATFORM="win64"
[ "$VARIANT" = lgpl ] || [ "$VARIANT" = gpl ] || die "不支持的变体：${VARIANT}"

# x265 不能用 MSYS2 的包：它是 4.3，而 FFmpeg n7.1 的 libx265.c 按 3.x 的
# encoder_encode 签名写（实测多出一个 x265_picture ** 参数而编译失败）。
# 其余依赖（lame/x264/libvpx/opus/vorbis/dav1d）与 n7.1 相容，继续用 MSYS2 包。
if [ "$VARIANT" = gpl ]; then
  if [ -f "$PREFIX/lib/libx265.a" ]; then
    echo "复用已构建的 x265：$PREFIX"
  else
    mkdir -p "$PREFIX"
    JOBS="$(nproc 2>/dev/null || echo 4)"
    build_x265 windows
  fi
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

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
    # 自建的 x265 只有静态库（ENABLE_SHARED=0），它的 x265.pc 里
    #   Libs.private: -lstdc++ -lgcc_s -lgcc -liconv ...
    # 不加 --static 时 pkg-config 只给 -lx265，把这些私有依赖漏掉，把 libx265.a 链进
    # avcodec-61.dll 时会留下未定义符号。用 --static 是为了让 .pc 自己声明清单，
    # 而不是我在这里硬抄一遍（硬抄会随 x265 版本漂移）。
    # 只加在 GPL 分支：LGPL 唯一的依赖是 MSYS2 的共享 lame，它根本不走 pkg-config，
    # 且上一轮 LGPL 已在无此参数的情况下构建成功，不必扰动。
    --pkg-config-flags=--static
  )
fi

CONFIGURE_ARGS="${ARGS[*]}"
export CONFIGURE_ARGS
if [ "$VARIANT" = gpl ]; then
  DEPS_NOTE="MSYS2 mingw-w64-x86_64: lame x264 libvpx opus libvorbis dav1d zlib bzip2（共享 DLL，已全部收进 bin/）+ x265 Release_4.0 自建静态库（MSYS2 的 4.3 与 FFmpeg n7.1 的 encoder_encode 签名不兼容）"
else
  DEPS_NOTE="MSYS2 mingw-w64-x86_64: lame（共享 DLL，运行时依赖已全部收进 bin/）"
fi
export DEPS_NOTE

echo "=== configure（${PLATFORM} / ${VARIANT}）==="
( cd "$BUILD" && "$FFMPEG_SRC/configure" "${ARGS[@]}" ) || {
  echo "===== configure 失败，尾部 config.log =====" >&2
  tail -80 "$BUILD/ffbuild/config.log" >&2 || true
  exit 1
}

( cd "$BUILD" && make -j"$JOBS" && make install )

echo "=== 收集运行时 DLL ==="
# 必须扫 bin/ 下的全部文件而不只是两个 .exe：--enable-shared 下 ffmpeg.exe 只直接依赖
# 我们自己的 av*.dll / sw*.dll，真正的第三方库（libmp3lame、libx264、zlib…）挂在那些
# DLL 上，只看 .exe 会漏掉它们。
# 枚举 bin/ 下所有 PE 文件引用的 /mingw64 DLL。整条管道的退出状态一律归零：
# grep 无匹配返回 1、xargs 在某个 ldd 失败时返回 123，而调用处是赋值语句，pipefail
# 会把非零状态透传给 set -e —— 但"无匹配"恰恰是闭合断言的成功路径。调用方只依据
# 输出为空/非空来判断，不依赖退出码。
collect_dlls() {
  { find "$TOP/bin" -maxdepth 1 -type f \( -name '*.exe' -o -name '*.dll' \) -print0 \
    | xargs -0 ldd 2>/dev/null \
    | { grep -oE '/mingw64/bin/[^ ]+\.dll' || true; } | sort -u; } || true
}
for d in $(collect_dlls); do cp -v "$d" "$TOP/bin/"; done

# 闭合断言：selfcheck 是在 MSYS2 里跑的，此时 /mingw64/bin 仍在 PATH 上，就算包里缺 DLL
# 也照样能启动 —— 自检通过并不证明包自洽。收集完再扫一遍，要求不再出现任何 /mingw64/bin
# 引用；残留即意味着该 DLL 没被收进 bin/，用户机器上会直接加载失败。
leftover="$(collect_dlls)"
if [ -n "$leftover" ]; then
  echo "===== 打包不自洽：以下 DLL 仍未收进 bin/ =====" >&2
  printf '%s\n' "$leftover" >&2
  exit 1
fi
echo "DLL 集合已闭合（无 /mingw64/bin 残留引用）"

selfcheck_ffmpeg "$TOP" "$VARIANT"

package --dir "$TOP" --variant "$VARIANT" --platform "$PLATFORM" --shared --zip --out "$OUT"
