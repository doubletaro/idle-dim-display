# idle-dim-display

[English](README.md) | [日本語](README.ja.md) | 中文

Windows 省电**系统托盘常驻工具**:键盘鼠标空闲时通过 DDC/CI 调暗显示器背光,**检测到输入后 1 秒内恢复**。面向台式机(交流电源)——Windows 自带的"暗显"功能只在电池模式下生效,所以本工具直接控制显示器。

## 行为规格

| 项目 | 默认值 |
|---|---|
| 变暗前的空闲时间 | 3 分钟 |
| 变暗时的亮度 | 30% |
| 检查间隔 | 1 秒(恢复延迟 ≤ 1 秒;DDC 通信仅在变暗时发生) |
| 恢复条件 | 检测到输入(空闲 < 10 秒) |
| 恢复后的重新变暗保护 | 30 秒 |

- **系统托盘常驻**(圆形图标:监控中=金色 / 已变暗=橙色半月 / 已暂停=灰色)。图标被隐藏时,可从任务栏右下角 `▲` 拖出常显。
- **双击图标**(或右键 → 打开设置)打开设置对话框:
  - 空闲分钟数 / 变暗亮度 / 检查间隔为数值输入 → "保存并应用"立即生效并持久化到 JSON
  - **当前亮度滑块**拖动时通过 DDC/CI 即时应用(相当于显示器 OSD)。滑块变更同时记录为恢复点,因此下一个变暗周期会恢复到正确的亮度
  - **Language 组**:日本語 / English / 中文 — 对话框、托盘菜单、工具提示立即切换,保存时持久化
- 托盘菜单:打开设置 / 立即测试变暗 / 恢复到100% / 暂停 / 退出
- 恢复时总是回到**变暗前一刻的亮度**——尊重手动亮度调整
- 无 DDC/CI 响应的显示器时不做任何操作(安全)
- 单实例保护(进程枚举 + 排除自身 PID)
- **自愈**:`idle-dim-wrapper.ps1`(由登录任务启动)在托盘异常退出(退出码≠0)时自动重启。未处理异常不再静默死亡,而是记录到 `~/bin/idle-dim.log`(`UI-EXCEPTION:` / `DOMAIN-EXCEPTION:` 行)。`idle-dim.ps1 stop` 会写入 `idle-dim.stop` 标志文件,让 wrapper 保持停止。

## 文件结构

| 文件 | 作用 |
|---|---|
| `idle-dim-tray.ps1` | **主体**:托盘常驻 + 设置界面 + DDC 控制(必须 UTF-8 **带 BOM** —— 无 BOM 时 PS 5.1 按 ANSI 解析导致语法错误) |
| `idle-dim-wrapper.ps1` | 保活包装器:崩溃时自动重启托盘;遵守 `idle-dim.stop` |
| `idle-dim.ps1` | 命令行操作:start / stop / status |
| `idle-dim-config.json` | 配置(部署到 `~/bin/`,由界面保存) |
| `ddc-probe.ps1` | 检查 DDC/CI 支持与当前亮度 |
| `ddc-test.ps1` | 变暗→恢复的一次性测试 |
| `ddc-restore.ps1` | 强制恢复亮度到 100% |
| `restart-idle-dim.ps1` | 结束所有进程→恢复亮度→从计划任务重启 |
| `register-idle-dim-task.ps1` | 注册登录启动任务 `IdleDimWatcher` |
| `launch-idle-dim-tray.vbs` | 隐藏窗口启动器(托盘用) |
| `launch-idle-dim.vbs` | (旧 CLI 监视器的启动器,留作参考) |
| `install.ps1` | 一键安装(复制→探测→注册→启动) |

## 安装(其他电脑 / 重新配置)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

内容:复制脚本到 `~/bin` → 探测 DDC/CI → 注册登录任务 → 启动托盘。

## 操作

```powershell
# GUI:双击托盘图标 → 设置对话框
# CLI:
powershell $env:USERPROFILE\bin\idle-dim.ps1 status   # 状态+配置+日志末尾
powershell $env:USERPROFILE\bin\idle-dim.ps1 stop     # 停止+亮度恢复100%
powershell $env:USERPROFILE\bin\idle-dim.ps1 start    # 重新启动
powershell $env:USERPROFILE\bin\restart-idle-dim.ps1  # 完全重启
```

## 配置

推荐通过界面修改("保存并应用"立即生效)。直接编辑请改 `~/bin/idle-dim-config.json`:

```json
{ "IdleMinutes": 3, "DimLevel": 30, "PollSec": 1, "Language": "ja" }
```

修改后运行 `restart-idle-dim.ps1`。

## 运维笔记(踩过的坑)

- **`schtasks /end` 杀不死子 powershell** —— 任务的 wscript 立即退出而 powershell 存活。停止/重启一律用 `restart-idle-dim.ps1`(进程枚举 + kill)。
- **`.ps1` 中的日文/中文字符串必须 UTF-8 带 BOM** —— 无 BOM 时 PowerShell 5.1 按 ANSI(Shift-JIS)解析,报出莫名其妙的 token 错误。
- **`New-Object 类型(a, b + c)` 会传 3 个参数** —— 逗号优先级高于 `+`,`(12, $y + 3)` 变成 `(12, $y, 3)`,打开对话框时构造函数抛异常。应写成 `Point(12, ($y + 3))`。
- **`Add-Type` 把 C# 警告当错误** —— 即使是未使用的字段也会编译失败。
- **事件处理 scriptblock 看不到函数局部变量** —— 但 `.GetNewClosure()` 不是解法:它把 `$script:` 名字重新绑定到闭包模块,全部为 null(`Set-Content` 报"参数不能为 null")。应把对话框控件放进 `$script:` 变量,处理器不加闭包。
- **用 `New-Object` + `[ref]` 的命名互斥量单实例保护不可靠** —— 应使用进程枚举 + 排除 `$PID`。
- **按命令行枚举进程会匹配到自己** —— 检查命令自身也包含脚本名,必须加 `$_.ProcessId -ne $PID`。
- **git-bash 中内联调用 PowerShell 会破坏 `$_`** —— 一定写成 `.ps1` 文件。
- 日志:`~/bin/idle-dim.log` —— 每次状态转换记录一行带时间戳。这是验证无界面常驻程序唯一实用的手段。
