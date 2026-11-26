# Antigravity Google Drive Sync

通过 Google Drive 在多台 Windows 电脑之间安全同步 Google Antigravity 本地对话记录的轻量脚本工具。

> Safely sync Google Antigravity local conversation history across multiple Windows PCs using Google Drive for Desktop — works directly with Stream mode (`G:\`) without risking SQLite WAL database corruption.

---

## 为什么需要这个工具？

Google Antigravity 默认将对话记录保存在本地（`%USERPROFILE%\.gemini\antigravity`），内部使用 SQLite 数据库（`.db` / `-wal` / `-shm`）。如果直接把目录软链接到网盘实时同步，很容易因为多端锁文件冲突或网络延迟导致数据库损坏。

本工具采用**「启动前安全拉取 + 退出后自动上传」**的机制：
- **支持流式盘直接运行**：无需把 Google Drive 桌面端改成占空间的「镜像文件」模式。
- **自动启动器**：双击启动 Antigravity，软件关闭后自动上传新对话，成功 3 秒后自动关闭终端窗口（出错则停留提示）。
- **冲突检测与防误覆盖**：通过 `sync_meta.json` 追踪设备与 `syncId`，防止两台电脑的修改互相盲目覆盖。
- **自动滚动本地备份**：每次从云端覆盖本地前，自动备份到 `%LOCALAPPDATA%\AntigravitySyncBackups`（最多保留最近 5 份）。
- **纯净输出**：独立拉起 `Antigravity.exe`，不会在同步窗口刷出 Electron / WSL 启动日志。
- **支持固定任务栏**：桌面快捷方式直接指向 `powershell.exe`，可右键固定到 Windows 任务栏。

---

## 文件说明

| 文件 | 用途 |
| :--- | :--- |
| `sync_antigravity.ps1` | 核心同步脚本（支持 `launch` / `upload` / `download` / `status` / `shortcut`） |
| `启动Antigravity(自动同步).bat` | 自动同步启动入口 |
| `手动上传到云端.bat` | 手动将本地对话上传至 Google Drive |
| `手动从云端下载.bat` | 手动从 Google Drive 拉取最新对话到本地 |
| `在当前电脑创建桌面快捷方式.bat` | 在当前电脑桌面生成可固定到任务栏的 `Antigravity (自动同步)` 快捷方式 |

---

## 快速上手

### 1. 部署到 Google Drive
将本仓库中的 `.ps1` 和 `.bat` 文件放到你 Google Drive 中的任意文件夹（例如 `G:\我的云端硬盘\AntigravitySync\`）。

### 2. 第一台电脑（主电脑）首次配置
1. 先**彻底关闭 Antigravity**（检查右下角系统托盘图标，若有请右键退出）。
2. 双击 **`手动上传到云端.bat`**，把现有本地对话上传到云端（保存在同级 `data/` 目录下）。
3. 双击 **`在当前电脑创建桌面快捷方式.bat`**，在桌面生成 **`Antigravity (自动同步)`** 图标。

### 3. 第二台电脑配置
1. 确保已安装 Antigravity 与 Google Drive 桌面端，且 `AntigravitySync` 目录已同步完成。
2. 先关闭该电脑上正在运行的 Antigravity。
3. 打开 Google Drive 中的 `AntigravitySync` 文件夹，双击一次 **`在当前电脑创建桌面快捷方式.bat`**。

### 4. 日常使用与固定到任务栏
- 右键桌面上的 **`Antigravity (自动同步)`**（Windows 11 需点击「显示更多选项」），选择 **「固定到任务栏」**。
- 以后直接从任务栏或桌面图标启动 Antigravity 即可（请勿在两台电脑上同时打开）。
- 切换电脑前，确认终端已自动关闭且右下角 Google Drive 托盘图标已完成上传。

---

## 同步范围说明

脚本仅同步对话数据与列表索引，不触碰设备专属的运行时状态与缓存：

| 同步内容 | 不同步内容（每台电脑独立保留） |
| :--- | :--- |
| `conversations/` | `antigravity_state.pbtxt` |
| `brain/` | `installation_id` |
| `annotations/` | `cache/`、`daemon/`、`bin/`、`lib/`、`builtin/` |
| `conversation_summaries.db*`、`agyhub_summaries_proto.pb` | `crashes/`、`presence/`、`scratch/` |

---

## License

[MIT](./LICENSE)
