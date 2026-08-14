# iCloud Passwords 验证码弹窗修复工具

修复 Windows 版 iCloud Passwords 浏览器扩展"验证码弹窗不出现"的问题。
无需修改任何 Apple 文件，仅补注册表；支持一键修复 / 撤销 / 状态检测。

## 目录

- [症状](#症状)
- [快速使用](#快速使用)
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

通常发生在**重装或升级 iCloud for Windows 之后**。未重装过的电脑（或历史注册还保留的电脑）没有此问题。

## 快速使用

```powershell
# 普通 PowerShell 即可（非管理员会自动弹 UAC 提权）
pwsh -File patch_icloud_secd_com.ps1        # 交互式菜单（推荐）
pwsh -File patch_icloud_secd_com.ps1 -Fix   # 直接修复
pwsh -File patch_icloud_secd_com.ps1 -Undo  # 直接撤销
```

右键"使用 PowerShell 运行"也可（脚本兼容 PS 5.1 与 PS 7，自动提权）。

修复后**完全关闭 Edge 再重新打开**，点击扩展图标验证。

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

### 3. Apple 的缺陷：重装后注册丢失且永不重建

**卸载重装 iCloud 后，隔离视图中的这条注册被清除，且 iCloud 的运行时注册器
在本机从未重新成功执行**（实测：多次重启全家、开关"密码"功能、退出重登均不重建）。
此后：

```
helper 的 CoCreateInstance → RPCSS 在所有视图都找不到 CLSID → 0x80040154 (CLASSNOTREG)
→ helper 抛 _com_error → 回 {"cmd":10} → 扩展显示"启用密码"错误 → 弹窗永不出现
```

**对比证据**：从未重装过的正常电脑，其 RPCSS 能从隔离视图打开该 CLSID（ETW 实锤，
`Status=0x0`）；本机所有路径均 `0xC0000034`。远端电脑的真实注册表（HKCR、
PackagedCom、HKCU Classes）也**同样没有**这条注册——它只存在于隔离视图。

> 补充：凌晨曾误判根因为 `p222-contactsws.icloud.com` DNS 退役（中国区账号卡顿），
> 已推翻——远端同样 NXDOMAIN 但功能正常。p222 只解释应用启动卡顿，与弹窗无关。

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

### 为什么需要 CKKS Passwords State = 1

重装后 iCloud 应用重建了 `HKCU\Software\Apple Inc.\Internet Services\
CKKS\Features\Passwords` 键，但 **State = 0**（功能未激活标志）。置 1 后
验证码流程完整走通（这是最后一块拼图——置 1 后弹窗首次出现）。

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

### 改动（1 个值）

| 位置 | 改动 |
|---|---|
| `HKCU\...\Internet Services\CKKS\Features\Passwords\State` | 0 → 1（重装后 Apple 建的值，仅改值） |

### 撤销（`-Undo`）删除什么

- 上述 11 个新增键全部删除（索引连带空壳父键）
- **State 保留**（如需恢复 0 请手动设置）
- 幂等：重复撤销安全；重复修复复用已有 ServerId（不产生孤儿条目）

---

## 脚本设计细节

- **自动提权**：非管理员运行时弹 UAC 重启自己（`Start-Process -Verb RunAs` +
  `cmd /c` 输出重定向回显，`-Verb RunAs` 与 `-RedirectStandardOutput` 参数集互斥
  故走 cmd）；提权解释器自适应（优先 pwsh，无则 PS 5.1）
- **5.1 兼容**：`#requires -Version 5.1` + **UTF-8 带 BOM**（5.1 按 ANSI 读
  无 BOM 的含中文脚本会解析错乱——踩过的坑）
- **动态取值**：包名（`Get-AppxPackage`）、ServerId（现有最大 +1，已注册则复用）、
  DeploymentVersion（读取现有 Class 的值）、secd.exe 路径（`InstallLocation`）
- **交互菜单**：实时状态检测（Class 是否注册 / State / marshal 是否齐全），
  选择修复 / 撤销 / 详细状态 / 退出；命令行模式 `-Fix` / `-Undo` 供脚本化调用

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
- 若修复后仍失败：检查 `CKKS\Features\Passwords\State` 是否被应用写回 0
  （置 1 后重启 Edge）

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

MIT。完整逆向诊断报告见 `analysis/2026-08-14-icloud-password-diagnosis/README.md`。
