#!/usr/bin/env bash
# 把 FFmpeg 的外部依赖从源码静态安装进独立 PREFIX（Linux / macOS）。
#
# 依赖只有 lame —— 这是刻意的范围决定：消费侧 GetM4A 是音频提取器，
# 只用到 aac / flac（FFmpeg 原生）与 libmp3lame（唯一外部库），从不编码视频。
# 不要"顺手"把 x264/x265/libvpx/dav1d 加回来：整条视频依赖链曾在 CMake 策略、
# meson 选项名、macOS 链接参数上反复翻车，而消费侧一个都用不到。
# 若将来真要视频编码器，参考 BtbN/FFmpeg-Builds 的 scripts.d/ 已验证配方。
#
# 用法：PREFIX=<abs> OS=linux|macos [WORK=<abs>] bash scripts/build-deps.sh
# LGPL 与 GPL 变体共用同一份依赖，无需传 VARIANT。
set -euo pipefail

fetch() { # fetch <dest> <url...>
  local dest="$1"; shift
  local u
  for u in "$@"; do
    # 必须走 stderr：unpack 用 stdout 回传路径，任何进度文字都会污染返回值。
    echo "  尝试 $u" >&2
    if curl -fsSL --retry 2 --connect-timeout 20 -o "$dest" "$u"; then return 0; fi
    echo "  失败，换源" >&2
  done
  return 1
}

unpack() { # unpack <name> <dest> <url...> -> 把解压后的目录路径写到 stdout
  local name="$1" dest="$2"; shift 2
  local arc="$WORK/$name.tar.gz"
  fetch "$arc" "$@" || { echo "build-deps: $name 所有源都失败" >&2; return 1; }
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xf "$arc" -C "$dest" --strip-components=1
  printf '%s\n' "$dest"
}

build_lame() {
  local dir; dir="$(unpack lame "$WORK/lame" \
    https://downloads.sourceforge.net/lame/lame-3.100.tar.gz \
    https://ftp.osuosl.org/pub/blfs/conglomeration/lame/lame-3.100.tar.gz)"
  ( cd "$dir"
    # --disable-frontend：跳过 mpg123 转码前端，只装 libmp3lame 与头文件。
    # CI 三平台实证通过的写法，勿改。
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend
    make -j"$JOBS"
    make install
  )
}

main() {
  : "${PREFIX:?需要 PREFIX}"
  OS="${OS:-linux}"
  WORK="${WORK:-$PWD/deps-work}"

  mkdir -p "$PREFIX" "$WORK"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-O2 -fPIC ${CFLAGS:-}"
  JOBS="$( { nproc || sysctl -n hw.ncpu; } 2>/dev/null | head -1 )"
  JOBS="${JOBS:-2}"

  echo "=== 构建依赖：lame（${OS}）==="
  build_lame

  # 收尾核验不能 ls "$PREFIX/lib/pkgconfig"：lame 不提供 .pc，ls 返回非零会让
  # set -e 在所有工作完成之后把步骤杀掉。逐库断言真实产物即可。
  [ -f "$PREFIX/lib/libmp3lame.a" ] || { echo "build-deps: 缺少 libmp3lame.a" >&2; exit 1; }
  [ -f "$PREFIX/include/lame/lame.h" ] || { echo "build-deps: 缺少 lame/lame.h" >&2; exit 1; }
  echo "依赖就绪：${PREFIX}"
}

# 仅在被直接执行时跑 main；被 source 时只暴露函数。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
