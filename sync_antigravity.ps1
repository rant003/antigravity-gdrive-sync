param(
    [ValidateSet("launch", "upload", "download", "status", "shortcut")]
    [string]$Mode = "status"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$CloudRoot = $PSScriptRoot
$CloudDataDir = Join-Path $CloudRoot "data"
$CloudMetaPath = Join-Path $CloudRoot "sync_meta.json"
$LocalRoot = Join-Path $env:USERPROFILE ".gemini\antigravity"
$LocalMetaPath = Join-Path $LocalRoot "last_cloud_sync.json"
$BackupRoot = Join-Path $env:LOCALAPPDATA "AntigravitySyncBackups"

$SyncDirs = @("conversations", "brain", "annotations")
$SyncFiles = @(
    "conversation_summaries.db",
    "conversation_summaries.db-wal",
    "conversation_summaries.db-shm",
    "agyhub_summaries_proto.pb"
)

function Get-AntigravityExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\antigravity\Antigravity.exe"),
        "C:\Program Files\Antigravity\Antigravity.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }
    return $null
}

function Get-RunningAntigravityProcesses {
    $result = @()
    $procs = Get-Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ProcessName -eq "Antigravity") {
            $result += $p
        }
        elseif ($p.ProcessName -eq "language_server") {
            try {
                if ($p.Path -and $p.Path -match "antigravity") {
                    $result += $p
                }
            }
            catch {
                # Ignore access denied on protected process paths
            }
        }
    }
    return $result
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        Write-Warning "读取元数据失败 ($Path): $_"
        return $null
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [hashtable]$Data
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Data | ConvertTo-Json -Depth 4
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Invoke-MirrorDir {
    param(
        [string]$SourceDir,
        [string]$DestDir
    )
    if (-not (Test-Path $SourceDir)) {
        return
    }
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    & robocopy $SourceDir $DestDir /MIR /COPY:DT /FFT /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        throw "robocopy 同步目录失败 ($SourceDir -> $DestDir), 退出码: $code"
    }
}

function Sync-RootFiles {
    param(
        [string]$SourceRoot,
        [string]$DestRoot
    )
    if (-not (Test-Path $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }
    foreach ($walFile in @("conversation_summaries.db-wal", "conversation_summaries.db-shm")) {
        $targetWal = Join-Path $DestRoot $walFile
        if (Test-Path $targetWal) {
            Remove-Item -Path $targetWal -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($fileName in $SyncFiles) {
        $srcFile = Join-Path $SourceRoot $fileName
        if (Test-Path $srcFile) {
            $dstFile = Join-Path $DestRoot $fileName
            Copy-Item -Path $srcFile -Destination $dstFile -Force
        }
    }
}

function Sync-DataDirection {
    param(
        [string]$SourceRoot,
        [string]$DestRoot
    )
    if (-not (Test-Path $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }
    foreach ($dirName in $SyncDirs) {
        $src = Join-Path $SourceRoot $dirName
        $dst = Join-Path $DestRoot $dirName
        Invoke-MirrorDir -SourceDir $src -DestDir $dst
    }
    Sync-RootFiles -SourceRoot $SourceRoot -DestRoot $DestRoot
}

function Backup-LocalData {
    param([string]$Reason = "manual")

    if (-not (Test-Path $LocalRoot)) {
        return $null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $BackupRoot "${Reason}_${timestamp}"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    foreach ($dirName in $SyncDirs) {
        $src = Join-Path $LocalRoot $dirName
        if (Test-Path $src) {
            $dst = Join-Path $backupDir $dirName
            Invoke-MirrorDir -SourceDir $src -DestDir $dst
        }
    }
    foreach ($fileName in $SyncFiles) {
        $srcFile = Join-Path $LocalRoot $fileName
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $backupDir $fileName) -Force
        }
    }

    # Prune older backups, keep latest 5
    if (Test-Path $BackupRoot) {
        $allBackups = Get-ChildItem -Path $BackupRoot -Directory | Sort-Object CreationTime -Descending
        if ($allBackups.Count -gt 5) {
            $allBackups | Select-Object -Skip 5 | ForEach-Object {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $backupDir
}

function Wait-ForAntigravityExitInteractive {
    while ($true) {
        $running = @(Get-RunningAntigravityProcesses)
        if ($running.Count -eq 0) {
            return $true
        }
        Write-Host ""
        Write-Host "[提示] 检测到 Antigravity 仍在运行（共 $($running.Count) 个进程）。" -ForegroundColor Yellow
        Write-Host "请先彻底退出 Antigravity（注意检查右下角系统托盘是否有图标，若有请右键退出）。" -ForegroundColor Yellow
        $ans = Read-Host "退出完成后按 [Enter] 重新检查，或输入 Q 取消操作"
        if ($ans -match "^[qQ]$") {
            Write-Host "已取消操作。" -ForegroundColor Red
            return $false
        }
    }
}

function New-SyncMetadata {
    $nowUtc = (Get-Date).ToUniversalTime()
    return @{
        syncId        = [guid]::NewGuid().ToString()
        machineName   = $env:COMPUTERNAME
        userName      = $env:USERNAME
        syncTimeUtc   = $nowUtc.ToString("o")
        syncTimeLocal = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Show-Status {
    $exe = Get-AntigravityExe
    $running = @(Get-RunningAntigravityProcesses)
    $cloudMeta = Read-JsonFile -Path $CloudMetaPath
    $localMeta = Read-JsonFile -Path $LocalMetaPath

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Antigravity Google Drive 同步状态" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "本地数据目录 : $LocalRoot"
    Write-Host "云端同步目录 : $CloudDataDir"
    Write-Host "主程序路径   : $(if ($exe) { $exe } else { '未找到' })"
    Write-Host "当前运行状态 : $(if ($running.Count -gt 0) { "运行中 ($($running.Count) 个进程)" } else { '未运行' })"
    Write-Host ""
    if ($cloudMeta) {
        Write-Host "云端最新记录 : $($cloudMeta.syncTimeLocal) | 设备: $($cloudMeta.machineName) ($($cloudMeta.userName))"
        Write-Host "云端 Sync ID : $($cloudMeta.syncId)"
    }
    else {
        Write-Host "云端最新记录 : 尚无同步记录"
    }
    if ($localMeta) {
        Write-Host "本地同步基准 : $($localMeta.syncTimeLocal) | 设备: $($localMeta.machineName)"
        Write-Host "本地 Sync ID : $($localMeta.syncId)"
    }
    else {
        Write-Host "本地同步基准 : 尚无记录"
    }
    Write-Host "========================================" -ForegroundColor Cyan
}

function Invoke-Upload {
    if (-not (Wait-ForAntigravityExitInteractive)) {
        return
    }
    if (-not (Test-Path $LocalRoot)) {
        Write-Host "[错误] 未找到本地 Antigravity 数据目录: $LocalRoot" -ForegroundColor Red
        return
    }

    Write-Host "等待 SQLite 写入落盘..." -ForegroundColor Gray
    Start-Sleep -Seconds 2

    $cloudMeta = Read-JsonFile -Path $CloudMetaPath
    $localMeta = Read-JsonFile -Path $LocalMetaPath

    if ($cloudMeta -and ((-not $localMeta) -or ($cloudMeta.syncId -ne $localMeta.syncId))) {
        Write-Host ""
        Write-Host "[警告] 云端数据较新或来自其他设备！" -ForegroundColor Yellow
        Write-Host "云端最后上传设备: $($cloudMeta.machineName) ($($cloudMeta.userName))" -ForegroundColor Yellow
        Write-Host "云端最后上传时间: $($cloudMeta.syncTimeLocal)" -ForegroundColor Yellow
        $confirm = Read-Host "继续上传将覆盖云端记录，确认覆盖请输入 Y，其他键取消"
        if ($confirm -notmatch "^[yY]$") {
            Write-Host "已取消上传。" -ForegroundColor Red
            return
        }
    }

    Write-Host "正在同步本地对话到 Google Drive..." -ForegroundColor Cyan
    Sync-DataDirection -SourceRoot $LocalRoot -DestRoot $CloudDataDir

    $meta = New-SyncMetadata
    Write-JsonFile -Path $CloudMetaPath -Data $meta
    Write-JsonFile -Path $LocalMetaPath -Data $meta

    Write-Host ""
    Write-Host "[成功] 对话记录已上传至云端目录！" -ForegroundColor Green
    Write-Host "同步时间: $($meta.syncTimeLocal) | Sync ID: $($meta.syncId)" -ForegroundColor Green
    Write-Host "提醒: 切换电脑前请确认右下角 Google Drive 托盘图标已显示同步完成。" -ForegroundColor Yellow
}

function Invoke-Download {
    if (-not (Wait-ForAntigravityExitInteractive)) {
        return
    }
    if (-not (Test-Path $CloudDataDir)) {
        Write-Host "[错误] 云端尚无对话数据目录: $CloudDataDir" -ForegroundColor Red
        return
    }

    Write-Host "正在自动备份本地数据..." -ForegroundColor Cyan
    $backupPath = Backup-LocalData -Reason "before_download"
    if ($backupPath) {
        Write-Host "本地备份已保存至: $backupPath" -ForegroundColor Gray
    }

    Write-Host "正在从 Google Drive 下载对话到本地..." -ForegroundColor Cyan
    Sync-DataDirection -SourceRoot $CloudDataDir -DestRoot $LocalRoot

    if (Test-Path $CloudMetaPath) {
        Copy-Item -Path $CloudMetaPath -Destination $LocalMetaPath -Force
    }

    $cloudMeta = Read-JsonFile -Path $CloudMetaPath
    Write-Host ""
    Write-Host "[成功] 已从云端同步最新对话到本地！" -ForegroundColor Green
    if ($cloudMeta) {
        Write-Host "同步来源: $($cloudMeta.machineName) | 上传时间: $($cloudMeta.syncTimeLocal)" -ForegroundColor Green
    }
}

function Test-LocalModifiedAfterSync {
    param($LocalMeta)
    if (-not $LocalMeta -or -not $LocalMeta.syncTimeUtc) {
        return $false
    }
    $convDir = Join-Path $LocalRoot "conversations"
    if (-not (Test-Path $convDir)) {
        return $false
    }
    $files = @(Get-ChildItem -Path $convDir -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return $false
    }
    try {
        $lastSyncUtc = [datetime]::Parse($LocalMeta.syncTimeUtc).ToUniversalTime()
        foreach ($f in $files) {
            if ($f.LastWriteTimeUtc -gt $lastSyncUtc.AddSeconds(5)) {
                return $true
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Invoke-Launch {
    $running = @(Get-RunningAntigravityProcesses)
    if ($running.Count -gt 0) {
        Write-Host "[警告] 检测到 Antigravity 已经在运行中！为防止损坏对话数据库，请先退出当前 Antigravity 再使用自动同步启动器。" -ForegroundColor Red
        Read-Host "按回车键关闭窗口"
        return
    }

    $exe = Get-AntigravityExe
    if (-not $exe) {
        Write-Host "[错误] 未找到 Antigravity.exe，请确认已安装 Antigravity。" -ForegroundColor Red
        Read-Host "按回车键关闭窗口"
        return
    }

    $cloudMeta = Read-JsonFile -Path $CloudMetaPath
    $localMeta = Read-JsonFile -Path $LocalMetaPath

    if ((Test-Path $CloudDataDir) -and $cloudMeta) {
        if ($localMeta -and ($cloudMeta.syncId -eq $localMeta.syncId)) {
            Write-Host "本地已是最新同步版本（$($cloudMeta.syncTimeLocal)），直接启动 Antigravity..." -ForegroundColor Green
        }
        else {
            $shouldDownload = $true
            if (Test-LocalModifiedAfterSync -LocalMeta $localMeta) {
                Write-Host ""
                Write-Host "[注意] 检测到云端和本地都有新的变动！" -ForegroundColor Yellow
                Write-Host "云端最新: $($cloudMeta.machineName) 于 $($cloudMeta.syncTimeLocal)" -ForegroundColor Yellow
                Write-Host "本地也有上次同步之后修改过的对话文件。" -ForegroundColor Yellow
                $choice = Read-Host "请选择: [Y] 用云端覆盖本地（会先自动备份本地） / [N] 保留本地直接启动"
                if ($choice -notmatch "^[yY]$") {
                    $shouldDownload = $false
                    Write-Host "已选择保留本地数据，跳过下载。" -ForegroundColor Cyan
                }
            }
            if ($shouldDownload) {
                Write-Host "发现云端新版本（来自 $($cloudMeta.machineName)，时间 $($cloudMeta.syncTimeLocal)），正在备份并拉取..." -ForegroundColor Cyan
                $backupPath = Backup-LocalData -Reason "before_launch_download"
                if ($backupPath) {
                    Write-Host "本地备份已保存至: $backupPath" -ForegroundColor Gray
                }
                Sync-DataDirection -SourceRoot $CloudDataDir -DestRoot $LocalRoot
                Copy-Item -Path $CloudMetaPath -Destination $LocalMetaPath -Force
                Write-Host "云端对话拉取完成！" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "云端尚无历史数据，将直接启动 Antigravity，退出后会自动完成首次上传。" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "正在启动 Antigravity..." -ForegroundColor Cyan
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$exe`"" | Out-Null

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "Antigravity 已启动！请保持此窗口打开（可最小化）。" -ForegroundColor Green
    Write-Host "使用完毕请彻底退出 Antigravity（若右下角托盘有图标请右键退出），" -ForegroundColor Yellow
    Write-Host "退出后本窗口会自动将新对话上传同步到 Google Drive。" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Green

    # Wait up to 30 seconds for Antigravity process to appear
    $appeared = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ((@(Get-RunningAntigravityProcesses)).Count -gt 0) {
            $appeared = $true
            break
        }
    }

    if (-not $appeared) {
        Write-Host "[警告] 等待 Antigravity 启动超时，未检测到运行进程，已跳过自动上传。" -ForegroundColor Yellow
        Read-Host "按回车键关闭窗口"
        return
    }

    # Monitor until all Antigravity processes exit
    while ((@(Get-RunningAntigravityProcesses)).Count -gt 0) {
        Start-Sleep -Seconds 3
    }

    Write-Host ""
    Write-Host "检测到 Antigravity 已完全退出，等待 SQLite 落盘后自动上传..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    try {
        Sync-DataDirection -SourceRoot $LocalRoot -DestRoot $CloudDataDir
        $meta = New-SyncMetadata
        Write-JsonFile -Path $CloudMetaPath -Data $meta
        Write-JsonFile -Path $LocalMetaPath -Data $meta

        Write-Host ""
        Write-Host "[成功] 本次对话记录已自动同步到 Google Drive！" -ForegroundColor Green
        Write-Host "同步时间: $($meta.syncTimeLocal) | Sync ID: $($meta.syncId)" -ForegroundColor Green
        Write-Host "请等待右下角 Google Drive 托盘图标完成上传后再关机或切换电脑。" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "窗口将在 3 秒后自动关闭..." -ForegroundColor Gray
        Start-Sleep -Seconds 3
    }
    catch {
        Write-Host ""
        Write-Host "[错误] 自动上传失败: $_" -ForegroundColor Red
        Write-Host "请稍后双击 运行 手动上传到云端.bat 进行补传。" -ForegroundColor Yellow
        Read-Host "按回车键关闭窗口"
    }
}

function New-DesktopShortcut {
    $desktopDir = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktopDir "Antigravity (自动同步).lnk"
    $scriptPath = Join-Path $CloudRoot "sync_antigravity.ps1"
    $exe = Get-AntigravityExe

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode launch"
    $shortcut.WorkingDirectory = $CloudRoot
    if ($exe) {
        $shortcut.IconLocation = "$exe,0"
    }
    $shortcut.Description = "启动 Antigravity 并通过 Google Drive 自动同步对话"
    $shortcut.Save()

    Write-Host "[成功] 已在桌面创建快捷方式: $shortcutPath" -ForegroundColor Green
    Write-Host "指向目标: $($shortcut.TargetPath) $($shortcut.Arguments)" -ForegroundColor Gray
}

switch ($Mode) {
    "status" { Show-Status }
    "upload" { Invoke-Upload }
    "download" { Invoke-Download }
    "launch" { Invoke-Launch }
    "shortcut" { New-DesktopShortcut }
}
