#requires -Version 5.1
# ============================================================
# iCloud Passwords 验证码弹窗修复工具（交互式，双模式）
#
# 背景：iCloud Passwords 扩展验证码弹窗失效的根因（2026-08-15 实锤）：
#   在 WindowsApps 权限已被提权（普通用户获得完全控制）的状态下安装 iCloud，
#   secd 的 COM 注册挂载机制静默失效（注册写进包内 Registry.dat 但 RPCSS 解析
#   不到）→ helper CoCreateInstance 0x80040154 → 弹窗不出现。
#
# 两种修复：
#   [急救] -Fix ：不重装，在真实注册表 HKLM\SOFTWARE\Classes\PackagedCom 下
#           模拟"打包 COM 声明"（让 SCM 以打包身份激活 secd），立即恢复弹窗
#   [治本] -Cure：还原 WindowsApps 标准 ACL + 引导用户重装 iCloud，
#           实测重装后弹窗直接正常、无需补丁
#
# 用法（需要管理员权限；脚本不做自动提权，仅提示）：
#   run_patch.bat                                  # 普通用户：双击启动器（自动提权 + 绕过执行策略）
#   pwsh -File patch_icloud_secd_com.ps1           # 交互式菜单
#   pwsh -File patch_icloud_secd_com.ps1 -Fix      # 急救修复
#   pwsh -File patch_icloud_secd_com.ps1 -Cure     # 治本修复
#   pwsh -File patch_icloud_secd_com.ps1 -Undo     # 撤销急救修复
#   专业用户建议直接开管理员 PowerShell 运行；非管理员时脚本仅提示，需自行提权。
#
# 兼容：iCloud for Windows 15.9.60.0 实测通过（Windows 11 26100/26200，Edge）。
# ============================================================

param([switch]$Undo, [switch]$Fix, [switch]$Cure)

# 强制 UTF-8 输出（cmd 重定向提权实例输出时避免 GBK 乱码）
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$clsid = 'CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4'   # SecDaemon 类
$iid   = 'E095A809-7CDD-4B6D-A528-5D4AC9420D91'   # ISecDaemon 接口
$tlid  = '71529314-E4B7-400B-8FD7-9A5F695AF311'   # TypeLib（secd 的 .rgs）

function Info($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }

# 是否已是管理员（bat 启动器已提权时全程为真，提权分支自动短路）
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- 管理员检查（不做自动提权，仅提示） ----------
function Test-Admin {
    if (-not $isAdmin) {
        Write-Host '需要管理员权限才能执行本操作。' -ForegroundColor Red
        Write-Host '  方式一：双击 run_patch.bat（自动请求管理员权限）' -ForegroundColor Yellow
        Write-Host '  方式二：右键开始菜单 → "终端(管理员)" 或 "Windows PowerShell(管理员)"，再运行本脚本' -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ---------- WindowsApps 权限检测（治本修复的状态依据） ----------
# 标准 ACL 的 8 个主体（SID 形式，与全新 VM 逐条核对过）
$StdAclSids = @(
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', # NT SERVICE\TrustedInstaller
    'S-1-15-3-1024-3635283841-2530182609-996808640-1887759898-3848208603-3313616867-983405619-2501854204', # 包能力 SID
    'S-1-5-18',  # NT AUTHORITY\SYSTEM
    'S-1-5-32-544', # BUILTIN\Administrators
    'S-1-5-19',  # NT AUTHORITY\LOCAL SERVICE
    'S-1-5-20',  # NT AUTHORITY\NETWORK SERVICE
    'S-1-5-12',  # NT AUTHORITY\RESTRICTED
    'S-1-5-32-545' # BUILTIN\Users
)
function Resolve-Sid([string]$Principal) {
    if ($Principal -match '^S-1-') { return $Principal }
    try { return ([System.Security.Principal.NTAccount]::new($Principal)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
    catch { return $Principal }
}
# 返回 WindowsApps 根 ACL 中非标准主体的列表（空 = 标准）
function Get-WindowsAppsAnomaly {
    $lines = icacls 'C:\Program Files\WindowsApps' 2>&1
    $extra = @()
    foreach ($line in $lines) {
        if ($line -match '^[^:]+:\(') {
            $p = ($line -split ':')[0].Trim()
            if ($p -and (Resolve-Sid $p) -notin $StdAclSids) { $extra += $p }
        }
    }
    return ,$extra
}

# ---------- 取 iCloud 包（过滤 Staged 残留，取最新版本——部署「失忆」时同名包可能并存） ----------
function Get-ICloudPackage {
    Get-AppxPackage AppleInc.iCloud -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -notmatch 'Staged' } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

# ---------- 状态检测（只读） ----------
function Get-PatchStatus {
    $appx = Get-ICloudPackage
    if (-not $appx) {
        return [pscustomobject]@{ Installed = $false; ClassExists = $false; ServerId = $null; State = $null; TypeLibOk = $false; InterfaceOk = $false; Summary = 'iCloud 未安装' }
    }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $classKey = "$pkgRoot\Class\{$clsid}"
    $serverId = (Get-ItemProperty $classKey -Name ServerId -ErrorAction SilentlyContinue).ServerId
    $state = (Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords' -Name State -ErrorAction SilentlyContinue).State
    $typeLibOk = Test-Path "HKCU:\Software\Classes\TypeLib\{$tlid}\1.0\0\win32"
    $interfaceOk = Test-Path "HKCU:\Software\Classes\Interface\{$iid}"
    $permAnomaly = Get-WindowsAppsAnomaly
    if ($serverId -ne $null -and $state -eq 1) {
        $summary = '✅ 已修复（急救补丁生效）'
    } elseif ($permAnomaly.Count -eq 0 -and $serverId -eq $null) {
        $summary = '✅ 权限正常（若弹窗失效，先试 -Cure 重装；若已装好则无需处理）'
    } elseif ($permAnomaly.Count -gt 0) {
        $summary = "⚠️ WindowsApps 权限异常（$($permAnomaly -join ', ')）——弹窗失效的根因，建议治本修复 [-Cure]"
    } elseif ($serverId -ne $null) {
        $summary = '⚠️ 部分（Class 已注册，State 未激活）'
    } else {
        $summary = '❌ 未修复'
    }
    return [pscustomobject]@{ Installed = $true; ClassExists = ($serverId -ne $null); ServerId = $serverId; State = $state; TypeLibOk = $typeLibOk; InterfaceOk = $interfaceOk; PermAnomaly = $permAnomaly; Summary = $summary }
}

# ---------- CRT 版本检测（旧版 MSVCP140 已知 bug：helper 连接 secd 时崩溃） ----------
function Test-CrtVersion {
    $dll = Get-Item 'C:\Windows\System32\MSVCP140.dll' -ErrorAction SilentlyContinue
    if (-not $dll) { return }
    $v = $dll.VersionInfo.FileVersion
    try { $ver = [version]$v } catch { return }
    if ($ver.Major -eq 14 -and $ver.Minor -lt 40) {
        Warn "检测到旧版 VC++ 运行库 MSVCP140.dll $v"
        Warn '  14.3x 及更早有已知 bug：helper 在连接 secd 时崩溃（0xC0000005），补丁将无法生效。'
        Warn '  请先安装最新 VC++ 2015-2022 Redistributable：https://aka.ms/vs/17/release/vc_redist.x64.exe'
        Warn '  （Win11 系统组件场景可先做 Windows 更新；升级后重新运行本工具）'
    } else {
        Ok "MSVCP140.dll $v（CRT 正常）"
    }
}

# ---------- Do-Fix 收尾回读校验（写失败默认静默，这里逐项比对） ----------
function Test-PatchIntegrity([int]$serverId) {
    $appx = Get-ICloudPackage
    if (-not $appx) { return ,@('iCloud 包不存在') }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $bad = @()
    $classServerId = (Get-ItemProperty "$pkgRoot\Class\{$clsid}" -Name ServerId -ErrorAction SilentlyContinue).ServerId
    if ($classServerId -ne $serverId) { $bad += "Class\{$clsid} ServerId（期望 $serverId，实际 $classServerId）" }
    $exe = (Get-ItemProperty "$pkgRoot\Server\$serverId" -Name Executable -ErrorAction SilentlyContinue).Executable
    if ($exe -ne 'iCloud\secd.exe') { $bad += "Server\$serverId Executable" }
    if (-not (Test-Path "$pkgRoot\Interface\{$iid}")) { $bad += "Interface\{$iid}" }
    if (-not (Test-Path "$pkgRoot\TypeLib\{$tlid}\1.0")) { $bad += "TypeLib\{$tlid}\1.0" }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}\$($appx.PackageFullName)")) { $bad += 'ClassIndex' }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}\$($appx.PackageFullName)")) { $bad += 'InterfaceIndex' }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}\$($appx.PackageFullName)")) { $bad += 'TypeLibIndex' }
    if (-not (Test-Path 'HKCU:\Software\Classes\TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}\1.0\0\win32')) { $bad += 'HKCU TypeLib marshal' }
    if (-not (Test-Path 'HKCU:\Software\Classes\Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91}')) { $bad += 'HKCU Interface marshal' }
    if ((Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords' -Name State -ErrorAction SilentlyContinue).State -ne 1) { $bad += 'CKKS State' }
    return ,$bad
}

# ---------- 治本修复：还原 WindowsApps 权限 + 引导重装 ----------
function Do-Cure {
    Write-Host '== 治本修复：还原 WindowsApps 权限 + 重装 iCloud ==' -ForegroundColor White
    Test-CrtVersion
    $extra = Get-WindowsAppsAnomaly
    if ($extra.Count -eq 0) {
        Ok 'WindowsApps 权限已是标准 ACL，无需还原'
    } else {
        Write-Host "发现非标准权限条目：$($extra -join ', ')" -ForegroundColor Yellow
        foreach ($p in $extra) {
            icacls 'C:\Program Files\WindowsApps' /remove "$p" | Out-Null
            Write-Host "  已移除: $p"
        }
        $after = Get-WindowsAppsAnomaly
        if ($after.Count -eq 0) { Ok 'WindowsApps 权限已还原为标准 ACL' }
        else { Warn "仍有非标准条目：$($after -join ', ')" }
    }
    Write-Host ''
    Write-Host '下一步（需手动完成，顺序不能反）：' -ForegroundColor Cyan
    Write-Host '  1. 卸载当前 iCloud（设置 > 应用 > iCloud > 卸载，或开始菜单右键卸载）'
    Write-Host '  2. 从 Microsoft Store 重新安装 iCloud'
    Write-Host '  3. 登录 Apple ID（两步验证）→ 开启"密码"功能'
    Write-Host '  4. 重启 Edge → 点击扩展图标 → 验证码弹窗应直接出现（无需补丁）'
    Write-Host '  ⚠️ 卸载会清空本地钥匙串，重装登录后自动从 iCloud 重新同步'
    Write-Host '  ⚠️ 重装完成前不要再改 WindowsApps 权限（安装时刻的权限状态决定成败）'
}

# ---------- 急救修复：PackagedCom 模拟 ----------
function Do-Fix {
    Write-Host '== 急救修复：写入 PackagedCom 打包 COM 声明（不重装） ==' -ForegroundColor White
    Test-CrtVersion
    $appx = Get-ICloudPackage
    if (-not $appx) { Warn '未检测到 AppleInc.iCloud 包，请先安装 iCloud for Windows。'; return 1 }
    $pkgFull = $appx.PackageFullName
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$pkgFull"
    $secdPath = Join-Path $appx.InstallLocation 'iCloud\secd.exe'
    Info "iCloud 包: $pkgFull"
    Info "secd.exe: $secdPath"
    if (-not (Test-Path $secdPath)) { Warn 'secd.exe 不存在于包内（版本结构不同？），终止。'; return 1 }

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
    Set-ItemProperty $k -Name ApplicationDisplayName -Value ('@{' + $pkgFull + '?ms-resource://AppleInc.iCloud/resources/iCloudHomeUIDisplayName}') -Type String
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

    # 7. CKKS Passwords State（键缺失也创建——坏装机器上该键常不存在，缺它弹窗不出）
    Write-Host '== CKKS Passwords State ==' -ForegroundColor White
    $ckks = 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords'
    if (-not (Test-Path $ckks)) {
        New-Item $ckks -Force | Out-Null
        Warn 'CKKS Passwords 键缺失，已自动创建（坏装机器常见；正常装由应用自建）'
    }
    Set-ItemProperty $ckks -Name 'State' -Value 1 -Type DWord
    Ok 'State = 1'

    # 8. 回读校验（写失败会静默，必须逐项确认）
    Write-Host '== 回读校验 ==' -ForegroundColor White
    $bad = Test-PatchIntegrity -serverId $serverId
    if ($bad.Count -eq 0) {
        Ok '回读校验全部通过'
    } else {
        Warn ('回读校验失败（' + $bad.Count + ' 项）：' + ($bad -join '；'))
        return 1
    }

    Write-Host ''
    Write-Host '✅ 修复完成。下一步：' -ForegroundColor Green
    Write-Host '  1. 完全关闭 Edge（所有窗口）再重新打开'
    Write-Host '  2. 点击 iCloud Passwords 扩展图标，输入验证码'
    return 0
}

# ---------- 撤销 ----------
function Do-Undo {
    Write-Host '== 撤销模式：删除修复写入的注册表项 ==' -ForegroundColor White
    $appx = Get-ICloudPackage
    if (-not $appx) { Warn '未检测到 AppleInc.iCloud 包。'; return 1 }
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
        if (-not (Test-Path $t)) { continue }
        # 误删保护：HKCR/HKCU 的 TypeLib/Interface 键只在 (default) 值是我们写的
        # 时才删——补丁前已存在的同 GUID 注册（正常安装态）不能动
        if ($t -match '\\TypeLib\\' -or $t -match '\\Interface\\') {
            $def = (Get-ItemProperty $t -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            $expect = if ($t -match '\\TypeLib\\') { 'SecDaemon 1.0 Type Library' } else { 'ISecDaemon' }
            if ($def -ne $expect) {
                Warn "跳过（非本工具写入，保留）: $($t -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')"
                continue
            }
        }
        Remove-Item $t -Recurse -Force
        Ok "已删除: $($t -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')"
    }
    Warn 'CKKS Passwords 键未被撤销（State 保留 1；如需彻底回滚可删除 HKCU:\Software\Apple Inc.\Internet Services\CKKS，注意应用可能自行重建）'
    Write-Host '撤销完成。重启 Edge 验证。' -ForegroundColor Green
    return 0
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
        Write-Host '  [1] 急救修复（PackagedCom 补丁，不重装）'
        Write-Host '  [2] 治本修复（还原 WindowsApps 权限 + 引导重装）'
        Write-Host '  [3] 撤销急救修复（回滚）'
        Write-Host '  [4] 查看详细状态'
        Write-Host '  [0] 退出'
        Write-Host ''
        $choice = Read-Host '  请选择 (0-4)'
        switch ($choice) {
            '1' {
                Write-Host ''
                if (Test-Admin) { Do-Fix }
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '2' {
                Write-Host ''
                if (Test-Admin) { Do-Cure }
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '3' {
                Write-Host ''
                if (Test-Admin) { Do-Undo }
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '4' {
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
                    Write-Host "  WindowsApps 权限：$(if ($st.PermAnomaly.Count -eq 0) { '标准' } else { '异常: ' + ($st.PermAnomaly -join ', ') })"
                    $crt = (Get-Item 'C:\Windows\System32\MSVCP140.dll' -ErrorAction SilentlyContinue).VersionInfo.FileVersion
                    Write-Host "  MSVCP140（VC++ 运行库）：$crt"
                }
                Write-Host ''; $null = Read-Host '按回车返回菜单'
            }
            '0' { Write-Host '再见。'; exit 0 }
            default { Write-Host '无效选择。' -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
    exit 0
}

# ============ 命令行模式（-Fix / -Cure / -Undo） ============
if (-not $isAdmin) {
    Write-Host '需要管理员权限：普通用户请双击 run_patch.bat；专业用户请以管理员身份打开 PowerShell 后重试。' -ForegroundColor Red
    exit 1
}
if ($Fix) { $rc = Do-Fix } elseif ($Cure) { $rc = Do-Cure } else { $rc = Do-Undo }
exit $rc
