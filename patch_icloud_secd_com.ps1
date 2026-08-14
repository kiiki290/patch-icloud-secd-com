#requires -Version 5.1
# ============================================================
# iCloud Passwords 验证码弹窗修复工具（交互式）
#
# 背景：iCloud for Windows 重装/升级后，secd.exe 的 COM 类
#   {CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4} 在打包应用隔离视图的注册丢失且
#   永不重建（Apple bug）→ helper 的 CoCreateInstance 返回 0x80040154
#   → 点击扩展永远显示"在 Windows 版 iCloud 中启用密码"，验证码弹窗不出现。
#
# 原理：在真实注册表 HKLM\SOFTWARE\Classes\PackagedCom 下模拟"打包 COM 声明"
#   （MSIX 包清单 com:Class 的物化位置），让 SCM 以打包身份激活 secd；
#   并补齐跨进程 marshal 所需的 TypeLib/Interface 注册和 CKKS Passwords State=1。
#
# 用法：
#   pwsh -File patch_icloud_secd_com.ps1            # 交互式菜单（推荐）
#   pwsh -File patch_icloud_secd_com.ps1 -Fix       # 直接修复（自动提权）
#   pwsh -File patch_icloud_secd_com.ps1 -Undo      # 直接撤销（自动提权）
#
# 兼容：iCloud for Windows 15.9.60.0 实测通过（Windows 11 26100，Edge）。
# ============================================================

param([switch]$Undo, [switch]$Fix)

# 强制 UTF-8 输出（cmd 重定向提权实例输出时避免 GBK 乱码）
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$clsid = 'CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4'   # SecDaemon 类
$iid   = 'E095A809-7CDD-4B6D-A528-5D4AC9420D91'   # ISecDaemon 接口
$tlid  = '71529314-E4B7-400B-8FD7-9A5F695AF311'   # TypeLib（secd 的 .rgs）

function Info($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }

# ---------- 提权执行（非管理员时通过 UAC 重启自己） ----------
# 说明：Start-Process -Verb RunAs 与 -RedirectStandardOutput 属于互斥参数集，
# 因此用 cmd /c 重定向把提权实例的输出写入临时文件，父进程等待后回显。
function Invoke-Elevated([string]$Mode) {
    # 提权解释器自适应：有 PS7 用 pwsh，否则退回系统自带的 PowerShell 5.1
    $shellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
    $outFile = Join-Path $env:TEMP "icloud-patch-out-$PID.log"
    $cmdLine = "$shellExe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -$Mode > `"$outFile`" 2>&1"
    try {
        $p = Start-Process cmd -Verb RunAs -Wait -PassThru -ArgumentList '/c', "`"$cmdLine`""
        if (Test-Path $outFile) {
            # 日志走信息流（Write-Host），这样 $null = 吞退出码时不会连日志一起吞掉
            Write-Host (Get-Content $outFile -Raw -Encoding UTF8)
        }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        return $p.ExitCode
    } catch {
        Write-Host "提权失败或已被取消：$($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

# ---------- 状态检测（只读） ----------
function Get-PatchStatus {
    $appx = Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue
    if (-not $appx) {
        return [pscustomobject]@{ Installed = $false; ClassExists = $false; ServerId = $null; State = $null; TypeLibOk = $false; InterfaceOk = $false; Summary = 'iCloud 未安装' }
    }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $classKey = "$pkgRoot\Class\{$clsid}"
    $serverId = (Get-ItemProperty $classKey -Name ServerId -ErrorAction SilentlyContinue).ServerId
    $state = (Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords' -Name State -ErrorAction SilentlyContinue).State
    $typeLibOk = Test-Path "HKCU:\Software\Classes\TypeLib\{$tlid}\1.0\0\win32"
    $interfaceOk = Test-Path "HKCU:\Software\Classes\Interface\{$iid}"
    $summary = if ($serverId -ne $null) {
        if ($state -eq 1) { '✅ 已修复' } else { '⚠️ 部分（Class 已注册，State 未激活）' }
    } elseif ($state -eq 1 -or $typeLibOk -or $interfaceOk) {
        '⚠️ 部分修复（Class 未注册，其他项存在）'
    } else {
        '❌ 未修复'
    }
    return [pscustomobject]@{ Installed = $true; ClassExists = ($serverId -ne $null); ServerId = $serverId; State = $state; TypeLibOk = $typeLibOk; InterfaceOk = $interfaceOk; Summary = $summary }
}

# ---------- 修复 ----------
function Do-Fix {
    Write-Host '== 写入 PackagedCom 打包 COM 声明 ==' -ForegroundColor White
    $appx = Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue
    if (-not $appx) { Warn '未检测到 AppleInc.iCloud 包，请先安装 iCloud for Windows。'; exit 1 }
    $pkgFull = $appx.PackageFullName
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$pkgFull"
    $secdPath = Join-Path $appx.InstallLocation 'iCloud\secd.exe'
    Info "iCloud 包: $pkgFull"
    Info "secd.exe: $secdPath"
    if (-not (Test-Path $secdPath)) { Warn 'secd.exe 不存在于包内（版本结构不同？），终止。'; exit 1 }

    # ServerId：已注册则复用（幂等），否则取现有最大值 +1
    $existingServerId = (Get-ItemProperty "$pkgRoot\Class\{$clsid}" -Name ServerId -ErrorAction SilentlyContinue).ServerId
    if ($existingServerId -ne $null -and [int]$existingServerId -ge 0) {
        $serverId = [int]$existingServerId
        Info "ServerId = $serverId（复用已有注册，幂等）"
    } else {
        $maxServer = -1
        Get-ChildItem "$pkgRoot\Server" -ErrorAction SilentlyContinue | ForEach-Object {
            $n = 0; if ([int]::TryParse($_.PSChildName, [ref]$n) -and $n -gt $maxServer) { $maxServer = $n }
        }
        $serverId = $maxServer + 1
        Info "ServerId = $serverId（现有最大 $maxServer）"
    }
    # DeploymentVersion：从现有 Class 读取，缺省 0x3ea
    $dv = 0x3ea
    Get-ChildItem "$pkgRoot\Class" -ErrorAction SilentlyContinue | ForEach-Object {
        $v = (Get-ItemProperty $_.PSPath -Name DeploymentVersion -ErrorAction SilentlyContinue).DeploymentVersion
        if ($v -and $v -ne $null) { $dv = [int]$v }
    }
    Info "DeploymentVersion = $dv"

    # 1. Class entry
    $k = "$pkgRoot\Class\{$clsid}"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name ServerId -Value $serverId -Type DWord
    Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon Class' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok 'Class\{CE6AF8E5}'

    # 2. ExeServer entry
    $k = "$pkgRoot\Server\$serverId"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name ApplicationId -Value 'iCloud' -Type String
    Set-ItemProperty $k -Name ApplicationDisplayName -Value "@{$pkgFull?ms-resource://AppleInc.iCloud/resources/iCloudHomeUIDisplayName}" -Type String
    Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon COM Server' -Type String
    Set-ItemProperty $k -Name Executable -Value 'iCloud\secd.exe' -Type String
    Set-ItemProperty $k -Name IsSystemExecutable -Value 0 -Type DWord
    Set-ItemProperty $k -Name TrustLevel -Value 1 -Type DWord
    Set-ItemProperty $k -Name RuntimeBehavior -Value 1 -Type DWord
    Set-ItemProperty $k -Name BnoIsolation -Value 0 -Type DWord
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok "Server\$serverId (Executable=iCloud\secd.exe)"

    # 3. Interface entry
    $k = "$pkgRoot\Interface\{$iid}"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name UseUniversalMarshaler -Value 1 -Type DWord
    Set-ItemProperty $k -Name TypeLibId -Value "{$tlid}" -Type String
    Set-ItemProperty $k -Name TypeLibVersionNumber -Value '1.0' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok 'Interface\{E095A809}'

    # 4. TypeLib entry
    $k = "$pkgRoot\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name LocaleId -Value 0 -Type DWord
    Set-ItemProperty $k -Name Flags -Value 0 -Type DWord
    Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon 1.0 Type Library' -Type String
    Set-ItemProperty $k -Name Win32Path -Value 'iCloud\secd.exe' -Type String
    Set-ItemProperty $k -Name Win64Path -Value 'iCloud\secd.exe' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok 'TypeLib\{71529314}\1.0'

    # 5. Indexes
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}\$pkgFull" -Force | Out-Null
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}\$pkgFull" -Force | Out-Null
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}\$pkgFull" -Force | Out-Null
    Ok 'ClassIndex / InterfaceIndex / TypeLibIndex'

    # 6. marshal 注册（HKCU + HKLM）
    Write-Host '== 写入 TypeLib / Interface marshal 注册 ==' -ForegroundColor White
    foreach ($root in @('HKCU:\Software\Classes', 'HKLM:\SOFTWARE\Classes')) {
        $k = "$root\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
        Set-ItemProperty $k -Name '(default)' -Value 'SecDaemon 1.0 Type Library' -Type String -ErrorAction SilentlyContinue
        New-Item "$k\0\win32" -Force | Out-Null
        Set-ItemProperty "$k\0\win32" -Name '(default)' -Value $secdPath -Type String -ErrorAction SilentlyContinue
        New-Item "$k\0\win64" -Force | Out-Null
        Set-ItemProperty "$k\0\win64" -Name '(default)' -Value $secdPath -Type String -ErrorAction SilentlyContinue
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
    Ok 'TypeLib / Interface（HKCU + HKLM 两侧）'

    # 7. CKKS Passwords State
    Write-Host '== CKKS Passwords State ==' -ForegroundColor White
    $ckks = 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords'
    if (Test-Path $ckks) {
        Set-ItemProperty $ckks -Name 'State' -Value 1 -Type DWord
        Ok 'State = 1'
    } else {
        Warn 'CKKS Passwords 键不存在（可能版本不同）；若修复后弹窗不出现，检查该键。'
    }

    Write-Host ''
    Write-Host '✅ 修复完成。下一步：' -ForegroundColor Green
    Write-Host '  1. 完全关闭 Edge（所有窗口）再重新打开'
    Write-Host '  2. 点击 iCloud Passwords 扩展图标，输入验证码'
}

# ---------- 撤销 ----------
function Do-Undo {
    Write-Host '== 撤销模式：删除修复写入的注册表项 ==' -ForegroundColor White
    $appx = Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue
    if (-not $appx) { Warn '未检测到 AppleInc.iCloud 包。'; exit 1 }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $targets = @(
        "$pkgRoot\Class\{$clsid}",
        "$pkgRoot\Interface\{$iid}",
        "$pkgRoot\TypeLib\{$tlid}",
        # 索引删除整个 {GUID} 键（CLSID/IID/TLID 全局唯一，连带空壳父键一起清理）
        "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}",
        "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}",
        "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}",
        'HKCU:\Software\Classes\TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}',
        'HKLM:\SOFTWARE\Classes\TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}',
        'HKCU:\Software\Classes\Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91}',
        'HKLM:\SOFTWARE\Classes\Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91}'
    )
    # Server\N：只删我们创建的（Executable 为 secd.exe 的）
    Get-ChildItem "$pkgRoot\Server" -ErrorAction SilentlyContinue | ForEach-Object {
        if ((Get-ItemProperty $_.PSPath -Name Executable -ErrorAction SilentlyContinue).Executable -eq 'iCloud\secd.exe') {
            $targets += $_.PSPath
        }
    }
    foreach ($t in $targets) {
        if (Test-Path $t) {
            Remove-Item $t -Recurse -Force
            Ok "已删除: $($t -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')"
        }
    }
    Warn 'CKKS Passwords\State 未被改动（如需恢复请手动设回 0）。'
    Write-Host '撤销完成。重启 Edge 验证。' -ForegroundColor Green
}

# ============================================================
# 入口
# ============================================================

if (-not $Undo -and -not $Fix) {
    # ============ 交互模式 ============
    while ($true) {
        Clear-Host
        Write-Host '============================================' -ForegroundColor Cyan
        Write-Host '  iCloud Passwords 验证码弹窗修复工具' -ForegroundColor Cyan
        Write-Host '============================================' -ForegroundColor Cyan
        $st = Get-PatchStatus
        Write-Host ''
        Write-Host "  当前状态：$($st.Summary)" -ForegroundColor $(if ($st.ClassExists -and $st.State -eq 1) { 'Green' } else { 'Yellow' })
        Write-Host ''
        Write-Host '  [1] 执行修复'
        Write-Host '  [2] 撤销修复（回滚）'
        Write-Host '  [3] 查看详细状态'
        Write-Host '  [0] 退出'
        Write-Host ''
        $choice = Read-Host '  请选择 (0-3)'
        switch ($choice) {
            '1' {
                Write-Host ''; Write-Host '正在请求提升权限执行修复（UAC 请点"是"）...' -ForegroundColor Yellow
                $null = Invoke-Elevated 'Fix'   # 吞掉退出码返回值（避免泄漏输出 "0"）
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '2' {
                Write-Host ''; Write-Host '正在请求提升权限执行撤销（UAC 请点"是"）...' -ForegroundColor Yellow
                $null = Invoke-Elevated 'Undo'  # 同上
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '3' {
                Write-Host ''
                Write-Host '  --- 详细状态 ---'
                $appx = Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue
                if (-not $appx) { Write-Host '  iCloud 包：未安装' -ForegroundColor Red }
                else {
                    Write-Host "  iCloud 包：$($appx.PackageFullName)"
                    Write-Host "  secd.exe：$(Test-Path (Join-Path $appx.InstallLocation 'iCloud\secd.exe'))"
                    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
                    Write-Host "  Class\{$clsid}：$(if ($st.ClassExists) { "已注册 (ServerId=$($st.ServerId))" } else { '未注册' })"
                    if ($st.ServerId -ne $null) {
                        $exe = (Get-ItemProperty "$pkgRoot\Server\$($st.ServerId)" -Name Executable -ErrorAction SilentlyContinue).Executable
                        Write-Host "  Server\$($st.ServerId) Executable：$exe"
                    }
                    Write-Host "  HKCU TypeLib 注册：$($st.TypeLibOk)"
                    Write-Host "  HKCU Interface 注册：$($st.InterfaceOk)"
                    Write-Host "  CKKS Passwords State：$(if ($st.State -ne $null) { $st.State } else { '（键不存在）' })"
                }
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '0' { Write-Host '再见。'; exit 0 }
            default { Write-Host '无效选择。' -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
    exit 0
}

# ============ 命令行模式（-Fix / -Undo，自动提权） ============
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '当前不是管理员，正在请求提升权限（请在 UAC 对话框中点击"是"）...' -ForegroundColor Yellow
    $mode = if ($Fix) { 'Fix' } else { 'Undo' }
    $null = Invoke-Elevated $mode   # 吞掉退出码返回值（避免泄漏输出 "0"）
    exit $LASTEXITCODE
}
if ($Fix) { Do-Fix } else { Do-Undo }
