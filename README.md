# Antigravity 多电脑对话同步工具（Google Drive 版）

在多台 Windows 电脑之间通过 Google Drive 安全同步 **Google Antigravity** 本地对话记录、聊天历史与索引列表的轻量脚本工具，支持多设备迁移、无损合并多机旧对话、流式盘直接运行，避免 SQLite 数据库损坏。

> Safely sync Google Antigravity local conversation history across multiple Windows PCs using Google Drive for Desktop — works directly with Stream mode (`G:\`) without risking SQLite WAL database corruption.

---

## 直接下载（无需懂 Git）

1. 打开 [**Releases 最新版本页面**](https://github.com/rant003/antigravity-gdrive-sync/releases/latest)
2. 下载压缩包 `antigravity-gdrive-sync-v1.2.0.zip`
3. 解压后把 `AntigravitySync` 文件夹放到你的网盘目录中（例如 `G:\我的云端硬盘\AntigravitySync\` 或 WPS / OneDrive 同步目录）即可按下方步骤使用。

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
   - 推荐本机已安装 **Python 3**（仅使用标准库 `sqlite3`），用于在每次上传/下载及运行 `合并备份对话.bat` 时自动完成 **SQLite WAL 落盘校验** 与 **对话列表索引（`conversation_summaries.db`）行级合并**；未安装 Python 时会自动回退为按最新时间安全增量拷贝。

6. **首次同步大体积历史对话的耗时说明**
   - 若本机原有数百 MB 的历史对话（含多篇 PDF 解析缓存），首次全量上传或合并后上传可能需要等待数十秒至数分钟让 Google Drive 完成后台同步；后续日常使用仅增量复制变动文件，通常只需数秒。

---

## 为什么需要这个工具？

Google Antigravity 默认将对话记录保存在本地（`%USERPROFILE%\.gemini\antigravity`），内部使用 SQLite 数据库（`.db` / `-wal` / `-shm`）。如果直接把目录软链接到网盘实时同步，很容易因为多端锁文件冲突或网络延迟导致数据库损坏、侧边栏历史对话丢失或无法显示。

本工具采用**「安全合并模式（启动前安全拉取合并 + 退出后自动落盘上传）」**：
- **安全合并模式，只增不减（v1.2.0 新增）**：彻底取消会删文件的 `/MIR` 镜像覆盖；`conversations/`、`annotations/`、`brain/` 均按「缺失补全 + 较新优先」增量合并，**永远不会删除或把另一台电脑的对话扫进回收站**。
- **自动 SQLite WAL 落盘与校验（v1.2.0 新增）**：传输单条对话 `.db` 前，若存在非空 `-wal` 缓存会在本地临时目录执行 `PRAGMA wal_checkpoint(TRUNCATE)` 与 `PRAGMA integrity_check`，再输出干净的单文件 `.db`，彻底避免云端残留冲突锁文件。
- **索引库自动行级合并**：每次上传/下载（及运行 `合并备份对话.bat`）均自动调用 `merge_summaries.py` 对 `conversation_summaries.db`（含 FTS 全文搜索表）做行级合并，换电脑后侧边栏直接汇总显示两台设备的所有对话。
- **启动前云端新鲜度提示（v1.2.0 新增）**：每次启动时醒目展示云端最新上传设备与时间；若显示仍来自本机，会提醒及时重启网盘刷新缓存。
- **支持流式盘直接运行**：无需把 Google Drive 桌面端改成占空间的「镜像文件」模式。
- **自动启动器**：双击启动 Antigravity，软件关闭后自动安全合并上传新对话，成功 3 秒后自动关闭终端窗口（出错则停留提示）。
- **自动滚动本地备份**：每次合并拉取前，自动备份到 `%LOCALAPPDATA%\AntigravitySyncBackups`（最多保留最近 10 份）。
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

### 3. 第二台电脑配置（两台电脑原本都有旧对话也能自动合流）
1. 确保已安装 Antigravity 与网盘客户端，且 `AntigravitySync` 目录已同步完成。
2. 先关闭该电脑上正在运行的 Antigravity。
3. 打开网盘中的 `AntigravitySync` 文件夹，双击一次 **`在当前电脑创建桌面快捷方式.bat`**。
4. 直接双击桌面 **`Antigravity (自动同步)`**：脚本会先自动备份本地，再把云端与本机对话安全合并到一起（不会删掉第二台电脑原有的旧对话）；待退出软件时再把合并结果同步回云端。
5. 若此前用旧版产生过备份想补合回来，也可在关闭 Antigravity 后双击 **`合并备份对话.bat`** 手动选择历史备份进行合并。

### 4. 日常使用与固定到任务栏
- 右键桌面上的 **`Antigravity (自动同步)`**（Windows 11 需点击「显示更多选项」），选择 **「固定到任务栏」**。
- 以后直接从任务栏或桌面图标启动 Antigravity 即可。
- 切换电脑前，确认终端已自动关闭且右下角 Google Drive 托盘图标已完成上传。

---

## 同步范围说明

脚本仅同步对话数据与列表索引，不触碰设备专属的运行时状态与缓存：

| 同步内容 | 不同步内容（每台电脑独立保留） |
| :--- | :--- |
| `conversations/`（单文件落盘 `.db`） | `antigravity_state.pbtxt` |
| `brain/` | `installation_id` |
| `annotations/` | `cache/`、`daemon/`、`bin/`、`lib/`、`builtin/` |
| `conversation_summaries.db`（行级合并）、`agyhub_summaries_proto.pb` | `crashes/`、`presence/`、`scratch/` |

---

## 常见问题（FAQ）

**Q：同步后旧对话里的 PDF 在另一台电脑打不开 / AI 说找不到文件怎么办？**
A：这是因为原 PDF 存放在第一台电脑的本地磁盘（例如桌面），同步脚本只同步对话本身、不搬运你的本地文档。把需要的 PDF 复制进 Google Drive 统一目录（两台电脑盘符路径一致），并在对话里 `@` 新路径下的 PDF 即可继续提问。

**Q：如果某台电脑因为网盘缓存延迟没拉到最新文件，再上传会把另一台电脑的对话删掉吗？**
A：不会。`v1.2.0` 已升级为「安全合并模式」，上传与下载只补充缺失或更晚修改的对话，并对 `conversation_summaries.db` 做行级合并，**绝不会删除云端或本地已有的其他对话**。若启动时发现「云端最新记录」仍显示为本机旧时间，退出并重开一下网盘客户端刷新缓存即可。

**Q：两台电脑上原来各自都有一些对话，怎么合并而互不覆盖？**
A：直接使用 `v1.2.0` 的 **`Antigravity (自动同步)`** 启动即可在备份后自动安全合并两边的对话与索引；如需把历史备份目录中的旧记录补合回来，也可退出软件后运行 `合并备份对话.bat`（需安装 Python 3）。

**Q：为什么不直接把 `.gemini\antigravity` 软链接到 Google Drive？**
A：Antigravity 运行时会持续读写 SQLite 数据库及其 `-wal` / `-shm` 锁文件，网盘实时扫描和流式虚拟盘很容易引发文件占用报错或数据库损坏；此外，不同设备的 `installation_id` 和运行缓存也不适合跨机混用。本工具只在软件彻底退出后做 WAL 落盘与安全合并同步，更安全稳定。

**Q：Google Drive 必须开「镜像文件（Mirror files）」模式吗？**
A：不需要。保持默认的「流式传输（Stream files，`G:\`）」即可正常使用，不会额外占用大量本地磁盘空间。

**Q：如果不小心直接点了原版 Antigravity 图标，会丢失刚聊的新对话吗？**
A：不会。即便期间两台电脑各自产生过新对话，下次通过 `Antigravity (自动同步)` 启动或退出时，安全合并模式都会把两边的新对话合并到一起，并在拉取前自动备份本地数据到 `%LOCALAPPDATA%\AntigravitySyncBackups`。

**Q：支持 WPS 网盘、OneDrive、Dropbox 等其他网盘吗？**
A：支持。脚本完全基于自身所在目录（`$PSScriptRoot`）定位同步文件夹，只要把 `AntigravitySync` 放到 WPS 桌面云同步、OneDrive 或 Dropbox 的本地同步文件夹中，并在两台电脑各运行一次 `在当前电脑创建桌面快捷方式.bat` 即可通用。

---

## License

[MIT](./LICENSE)
