# apps/ —— 自编译离线安装包目录

本目录存放**自编译**的 `.apk` 离线包，在 FanchmWrt 首次启动时由
`files-fanchmwrt/etc/init.d/firstboot-pkgs` 离线安装（`apk --allow-untrusted add`）。

## 适用场景
- **带 vermagic 的 kmod**（内核模块，如网卡驱动、kmod-tun、fwxd 等）：
  官方 release 源的 kmod 与自编译内核的 vermagic 不一致，`insmod` 会拒绝加载，
  因此必须随固件编译进镜像（FanchmWrt 由 `build.sh` / workflow 内联最小种子中的 `CONFIG_PACKAGE_kmod-*` 段 + `make defconfig` 生成）或作为同源编译的 `.apk` 离线装。
- **闭源 / 自编译 / 非官方源的 userspace 包**（如 OpenClash、AdGuardHome 包装成的 `.apk`、
  你自己的 Lua 应用等），官方 apk 源取不到的，放这里离线装。

## 放置规则
- 直接把 `.apk` 丢进本目录即可，构建脚本会自动拷到镜像的
  `/etc/firstboot-pkgs/apps/` 并在首启安装。
- `*.apk` 已被 `.gitignore` 忽略，**不会提交进仓库**（避免大二进制入库）；
  它们应来自你本地的编译产物或可信来源。
- 纯官方源就能取到的 userspace 包，请改用 `lists/` 在线装，不要放这里。

## 注意
- 原始二进制（如 OpenClash 的 clash_meta 核心、AdGuardHome 可执行文件）不是 `.apk`，
  应直接放进 `files-fanchmwrt/`（编译进镜像），而不是本目录。
- 若日后获得 **fwxd（fwx 内核模块）** 源码并编译出 `kmod-fwxd*.apk`，放这里即可让 fwx 真正可用。
