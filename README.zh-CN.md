# XDR Agent Screen

[English](README.md) | 中文

一个 macOS 菜单栏小工具：让显示器保持全黑，同时 computer-use agent 照常工作。

## 为什么需要它

在 Apple 芯片的 Mac 上，只要显示器进入睡眠，系统就会盖上锁屏遮罩，即使没有设置密码也一样。
一旦锁屏，截图就拿不到任何画面，依赖 computer use 的 agent 也就"看不见"了。

XDR Agent Screen 让屏幕变黑，但**不让显示器睡眠**：通过 gamma 表把画面压暗，同时把背光调到最低。
屏幕看起来是关着的，但截图仍然能拿到完整的桌面。

最初是为 Mac mini + Pro Display XDR 写的，其他显示器同样适用。

## 功能

- **Black Out Now** 和全局快捷键（可自定义，默认 ⌃⌥⌘L），一键切换全暗 / 恢复。
- **组合亮度滑块**：右半段调节原生背光（和系统亮度调节相同），左半段把背光保持在最低，
  再用软件继续压暗，最左边为全黑。
- **闲置自动全暗**：无操作 1–60 分钟后自动全暗，也可以关闭。
- **Agent Display**：可选的虚拟显示器（1280×720 到 3840×2160），默认镜像主显示器。
  如果物理显示器断电（例如用智能插座），虚拟显示器会接替成为主屏，agent 依然有屏幕可用。
- 菜单里的 **Launch at Login** 开机启动（只会运行一个实例；命令行用 `--login-item status|on|off`）。
- 安全恢复：程序退出或崩溃时会恢复画面；锁屏时会自动恢复亮度，保证能看见登录界面。

## 环境要求

- macOS 14 或更高版本，Apple 芯片
- Xcode 命令行工具（`swiftc`）
- 建议：系统设置 → 锁定屏幕 → "不活跃时关闭显示器"和"不活跃时启动屏幕保护程序"都设为**永不**

## 下载

从 [Releases](https://github.com/bitcinnamon/xdr-agent-screen/releases) 下载 `XDR-Agent-Screen-*-arm64.zip`，
解压后把 `XDR Agent Screen.app` 拖到 `/Applications`。应用只做了临时签名、没有经过 Apple 公证，
第一次打开会被系统拦截：右键点应用 → **打开**，或者执行

```sh
xattr -dr com.apple.quarantine "/Applications/XDR Agent Screen.app"
```

想开机自动启动，在菜单里选 **Launch at Login**。

## 从源码编译安装

```sh
./install.sh     # 编译并安装到 /Applications，启动它并打开 Launch at Login
./uninstall.sh   # 关闭 Launch at Login，退出程序（会恢复亮度）并删除应用
```

日志：`~/Library/Logs/xdr-agent-screen.log`。设置：`defaults read local.xdr-agent-screen`。

## 远程控制

```sh
kill -USR2 $(pgrep -x XDRAgentScreen)   # 切换全暗 / 恢复，效果同快捷键
kill -USR1 $(pgrep -x XDRAgentScreen)   # 弹出菜单 5 秒（方便截图）
```

如果屏幕卡在全黑，退出程序一定能恢复：

```sh
pkill -x XDRAgentScreen
```

## 说明

- 自动化程序模拟的输入在系统看来也算用户操作，所以它会影响闲置计时、可能触发闲置全暗，
  但不会让屏幕恢复亮度；只有快捷键、菜单或信号才能恢复。
- 硬件亮度和虚拟显示器用到了 macOS 的私有接口（`DisplayServices`、`CGVirtualDisplay`），
  未来的系统版本可能失效。
