# Antigravity 多电脑对话同步工具（Google Drive 版）

在多台 Windows 电脑之间通过 Google Drive 安全同步 **Google Antigravity** 本地对话记录、聊天历史与索引列表的轻量脚本工具，支持多设备迁移、无损合并多机旧对话、流式盘直接运行，避免 SQLite 数据库损坏。

> Safely sync Google Antigravity local conversation history across multiple Windows PCs using Google Drive for Desktop — works directly with Stream mode (`G:\`) without risking SQLite WAL database corruption.

---

## 直接下载（无需懂 Git）

1. 打开 [**Releases 最新版本页面**](https://github.com/rant003/antigravity-gdrive-sync/releases/latest)
2. 下载压缩包 `antigravity-gdrive-sync-v1.1.0.zip`
3. 解压后把 `AntigravitySync` 文件夹放到你的 Google Drive 目录中（例如 `G:\我的云端硬盘\AntigravitySync\`）即可按下方步骤使用。

---

## ⚠️ 使用边界与局限性（使用前必读）

为了避免踩坑或误以为数据丢失，请在使用前了解本同步方案的能力边界：

1. **仅同步对话记录与聊天框附件，不同步本地硬盘上的原文件（PDF / 代码）**
   - 对话中的全部文字记录、AI 总结以及聊天框内上传的附件（存储在 `brain/` 中）会完整同步。
   - **存放在本机桌面或普通硬盘路径（如 `C:\Users\...\Desktop\...`）中的原 PDF、笔记或代码项目，不会跟着对话一起同步**。跨电脑打开旧对话时，历史聊天内容都可以正常浏览，但点击原本地文件链接或让 AI 重新读取原文件未讨论过的部分时会提示找不到路径。
   - **最佳实践**：跨电脑共用的文献 PDF、Markdown 笔记建议直接放入 Google Drive 的相同路径（如 `G:\我的云端硬盘\Papers\`）；代码项目建议通过 Git 同步，并在多台电脑保持完全一致的本地路径。

2. **仅支持单人串行切换电脑，不支持两台电脑同时运行**
   - 切勿在两台电脑同时打开 Antigravity。每次切换设备前，务必**彻底退出当前电脑的 Antigravity**（检查右下角托盘图标），并确认 Google Drive 托盘图标已完成上传。

3. **不建议把大型代码仓库直接放在 Google Drive 运行**
   - 带 `.git`、`node_modules`、`.venv` 等海量小文件的代码项目直接放网盘实时同步极易出现文件占用或仓库损坏。本工具最适合**「纯文献阅读 / Markdown 笔记（放 Google Drive）」**或**「代码走 Git + 对话走本工具」**的组合。

4. **插件授权、账号登录态与设备专属配置独立保留**
   - 不同步 `antigravity_state.pbtxt`、`installation_id` 及插件登录凭据，因此如 **Notion、Google Drive** 等插件授权需要在每台电脑分别登录一次。

5. **平台与运行依赖限制**
   - 仅支持 **Windows 10 / 11**（依赖 PowerShell 与系统自带 `robocopy`）。
   - 日常自动同步（`启动Antigravity(自动同步)` / 手动上传下载）**零外部依赖**；仅当需要**合并两台电脑各自已有的旧对话**（运行 `合并备份对话.bat`）时，需要本机已安装 **Python 3**（仅使用标准库 `sqlite3`）。

6. **首次同步大体积历史对话的耗时说明**
   - 若本机原有数百 MB 的历史对话（含多篇 PDF 解析缓存），首次全量上传或合并后上传可能需要等待数十秒至数分钟让 Google Drive 完成后台同步；后续日常使用仅增量复制变动文件，通常只需数秒。

---

## 为什么需要这个工具？

Google Antigravity 默认将对话记录保存在本地（`%USERPROFILE%\.gemini\antigravity`），内部使用 SQLite 数据库（`.db` / `-wal` / `-shm`）。如果直接把目录软链接到网盘实时同步，很容易因为多端锁文件冲突或网络延迟导致数据库损坏、侧边栏历史对话丢失或无法显示。

本工具采用**「启动前安全拉取 + 退出后自动上传」**的机制：
- **支持流式盘直接运行**：无需把 Google Drive 桌面端改成占空间的「镜像文件」模式。
- **自动启动器**：双击启动 Antigravity，软件关闭后自动上传新对话，成功 3 秒后自动关闭终端窗口（出错则停留提示）。
- **冲突检测与新机防误覆盖**：通过 `sync_meta.json` 追踪设备与 `syncId`；若新电脑首次同步时本地已有未同步旧对话，会弹窗提醒避免直接覆盖。
- **无损合并多机旧对话（v1.1.0 新增）**：内置 `合并备份对话.bat` + `merge_summaries.py`，可将两台电脑原本各自的对话与 SQLite 索引库（含 FTS 全文搜索表）无损合二为一。
- **自动滚动本地备份**：每次覆盖本地前，自动备份到 `%LOCALAPPDATA%\AntigravitySyncBackups`（最多保留最近 10 份）。
- **纯净输出 & 支持固定任务栏**：独立拉起 `Antigravity.exe`，无多余启动日志刷屏；桌面快捷方式直接指向 `powershell.exe`，可右键固定到 Windows 任务栏。

---

## 文件说明

| 文件 | 用途 |
| :--- | :--- |
| `sync_antigravity.ps1` | 核心同步脚本（支持 `launch` / `upload` / `download` / `merge` / `status` / `shortcut`） |
| `merge_summaries.py` | SQLite 对话索引库无损合并脚本（供 `合并备份对话.bat` 调用） |
| `启动Antigravity(自动同步).bat` | 自动同步启动入口 |
| `手动上传到云端.bat` | 手动将本地对话上传至 Google Drive |
| `手动从云端下载.bat` | 手动从 Google Drive 拉取最新对话到本地 |
| `合并备份对话.bat` | 将自动备份目录中的本机旧对话与当前云端对话无损合并 |
| `在当前电脑创建桌面快捷方式.bat` | 在当前电脑桌面生成可固定到任务栏的 `Antigravity (自动同步)` 快捷方式 |

---

## 快速上手（换电脑迁移与日常多设备同步）

### 1. 部署到 Google Drive
将压缩包解压出的 `AntigravitySync` 文件夹放到 Google Drive 中（例如 `G:\我的云端硬盘\AntigravitySync\`）。

### 2. 第一台电脑（主电脑）首次配置
1. 先**彻底关闭 Antigravity**（检查右下角系统托盘图标，若有请右键退出）。
2. 双击 **`手动上传到云端.bat`**，把现有本地对话上传到云端（保存在同级 `data/` 目录下）。
3. 双击 **`在当前电脑创建桌面快捷方式.bat`**，在桌面生成 **`Antigravity (自动同步)`** 图标。

### 3. 第二台电脑配置（含“两台电脑都有旧对话”的场景）
1. 确保已安装 Antigravity 与 Google Drive 桌面端，且 `AntigravitySync` 目录已同步完成。
2. 先关闭该电脑上正在运行的 Antigravity。
3. 打开 Google Drive 中的 `AntigravitySync` 文件夹，双击一次 **`在当前电脑创建桌面快捷方式.bat`**。
4. **若第二台电脑原本没有重要对话**：直接双击桌面 **`Antigravity (自动同步)`**，确认从云端拉取即可。
5. **若第二台电脑原本也有自己的旧对话想一起保留**：
   - 先运行一次 `Antigravity (自动同步)` 拉取云端对话（本机旧对话会被自动备份到 `%LOCALAPPDATA%\AntigravitySyncBackups`）；
   - 关闭 Antigravity 后，双击 **`合并备份对话.bat`**，按回车选择最新备份并上传，即可把两台电脑的对话合并到一起。

### 4. 日常使用与固定到任务栏
- 右键桌面上的 **`Antigravity (自动同步)`**（Windows 11 需点击「显示更多选项」），选择 **「固定到任务栏」**。
- 以后直接从任务栏或桌面图标启动 Antigravity 即可。
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

**Q：同步后旧对话里的 PDF 在另一台电脑打不开 / AI 说找不到文件怎么办？**
A：这是因为原 PDF 存放在第一台电脑的本地磁盘（例如桌面），同步脚本只同步对话本身、不搬运你的本地文档。把需要的 PDF 复制进 Google Drive 统一目录（两台电脑盘符路径一致），并在对话里 `@` 新路径下的 PDF 即可继续提问。

**Q：两台电脑上原来各自都有一些对话，怎么合并而互不覆盖？**
A：先退出 Antigravity，用 `Antigravity (自动同步)` 或 `手动从云端下载.bat` 拉取另一台电脑的对话（原本地对话会自动备份），退出后再运行 `合并备份对话.bat`（需安装 Python 3）即可无损合并并上传。

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
