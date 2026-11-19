# 项目协作约定

- 推送到远程前：默认运行 L2 轻量安全审查（qodersec review --layer=l2），
  无需每次询问 L3；发现安全问题时先呈现问题再决定修复与推送。
- 网络环境：访问 GitHub 需走本地代理 socks5h://127.0.0.1:10808
  （git 用 `-c http.proxy=...`，gh 用 `HTTPS_PROXY=socks5://127.0.0.1:10808`）。
- 本仓库必须保持 **public**：消费侧匿名下载 Release 资产，不用 token。
  一旦转 private，下游所有平台的 ffmpeg 获取会同时失效。
- 产物契约（改动前必读）：包内只有一个以 `ffmpeg-` 开头的顶层目录，
  其下 `bin/` 放可执行文件与运行时库、顶层放 `LICENSE.txt`。
  资产文件名固定且不含版本号（版本只出现在顶层目录名与 `README-build.txt`）。
  破坏其中任一条都属于破坏性变更。
- LGPL 变体的 configure 里绝不能出现 `--enable-gpl` / `--enable-nonfree`：
  `scripts/finalize.sh` 的 `selfcheck_ffmpeg` 会主动拦截，不要绕过它。
- 本地复现构建：Windows 需在 MSYS2 MINGW64  shell 里跑
  `scripts/build-ffmpeg-msys2.sh`；Linux/macOS 先跑 `scripts/build-deps.sh`
  再跑 `scripts/build-ffmpeg.sh`，两个脚本都只读环境变量。
