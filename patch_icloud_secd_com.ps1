#requires -Version 5.1
# ============================================================
# iCloud Passwords 验证码弹窗修复工具（交互式，双模式，中英双语）
#
# 背景：iCloud Passwords 扩展验证码弹窗失效的根因：
#   在 WindowsApps 权限已被提权（普通用户获得完全控制）的状态下安装 iCloud，
#   secd 的 COM 注册挂载机制静默失效（两态注册都在包内 Registry.dat——包内置基线、
#   内容等价；提权状态下系统的 COM 视图挂载工序被静默跳过，RPCSS 解析不到）
#   → helper CoCreateInstance 0x80040154 → 弹窗不出现。
#
# 两种修复：
#   [权限] -Cure：还原 WindowsApps 标准 ACL——当场生效，无需重装/重启/补丁
#           （VM 实测验证）
#   [补丁] -Fix ：不重装，在真实注册表 HKLM\SOFTWARE\Classes\PackagedCom 下
#           模拟"打包 COM 声明"（让 SCM 以打包身份激活 secd），立即恢复弹窗
#
# 语言：界面文字自动跟随系统语言（Get-UICulture），也可用 -Lang 强制指定：
#   pwsh -File patch_icloud_secd_com.ps1 -Lang en    # 英文界面
#   pwsh -File patch_icloud_secd_com.ps1 -Lang zh    # 中文界面
#   run_patch.bat en                                 # 启动器同参数
#
# 用法（需要管理员权限；脚本不做自动提权，仅提示）：
#   run_patch.bat                                  # 普通用户：双击启动器（自动提权 + 绕过执行策略）
#   pwsh -File patch_icloud_secd_com.ps1           # 交互式菜单
#   pwsh -File patch_icloud_secd_com.ps1 -Cure     # 权限修复
#   pwsh -File patch_icloud_secd_com.ps1 -Fix      # 补丁修复
#   pwsh -File patch_icloud_secd_com.ps1 -Undo     # 撤销补丁
#   专业用户建议直接开管理员 PowerShell 运行；非管理员时脚本仅提示，需自行提权。
#
# 兼容：iCloud for Windows 15.9.60.0 实测通过（Windows 11 26100/26200，Edge）。
# ============================================================

param([switch]$Undo, [switch]$Fix, [switch]$Cure, [ValidateSet('zh', 'en')][string]$Lang)

# 强制 UTF-8 输出（cmd 重定向提权实例输出时避免 GBK 乱码）
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- 本地化 ----------
# 界面语言：优先「用户首选 UI 语言」（HKCU PreferredUILanguages = Windows 显示语言设置，
# 跨 PS 5.1/7 一致）——不依赖 Get-UICulture 单点（实测部分多语言混合环境下
# PS 5.1 返回 en-US 而 PS7 返回 zh-CN，同一台机器两版本不一致）；-Lang zh|en 可强制
function Select-Language {
    param([string]$Force)
    if ($Force) { return $Force }
    try {
        $pref = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name PreferredUILanguages -ErrorAction Stop).PreferredUILanguages
        if ($pref) {
            $first = ($pref -split ';')[0].Trim()
            if ($first -like 'zh*') { return 'zh' }
            if ($first -like 'en*') { return 'en' }
        }
    } catch {}
    $two = (Get-UICulture).TwoLetterISOLanguageName
    if ($two -like 'zh*') { return 'zh' }
    return 'en'
}
function T([string]$key) {
    if ($script:Ui.ContainsKey($key)) { return $script:Ui[$key] }
    return $key   # 缺键时返回键名，便于发现漏翻
}
function Get-UiStrings([string]$lang) {
    if ($lang -eq 'en') {
        return @{
            # --- 管理员提示 ---
            admin_need      = 'Administrator rights are required for this operation.'
            admin_hint_bat  = '  Option 1: double-click run_patch.bat (requests admin rights via UAC)'
            admin_hint_ps   = '  Option 2: right-click the Start menu → "Terminal (Admin)" or "Windows PowerShell (Admin)", then run this script'
            admin_cli       = 'Administrator rights required: normal users, double-click run_patch.bat; power users, open an elevated PowerShell and retry.'
            # --- 状态 ---
            st_not_installed = 'iCloud is not installed'
            st_fixed_patch   = '✅ Fixed (patch active)'
            st_ok_no_action  = '✅ WindowsApps folder permissions are normal, nothing to do (if the popup still fails, try [2] Patch fix)'
            st_perm_bad      = '⚠️ WindowsApps folder permissions are abnormal ({0}) — the root cause of the popup failure; use [1] Permission fix [-Cure]'
            st_partial       = '⚠️ Partially fixed (Class registered, State not active)'
            st_not_fixed     = '❌ Not fixed'
            # --- CRT 检测 ---
            crt_ok          = 'MSVCP140.dll {0} (CRT OK)'
            crt_old         = 'Detected an old VC++ runtime: MSVCP140.dll {0}'
            crt_old_bug     = '  14.3x and older have a known bug: the helper crashes while connecting to secd (0xC0000005) — the patch will not take effect.'
            crt_install     = '  Install the latest VC++ 2015-2022 Redistributable first: https://aka.ms/vs/17/release/vc_redist.x64.exe'
            crt_winupdate   = '  (On Win11 where it is an OS component, try Windows Update first; re-run this tool after upgrading)'
            # --- 回读校验错误项 ---
            int_no_pkg       = 'iCloud package not found'
            int_class        = 'Class\{0} ServerId (expected {1}, actual {2})'
            int_server       = 'Server\{0} Executable'
            int_iface        = 'Interface\{0}'
            int_tlib         = 'TypeLib\{0}\1.0'
            int_classidx     = 'ClassIndex'
            int_ifaceidx     = 'InterfaceIndex'
            int_tlibidx      = 'TypeLibIndex'
            int_typelib_marshal = 'HKCU TypeLib marshal'
            int_iface_marshal   = 'HKCU Interface marshal'
            int_state        = 'CKKS State'
            sep_bad_list     = '; '
            # --- 权限修复（-Cure） ---
            cure_title       = '== Permission fix: restore WindowsApps permissions (no reinstall — takes effect immediately) =='
            cure_already     = 'WindowsApps permissions are already the standard ACL, nothing to restore'
            cure_found       = 'Found non-standard permission entries: {0}'
            cure_removed     = 'Removed: {0}'
            cure_remove_failed = 'Failed to remove: {0} (exit code {1}; may be an inherited ACE or an unresolvable name)'
            cure_restored    = 'WindowsApps permissions restored to the standard ACL'
            cure_remaining   = 'Still non-standard entries: {0}'
            cure_done        = '✅ Permission fix complete. No reinstall, no reboot, no patch needed.'
            cure_step1       = '  1. Restart Edge (or directly) and click the iCloud Passwords extension icon'
            cure_step2       = '  2. If the verification popup appears, it works; if not, try the patch fix [-Fix] or consider reinstalling'
            cure_warn_future = '  ⚠️ Do not add user permissions to WindowsApps again (otherwise a future upgrade/reinstall will break it again)'
            cure_incomplete  = '⚠️ Permission fix did not fully apply — check the entries above that could not be removed (may be inherited ACEs, or remove them manually in the Security properties dialog).'
            # --- 补丁修复（-Fix） ---
            fix_title        = '== Patch fix: write PackagedCom packaged-COM declarations (no reinstall) =='
            fix_no_pkg       = 'AppleInc.iCloud package not detected — install iCloud for Windows first.'
            fix_pkg          = 'iCloud package: {0}'
            fix_secd         = 'secd.exe: {0}'
            fix_no_secd      = 'secd.exe not found in the package (different version layout?) — aborting.'
            fix_serverid_reuse = 'ServerId = {0} (reusing the existing registration, idempotent)'
            fix_serverid_new = 'ServerId = {0} (current max is {1})'
            fix_dv           = 'DeploymentVersion = {0}'
            fix_ok_class     = 'Class\{0}'
            fix_ok_server    = 'Server\{0} (Executable=iCloud\secd.exe)'
            fix_ok_iface     = 'Interface\{0}'
            fix_ok_tlib      = 'TypeLib\{0}\1.0'
            fix_ok_indexes   = 'ClassIndex / InterfaceIndex / TypeLibIndex'
            fix_marshal_title = '== Writing TypeLib / Interface marshal registrations =='
            fix_marshal_ok   = 'TypeLib / Interface (both HKCU and HKLM)'
            fix_ckks_title   = '== CKKS Passwords State =='
            fix_ckks_created = 'CKKS Passwords key was missing — created automatically (common on broken installs; created by the app on healthy ones)'
            fix_state_ok     = 'State = 1'
            fix_rb_title     = '== Read-back verification =='
            fix_rb_ok        = 'Read-back verification passed'
            fix_rb_fail      = 'Read-back verification failed ({0} items): {1}'
            fix_done         = '✅ Fix complete. Next steps:'
            fix_done_step1   = '  1. Fully close Edge (all windows) and reopen it'
            fix_done_step2   = '  2. Click the iCloud Passwords extension icon and enter the verification code'
            fix_lowcrt       = '⚠️ The patch was written, but MSVCP140 is too old — the patch may not take effect in the current state.'
            fix_lowcrt_install = '  Install the latest VC++ 2015-2022 Redistributable, then re-run this tool:'
            fix_lowcrt_winupdate = '  (On Win11 where it is an OS component, try Windows Update first)'
            fix_lowcrt_after = '  After upgrading: 1. fully close Edge and reopen it; 2. click the extension icon and enter the code'
            # --- 撤销（-Undo） ---
            undo_title       = '== Undo mode: remove the registry entries written by the fix =='
            undo_no_pkg      = 'AppleInc.iCloud package not detected.'
            undo_skip        = 'Skipped (not written by this tool, kept): {0}'
            undo_del         = 'Deleted: {0}'
            undo_ckks_note   = 'CKKS Passwords key was not undone (State stays 1; to fully roll back, delete HKCU:\Software\Apple Inc.\Internet Services\CKKS — note the app may recreate it)'
            undo_done        = 'Undo complete. Restart Edge to verify.'
            # --- 交互菜单 ---
            menu_title       = '  iCloud Passwords Verification Popup Fix'
            menu_state       = '  Current status: {0}'
            menu_state_lowcrt = '  Current status: {0} (MSVCP140 {1} is too old — the patch may not take effect; upgrade the VC++ runtime)'
            menu_1           = '  [1] Permission fix (restore WindowsApps permissions — takes effect immediately)'
            menu_2           = '  [2] Patch fix (PackagedCom patch — no reinstall)'
            menu_3           = '  [3] Undo patch (rollback)'
            menu_4           = '  [4] Show detailed status'
            menu_5           = '  [5] Switch language (current: English)'
            lang_switched    = 'Switched to English UI'
            menu_0           = '  [0] Exit'
            menu_prompt      = '  Please choose (0-5)'
            menu_press_enter = 'Press Enter to return to the menu'
            menu_detail_title = '  --- Detailed status ---'
            menu_bye         = 'Goodbye.'
            menu_invalid     = 'Invalid choice.'
            # --- 详细状态 ---
            detail_pkg_missing = '  iCloud package: not installed'
            detail_pkg       = '  iCloud package: {0}'
            detail_secd      = '  secd.exe: {0}'
            detail_class     = '  Class\{0}: {1}'
            detail_class_reg = 'registered (ServerId={0})'
            detail_class_notreg = 'not registered'
            detail_server    = '  Server\{0} Executable: {1}'
            detail_typelib   = '  HKCU TypeLib registration: {0}'
            detail_iface     = '  HKCU Interface registration: {0}'
            detail_state     = '  CKKS Passwords State: {0}'
            detail_state_missing = '(key does not exist)'
            detail_perm      = '  WindowsApps permissions: {0}'
            detail_perm_ok   = 'standard'
            detail_perm_bad  = 'abnormal: {0}'
            detail_crt       = '  MSVCP140 (VC++ runtime): {0}'
        }
    }
    return @{
        # --- 管理员提示 ---
        admin_need      = '需要管理员权限才能执行本操作。'
        admin_hint_bat  = '  方式一：双击 run_patch.bat（自动请求管理员权限）'
        admin_hint_ps   = '  方式二：右键开始菜单 → "终端(管理员)" 或 "Windows PowerShell(管理员)"，再运行本脚本'
        admin_cli       = '需要管理员权限：普通用户请双击 run_patch.bat；专业用户请以管理员身份打开 PowerShell 后重试。'
        # --- 状态 ---
        st_not_installed = 'iCloud 未安装'
        st_fixed_patch   = '✅ 已修复（补丁生效）'
        st_ok_no_action  = '✅ WindowsApps文件夹权限正常，无需处理（若弹窗仍然失效，可试试 [2] 补丁修复）'
        st_perm_bad      = '⚠️ WindowsApps文件夹权限异常（{0}）——弹窗失效的根因，建议使用 [1] 权限修复 [-Cure]'
        st_partial       = '⚠️ 部分（Class 已注册，State 未激活）'
        st_not_fixed     = '❌ 未修复'
        # --- CRT 检测 ---
        crt_ok          = 'MSVCP140.dll {0}（CRT 正常）'
        crt_old         = '检测到旧版 VC++ 运行库 MSVCP140.dll {0}'
        crt_old_bug     = '  14.3x 及更早有已知 bug：helper 在连接 secd 时崩溃（0xC0000005），补丁将无法生效。'
        crt_install     = '  请先安装最新 VC++ 2015-2022 Redistributable：https://aka.ms/vs/17/release/vc_redist.x64.exe'
        crt_winupdate   = '  （Win11 系统组件场景可先做 Windows 更新；升级后重新运行本工具）'
        # --- 回读校验错误项 ---
        int_no_pkg       = 'iCloud 包不存在'
        int_class        = 'Class\{0} ServerId（期望 {1}，实际 {2}）'
        int_server       = 'Server\{0} Executable'
        int_iface        = 'Interface\{0}'
        int_tlib         = 'TypeLib\{0}\1.0'
        int_classidx     = 'ClassIndex'
        int_ifaceidx     = 'InterfaceIndex'
        int_tlibidx      = 'TypeLibIndex'
        int_typelib_marshal = 'HKCU TypeLib marshal'
        int_iface_marshal   = 'HKCU Interface marshal'
        int_state        = 'CKKS State'
        sep_bad_list     = '；'
        # --- 权限修复（-Cure） ---
        cure_title       = '== 权限修复：还原 WindowsApps 权限（无需重装，当场生效） =='
        cure_already     = 'WindowsApps 权限已是标准 ACL，无需还原'
        cure_found       = '发现非标准权限条目：{0}'
        cure_removed     = '已移除: {0}'
        cure_remove_failed = '移除失败: {0}（退出码 {1}，可能为继承 ACE 或名称无法解析）'
        cure_restored    = 'WindowsApps 权限已还原为标准 ACL'
        cure_remaining   = '仍有非标准条目：{0}'
        cure_done        = '✅ 权限修复完成。无需重装、无需重启计算机、无需补丁。'
        cure_step1       = '  1. 重启 Edge（或直接）点击 iCloud Passwords 扩展图标'
        cure_step2       = '  2. 验证码弹窗出现即生效；若仍不出现，再试补丁修复 [-Fix] 或考虑重装'
        cure_warn_future = '  ⚠️ 以后不要再给 WindowsApps 添加用户权限（否则将来升级/重装会再次失效）'
        cure_incomplete  = '⚠️ 权限修复未完全生效——请检查上方未移除的条目（可能是继承 ACE 或需在安全属性界面手动移除）。'
        # --- 补丁修复（-Fix） ---
        fix_title        = '== 补丁修复：写入 PackagedCom 打包 COM 声明（不重装） =='
        fix_no_pkg       = '未检测到 AppleInc.iCloud 包，请先安装 iCloud for Windows。'
        fix_pkg          = 'iCloud 包: {0}'
        fix_secd         = 'secd.exe: {0}'
        fix_no_secd      = 'secd.exe 不存在于包内（版本结构不同？），终止。'
        fix_serverid_reuse = 'ServerId = {0}（复用已有注册，幂等）'
        fix_serverid_new = 'ServerId = {0}（现有最大 {1}）'
        fix_dv           = 'DeploymentVersion = {0}'
        fix_ok_class     = 'Class\{0}'
        fix_ok_server    = 'Server\{0} (Executable=iCloud\secd.exe)'
        fix_ok_iface     = 'Interface\{0}'
        fix_ok_tlib      = 'TypeLib\{0}\1.0'
        fix_ok_indexes   = 'ClassIndex / InterfaceIndex / TypeLibIndex'
        fix_marshal_title = '== 写入 TypeLib / Interface marshal 注册 =='
        fix_marshal_ok   = 'TypeLib / Interface（HKCU + HKLM 两侧）'
        fix_ckks_title   = '== CKKS Passwords State =='
        fix_ckks_created = 'CKKS Passwords 键缺失，已自动创建（坏装机器常见；正常装由应用自建）'
        fix_state_ok     = 'State = 1'
        fix_rb_title     = '== 回读校验 =='
        fix_rb_ok        = '回读校验全部通过'
        fix_rb_fail      = '回读校验失败（{0} 项）：{1}'
        fix_done         = '✅ 修复完成。下一步：'
        fix_done_step1   = '  1. 完全关闭 Edge（所有窗口）再重新打开'
        fix_done_step2   = '  2. 点击 iCloud Passwords 扩展图标，输入验证码'
        fix_lowcrt       = '⚠️ 补丁已写入，但 MSVCP140 版本过低，当前状态下补丁可能无法生效。'
        fix_lowcrt_install = '  请安装最新 VC++ 2015-2022 Redistributable 后重新运行本工具：'
        fix_lowcrt_winupdate = '  （Win11 系统组件场景可先做 Windows 更新）'
        fix_lowcrt_after = '  升级完成后：1. 完全关闭 Edge 再重新打开；2. 点击扩展图标输入验证码'
        # --- 撤销（-Undo） ---
        undo_title       = '== 撤销模式：删除修复写入的注册表项 =='
        undo_no_pkg      = '未检测到 AppleInc.iCloud 包。'
        undo_skip        = '跳过（非本工具写入，保留）: {0}'
        undo_del         = '已删除: {0}'
        undo_ckks_note   = 'CKKS Passwords 键未被撤销（State 保留 1；如需彻底回滚可删除 HKCU:\Software\Apple Inc.\Internet Services\CKKS，注意应用可能自行重建）'
        undo_done        = '撤销完成。重启 Edge 验证。'
        # --- 交互菜单 ---
        menu_title       = '  iCloud Passwords 验证码弹窗修复工具'
        menu_state       = '  当前状态：{0}'
        menu_state_lowcrt = '  当前状态：{0}（MSVCP140 {1} 版本过低，补丁可能无法生效——请升级 VC++ 运行库）'
        menu_1           = '  [1] 权限修复（还原 WindowsApps 权限，当场生效）'
        menu_2           = '  [2] 补丁修复（PackagedCom 补丁，不重装）'
        menu_3           = '  [3] 撤销补丁（回滚）'
        menu_4           = '  [4] 查看详细状态'
        menu_5           = '  [5] 切换语言（当前：中文）'
        lang_switched    = '已切换为英文界面'
        menu_0           = '  [0] 退出'
        menu_prompt      = '  请选择 (0-5)'
        menu_press_enter = '按回车返回菜单'
        menu_detail_title = '  --- 详细状态 ---'
        menu_bye         = '再见。'
        menu_invalid     = '无效选择。'
        # --- 详细状态 ---
        detail_pkg_missing = '  iCloud 包：未安装'
        detail_pkg       = '  iCloud 包：{0}'
        detail_secd      = '  secd.exe：{0}'
        detail_class     = '  Class\{0}：{1}'
        detail_class_reg = '已注册 (ServerId={0})'
        detail_class_notreg = '未注册'
        detail_server    = '  Server\{0} Executable：{1}'
        detail_typelib   = '  HKCU TypeLib 注册：{0}'
        detail_iface     = '  HKCU Interface 注册：{0}'
        detail_state     = '  CKKS Passwords State：{0}'
        detail_state_missing = '（键不存在）'
        detail_perm      = '  WindowsApps 权限：{0}'
        detail_perm_ok   = '标准'
        detail_perm_bad  = '异常: {0}'
        detail_crt       = '  MSVCP140（VC++ 运行库）：{0}'
    }
}
$script:lang = Select-Language -Force $Lang
$script:Ui = Get-UiStrings $script:lang

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
        Write-Host (T 'admin_need') -ForegroundColor Red
        Write-Host (T 'admin_hint_bat') -ForegroundColor Yellow
        Write-Host (T 'admin_hint_ps') -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ---------- WindowsApps 权限检测（权限修复的状态依据） ----------
# 标准 ACL 的 8 个主体（SID 形式；⚠️ 包能力 SID（S-1-15-3-1024）随机器/包部署而异，
# 不能精确匹配，按前缀匹配——硬编码单一值会在其他机器上误报「权限异常」）
$StdAclSids = @(
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', # NT SERVICE\TrustedInstaller
    'S-1-15-3-1024-*', # 包能力 SID（值因机器/包而异，前缀匹配）
    'S-1-5-18',  # NT AUTHORITY\SYSTEM
    'S-1-5-32-544', # BUILTIN\Administrators
    'S-1-5-19',  # NT AUTHORITY\LOCAL SERVICE
    'S-1-5-20',  # NT AUTHORITY\NETWORK SERVICE
    'S-1-5-12',  # NT AUTHORITY\RESTRICTED
    'S-1-5-32-545' # BUILTIN\Users
)
# SID 是否属于标准 ACL（支持通配符匹配）
function Test-StdSid([string]$sid) {
    foreach ($w in $StdAclSids) { if ($sid -like $w) { return $true } }
    return $false
}
# 返回 WindowsApps 根 ACL 中非标准主体的列表（空 = 标准）
# 用 Get-Acl 结构化解析（icacls 文本解析在「路径+ACE 首行混排」时可能漏报首个 ACE）
function Get-WindowsAppsAnomaly {
    $extra = @()
    try {
        $acl = Get-Acl 'C:\Program Files\WindowsApps' -ErrorAction Stop
        foreach ($ace in $acl.Access) {
            if ($ace.IsInherited) { continue }   # 只统计显式 ACE（标准 ACL 的 8 条均为显式）
            try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = $ace.IdentityReference.Value }   # 解析失败按 SID 字符串比对
            if (-not (Test-StdSid $sid)) { $extra += $ace.IdentityReference.Value }
        }
    } catch { return ,@() }   # 读取失败按无异常处理，不阻塞流程
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
        return [pscustomobject]@{ Installed = $false; ClassExists = $false; ServerId = $null; State = $null; TypeLibOk = $false; InterfaceOk = $false; FixedByPatch = $false; Summary = (T 'st_not_installed') }
    }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $classKey = "$pkgRoot\Class\{$clsid}"
    $serverId = (Get-ItemProperty $classKey -Name ServerId -ErrorAction SilentlyContinue).ServerId
    $state = (Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords' -Name State -ErrorAction SilentlyContinue).State
    $typeLibOk = Test-Path "HKCU:\Software\Classes\TypeLib\{$tlid}\1.0\0\win32"
    $interfaceOk = Test-Path "HKCU:\Software\Classes\Interface\{$iid}"
    $permAnomaly = Get-WindowsAppsAnomaly
    $fixedByPatch = ($serverId -ne $null -and $state -eq 1)
    if ($fixedByPatch) {
        $summary = T 'st_fixed_patch'
    } elseif ($permAnomaly.Count -eq 0 -and $serverId -eq $null) {
        $summary = T 'st_ok_no_action'
    } elseif ($permAnomaly.Count -gt 0) {
        $summary = (T 'st_perm_bad') -f ($permAnomaly -join ', ')
    } elseif ($serverId -ne $null) {
        $summary = T 'st_partial'
    } else {
        $summary = T 'st_not_fixed'
    }
    return [pscustomobject]@{ Installed = $true; ClassExists = ($serverId -ne $null); ServerId = $serverId; State = $state; TypeLibOk = $typeLibOk; InterfaceOk = $interfaceOk; FixedByPatch = $fixedByPatch; PermAnomaly = $permAnomaly; Summary = $summary }
}

# ---------- CRT 版本检测（旧版 MSVCP140 已知 bug：helper 连接 secd 时崩溃） ----------
# 返回 CRT 是否满足要求（≥14.40；读取失败时按满足处理，不阻塞流程）
function Test-CrtOk {
    $dll = Get-Item 'C:\Windows\System32\MSVCP140.dll' -ErrorAction SilentlyContinue
    if (-not $dll) { return $true }
    try { $ver = [version]$dll.VersionInfo.FileVersion } catch { return $true }
    return -not ($ver.Major -eq 14 -and $ver.Minor -lt 40)
}
function Get-CrtVersion {
    return (Get-Item 'C:\Windows\System32\MSVCP140.dll' -ErrorAction SilentlyContinue).VersionInfo.FileVersion
}
function Test-CrtVersion {
    if (Test-CrtOk) {
        Ok ((T 'crt_ok') -f (Get-CrtVersion))
    } else {
        Warn ((T 'crt_old') -f (Get-CrtVersion))
        Warn (T 'crt_old_bug')
        Warn (T 'crt_install')
        Warn (T 'crt_winupdate')
    }
}

# ---------- Do-Fix 收尾回读校验（写失败默认静默，这里逐项比对） ----------
function Test-PatchIntegrity([int]$serverId) {
    $appx = Get-ICloudPackage
    if (-not $appx) { return ,@((T 'int_no_pkg')) }
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
    $bad = @()
    $classServerId = (Get-ItemProperty "$pkgRoot\Class\{$clsid}" -Name ServerId -ErrorAction SilentlyContinue).ServerId
    if ($classServerId -ne $serverId) { $bad += ((T 'int_class') -f $clsid, $serverId, $classServerId) }
    $exe = (Get-ItemProperty "$pkgRoot\Server\$serverId" -Name Executable -ErrorAction SilentlyContinue).Executable
    if ($exe -ne 'iCloud\secd.exe') { $bad += ((T 'int_server') -f $serverId) }
    if (-not (Test-Path "$pkgRoot\Interface\{$iid}")) { $bad += ((T 'int_iface') -f $iid) }
    if (-not (Test-Path "$pkgRoot\TypeLib\{$tlid}\1.0")) { $bad += ((T 'int_tlib') -f $tlid) }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}\$($appx.PackageFullName)")) { $bad += T 'int_classidx' }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}\$($appx.PackageFullName)")) { $bad += T 'int_ifaceidx' }
    if (-not (Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}\$($appx.PackageFullName)")) { $bad += T 'int_tlibidx' }
    if (-not (Test-Path 'HKCU:\Software\Classes\TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}\1.0\0\win32')) { $bad += T 'int_typelib_marshal' }
    if (-not (Test-Path 'HKCU:\Software\Classes\Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91}')) { $bad += T 'int_iface_marshal' }
    if ((Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords' -Name State -ErrorAction SilentlyContinue).State -ne 1) { $bad += T 'int_state' }
    return ,$bad
}

# ---------- 权限修复：还原 WindowsApps 权限（当场生效，无需重装） ----------
function Do-Cure {
    Write-Host (T 'cure_title') -ForegroundColor White
    $extra = Get-WindowsAppsAnomaly
    if ($extra.Count -eq 0) {
        Ok (T 'cure_already')
        $after = @()
    } else {
        Write-Host ((T 'cure_found') -f ($extra -join ', ')) -ForegroundColor Yellow
        foreach ($p in $extra) {
            icacls 'C:\Program Files\WindowsApps' /remove "$p" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok ((T 'cure_removed') -f $p) }
            else { Warn ((T 'cure_remove_failed') -f $p, $LASTEXITCODE) }
        }
        $after = Get-WindowsAppsAnomaly
        if ($after.Count -eq 0) { Ok (T 'cure_restored') }
        else { Warn ((T 'cure_remaining') -f ($after -join ', ')) }
    }
    Write-Host ''
    if ($after.Count -eq 0) {
        Write-Host (T 'cure_done') -ForegroundColor Green
        Write-Host (T 'cure_step1')
        Write-Host (T 'cure_step2')
        Write-Host (T 'cure_warn_future')
        return 0
    } else {
        Write-Host (T 'cure_incomplete') -ForegroundColor Yellow
        return 1
    }
}

# ---------- 补丁修复：PackagedCom 模拟 ----------
function Do-Fix {
    Write-Host (T 'fix_title') -ForegroundColor White
    Test-CrtVersion
    $appx = Get-ICloudPackage
    if (-not $appx) { Warn (T 'fix_no_pkg'); return 1 }
    $pkgFull = $appx.PackageFullName
    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$pkgFull"
    $secdPath = Join-Path $appx.InstallLocation 'iCloud\secd.exe'
    Info ((T 'fix_pkg') -f $pkgFull)
    Info ((T 'fix_secd') -f $secdPath)
    if (-not (Test-Path $secdPath)) { Warn (T 'fix_no_secd'); return 1 }

    # ServerId：已注册则复用（幂等），否则取现有最大值 +1
    $existingServerId = (Get-ItemProperty "$pkgRoot\Class\{$clsid}" -Name ServerId -ErrorAction SilentlyContinue).ServerId
    if ($existingServerId -ne $null -and [int]$existingServerId -ge 0) {
        $serverId = [int]$existingServerId
        Info ((T 'fix_serverid_reuse') -f $serverId)
    } else {
        $maxServer = -1
        Get-ChildItem "$pkgRoot\Server" -ErrorAction SilentlyContinue | ForEach-Object {
            $n = 0; if ([int]::TryParse($_.PSChildName, [ref]$n) -and $n -gt $maxServer) { $maxServer = $n }
        }
        $serverId = $maxServer + 1
        Info ((T 'fix_serverid_new') -f $serverId, $maxServer)
    }
    # DeploymentVersion：从现有 Class 读取，缺省 0x3ea
    $dv = 0x3ea
    Get-ChildItem "$pkgRoot\Class" -ErrorAction SilentlyContinue | ForEach-Object {
        $v = (Get-ItemProperty $_.PSPath -Name DeploymentVersion -ErrorAction SilentlyContinue).DeploymentVersion
        if ($v -and $v -ne $null) { $dv = [int]$v }
    }
    Info ((T 'fix_dv') -f $dv)

    # 1. Class entry
    # ⚠️ 注册表写入值（DisplayName 等）是 Undo 误删保护的回读依据，必须保持英文常量，不得本地化
    $k = "$pkgRoot\Class\{$clsid}"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name ServerId -Value $serverId -Type DWord
    Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon Class' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok ((T 'fix_ok_class') -f $clsid)

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
    Ok ((T 'fix_ok_server') -f $serverId)

    # 3. Interface entry
    $k = "$pkgRoot\Interface\{$iid}"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name UseUniversalMarshaler -Value 1 -Type DWord
    Set-ItemProperty $k -Name TypeLibId -Value "{$tlid}" -Type String
    Set-ItemProperty $k -Name TypeLibVersionNumber -Value '1.0' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok ((T 'fix_ok_iface') -f $iid)

    # 4. TypeLib entry
    $k = "$pkgRoot\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
    Set-ItemProperty $k -Name LocaleId -Value 0 -Type DWord
    Set-ItemProperty $k -Name Flags -Value 0 -Type DWord
    Set-ItemProperty $k -Name DisplayName -Value 'SecDaemon 1.0 Type Library' -Type String
    Set-ItemProperty $k -Name Win32Path -Value 'iCloud\secd.exe' -Type String
    Set-ItemProperty $k -Name Win64Path -Value 'iCloud\secd.exe' -Type String
    Set-ItemProperty $k -Name DeploymentVersion -Value $dv -Type DWord
    Ok ((T 'fix_ok_tlib') -f $tlid)

    # 5. Indexes
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\ClassIndex\{$clsid}\$pkgFull" -Force | Out-Null
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\InterfaceIndex\{$iid}\$pkgFull" -Force | Out-Null
    New-Item "HKLM:\SOFTWARE\Classes\PackagedCom\TypeLibIndex\{$tlid}\$pkgFull" -Force | Out-Null
    Ok (T 'fix_ok_indexes')

    # 6. marshal 注册（HKCU + HKLM）
    Write-Host (T 'fix_marshal_title') -ForegroundColor White
    foreach ($root in @('HKCU:\Software\Classes', 'HKLM:\SOFTWARE\Classes')) {
        $k = "$root\TypeLib\{$tlid}\1.0"; New-Item $k -Force | Out-Null
        Set-ItemProperty $k -Name '(default)' -Value 'SecDaemon 1.0 Type Library' -Type String -ErrorAction SilentlyContinue
        # TypeLib 根键标记值（Undo 误删保护的判断依据）：根键 (default) 为空才写，
        # 不覆盖可能已存在的同 GUID 注册；没有它 Undo 会把整棵 TypeLib\{tlid} 当「非本工具」保留
        $tlRoot = "$root\TypeLib\{$tlid}"
        if (-not (Get-ItemProperty $tlRoot -Name '(default)' -ErrorAction SilentlyContinue).'(default)') {
            Set-ItemProperty $tlRoot -Name '(default)' -Value 'SecDaemon 1.0 Type Library' -Type String -ErrorAction SilentlyContinue
        }
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
    Ok (T 'fix_marshal_ok')

    # 7. CKKS Passwords State（键缺失也创建——坏装机器上该键常不存在，缺它弹窗不出）
    Write-Host (T 'fix_ckks_title') -ForegroundColor White
    $ckks = 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords'
    if (-not (Test-Path $ckks)) {
        New-Item $ckks -Force | Out-Null
        Warn (T 'fix_ckks_created')
    }
    Set-ItemProperty $ckks -Name 'State' -Value 1 -Type DWord
    Ok (T 'fix_state_ok')

    # 8. 回读校验（写失败会静默，必须逐项确认）
    Write-Host (T 'fix_rb_title') -ForegroundColor White
    $bad = Test-PatchIntegrity -serverId $serverId
    if ($bad.Count -eq 0) {
        Ok (T 'fix_rb_ok')
    } else {
        Warn ((T 'fix_rb_fail') -f $bad.Count, ($bad -join (T 'sep_bad_list')))
        return 1
    }

    Write-Host ''
    if (Test-CrtOk) {
        Write-Host (T 'fix_done') -ForegroundColor Green
        Write-Host (T 'fix_done_step1')
        Write-Host (T 'fix_done_step2')
    } else {
        Write-Host (T 'fix_lowcrt') -ForegroundColor Yellow
        Write-Host (T 'fix_lowcrt_install') -ForegroundColor Yellow
        Write-Host '  https://aka.ms/vs/17/release/vc_redist.x64.exe' -ForegroundColor Yellow
        Write-Host (T 'fix_lowcrt_winupdate') -ForegroundColor Yellow
        Write-Host (T 'fix_lowcrt_after') -ForegroundColor Yellow
    }
    return 0
}

# ---------- 撤销 ----------
function Do-Undo {
    Write-Host (T 'undo_title') -ForegroundColor White
    $appx = Get-ICloudPackage
    if (-not $appx) { Warn (T 'undo_no_pkg'); return 1 }
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
        # 误删保护：仅对真实注册（HKCU/HKLM Software\Classes 下）的 TypeLib/Interface 键，
        # 在 (default) 值确认是本工具写入时才删——补丁前已存在的同 GUID 注册（正常安装态）
        # 不能动；PackagedCom 下的是本工具专属命名空间（模拟物化），直接删。
        # ⚠️ 这里的期望值必须是英文常量（写入端也保持英文），与界面语言无关
        if ($t -notmatch '\\PackagedCom\\' -and ($t -match '\\TypeLib\\' -or $t -match '\\Interface\\')) {
            $def = (Get-ItemProperty $t -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            $expect = if ($t -match '\\TypeLib\\') { 'SecDaemon 1.0 Type Library' } else { 'ISecDaemon' }
            if ($def -ne $expect) {
                Warn ((T 'undo_skip') -f ($t -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''))
                continue
            }
        }
        Remove-Item $t -Recurse -Force
        Ok ((T 'undo_del') -f ($t -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''))
    }
    Warn (T 'undo_ckks_note')
    Write-Host (T 'undo_done') -ForegroundColor Green
    return 0
}

# ============================================================
# 入口
# ============================================================

if (-not $Undo -and -not $Fix -and -not $Cure) {
    # ============ 交互模式 ============
    while ($true) {
        Clear-Host
        Write-Host '============================================' -ForegroundColor Cyan
        Write-Host (T 'menu_title') -ForegroundColor Cyan
        Write-Host '============================================' -ForegroundColor Cyan
        $st = Get-PatchStatus
        Write-Host ''
        # 当前状态行颜色：
        #   「已修复（补丁生效）」段 → 按 CRT 版本判定（<14.40 标红 + 提示，达标绿）
        #   其余段 → 按权限状态判定（权限异常红，正常绿）
        if ($st.FixedByPatch) {
            if (Test-CrtOk) {
                Write-Host ((T 'menu_state') -f $st.Summary) -ForegroundColor Green
            } else {
                Write-Host ((T 'menu_state_lowcrt') -f $st.Summary, (Get-CrtVersion)) -ForegroundColor Red
            }
        } else {
            Write-Host ((T 'menu_state') -f $st.Summary) -ForegroundColor $(if ($st.PermAnomaly.Count -gt 0) { 'Red' } else { 'Green' })
        }
        Write-Host ''
        Write-Host (T 'menu_1')
        Write-Host (T 'menu_2')
        Write-Host (T 'menu_3')
        Write-Host (T 'menu_4')
        Write-Host (T 'menu_5')
        Write-Host (T 'menu_0')
        Write-Host ''
        $choice = Read-Host (T 'menu_prompt')
        # stdin EOF（管道/重定向场景）时 Read-Host 立即返回空 → 防止无限刷「无效选择」死循环；
        # 真实键盘交互不受影响（IsInputRedirected=False，按回车仅提示无效）
        if (-not $choice -and [Console]::IsInputRedirected) { exit 0 }
        switch ($choice) {
            '1' {
                Write-Host ''
                if (Test-Admin) { Do-Cure }
                Write-Host ''; $null = Read-Host (T 'menu_press_enter')
            }
            '2' {
                Write-Host ''
                if (Test-Admin) { Do-Fix }
                Write-Host ''; $null = Read-Host (T 'menu_press_enter')
            }
            '3' {
                Write-Host ''
                if (Test-Admin) { Do-Undo }
                Write-Host ''; $null = Read-Host (T 'menu_press_enter')
            }
            '4' {
                Write-Host ''
                Write-Host (T 'menu_detail_title')
                $appx = Get-ICloudPackage
                if (-not $appx) { Write-Host (T 'detail_pkg_missing') -ForegroundColor Red }
                else {
                    Write-Host ((T 'detail_pkg') -f $appx.PackageFullName)
                    Write-Host ((T 'detail_secd') -f (Test-Path (Join-Path $appx.InstallLocation 'iCloud\secd.exe')))
                    $pkgRoot = "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$($appx.PackageFullName)"
                    if ($st.ClassExists) { $classStr = ((T 'detail_class_reg') -f $st.ServerId) }
                    else { $classStr = T 'detail_class_notreg' }
                    Write-Host ((T 'detail_class') -f $clsid, $classStr)
                    if ($st.ServerId -ne $null) {
                        $exe = (Get-ItemProperty "$pkgRoot\Server\$($st.ServerId)" -Name Executable -ErrorAction SilentlyContinue).Executable
                        Write-Host ((T 'detail_server') -f $st.ServerId, $exe)
                    }
                    Write-Host ((T 'detail_typelib') -f $st.TypeLibOk)
                    Write-Host ((T 'detail_iface') -f $st.InterfaceOk)
                    if ($st.State -ne $null) { $stateStr = $st.State } else { $stateStr = T 'detail_state_missing' }
                    Write-Host ((T 'detail_state') -f $stateStr)
                    if ($st.PermAnomaly.Count -eq 0) { $permStr = T 'detail_perm_ok' }
                    else { $permStr = ((T 'detail_perm_bad') -f ($st.PermAnomaly -join ', ')) }
                    Write-Host ((T 'detail_perm') -f $permStr)
                    $crt = (Get-Item 'C:\Windows\System32\MSVCP140.dll' -ErrorAction SilentlyContinue).VersionInfo.FileVersion
                    Write-Host ((T 'detail_crt') -f $crt)
                }
                Write-Host ''; $null = Read-Host (T 'menu_press_enter')
            }
            '5' {
                Write-Host ''
                # 切换语言：重载字符串表后重绘菜单（仅当前会话，下次启动仍按自动检测）
                $script:lang = if ($script:lang -eq 'zh') { 'en' } else { 'zh' }
                $script:Ui = Get-UiStrings $script:lang
                Ok (T 'lang_switched')
                Write-Host ''; $null = Read-Host (T 'menu_press_enter')
            }
            '0' { Write-Host (T 'menu_bye'); exit 0 }
            default { Write-Host (T 'menu_invalid') -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
    exit 0
}

# ============ 命令行模式（-Fix / -Cure / -Undo） ============
if (-not $isAdmin) {
    Write-Host (T 'admin_cli') -ForegroundColor Red
    exit 1
}
if ($Fix) { $rc = Do-Fix } elseif ($Cure) { $rc = Do-Cure } else { $rc = Do-Undo }
exit $rc
