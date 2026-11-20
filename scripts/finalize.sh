#!/usr/bin/env bash
# 共用工具与产物打包。既可被 source（ensure_src / selfcheck_ffmpeg），也可直接执行来打包。
#
# 直接执行：
#   FFMPEG_SRC=.. FFMPEG_REF=.. FFMPEG_COMMIT=.. CONFIGURE_ARGS=.. DEPS_NOTE=.. \
#   finalize.sh --dir <install_dir> --variant lgpl|gpl --platform win64|linux64|macos-arm64 \
#               [--shared] [--zip] [--out out]
set -euo pipefail

die() { echo "finalize: $*" >&2; exit 1; }

ensure_src() {
  : "${FFMPEG_SRC:?ensure_src: 需要 FFMPEG_SRC}"
  : "${FFMPEG_REF:?ensure_src: 需要 FFMPEG_REF}"
  if [ -f "$FFMPEG_SRC/configure" ]; then
    echo "复用已有源码：$FFMPEG_SRC"
  else
    mkdir -p "$(dirname "$FFMPEG_SRC")"
    echo "克隆 FFmpeg $FFMPEG_REF"
    if ! git clone --depth 1 --branch "$FFMPEG_REF" https://git.ffmpeg.org/ffmpeg.git "$FFMPEG_SRC"; then
      echo "  上游不可达，改用官方 GitHub 镜像"
      git clone --depth 1 --branch "$FFMPEG_REF" https://github.com/ffmpeg/ffmpeg.git "$FFMPEG_SRC"
    fi
  fi
  FFMPEG_COMMIT="$(git -C "$FFMPEG_SRC" rev-parse HEAD)"
  export FFMPEG_COMMIT
}

# 校验产物满足消费侧的硬性要求（GetM4A/build.py 的 verify_lgpl 会做同样的判断）。
selfcheck_ffmpeg() {
  local dir="$1" variant="$2"
  local exe="$dir/bin/ffmpeg"
  [ -f "$exe.exe" ] && exe="$exe.exe"
  [ -f "$exe" ] || die "自检失败：$dir/bin/ffmpeg 不存在"

  local ver
  ver="$("$exe" -hide_banner -version)"
  echo "$ver" | head -2

  local flags
  flags="$("$exe" -hide_banner -encoders | awk '{print $2}')"
  has() { printf '%s\n' "$flags" | grep -qx "$1"; }

  case "$ver" in
    *"--enable-nonfree"*) die "自检失败：产物含 nonfree 组件，两种变体都不允许" ;;
  esac
  if [ "$variant" = lgpl ]; then
    case "$ver" in
      *"--enable-gpl"*) die "自检失败：LGPL 产物的 configure 里出现了 --enable-gpl" ;;
    esac
  else
    case "$ver" in
      *"--enable-gpl"*) ;;
      *) die "自检失败：GPL 产物缺少 --enable-gpl" ;;
    esac
  fi

  # aac/flac 是 ffmpeg 原生编码器，libmp3lame 来自 lame —— 消费侧只依赖这三个。
  # 两个变体要求相同：GPL 变体是音频范围构建，不含 x264/x265（见构建脚本注释）。
  for c in aac flac libmp3lame; do
    has "$c" || die "自检失败：缺少编码器 $c"
  done
  echo "自检通过（${variant}）"
}

package() {
  local DIR="" VARIANT="" PLATFORM="" SHARED=0 ZIP=0 OUT="out"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) DIR="$2"; shift 2 ;;
      --variant) VARIANT="$2"; shift 2 ;;
      --platform) PLATFORM="$2"; shift 2 ;;
      --shared) SHARED=1; shift ;;
      --zip) ZIP=1; shift ;;
      --out) OUT="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ -n "$DIR" ] && [ -n "$VARIANT" ] && [ -n "$PLATFORM" ] || die "需要 --dir/--variant/--platform"
  [ -d "$DIR/bin" ] || die "$DIR/bin 不存在，安装步骤可能失败"

  local suffix=""
  [ "$SHARED" = 1 ] && suffix="-shared"

  if command -v strip >/dev/null 2>&1; then
    find "$DIR/bin" -maxdepth 1 -type f \( -name 'ffmpeg*' -o -name 'ffprobe*' -o -name '*.dll' -o -name '*.so*' \) \
      -exec strip --strip-unneeded {} + 2>/dev/null || echo "警告：strip 失败，保留未剥离二进制"
    # strip 底层是 objcopy，它会在目标同目录建 st###### 形式的临时文件；失败时临时文件
    # 不会被回收，于是被一起打进发布资产（本地用假二进制复现过：bin/st3cqBko 等）。
    # 成功路径下不会有残留，所以这里无条件清一次。
    find "$DIR/bin" -maxdepth 1 -type f -name 'st??????' -delete 2>/dev/null || true
  fi

  local lic_src
  case "$VARIANT" in
    lgpl) lic_src="$FFMPEG_SRC/COPYING.LGPLv2.1" ;;
    gpl)  lic_src="$FFMPEG_SRC/COPYING.GPLv3" ;;
    *) die "未知变体：$VARIANT" ;;
  esac
  [ -f "$lic_src" ] || die "找不到许可证文本：$lic_src"
  cp "$lic_src" "$DIR/LICENSE.txt"

  cat > "$DIR/README-build.txt" <<EOF
FFmpeg 构建说明（自动生成，勿手工编辑）

ref           : ${FFMPEG_REF:-unknown}
commit        : ${FFMPEG_COMMIT:-unknown}
platform      : ${PLATFORM}
variant       : ${VARIANT}
linkage       : $([ "$SHARED" = 1 ] && echo shared || echo static)
源码          : https://git.ffmpeg.org/ffmpeg.git
configure     : ${CONFIGURE_ARGS:-（未记录）}
外部依赖      : ${DEPS_NOTE:-（未记录）}
构建时间(UTC) : $(date -u '+%Y-%m-%d %H:%M:%S')
构建环境      : ${RUNNER_OS:-local} ${RUNNER_ARCH:-} ${GITHUB_REF_NAME:-}
EOF

  local top parent out_abs archive
  top="$(basename "$DIR")"
  parent="$(dirname "$DIR")"
  mkdir -p "$OUT"
  out_abs="$(cd "$OUT" && pwd)"
  local base="ffmpeg-${PLATFORM}-${VARIANT}${suffix}"

  if [ "$ZIP" = 1 ]; then
    archive="$out_abs/$base.zip"
    rm -f "$archive"
    if command -v zip >/dev/null 2>&1; then
      (cd "$parent" && zip -qr "$archive" "$top")
    elif command -v 7z >/dev/null 2>&1; then
      (cd "$parent" && 7z a -tzip -mx=9 "$archive" "$top" >/dev/null)
    else
      die "PATH 里没有 zip 也没有 7z，无法打 Windows 压缩包"
    fi
  else
    archive="$out_abs/$base.tar.xz"
    rm -f "$archive"
    tar -cJf "$archive" -C "$parent" "$top"
  fi

  echo "产物：$archive"
  printf '%s\n' "$archive"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  package "$@"
fi
