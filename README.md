# Antigravity 多电脑对话同步工具（Google Drive 版）

在多台 Windows 电脑之间通过 Google Drive 安全同步 **Google Antigravity** 本地对话记录、聊天历史与索引列表的轻量脚本工具，支持多设备迁移、流式盘直接运行，避免 SQLite 数据库损坏。

> Safely sync Google Antigravity local conversation history across multiple Windows PCs using Google Drive for Desktop — works directly with Stream mode (`G:\`) without risking SQLite WAL database corruption.

---

## 直接下载（无需懂 Git）

1. 打开 [**Releases 最新版本页面**](https://github.com/rant003/antigravity-gdrive-sync/releases/latest)
2. 下载压缩包 `antigravity-gdrive-sync-v1.0.0.zip`
3. 解压后把 `AntigravitySync` 文件夹放到你的 Google Drive 目录中（例如 `G:\我的云端硬盘\AntigravitySync\`）即可按下方步骤使用。

---

## 为什么需要这个工具？

Google Antigravity 默认将对话记录保存在本地（`%USERPROFILE%\.gemini\antigravity`），内部使用 SQLite 数据库（`.db` / `-wal` / `-shm`）。如果直接把目录软链接到网盘实时同步，很容易因为多端锁文件冲突或网络延迟导致数据库损坏、侧边栏历史对话丢失或无法显示。

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

## 快速上手（换电脑迁移与日常多设备同步）

### 1. 部署到 Google Drive
将压缩包解压出的 `AntigravitySync` 文件夹放到 Google Drive 中（例如 `G:\我的云端硬盘\AntigravitySync\`）。

### 2. 第一台电脑（主电脑）首次配置
1. 先**彻底关闭 Antigravity**（检查右下角系统托盘图标，若有请右键退出）。
2. 双击 **`手动上传到云端.bat`**，把现有本地对话上传到云端（保存在同级 `data/` 目录下）。
3. 双击 **`在当前电脑创建桌面快捷方式.bat`**，在桌面生成 **`Antigravity (自动同步)`** 图标。

### 3. 第二台电脑配置（或换新电脑迁移对话）
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

## 常见问题（FAQ）

**Q：换新电脑怎么迁移 Antigravity 历史对话？**
A：在旧电脑退出 Antigravity 后运行一次 `手动上传到云端.bat`；在新电脑安装好 Google Drive 和 Antigravity 后，进入云盘里的 `AntigravitySync` 文件夹运行 `在当前电脑创建桌面快捷方式.bat`，然后直接通过桌面图标启动即可自动拉取全部历史对话。

**Q：为什么不直接把 `.gemini\antigravity` 软链接到 Google Drive？**
A：Antigravity 运行时会持续读写 SQLite 数据库及其 `-wal` / `-shm` 锁文件，网盘实时扫描和流式虚拟盘很容易引发文件占用报错或数据库损坏；此外，不同设备的 `installation_id` 和运行缓存也不适合跨机混用。本工具只在软件彻底退出后做镜像同步，更安全稳定。

**Q：Google Drive 必须开「镜像文件（Mirror files）」模式吗？**
A：不需要。保持默认的「流式传输（Stream files，`G:\`）」即可正常使用，不会额外占用大量本地磁盘空间。

**Q：如果不小心直接点了原版 Antigravity 图标，会丢失刚聊的新对话吗？**
A：不会。如果在同一台电脑上误用了原图标，下次再使用 `Antigravity (自动同步)` 启动时，脚本会对比 `syncId` 并发现云端没有被其他设备更新过，因此会跳过覆盖，并在退出后把新对话正常上传。即便双端都产生了改动，脚本也会先弹窗提示并自动备份本地数据到 `%LOCALAPPDATA%\AntigravitySyncBackups`。

**Q：支持 OneDrive、Dropbox 等其他网盘吗？**
A：支持。脚本完全基于自身所在目录（`$PSScriptRoot`）定位同步文件夹，只要把脚本放到 OneDrive 或 Dropbox 的本地同步文件夹中即可通用。

---

## License

[MIT](./LICENSE)
