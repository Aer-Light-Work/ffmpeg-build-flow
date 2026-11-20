#!/usr/bin/env bash
# 把 FFmpeg 的外部依赖从源码静态安装进独立 PREFIX（Linux / macOS 全流程；Windows 只借用 x265）。
#
# 为什么要自己静态编：发行版与 Homebrew 的 x264/x265/libvpx/opus/vorbis 基本只发
# .so/.dylib，直接链上去会得到依赖系统库的“假静态”二进制 —— 下游把二进制分发到
# 没装这些库的机器上就跑不起来。
#
# 用法：PREFIX=<abs> VARIANT=lgpl|gpl OS=linux|macos [WORK=<abs>] bash scripts/build-deps.sh
# 产出：$PREFIX/{lib,include,lib/pkgconfig}
#
# 本文件也可被 source：Windows 脚本只借用其中的 build_x265 / ensure_cmake3 / fetch / unpack，
# 因此强制校验与主循环都收在 main 里，source 时不产生副作用。
set -euo pipefail

# 不叫 die：本文件会被 Windows 脚本 source，而 finalize.sh 已有 die（语义是 exit 1）。
# 同名会覆盖它，把自检的致命错误降级成 return。
deps_die() { echo "build-deps: $*" >&2; return 1; }

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

# x265 的 CMakeLists 设置了 CMP0025/CMP0054 的 OLD 策略，CMake 4 已彻底移除该能力
# （runner 上的 cmake 是 4.4.5，MSYS2 的是 4.5.0，实测都报
#  “Policy CMP0025 may not be set to OLD behavior”）。这里取一份官方 CMake 3.31 二进制
# 放进临时目录并前置到 PATH，只影响本进程，不改 runner 全局。
CMAKE3_VER="3.31.6"

ensure_cmake3() {
  local plat
  case "${OS:-linux}" in
    linux)        plat=linux-x86_64 ;;
    macos)        plat=macos-universal ;;
    windows|msys) plat=windows-x86_64 ;;
    *) deps_die "ensure_cmake3: 不支持的 OS ${OS:-}" ;;
  esac
  local dest="${WORK:?ensure_cmake3 需要 WORK}/cmake3"
  local cached
  # 目录尚不存在时 find 返回 1，叠加 pipefail 会让这条赋值触发 set -e 退出，故显式吞掉。
  # 深度必须够：macos-universal 归档解出来是 CMake.app/Contents/bin/cmake（相对 dest 第 4 层），
  # 而 windows 是 <dir>/bin/cmake.exe、linux 是 bin/cmake。上一轮 -maxdepth 3 让 linux 与
  # windows 都侥幸通过，只有 macOS 报 “解压后找不到 cmake 可执行文件（CMake.app）”。
  cached="$( { find "$dest" -maxdepth 6 -type f \( -path '*/bin/cmake' -o -path '*/bin/cmake.exe' \) -print 2>/dev/null || true; } | head -1)"
  if [ -n "$cached" ]; then
    export PATH="$(dirname "$cached"):$PATH"
    echo "复用已引导的 cmake -> $(cmake --version | head -1)"
    return 0
  fi
  mkdir -p "$dest"
  local base="https://github.com/Kitware/CMake/releases/download/v${CMAKE3_VER}/cmake-${CMAKE3_VER}-${plat}"
  case "$plat" in
    windows-x86_64)
      fetch "$dest/cmake.zip" "$base.zip" || return 1
      # MSYS2 的 zip 包不提供 unzip，因此优先用 runner 自带的 tar（它能读 zip）。
      if command -v unzip >/dev/null 2>&1; then unzip -q "$dest/cmake.zip" -d "$dest"
      else tar -xf "$dest/cmake.zip" -C "$dest" --strip-components=1
      fi ;;
    *)
      fetch "$dest/cmake.tar.gz" "$base.tar.gz" || return 1
      tar -xf "$dest/cmake.tar.gz" -C "$dest" --strip-components=1 ;;
  esac
  rm -f "$dest"/cmake.*
  # 三平台归档层级不同，且归档里另有同名非可执行文件（macOS 的
  # Contents/share/bash-completion/completions/cmake，以及 bin/cmake-gui），
  # 所以必须同时限定 */bin/ 与精确文件名，不能只 -name cmake 再取 head -1。
  local b; b="$( { find "$dest" -maxdepth 6 -type f \( -path '*/bin/cmake' -o -path '*/bin/cmake.exe' \) -print 2>/dev/null || true; } | head -1)"
  [ -n "$b" ] || deps_die "ensure_cmake3: 解压后找不到 cmake 可执行文件（$(ls "$dest")）"
  export PATH="$(dirname "$b"):$PATH"
  local v; v="$(cmake --version | head -1)"
  echo "已引导 cmake：$v"
  case "$v" in
    "cmake version 3."*) ;;
    *) deps_die "ensure_cmake3: 拿到的不是 3.x（${v}）" ;;
  esac
}

# x265 必须钉在 Release_4.0（X265_BUILD 212）。FFmpeg n7.1 的 libx265.c 用
# `#if X265_BUILD >= 210` 选择 encoder_encode 的第 5 参类型，而 x265 的类型来回改过：
#   3.5 → BUILD 200, x265_picture *   （走 #else 分支）
#   4.0 → BUILD 212, x265_picture **  （走 >= 210 分支，匹配）
#   4.1 → BUILD 215, x265_picture *   （仍走 >= 210 分支 → 类型不符）
# MSYS2 当前发 4.3，Windows 实测报 “expected 'x265_picture *' but argument is of type
# 'x265_picture **'”。三平台统一 4.0，产物才可比对。
X265_REF="Release_4.0"

build_x265() {
  local os="${1:-${OS:-linux}}"
  rm -rf "$WORK/x265"
  # 单源：videolan/x265 镜像没有任何 Release_* tag（已用 git ls-remote 核实），
  # 而 bitbucket 在 runner 上实测可达（上一轮正是克隆成功之后才报的 cmake 错）。
  git clone --depth 1 --branch "$X265_REF" https://bitbucket.org/multicoreware/x265_git.git "$WORK/x265" \
    || deps_die "build_x265: 克隆 $X265_REF 失败"

  # 浅克隆不带 tag，Version.cmake 的 `git describe --abbrev=0 --tags` 于是返回空，
  # X265_LATEST_TAG 为空 → CMakeLists 里 string(REGEX MATCHALL ...) 得到空列表 →
  # “list GET given empty list” 直接 configure 失败。该分支被 if(CMAKE_RC_COMPILER)
  # 包着，所以只有装了 windres 的 Windows 会中招（Linux/macOS 跳过），本地已复现：
  # 打一个与所构建 ref 一致的轻量 tag 后 configure 完整通过。
  local tag="${X265_REF#Release_}"
  git -C "$WORK/x265" tag -f "$tag" HEAD
  echo "x265 版本标记：$(git -C "$WORK/x265" describe --abbrev=0 --tags)"

  ensure_cmake3
  # 只使用已在 $X265_REF 的 source/CMakeLists.txt 里核实存在的变量：
  # ENABLE_SHARED / ENABLE_PIC / ENABLE_CLI / EXTRA_LINK_FLAGS。
  # 注意 3.x/4.x 都没有 ENABLE_STATIC —— x265-static 是无条件 add_library + install 的。
  #
  # 不要传 -DEXTRA_LIB=...：x265 的 encoder/CMakeLists.txt 有
  #   if(EXTRA_LIB) … set_source_files_properties(api.cpp PROPERTIES COMPILE_FLAGS ${APIFLAGSTR})
  # 而 APIFLAGSTR 只在 LINKED_8/10/12BIT 时才非空。我们不做多位深构建，于是 EXTRA_LIB 一旦
  # 非空，该命令就只有 3 个参数 → “set_source_files_properties called with incorrect number
  # of arguments”，configure 直接失败（Linux GPL 实测就是这样挂的，Windows/macOS 没传所以过）。
  # 静态库本身也不需要 EXTRA_LIB：-ldl/-lstdc++ 这类由 x265.pc 的 Libs.private 经
  # --pkg-config-flags=--static 交给 FFmpeg，不是在这里补。
  local -a args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DENABLE_SHARED=0
    -DENABLE_PIC=1
    -DENABLE_CLI=0
    -DEXTRA_LINK_FLAGS=
  )
  case "$os" in
    windows|msys) args+=(-G "MSYS Makefiles") ;;
  esac
  ( cd "$WORK/x265/source"
    cmake . "${args[@]}"
    make -j"${JOBS:-1}"
    make install
  )
  ls "$PREFIX/lib/"*x265* "$PREFIX/lib/pkgconfig/x265.pc"
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

main() {
  : "${PREFIX:?需要 PREFIX}"
  : "${VARIANT:?需要 VARIANT}"
  OS="${OS:-linux}"
  WORK="${WORK:-$PWD/deps-work}"

  mkdir -p "$PREFIX" "$WORK"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-O2 -fPIC ${CFLAGS:-}"
  export CXXFLAGS="-O2 -fPIC ${CXXFLAGS:-}"
  JOBS="$( { nproc || sysctl -n hw.ncpu; } 2>/dev/null | head -1 )"
  JOBS="${JOBS:-2}"

  local -a deps
  # x265 排第二：它是唯一在 configure 阶段就可能失败的依赖（要额外引导 CMake 3.x），
  # 让它早死，省掉后面几个依赖的无效编译时间。
  case "$VARIANT" in
    lgpl) deps=(lame) ;;
    gpl)  deps=(lame x265 ogg vorbis x264 libvpx opus dav1d) ;;
    *) deps_die "未知变体 ${VARIANT}" ;;
  esac

  local d
  for d in "${deps[@]}"; do
    echo "=== 构建依赖：${d}（${VARIANT} / ${OS}）==="
    "build_$d"
  done

  # 收尾核验。注意不能直接 ls "$PREFIX/lib/pkgconfig"：lame 只装 libmp3lame.a 与头文件、
  # 不提供 .pc，于是纯 LGPL 变体（只编 lame）的 pkgconfig 目录压根不存在，ls 返回 2，
  # set -e 会在所有依赖都编好之后把步骤杀掉 —— 验证语句本身在成功路径上失败。
  local missing="" n
  for n in "${deps[@]}"; do
    case "$n" in
      lame)     [ -f "$PREFIX/lib/libmp3lame.a" ] || missing="$missing libmp3lame.a" ;;
      x264)     [ -f "$PREFIX/lib/libx264.a" ]    || missing="$missing libx264.a" ;;
      x265)     [ -f "$PREFIX/lib/libx265.a" ]    || missing="$missing libx265.a" ;;
      libvpx)   [ -f "$PREFIX/lib/libvpx.a" ]     || missing="$missing libvpx.a" ;;
      opus)     [ -f "$PREFIX/lib/libopus.a" ]    || missing="$missing libopus.a" ;;
      ogg)      [ -f "$PREFIX/lib/libogg.a" ]     || missing="$missing libogg.a" ;;
      vorbis)   [ -f "$PREFIX/lib/libvorbis.a" ]  || missing="$missing libvorbis.a" ;;
      dav1d)    [ -f "$PREFIX/lib/libdav1d.a" ]   || missing="$missing libdav1d.a" ;;
    esac
  done
  if [ -n "$missing" ]; then
    deps_die "依赖产物缺失：$missing"
  fi
  echo "依赖就绪：${PREFIX}"
  echo "  静态库：$(ls "$PREFIX"/lib/*.a 2>/dev/null | wc -l) 个"
  echo "  .pc：$( { ls "$PREFIX"/lib/pkgconfig/*.pc "$PREFIX"/lib64/pkgconfig/*.pc 2>/dev/null || true; } | wc -l) 个（lame 不提供 .pc，少一个是正常的）"
}

# 仅在被直接执行时跑 main；被 source 时只暴露函数。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
