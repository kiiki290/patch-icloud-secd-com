#requires -Version 7.0
# ============================================================
# iCloud Passwords 验证码弹窗修复脚本（2026-08-14 深夜验证成功）
#
# 背景：iCloud 重装/升级后，secd 的 COM 类 {CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}
#   在隔离视图的注册丢失且不再重建 → helper 的 CoCreateInstance 0x80040154
#   → 扩展永远显示"在 Windows 版 iCloud 中启用密码"。
# 修复：在真实注册表 PackagedCom 中模拟"打包 COM 声明" + HKCU/HKLM marshal 注册
#   + CKKS Passwords State=1，让 SCM 以打包身份激活 secd，弹窗恢复。
# ============================================================
#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# 动态取当前安装的 iCloud 包全名（适配任意版本，重装/升级后直接跑本脚本）
$appx = Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue
if (-not $appx) {
    Write-Host '错误：未检测到 AppleInc.iCloud 包，请先安装 iCloud for Windows。' -ForegroundColor Red
    exit 1
}
$pkgFull = $appx.PackageFullName
$pkg = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$pkgFull"
$clsid = 'CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4'
$iid   = 'E095A809-7CDD-4B6D-A528-5D4AC9420D91'
$tlid  = '71529314-E4B7-400B-8FD7-9A5F695AF311'
$dv    = 0x3ea

# 1. Class entry (core: packaged COM activation)
$k = "$pkg\Class\{$clsid}"; New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name ServerId -Value 5 -Type DWord
Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon Class' -Type String
Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord

# 2. ExeServer entry
$k = "$pkg\Server\5"; New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name ApplicationId -Value 'iCloud' -Type String
Set-ItemProperty $k -Name ApplicationDisplayName -Value "@{$pkgFull?ms-resource://AppleInc.iCloud/resources/iCloudHomeUIDisplayName}" -Type String
Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon COM Server' -Type String
Set-ItemProperty $k -Name Executable -Value 'iCloud\secd.exe' -Type String
Set-ItemProperty $k -Name IsSystemExecutable -Value 0 -Type DWord
Set-ItemProperty $k -Name TrustLevel -Value 1 -Type DWord
Set-ItemProperty $k -Name RuntimeBehavior -Value 1 -Type DWord
Set-ItemProperty $k -Name BnoIsolation -Value 0 -Type DWord
Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord

# 3. Interface entry (ISecDaemon)
$k = "$pkg\Interface\{$iid}"; New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name UseUniversalMarshaler -Value 1 -Type DWord
Set-ItemProperty $k -Name TypeLibId -Value "{$tlid}" -Type String
Set-ItemProperty $k -Name TypeLibVersionNumber -Value '1.0' -Type String
Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord

# 4. TypeLib entry
$k = "$pkg\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name LocaleId -Value 0 -Type DWord
Set-ItemProperty $k -Name Flags -Value 0 -Type DWord
Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon 1.0 Type Library' -Type String
Set-ItemProperty $k -Name Win32Path -Value 'iCloud\secd.exe' -Type String
Set-ItemProperty $k -Name Win64Path -Value 'iCloud\secd.exe' -Type String
Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord

# 5. Indexes
New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}\$pkgFull" -Force | Out-Null
New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}\$pkgFull" -Force | Out-Null
New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}\$pkgFull" -Force | Out-Null

# 6. HKCU + HKLM marshal registration (TypeLib + Interface)
$secd = 'C:\Program Files\WindowsApps\' + (Get-AppxPackage AppleInc.iCloud).PackageFullName + '\iCloud\secd.exe'
foreach ($root in @('HKCU:\Software\Classes', 'HKLM:\SOFTWARE\Classes')) {
    $k = "$root\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name '(default)' -Value 'SecDaemon 1.0 Type Library' -Type String -ErrorAction SilentlyContinue
    New-Item "$k\0\win32" -Force | Out-Null
    Set-ItemProperty "$k\0\win32" -Name '(default)' -Value $secd -Type String -ErrorAction SilentlyContinue
    New-Item "$k\0\win64" -Force | Out-Null
    Set-ItemProperty "$k\0\win64" -Name '(default)' -Value $secd -Type String -ErrorAction SilentlyContinue
    New-Item "$k\FLAGS" -Force | Out-Null; Set-ItemProperty "$k\FLAGS" -Name '(default)' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    New-Item "$k\HELPDIR" -Force | Out-Null; Set-ItemProperty "$k\HELPDIR" -Name '(default)' -Value '' -Type String -ErrorAction SilentlyContinue

    $k2 = "$root\Interface\{$iid}"; New-Item $k2 -Force | Out-Null
    Set-ItemProperty $k2 -Name '(default)' -Value 'ISecDaemon' -Type String -ErrorAction SilentlyContinue
    New-Item "$k2\TypeLib" -Force | Out-Null
    Set-ItemProperty "$k2\TypeLib" -Name '(default)' -Value "{$tlid}" -Type String -ErrorAction SilentlyContinue
    New-Item "$k2\TypeLib\Version" -Force | Out-Null
    Set-ItemProperty "$k2\TypeLib\Version" -Name '(default)' -Value '1.0' -Type String -ErrorAction SilentlyContinue
    New-Item "$k2\Version" -Force | Out-Null
    Set-ItemProperty "$k2\Version" -Name '(default)' -Value '1.0' -Type String -ErrorAction SilentlyContinue
    New-Item "$k2\ProxyStubClsid32" -Force | Out-Null
    Set-ItemProperty "$k2\ProxyStubClsid32" -Name '(default)' -Value '{00020424-0000-0000-C000-000000000046}' -Type String -ErrorAction SilentlyContinue
}

# 7. CKKS Passwords State = 1 (reinstall recreates this key with State=0)
$ckks = 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords'
if (Test-Path $ckks) { Set-ItemProperty $ckks -Name 'State' -Value 1 -Type DWord }

Write-Host 'iCloud Passwords COM 修复完成。重启 Edge 后点击扩展图标验证。' -ForegroundColor Green
