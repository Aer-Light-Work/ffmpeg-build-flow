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

两个变体**依赖完全相同**：只链 `libmp3lame`（lame 本身是 LGPL）。差异仅在许可开关：

- **LGPL**：configure 不含 `--enable-gpl` / `--enable-nonfree`，构建后主动校验，
  产物可用于 LGPL 分发场景。
- **GPL**：加 `--enable-gpl --enable-version3`，启用 libpostproc 等 GPL 原生组件。

两者都保留 FFmpeg 全部原生编解码器与容器支持（`aac`/`flac` 编码、各容器 demuxer/muxer 等）。

**GPL 变体是音频范围构建，故意不含 x264 / x265 / libvpx / dav1d 等视频编码器**：
消费侧 GetM4A 只提取音频（`-c:a copy/aac/flac/libmp3lame`，从不编码视频），而视频依赖链
曾在 CMake 策略、meson 选项名、x265 API 版本上反复出问题。若将来确需视频编码器，
参考 BtbN/FFmpeg-Builds 的 `scripts.d/` 已验证配方引入，不要凭记忆写参数。
同理不含 `libfdk_aac` 等 nonfree 组件。

Linux/macOS 产出静态自包含二进制（lame 从源码静态编译，避免产物依赖系统 `.so` / Homebrew `.dylib`）；
Windows 产出共享库（DLL）形式，并把全部运行时 DLL 收进 `bin/`，以满足「用户可自行替换兼容 DLL
再链接」的 LGPL 条件。

## 触发方式

- push 到 `main`（忽略 `**.md` 与 `.gitignore`）
- 手动 `workflow_dispatch`，可指定 `ffmpeg_ref`（默认 `n7.1`）
- 每周一 04:00 UTC 定时跑一次，用于发现依赖下载源腐烂

6 个 job 相互独立（`fail-fast: false`），可单独重跑，每个只覆盖自己那一个资产。
拆到变体粒度是为了失败隔离：曾有过一个变体挂掉连坐另一变体本可成功产物的教训。

即使构建失败，已产出的压缩包仍会上传（publish 步骤是 `if: always()`）。

Linux 构建基线取 `ubuntu-22.04`（glibc 2.35），保证产物在老发行版上也能运行。

## 目录结构

```
.github/workflows/build-ffmpeg.yml   平台 × 变体矩阵（6 个 job，只负责装工具链）
.github/actions/publish/             滚动 release 上传（composite action）
scripts/build-deps.sh                lame 静态编译（唯一外部依赖）
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
OS=linux bash scripts/build-deps.sh          # 两变体共用，只编 lame
VARIANT=lgpl OS=linux bash scripts/build-ffmpeg.sh
```

macOS 把 `OS=linux` 换成 `OS=macos`。

## 已知维护成本

`scripts/build-deps.sh` 里 lame 3.100 的 tarball 链接会随时间腐烂，已配双源，
且每周一定时构建会把失效暴露出来。

每周一定时构建会把上述失效暴露出来。
