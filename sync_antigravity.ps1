param(
    [ValidateSet("launch", "upload", "download", "status", "shortcut", "merge")]
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

function Get-SqliteEffectiveMtimeUtc {
    param(
        [string]$Dir,
        [string]$DbFileName
    )
    $dbPath = Join-Path $Dir $DbFileName
    if (-not (Test-Path $dbPath)) {
        return $null
    }
    $latest = (Get-Item -Path $dbPath).LastWriteTimeUtc
    $walPath = Join-Path $Dir ($DbFileName + "-wal")
    if (Test-Path $walPath) {
        $walItem = Get-Item -Path $walPath
        if ($walItem.Length -gt 0 -and $walItem.LastWriteTimeUtc -gt $latest) {
            $latest = $walItem.LastWriteTimeUtc
        }
    }
    return $latest
}

function Copy-SqliteClean {
    param(
        [string]$SrcDir,
        [string]$DstDir,
        [string]$DbFileName,
        [string]$PythonExe
    )
    if (-not (Test-Path $DstDir)) {
        New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
    }
    $srcDb = Join-Path $SrcDir $DbFileName
    if (-not (Test-Path $srcDb)) {
        return
    }
    $dstDb = Join-Path $DstDir $DbFileName
    $srcWal = Join-Path $SrcDir ($DbFileName + "-wal")
    $srcShm = Join-Path $SrcDir ($DbFileName + "-shm")

    foreach ($suffix in @("-wal", "-shm")) {
        $stale = Join-Path $DstDir ($DbFileName + $suffix)
        if (Test-Path $stale) {
            Remove-Item -Path $stale -Force -ErrorAction SilentlyContinue
        }
    }

    $hasWalData = (Test-Path $srcWal) -and ((Get-Item -Path $srcWal).Length -gt 0)
    if ($hasWalData -and $PythonExe) {
        $tmpDir = Join-Path $env:TEMP ("agy_sqlite_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $tmpDb = Join-Path $tmpDir $DbFileName
            Copy-Item -Path $srcDb -Destination $tmpDb -Force
            Copy-Item -Path $srcWal -Destination ($tmpDb + "-wal") -Force
            if (Test-Path $srcShm) {
                Copy-Item -Path $srcShm -Destination ($tmpDb + "-shm") -Force
            }
            $pyCheck = "import sqlite3, sys; con = sqlite3.connect(sys.argv[1]); con.execute('PRAGMA wal_checkpoint(TRUNCATE);'); integ = con.execute('PRAGMA integrity_check;').fetchone()[0]; con.close(); sys.exit(0 if integ == 'ok' else 1)"
            $errOut = & $PythonExe -c $pyCheck $tmpDb 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "SQLite WAL checkpoint 失败 ($srcDb): $errOut"
            }
            Copy-Item -Path $tmpDb -Destination $dstDb -Force
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Copy-Item -Path $srcDb -Destination $dstDb -Force
        if ($hasWalData) {
            Copy-Item -Path $srcWal -Destination ($dstDb + "-wal") -Force
            if (Test-Path $srcShm) {
                Copy-Item -Path $srcShm -Destination ($dstDb + "-shm") -Force
            }
        }
    }
}

function Merge-SummaryDatabase {
    param(
        [string]$SrcRoot,
        [string]$DstRoot
    )
    $srcSumDb = Join-Path $SrcRoot "conversation_summaries.db"
    if (-not (Test-Path $srcSumDb)) {
        return "无源索引库"
    }
    if (-not (Test-Path $DstRoot)) {
        New-Item -ItemType Directory -Path $DstRoot -Force | Out-Null
    }
    $dstSumDb = Join-Path $DstRoot "conversation_summaries.db"
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    $pythonExe = if ($pythonCmd) { $pythonCmd.Source } else { $null }
    $mergePy = Join-Path $CloudRoot "merge_summaries.py"

    if ((Test-Path $dstSumDb) -and $pythonExe -and (Test-Path $mergePy)) {
        $tmpDir = Join-Path $env:TEMP ("agy_sum_merge_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $tmpSrc = Join-Path $tmpDir "src.db"
            $tmpDst = Join-Path $tmpDir "dst.db"

            Copy-Item -Path $srcSumDb -Destination $tmpSrc -Force
            foreach ($suffix in @("-wal", "-shm")) {
                $sFile = $srcSumDb + $suffix
                if (Test-Path $sFile) { Copy-Item -Path $sFile -Destination ($tmpSrc + $suffix) -Force }
            }

            Copy-Item -Path $dstSumDb -Destination $tmpDst -Force
            foreach ($suffix in @("-wal", "-shm")) {
                $dFile = $dstSumDb + $suffix
                if (Test-Path $dFile) { Copy-Item -Path $dFile -Destination ($tmpDst + $suffix) -Force }
            }

            $mergeOut = & $pythonExe $mergePy $tmpSrc $tmpDst 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "merge_summaries.py 失败: $mergeOut"
            }

            $pyVerify = "import sqlite3, sys; con = sqlite3.connect(sys.argv[1]); con.execute('PRAGMA wal_checkpoint(TRUNCATE);'); integ = con.execute('PRAGMA integrity_check;').fetchone()[0]; con.close(); sys.exit(0 if integ == 'ok' else 1)"
            $verifyOut = & $pythonExe -c $pyVerify $tmpDst 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "索引库完整性校验失败: $verifyOut"
            }

            foreach ($suffix in @("-wal", "-shm")) {
                $stale = $dstSumDb + $suffix
                if (Test-Path $stale) { Remove-Item -Path $stale -Force -ErrorAction SilentlyContinue }
            }
            Copy-Item -Path $tmpDst -Destination $dstSumDb -Force
            return ($mergeOut -join " ").Trim()
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    elseif (-not (Test-Path $dstSumDb)) {
        Copy-SqliteClean -SrcDir $SrcRoot -DstDir $DstRoot -DbFileName "conversation_summaries.db" -PythonExe $pythonExe
        return "初始化索引库"
    }
    else {
        $srcMtime = Get-SqliteEffectiveMtimeUtc -Dir $SrcRoot -DbFileName "conversation_summaries.db"
        $dstMtime = Get-SqliteEffectiveMtimeUtc -Dir $DstRoot -DbFileName "conversation_summaries.db"
        if ($srcMtime -and ((-not $dstMtime) -or ($srcMtime -gt $dstMtime.AddSeconds(2)))) {
            Copy-SqliteClean -SrcDir $SrcRoot -DstDir $DstRoot -DbFileName "conversation_summaries.db" -PythonExe $pythonExe
            return "无 Python 环境，按最新时间覆盖"
        }
        return "索引库无需更新"
    }
}

function Sync-DataMerge {
    param(
        [string]$SourceRoot,
        [string]$DestRoot
    )
    if (-not (Test-Path $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    $pythonExe = if ($pythonCmd) { $pythonCmd.Source } else { $null }

    # 1. conversations/*.db (additive newest-wins, never deletes destination-only chats)
    $srcConvDir = Join-Path $SourceRoot "conversations"
    $dstConvDir = Join-Path $DestRoot "conversations"
    $convAdded = 0
    $convUpdated = 0
    if (Test-Path $srcConvDir) {
        if (-not (Test-Path $dstConvDir)) {
            New-Item -ItemType Directory -Path $dstConvDir -Force | Out-Null
        }
        $srcDbs = @(Get-ChildItem -Path $srcConvDir -Filter "*.db" -File -ErrorAction SilentlyContinue)
        foreach ($srcDb in $srcDbs) {
            $srcMtime = Get-SqliteEffectiveMtimeUtc -Dir $srcConvDir -DbFileName $srcDb.Name
            $dstMtime = Get-SqliteEffectiveMtimeUtc -Dir $dstConvDir -DbFileName $srcDb.Name
            if (-not $dstMtime) {
                Copy-SqliteClean -SrcDir $srcConvDir -DstDir $dstConvDir -DbFileName $srcDb.Name -PythonExe $pythonExe
                $convAdded++
            }
            elseif ($srcMtime -gt $dstMtime.AddSeconds(2)) {
                Copy-SqliteClean -SrcDir $srcConvDir -DstDir $dstConvDir -DbFileName $srcDb.Name -PythonExe $pythonExe
                $convUpdated++
            }
        }
    }

    # 2. annotations/ (additive newest-wins)
    $srcAnnDir = Join-Path $SourceRoot "annotations"
    $dstAnnDir = Join-Path $DestRoot "annotations"
    if (Test-Path $srcAnnDir) {
        if (-not (Test-Path $dstAnnDir)) {
            New-Item -ItemType Directory -Path $dstAnnDir -Force | Out-Null
        }
        $annFiles = @(Get-ChildItem -Path $srcAnnDir -File -ErrorAction SilentlyContinue)
        foreach ($af in $annFiles) {
            $dstAnn = Join-Path $dstAnnDir $af.Name
            if ((-not (Test-Path $dstAnn)) -or ($af.LastWriteTimeUtc -gt (Get-Item -Path $dstAnn).LastWriteTimeUtc.AddSeconds(2))) {
                Copy-Item -Path $af.FullName -Destination $dstAnn -Force
            }
        }
    }

    # 3. brain/ (additive newest-wins via robocopy /E /XO, never /MIR or /PURGE)
    $srcBrainDir = Join-Path $SourceRoot "brain"
    $dstBrainDir = Join-Path $DestRoot "brain"
    if (Test-Path $srcBrainDir) {
        if (-not (Test-Path $dstBrainDir)) {
            New-Item -ItemType Directory -Path $dstBrainDir -Force | Out-Null
        }
        & robocopy $srcBrainDir $dstBrainDir /E /XO /COPY:DT /FFT /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        $rcCode = $LASTEXITCODE
        if ($rcCode -ge 8) {
            throw "robocopy 合并 brain 目录失败 ($srcBrainDir -> $dstBrainDir), 退出码: $rcCode"
        }
    }

    # 4. conversation_summaries.db (row-level SQLite merge)
    $sumSummary = Merge-SummaryDatabase -SrcRoot $SourceRoot -DstRoot $DestRoot

    # 5. agyhub_summaries_proto.pb (newest-wins)
    $srcProto = Join-Path $SourceRoot "agyhub_summaries_proto.pb"
    $dstProto = Join-Path $DestRoot "agyhub_summaries_proto.pb"
    if (Test-Path $srcProto) {
        if ((-not (Test-Path $dstProto)) -or ((Get-Item -Path $srcProto).LastWriteTimeUtc -gt (Get-Item -Path $dstProto).LastWriteTimeUtc.AddSeconds(2))) {
            Copy-Item -Path $srcProto -Destination $dstProto -Force
        }
    }

    Write-Host "同步详情: 对话新增 $convAdded 个, 更新 $convUpdated 个 | 索引库: $sumSummary" -ForegroundColor Gray
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

    # Prune older backups, keep latest 10
    if (Test-Path $BackupRoot) {
        $allBackups = Get-ChildItem -Path $BackupRoot -Directory | Sort-Object CreationTime -Descending
        if ($allBackups.Count -gt 10) {
            $allBackups | Select-Object -Skip 10 | ForEach-Object {
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
    $localConvCount = @(Get-ChildItem -Path (Join-Path $LocalRoot "conversations") -Filter "*.db" -File -ErrorAction SilentlyContinue).Count
    $cloudConvCount = @(Get-ChildItem -Path (Join-Path $CloudDataDir "conversations") -Filter "*.db" -File -ErrorAction SilentlyContinue).Count

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Antigravity Google Drive 同步状态" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "同步模式     : 安全合并模式 (只增不减 + SQLite 索引合并)"
    Write-Host "本地数据目录 : $LocalRoot ($localConvCount 个对话)"
    Write-Host "云端同步目录 : $CloudDataDir ($cloudConvCount 个对话)"
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
        Write-Host "[提示] 云端最新记录来自 $($cloudMeta.machineName) @ $($cloudMeta.syncTimeLocal)。" -ForegroundColor Yellow
        Write-Host "将以「安全合并模式」上传，不会删除云端已有的对话记录。" -ForegroundColor Cyan
        $confirm = Read-Host "是否继续安全合并上传？[Y/n]"
        if (-not [string]::IsNullOrWhiteSpace($confirm) -and ($confirm -notmatch "^[yY]$")) {
            Write-Host "已取消上传。" -ForegroundColor Red
            return
        }
    }

    Write-Host "正在以安全合并模式同步本地对话到云端..." -ForegroundColor Cyan
    Sync-DataMerge -SourceRoot $LocalRoot -DestRoot $CloudDataDir

    $meta = New-SyncMetadata
    Write-JsonFile -Path $CloudMetaPath -Data $meta
    Write-JsonFile -Path $LocalMetaPath -Data $meta

    Write-Host ""
    Write-Host "[成功] 对话记录已安全合并上传至云端目录！" -ForegroundColor Green
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
    $backupPath = Backup-LocalData -Reason "before_download_merge"
    if ($backupPath) {
        Write-Host "本地备份已保存至: $backupPath" -ForegroundColor Gray
    }

    Write-Host "正在以安全合并模式从云端拉取对话到本地..." -ForegroundColor Cyan
    Sync-DataMerge -SourceRoot $CloudDataDir -DestRoot $LocalRoot

    if (Test-Path $CloudMetaPath) {
        Copy-Item -Path $CloudMetaPath -Destination $LocalMetaPath -Force
    }

    $cloudMeta = Read-JsonFile -Path $CloudMetaPath
    Write-Host ""
    Write-Host "[成功] 已从云端安全合并最新对话到本地！" -ForegroundColor Green
    if ($cloudMeta) {
        Write-Host "同步来源: $($cloudMeta.machineName) | 上传时间: $($cloudMeta.syncTimeLocal)" -ForegroundColor Green
    }
}

function Test-CloudHasUpdates {
    $cloudConvDir = Join-Path $CloudDataDir "conversations"
    $localConvDir = Join-Path $LocalRoot "conversations"
    if (-not (Test-Path $cloudConvDir)) {
        return $false
    }
    $cloudDbs = @(Get-ChildItem -Path $cloudConvDir -Filter "*.db" -File -ErrorAction SilentlyContinue)
    foreach ($cDb in $cloudDbs) {
        $cMtime = Get-SqliteEffectiveMtimeUtc -Dir $cloudConvDir -DbFileName $cDb.Name
        $lMtime = Get-SqliteEffectiveMtimeUtc -Dir $localConvDir -DbFileName $cDb.Name
        if (-not $lMtime) {
            return $true
        }
        if ($cMtime -gt $lMtime.AddSeconds(2)) {
            return $true
        }
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
        Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "云端最新记录: $($cloudMeta.machineName) ($($cloudMeta.userName)) @ $($cloudMeta.syncTimeLocal)" -ForegroundColor Cyan
        if ($cloudMeta.machineName -eq $env:COMPUTERNAME) {
            Write-Host "提示: 云端最新记录来自本机；若刚在另一台电脑用过却没看到对方记录，请先重启 Google Drive 刷新。" -ForegroundColor Yellow
        }
        Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan

        $needPull = (-not $localMeta) -or ($cloudMeta.syncId -ne $localMeta.syncId) -or (Test-CloudHasUpdates)
        if (-not $needPull) {
            Write-Host "本地已是最新同步版本，直接启动 Antigravity..." -ForegroundColor Green
        }
        else {
            Write-Host "正在备份本地并安全合并云端对话（只增不减，不会丢失本机已有对话）..." -ForegroundColor Cyan
            $backupPath = Backup-LocalData -Reason "before_launch_merge"
            if ($backupPath) {
                Write-Host "本地备份已保存至: $backupPath" -ForegroundColor Gray
            }
            Sync-DataMerge -SourceRoot $CloudDataDir -DestRoot $LocalRoot
            Copy-Item -Path $CloudMetaPath -Destination $LocalMetaPath -Force
            Write-Host "云端对话安全合并完成！" -ForegroundColor Green
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
    Write-Host "检测到 Antigravity 已完全退出，等待 SQLite 落盘后安全合并上传..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    try {
        Sync-DataMerge -SourceRoot $LocalRoot -DestRoot $CloudDataDir
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

function Invoke-Merge {
    if (-not (Wait-ForAntigravityExitInteractive)) {
        return
    }

    Write-Host "等待 SQLite 写入落盘..." -ForegroundColor Gray
    Start-Sleep -Seconds 2

    if (-not (Test-Path $BackupRoot)) {
        Write-Host "[错误] 未找到本地备份目录: $BackupRoot" -ForegroundColor Red
        return
    }

    $backups = @(Get-ChildItem -Path $BackupRoot -Directory | Sort-Object CreationTime -Descending)
    if ($backups.Count -eq 0) {
        Write-Host "[错误] 备份目录中没有可用的备份。" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "可用的本地备份列表（按时间从新到旧）" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $bDir = $backups[$i]
        $bConvDir = Join-Path $bDir.FullName "conversations"
        $dbCount = if (Test-Path $bConvDir) { @(Get-ChildItem -Path $bConvDir -Filter "*.db" -File -ErrorAction SilentlyContinue).Count } else { 0 }
        Write-Host ("  [{0}] {1}  ({2} 个对话)" -f ($i + 1), $bDir.Name, $dbCount)
    }
    Write-Host ""
    $sel = Read-Host "请输入要合并的备份编号（直接按 [Enter] 默认选 1，输入 Q 取消）"
    if ($sel -match "^[qQ]$") {
        Write-Host "已取消合并。" -ForegroundColor Red
        return
    }
    $idx = 0
    if (-not [string]::IsNullOrWhiteSpace($sel)) {
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $backups.Count) {
            Write-Host "[错误] 无效的编号: $sel" -ForegroundColor Red
            return
        }
        $idx = $idx - 1
    }
    $selectedBackup = $backups[$idx]
    Write-Host "已选择备份: $($selectedBackup.Name)" -ForegroundColor Cyan

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd) {
        Write-Host "[错误] 未找到 python 命令，无法合并 conversation_summaries.db。" -ForegroundColor Red
        return
    }
    $mergePy = Join-Path $CloudRoot "merge_summaries.py"
    if (-not (Test-Path $mergePy)) {
        Write-Host "[错误] 未找到合并脚本: $mergePy" -ForegroundColor Red
        return
    }

    Write-Host "正在创建合并前安全快照..." -ForegroundColor Cyan
    $preMergeBackup = Backup-LocalData -Reason "before_merge"
    if ($preMergeBackup) {
        Write-Host "快照已保存至: $preMergeBackup" -ForegroundColor Gray
    }

    if (-not (Test-Path $LocalRoot)) {
        New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
    }

    # 1. Merge conversations/*.db (+ -wal/-shm) additively
    $srcConvDir = Join-Path $selectedBackup.FullName "conversations"
    $dstConvDir = Join-Path $LocalRoot "conversations"
    if (-not (Test-Path $dstConvDir)) {
        New-Item -ItemType Directory -Path $dstConvDir -Force | Out-Null
    }
    if (Test-Path $srcConvDir) {
        $srcDbs = @(Get-ChildItem -Path $srcConvDir -Filter "*.db" -File)
        foreach ($srcDb in $srcDbs) {
            $cid = [System.IO.Path]::GetFileNameWithoutExtension($srcDb.Name)
            $dstDb = Join-Path $dstConvDir $srcDb.Name
            $shouldCopy = $false
            if (-not (Test-Path $dstDb)) {
                $shouldCopy = $true
            }
            elseif ($srcDb.LastWriteTimeUtc -gt (Get-Item $dstDb).LastWriteTimeUtc) {
                $shouldCopy = $true
            }
            if ($shouldCopy) {
                foreach ($suffix in @("-wal", "-shm")) {
                    $stale = Join-Path $dstConvDir ($cid + ".db" + $suffix)
                    if (Test-Path $stale) {
                        Remove-Item -Path $stale -Force -ErrorAction SilentlyContinue
                    }
                }
                Copy-Item -Path $srcDb.FullName -Destination $dstDb -Force
                foreach ($suffix in @("-wal", "-shm")) {
                    $srcSidecar = Join-Path $srcConvDir ($cid + ".db" + $suffix)
                    if (Test-Path $srcSidecar) {
                        Copy-Item -Path $srcSidecar -Destination (Join-Path $dstConvDir ($cid + ".db" + $suffix)) -Force
                    }
                }
            }
        }
    }

    # 2. Merge annotations/ additively
    $srcAnnDir = Join-Path $selectedBackup.FullName "annotations"
    $dstAnnDir = Join-Path $LocalRoot "annotations"
    if (Test-Path $srcAnnDir) {
        if (-not (Test-Path $dstAnnDir)) {
            New-Item -ItemType Directory -Path $dstAnnDir -Force | Out-Null
        }
        $annFiles = @(Get-ChildItem -Path $srcAnnDir -File)
        foreach ($af in $annFiles) {
            $dstAnn = Join-Path $dstAnnDir $af.Name
            if ((-not (Test-Path $dstAnn)) -or ($af.LastWriteTimeUtc -gt (Get-Item $dstAnn).LastWriteTimeUtc)) {
                Copy-Item -Path $af.FullName -Destination $dstAnn -Force
            }
        }
    }

    # 3. Merge brain/<id> subdirectories additively
    $srcBrainDir = Join-Path $selectedBackup.FullName "brain"
    $dstBrainDir = Join-Path $LocalRoot "brain"
    if (Test-Path $srcBrainDir) {
        if (-not (Test-Path $dstBrainDir)) {
            New-Item -ItemType Directory -Path $dstBrainDir -Force | Out-Null
        }
        $brainSubs = @(Get-ChildItem -Path $srcBrainDir -Directory)
        foreach ($sub in $brainSubs) {
            $dstSub = Join-Path $dstBrainDir $sub.Name
            if (-not (Test-Path $dstSub)) {
                & robocopy $sub.FullName $dstSub /E /COPY:DT /FFT /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) {
                    throw "robocopy 复制 brain 子目录失败 ($($sub.FullName) -> $dstSub), 退出码: $LASTEXITCODE"
                }
            }
        }
    }

    # 4. Merge conversation_summaries.db
    $backupSumDb = Join-Path $selectedBackup.FullName "conversation_summaries.db"
    $localSumDb = Join-Path $LocalRoot "conversation_summaries.db"
    if (Test-Path $backupSumDb) {
        Write-Host "正在合并对话索引库 (conversation_summaries.db)..." -ForegroundColor Cyan
        $mergeOutput = & python $mergePy $backupSumDb $localSumDb 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host $mergeOutput -ForegroundColor Red
            throw "合并 conversation_summaries.db 失败，退出码: $LASTEXITCODE"
        }
        Write-Host "索引合并结果: $mergeOutput" -ForegroundColor Gray
    }

    $totalLocalDbs = @(Get-ChildItem -Path $dstConvDir -Filter "*.db" -File -ErrorAction SilentlyContinue).Count
    Write-Host ""
    Write-Host "[成功] 合并完成！当前本地共有 $totalLocalDbs 个对话。" -ForegroundColor Green
    $upAns = Read-Host "是否立即将合并后的全部对话上传同步到 Google Drive？[Y/n]"
    if ([string]::IsNullOrWhiteSpace($upAns) -or $upAns -match "^[yY]$") {
        Write-Host "正在以安全合并模式上传全部对话到 Google Drive..." -ForegroundColor Cyan
        Sync-DataMerge -SourceRoot $LocalRoot -DestRoot $CloudDataDir
        $meta = New-SyncMetadata
        Write-JsonFile -Path $CloudMetaPath -Data $meta
        Write-JsonFile -Path $LocalMetaPath -Data $meta
        Write-Host ""
        Write-Host "[成功] 合并后的全部对话已上传至云端！" -ForegroundColor Green
        Write-Host "同步时间: $($meta.syncTimeLocal) | Sync ID: $($meta.syncId)" -ForegroundColor Green
        Write-Host "提醒: 切换电脑前请确认右下角 Google Drive 托盘图标已完成上传。" -ForegroundColor Yellow
    }
    else {
        Write-Host "已跳过上传。稍后可随时运行 手动上传到云端.bat 上传到云端。" -ForegroundColor Yellow
    }
}

switch ($Mode) {
    "status" { Show-Status }
    "upload" { Invoke-Upload }
    "download" { Invoke-Download }
    "launch" { Invoke-Launch }
    "shortcut" { New-DesktopShortcut }
    "merge" { Invoke-Merge }
}
