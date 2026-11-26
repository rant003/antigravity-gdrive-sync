@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_antigravity.ps1" -Mode merge
pause
