# ffmpeg-build-flow

自动构建 FFmpeg 可执行文件的仓库：按 **平台 × 变体** 组成 6 个 job（三平台各有 LGPL 与 GPL 一份），
结果发布到本仓库的滚动 Release（`latest`）。

本仓库须保持 **public** —— 消费侧用匿名直链下载资产，不走 token。

## 产物

| 平台 | LGPL | GPL |
|---|---|---|
| Windows x64 | `ffmpeg-win64-lgpl-shared.zip` | `ffmpeg-win64-gpl-shared.zip` |
| Linux x64 | `ffmpeg-linux64-lgpl.tar.xz` | `ffmpeg-linux64-gpl.tar.xz` |
| macOS arm64 | `ffmpeg-macos-arm64-lgpl.tar.xz` | `ffmpeg-macos-arm64-gpl.tar.xz` |

文件名固定、不含版本号，因此直链恒定：

```
https://github.com/Aer-Light-Work/ffmpeg-build-flow/releases/download/latest/ffmpeg-win64-lgpl-shared.zip
```

版本信息（ref、精确 commit、完整 configure 参数、外部依赖）写在每个包内的
`README-build.txt`，也可用 `ffmpeg -version` 查看。

包内布局统一：

```
ffmpeg-<ref>-<platform>-<variant>[-shared]/
├── bin/                可执行文件 + 运行时库（Windows 为 ffmpeg.exe / ffprobe.exe / *.dll）
├── LICENSE.txt         LGPLv2.1 或 GPLv3
└── README-build.txt   构建溯源信息
```

## 两个变体的区别

- **LGPL**：只链 `libmp3lame`（lame 本身是 LGPL）。configure 不含 `--enable-gpl` /
  `--enable-nonfree`，构建后会主动校验，产物可用于 LGPL 分发场景。原生编码器（`aac`、`flac`、
  `mp3` 解码、各容器 demuxer/muxer）全部保留。
- **GPL**：`--enable-gpl --enable-version3`，外加 `libx264`、`libx265`、`libvpx`、`libopus`、
  `libvorbis`、`libdav1d`。刻意不含 `libfdk_aac` 等 nonfree 组件。

Linux/macOS 产出静态自包含二进制（外部依赖从源码静态编译，避免产物依赖系统 `.so` / Homebrew `.dylib`）；
Windows 产出共享库（DLL）形式，并把全部运行时 DLL 收进 `bin/`，以满足「用户可自行替换兼容 DLL
再链接」的 LGPL 条件。

## 触发方式

- push 到 `main`（忽略 `**.md` 与 `.gitignore`）
- 手动 `workflow_dispatch`，可指定 `ffmpeg_ref`（默认 `n7.1`）
- 每周一 04:00 UTC 定时跑一次，用于发现依赖下载源腐烂

6 个 job 相互独立（`fail-fast: false`），可单独重跑，每个只覆盖自己那一个资产。

拆到变体粒度而不是「一个平台 job 内串行跑两变体」，是因为 GPL 的依赖链明显更长更脆
（要额外引导 CMake 3.x、要静态编六个库）：把它们绑在一个 job 里时，GPL 依赖一挂，
几分钟就能出来的 LGPL 产物也被连带拖死。分开后 LGPL 只编 lame 一个依赖。

即使构建失败，已产出的压缩包仍会上传（publish 步骤是 `if: always()`）。

## 目录结构

```
.github/workflows/build-ffmpeg.yml   平台 × 变体矩阵（6 个 job，只负责装工具链）
.github/actions/publish/             滚动 release 上传（composite action）
scripts/build-deps.sh                外部依赖静态编译；Windows 也 source 它复用 build_x265
scripts/build-ffmpeg.sh              Linux/macOS 构建 + 自检 + 打包
scripts/build-ffmpeg-msys2.sh        Windows(MSYS2) 构建 + DLL 收集 + 自检 + 打包
scripts/finalize.sh                  共用：源码获取、合规自检、许可证与溯源文件、打包
```

## 本地复现

Windows（MSYS2 MINGW64 shell）：

```bash
FFMPEG_REF=n7.1 VARIANT=lgpl FFMPEG_SRC=/d/tmp/ffmpeg-src OUT=/d/tmp/out bash scripts/build-ffmpeg-msys2.sh
```

Linux / macOS：

```bash
export FFMPEG_REF=n7.1 FFMPEG_SRC=$PWD/ffmpeg-src PREFIX=$PWD/deps OUT=$PWD/out WORK=$PWD/work
VARIANT=gpl OS=linux bash scripts/build-deps.sh      # GPL 需要先编依赖
VARIANT=lgpl OS=linux bash scripts/build-ffmpeg.sh
```

macOS 把 `OS=linux` 换成 `OS=macos`。LGPL 只需 `VARIANT=lgpl bash scripts/build-deps.sh`
（只编 lame）。`build-deps.sh` 会按需自行引导 CMake 3.x 到 `$WORK/cmake3`，不必手工安装。

## 已知维护成本

`scripts/build-deps.sh` 里的依赖版本是钉死的，上游 tarball 链接会随时间腐烂。
多数依赖配了备用源，但 **x265 是单源**（bitbucket）：备用镜像 `videolan/x265` 没有任何
`Release_*` tag，写了也回落不了，所以宁可留单源、让失败明确暴露。

x265 的版本尤其不能随手升：它钉在 `Release_4.0` 是因为 FFmpeg n7.1 的 libx265 wrapper
按 `X265_BUILD >= 210` 选择 `encoder_encode` 的参数类型，而 x265 4.1 又把该参数改了回去。
升级 FFmpeg ref 时必须重新比对这张表。

每周一定时构建会把上述失效暴露出来。
