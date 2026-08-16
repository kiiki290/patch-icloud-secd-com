@echo off
chcp 65001 >nul
title iCloud Passwords 验证码弹窗修复工具

rem ============ 语言（可选：run_patch.bat en / run_patch.bat zh，缺省跟随系统语言） ============
set "LANG_ELEV="
set "LANG_DIRECT="
if not "%~1"=="" (
    set "LANG_ELEV=,'-Lang','%~1'"
    set "LANG_DIRECT=-Lang %~1"
)

rem ============ 自动提权（非管理员时通过 UAC 重启自己） ============
rem 固定使用系统自带的 Windows PowerShell 5.1（5.1 必有且与脚本完全兼容，无需探测路由）
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限（UAC 请点"是"）...
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0patch_icloud_secd_com.ps1'%LANG_ELEV%"
    exit /b
)

rem ============ 管理员模式：直接运行（Bypass 绕过执行策略/Smart App Control） ============
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch_icloud_secd_com.ps1" %LANG_DIRECT%
pause
