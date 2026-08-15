@echo off
chcp 65001 >nul
title iCloud Passwords 验证码弹窗修复工具

rem ============ 自动提权（非管理员时通过 UAC 重启自己） ============
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限（UAC 请点"是"）...
    where pwsh >nul 2>&1
    if %errorlevel%==0 (
        powershell.exe -NoProfile -Command "Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0patch_icloud_secd_com.ps1'"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0patch_icloud_secd_com.ps1'"
    )
    exit /b
)

rem ============ 管理员模式：直接运行（Bypass 绕过执行策略/Smart App Control） ============
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch_icloud_secd_com.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch_icloud_secd_com.ps1"
)
pause
