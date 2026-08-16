# iCloud Passwords 验证码弹窗修复工具

> [English](README.en.md) | 简体中文

修复 Windows 版 iCloud Passwords 浏览器扩展"验证码弹窗不出现"的问题。
无需修改任何 Apple 文件，仅补注册表；支持一键修复 / 撤销 / 状态检测。

## 目录

- [症状](#症状)
- [快速使用](#快速使用)
- [工具使用方法](#工具使用方法)
- [根因详解](#根因详解)
- [修复原理](#修复原理)
- [注册表改动清单](#注册表改动清单)
- [脚本设计细节](#脚本设计细节)
- [兼容性与限制](#兼容性与限制)
- [已知问题](#已知问题)
- [如何验证修复生效](#如何验证修复生效)
- [License](#license)

---

## 症状

点击 Edge/Chrome 里的 iCloud Passwords 扩展图标后：

1. 扩展出现验证码输入界面（"iCloud 已向你发送包含验证码的通知"）
2. 但**验证码弹窗**（显示 6 位数字的小窗口，`#32770` 对话框）**永远不出现**
3. 约 20~30 秒后扩展报错："在 Windows 版 iCloud 中启用"密码"以配合 Edge 使用 iCloud 密码"

**触发条件**（2026-08-15 VM 复现实验实锤）：在 **WindowsApps 文件夹权限已被提权**
（普通用户获得完全控制）的**状态下安装/重装** iCloud 即会失效——无需卸载重装，
提权状态下首次安装同样触发；权限正常的机器安装则不受影响。**反向也成立**
（2026-08-16 VM 实测）：还原权限后**当场生效**，无需重装。

## 快速使用

```powershell
# 普通用户：直接双击 run_patch.bat（自动请求管理员权限）
# 专业用户：右键"终端(管理员)"或"Windows PowerShell(管理员)"打开后：
pwsh -File patch_icloud_secd_com.ps1        # 交互式菜单（推荐）
pwsh -File patch_icloud_secd_com.ps1 -Cure  # 权限修复
pwsh -File patch_icloud_secd_com.ps1 -Fix   # 补丁修复
pwsh -File patch_icloud_secd_com.ps1 -Undo  # 撤销补丁
```

右键"使用 PowerShell 运行"也可（脚本兼容 PS 5.1 与 PS 7）。**脚本不做自动提权**：
非管理员运行仅提示，需自行用 run_patch.bat 或以管理员方式打开。

## 工具使用方法

### 运行方式

| 方式 | 命令 |
|---|---|
| 双击启动器（推荐，自动提权 + 绕过执行策略） | `run_patch.bat` |
| 交互式菜单（需管理员） | `pwsh -File patch_icloud_secd_com.ps1` |
| 权限修复（需管理员，当场生效） | `pwsh -File patch_icloud_secd_com.ps1 -Cure` |
| 补丁修复（需管理员） | `pwsh -File patch_icloud_secd_com.ps1 -Fix` |
| 撤销补丁（需管理员） | `pwsh -File patch_icloud_secd_com.ps1 -Undo` |

### 交互菜单

![交互菜单](images/01-menu.png)

运行后自动检测当前状态并显示菜单（双模式）：

- **当前状态**（自动检测）：
  - `✅ 已修复` — Class 注册 + State=1 齐全
  - `⚠️ 部分修复` — 部分项存在（常见：只差 State 或 Class）
  - `❌ 未修复` — 全部缺失（重装后的典型状态）
  - 另显示 WindowsApps 权限是否异常、MSVCP140（VC++ 运行库）版本
- **[1] 权限修复**：还原 WindowsApps 权限——**当场生效，无需重装/重启/补丁**（VM 实测）
- **[2] 补丁修复**：写入 PackagedCom 打包 COM 声明（不重装，立即恢复弹窗）
- **[3] 撤销补丁**：删除补丁写入项（State 保留）
- **[4] 查看详细状态**：只读展示 包/Class/Server/TypeLib/Interface/State/权限/CRT
- **[0] 退出**

已管理员时 [1]/[2]/[3] 直接执行；未管理员仅提示提权方式（用 run_patch.bat 或管理员窗口）。

### 修复输出

修复成功的标志：每步 `[OK]` + `✅ 修复完成`。

### 验证效果

修复后**完全关闭 Edge 再重新打开**，点击扩展图标：验证码弹窗（显示 6 位数字）出现 → 输入扩展输入框 → 自动填充成功。

---

## 根因详解

### 1. iCloud 的密码守护进程是一个打包 COM 服务器

iCloud for Windows 是 **MSIX 打包应用**（Store 包 `AppleInc.iCloud`）。其密码管理守护进程
`secd.exe`（位于 `iCloud\secd.exe`）是一个 **COM 服务器**：

| 标识 | 值 |
|---|---|
| CLSID | `{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}`（"SecDaemon Class"） |
| 私有接口 | `{E095A809-7CDD-4B6D-A528-5D4AC9420D91}`（ISecDaemon，方法 PerformOperation） |
| TypeLib | `{71529314-E4B7-400B-8FD7-9A5F695AF311}` v1.0（库名 secdLib） |

扩展的 helper 进程 `iCloudPasswordsExtensionHelper.exe` 每次点击扩展都会执行：

```
CoCreateInstance(CLSID, CLSCTX_LOCAL_SERVER, IID_E095A809)
→ RPCSS 解析 CLSID → SCM 启动 secd.exe -Embedding → 返回 ISecDaemon 接口
→ 调用 PerformOperation（PAKE 密钥协商）
→ 成功 → 本地生成 6 位验证码（GeneratePIN）→ 弹出 PINDialog（#32770）显示 "xxx xxx"
→ 扩展收到 {"cmd":2}（ChallengePIN）→ 显示输入框 → 用户输入 → 验证 → 自动填充
```

**任何一环失败，验证码弹窗都不会出现。**

### 2. 打包应用的注册表"隔离视图"

MSIX 打包应用（及其 COM 服务器）的注册表是**虚拟化**的：打包进程看到的注册表是
"真实注册表 + 隔离视图"的合并。打包 COM 类的注册位于**隔离视图命名空间**
`\REGISTRY\COMROOT\CLASSES`（物理存储在 `\REGISTRY\WC\SiloXXXcom` 挂载的
`Helium\Cache\*_COM15.dat` hive 中）——**regedit 和常规注册表 API 不可见**。

secd 的注册由 iCloud 运行时流程写入（secd 内置 ATL `.rgs` 脚本：
`CLSID\{CE6AF8E5}='SecDaemon Class'` + `LocalServer32='%MODULE%'` +
`TypeLib={71529314-...}`），**仅在首次安装时执行**。

### 3. 真正的根因：提权状态下安装 → 打包注册挂载机制静默失效（2026-08-15 实锤修正）

**卸载重装本身不会导致失效**（VM A/B 实验：标准权限下卸载重装 → 弹窗正常）；
**WindowsApps 权限已提权时安装** → 直接失效（首次安装同样触发，无需重装）。

故障机理：提权状态下，secd 的运行时自注册**写进了包内 `Registry.dat`**（App-V
风格的注册表文件虚拟化；证据：故障态 Registry.dat 内含完整 SecDaemon Class +
ISecDaemon marshal + TypeLib 注册），但 **RPCSS 的 COMROOT 解析不到这份注册**
→ helper CoCreateInstance 0x80040154 (CLASSNOTREG) → 回 {"cmd":10} → 弹窗不出现。

**对比证据**：正常权限安装的电脑，RPCSS 能从隔离视图打开该 CLSID；本机故障态
所有路径均解析失败。远端真实注册表（HKCR、PackagedCom、HKCU Classes）同样
没有这条注册——它只存在于隔离视图。

> 补充：早期曾误判根因为 `p222-contactsws.icloud.com` DNS 退役（中国区账号卡顿）
> 与「重装后注册丢失」——均已推翻/修正：p222 只解释应用启动卡顿，与弹窗无关；
> 「注册丢失」实为挂载失效（8-15 深夜修正，见归档 README）。

---

## 修复原理

### 关键发现：PackagedCom 是打包 COM 声明的真实注册表物化位置

MSIX 包清单（`AppxManifest.xml`）中的 `<com:Class>` 声明会物化到真实注册表
`HKLM\SOFTWARE\Classes\PackagedCom\`（SCM/RPCSS 可读）。iCloud 包的
iCloudHome / iCloudDrive / iCloudPhotos / APSDaemon 四个 COM 服务器**都靠
manifest 声明 + PackagedCom 物化工作**——**唯独 Apple 漏掉了 secd**（它依赖
隔离视图的运行时注册，而该注册重装后丢失）。

### 修复做法

在 `PackagedCom` 下为 secd **补上缺失的"打包 COM 声明"**（模拟 manifest 声明）：

```
HKLM\SOFTWARE\Classes\PackagedCom\Package\AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa\
├── Class\{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}   ← CLSID 声明（ServerId 指向下方 Server）
├── Server\5                                        ← ExeServer：Executable=iCloud\secd.exe
├── Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91} ← ISecDaemon（UseUniversalMarshaler）
├── TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}\1.0 ← Win32Path=iCloud\secd.exe
└── ClassIndex / InterfaceIndex / TypeLibIndex 索引
```

**效果**（ETW 内核进程事件铁证）：点击扩展后，RPCSS 从 PackagedCom 解析 CLSID，
以**打包身份**启动 secd：

```
Process 5064 started by parent 1968 (RPCSS/DcomLaunch)
ImageName: ...\AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa\iCloud\secd.exe
PackageFullName: AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa   ← 打包身份激活！
```

**与正常电脑行为完全一致**——helper 的 CoCreateInstance 成功 → PAKE →
GeneratePIN → 验证码弹窗出现。

### 为什么还需要 marshal 注册（HKCU/HKLM TypeLib + Interface）

helper 与 secd 是**跨进程** COM 调用。ISecDaemon 接口的编组（marshaling）依赖
TypeLib（通用编组器 Universal Marshaler）：`LoadTypeLib` 从注册表
`TypeLib\{71529314}\1.0\0\win32` 找到 TLB 位置，`Interface\{E095A809}` 提供
TypeLib 引用与代理信息。实测 helper/secd 启动时**反复查询**这些键（ETW/ProcMon
证据），缺失会导致调用失败。脚本在 **HKCU + HKLM 两侧**补齐（打包进程的用户视图
与系统视图都能解析）。

### 前置条件：VC++ 运行库（MSVCP140 ≥ 14.4x）

VM 交叉实验（2026-08-16）：System32 的 MSVCP140（VC++ 2015-2022 运行库）
**低于 14.40** 时，helper 会在连接 secd 的 `securityd_connection` 互斥锁路径
崩溃（0xC0000005，`_Mtx_do_lock` 空指针解引用）——补丁根本来不及生效。
脚本内置检测：`<14.40` 时警告先装
[VC++ 2015-2022 Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe)
（Win11 系统组件场景可先做 Windows 更新）。

### 为什么需要 CKKS Passwords State = 1

iCloud「密码」功能的启用状态开关。正常安装的机器上应用会创建该键（State=1）；
故障/坏装机器上该键可能**完全缺失**（VM 交叉实验：CRT 正常 + 无此键 → 弹窗不出，
被 helper 的状态门挡住；建键置 1 后立即恢复）。脚本**键缺失时自动创建**并置 1。

---

## 注册表改动清单

**脚本只做"新增键 + 一个改值"，不覆盖任何 Apple 已有注册。**

### 新增（11 个键）

| # | 位置 | 内容 | 用途 |
|---|---|---|---|
| 1 | `HKLM\...\PackagedCom\Package\<包>\Class\{CE6AF8E5}` | ServerId / DisplayName / DeploymentVersion | CLSID 打包声明（核心） |
| 2 | `...\Server\<N>`（N 动态避让） | Executable=`iCloud\secd.exe`、ApplicationId、TrustLevel=1、RuntimeBehavior=1、BnoIsolation=0 等 | secd 的 ExeServer 定义 |
| 3 | `...\Interface\{E095A809}` | UseUniversalMarshaler=1、TypeLibId、TypeLibVersionNumber=1.0 | ISecDaemon 接口声明 |
| 4 | `...\TypeLib\{71529314}\1.0` | Win32Path/Win64Path=`iCloud\secd.exe` | TypeLib 声明 |
| 5-7 | `PackagedCom\ClassIndex/InterfaceIndex/TypeLibIndex\{GUID}\<包>` | 空键 | 索引（SCM 查找用） |
| 8 | `HKCU\Software\Classes\TypeLib\{71529314}\1.0` | `0\win32`/`0\win64`=secd.exe 绝对路径、FLAGS、HELPDIR | 编组加载 TypeLib |
| 9 | `HKLM\SOFTWARE\Classes\TypeLib\{71529314}\1.0` | 同上 | 系统视图双保险 |
| 10 | `HKCU\Software\Classes\Interface\{E095A809}` | TypeLib={71529314}、TypeLib\Version=1.0、Version=1.0、ProxyStubClsid32={00020424-...} | 接口编组解析 |
| 11 | `HKLM\SOFTWARE\Classes\Interface\{E095A809}` | 同上 | 系统视图双保险 |

### 改动（1 个值；键缺失时自动创建）

| 位置 | 改动 |
|---|---|
| `HKCU\...\Internet Services\CKKS\Features\Passwords\State` | 置 1（正常装该键存在仅改值；坏装/重装后可能缺失 → 脚本自动创建） |

### 撤销（`-Undo`）删除什么

- 上述 11 个新增键全部删除（索引连带空壳父键）
- **State 保留**（如需恢复 0 请手动设置）
- 幂等：重复撤销安全；重复修复复用已有 ServerId（不产生孤儿条目）

---

## 脚本设计细节

- **提权策略**（v2026-08-16 起）：脚本**不做自动提权**——普通用户双击
  `run_patch.bat`（启动器负责 UAC 提权 + `-ExecutionPolicy Bypass`），专业用户
  自开管理员 PowerShell；非管理员运行脚本仅打印提示并退出，避免 bat 提权后
  菜单再弹一次 UAC
- **5.1 兼容**：`#requires -Version 5.1` + **UTF-8 带 BOM**（5.1 按 ANSI 读
  无 BOM 的含中文脚本会解析错乱——踩过的坑）
- **动态取值**：包名（`Get-AppxPackage`）、ServerId（现有最大 +1，已注册则复用）、
  DeploymentVersion（读取现有 Class 的值）、secd.exe 路径（`InstallLocation`）
- **交互菜单**：实时状态检测（Class 是否注册 / State / marshal 是否齐全 /
  WindowsApps 权限 / MSVCP140 版本），选择修复 / 撤销 / 详细状态 / 退出；
  命令行模式 `-Fix` / `-Cure` / `-Undo` 供脚本化调用（退出码透传）
- **回读校验**：Do-Fix 收尾逐项比对 10 个关键注册项，写失败（默认静默）会被
  检出并标红，不再「假成功」
- **撤销保护**：Do-Undo 只删本工具写入的 TypeLib/Interface 键（校验 (default)
  值），补丁前已存在的同 GUID 注册不会被误删
- **多包过滤**：`Get-ICloudPackage` 过滤 Staged 残留包（部署「失忆」场景），
  取最新已安装版本

---

## 兼容性与限制

| 项目 | 实测 |
|---|---|
| Windows | 11 Pro 10.0.26100（24H2） |
| iCloud for Windows | 15.9.60.0 |
| Edge / Chrome | 最新稳定版 |
| PowerShell | 5.1 / 7.x 均可 |

- 三个 GUID（CLSID/接口/TypeLib）是 iCloud 产品线内的稳定标识，但**未来版本若变更
  导致失效**，请反馈（可对照 `secd.exe` 内置 .rgs 提取最新值）
- iCloud **升级/重装**后 `PackagedCom` 会切到新版本号目录 → **重跑一次脚本**即可
- 若修复后仍失败：先看脚本输出的「回读校验」是否全过；再检查
  `CKKS\Features\Passwords\State`（置 1 后重启 Edge）与 MSVCP140 版本（≥14.40）

---

## 已知问题

- **弹窗文字显示资源名**（`Dlg_PinTitle` / `Dlg_PinText` / `Dlg_Dismiss`）：
  本地化文本经 WinRT `ApplicationModel.Resources` 加载失败时回退显示资源名。
  PRI 资源文件齐全（zh-cn/en-US 均在），是运行时加载失败（疑似重装后 helper
  进程身份/包上下文问题，Apple 侧）。**验证码数字与功能不受影响**，纯观感问题。
- **p222 DNS 退役**：`p222-contactsws.icloud.com` NXDOMAIN 导致 iCloud 应用
  启动时 contacts 拉取卡顿 ~30 秒（中国区账号路由 bug，与弹窗无关）。

---

## 如何验证修复生效

```powershell
# 1. 注册表检查（全部应为 True，State 应为 1）
Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$((Get-AppxPackage AppleInc.iCloud).PackageFullName)\Class\{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}"
(Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords').State

# 2. 重启 Edge → 点击扩展图标 → 验证码弹窗（#32770，显示 6 位数字）出现
# 3. 输入验证码 → 自动填充成功
```

功能链路：扩展点击 → helper `CoCreateInstance`（成功，secd 打包身份激活）→
PAKE 会话 → 生成 6 位验证码 → PINDialog 弹窗 → 输入 → 验证 → 自动填充。

---

## License

MIT。
