# iCloud Passwords Verification Popup Fix

Fixes the "verification code popup never appears" issue with the iCloud Passwords browser extension on Windows.
No Apple files are modified — the script only adds registry entries, with one-click **Fix / Undo / Status** modes.

## Contents

- [Symptoms](#symptoms)
- [Quick Start](#quick-start)
- [Root Cause](#root-cause)
- [How the Fix Works](#how-the-fix-works)
- [Registry Changes](#registry-changes)
- [Script Design](#script-design)
- [Compatibility & Limitations](#compatibility--limitations)
- [Known Issues](#known-issues)
- [Verifying the Fix](#verifying-the-fix)
- [License](#license)

---

## Symptoms

After clicking the iCloud Passwords extension icon in Edge/Chrome:

1. The extension shows the verification code input UI ("iCloud sent a notification with a verification code to your devices")
2. But the **verification popup** (the small window with a 6-digit code, a `#32770` dialog) **never appears**
3. After ~20–30 s the extension reports: *"Turn on Passwords in iCloud for Windows to use iCloud Passwords with Edge"*

This typically happens **after reinstalling or upgrading iCloud for Windows**. Machines that were never reinstalled (or still have the historical registration) are unaffected.

## Quick Start

```powershell
# Run in a normal PowerShell window (auto-elevates via UAC when not admin)
pwsh -File patch_icloud_secd_com.ps1        # interactive menu (recommended)
pwsh -File patch_icloud_secd_com.ps1 -Fix   # fix directly
pwsh -File patch_icloud_secd_com.ps1 -Undo  # undo directly
```

Right-click → "Run with PowerShell" also works (the script is compatible with both PS 5.1 and PS 7, and elevates itself).

After fixing: **fully close Edge and reopen it**, then click the extension icon to verify.

---

## Root Cause

### 1. iCloud's password daemon is a packaged COM server

iCloud for Windows is an **MSIX packaged app** (Store package `AppleInc.iCloud`). Its password-management daemon `secd.exe` (at `iCloud\secd.exe`) is a **COM server**:

| Identifier | Value |
|---|---|
| CLSID | `{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}` ("SecDaemon Class") |
| Private interface | `{E095A809-7CDD-4B6D-A528-5D4AC9420D91}` (ISecDaemon, method PerformOperation) |
| TypeLib | `{71529314-E4B7-400B-8FD7-9A5F695AF311}` v1.0 (secdLib) |

Each time you click the extension, its helper process `iCloudPasswordsExtensionHelper.exe` runs:

```
CoCreateInstance(CLSID, CLSCTX_LOCAL_SERVER, IID_E095A809)
→ RPCSS resolves the CLSID → SCM launches secd.exe -Embedding → returns ISecDaemon
→ PerformOperation (PAKE key agreement)
→ success → 6-digit code generated locally (GeneratePIN) → PINDialog (#32770) shows "xxx xxx"
→ extension receives {"cmd":2} (ChallengePIN) → shows input box → user enters code → verified → auto-fill
```

**If any step fails, the verification popup never appears.**

### 2. The "isolated view" registry of packaged apps

The registry of an MSIX packaged app (and its COM servers) is **virtualized**: packaged processes see a merge of the "real registry" and an "isolated view". Packaged COM class registrations live in the isolated-view namespace `\REGISTRY\COMROOT\CLASSES` (physically stored in `Helium\Cache\*_COM15.dat` hives mounted as `\REGISTRY\WC\SiloXXXcom`) — **invisible to regedit and the normal registry APIs**.

secd's registration is written by an iCloud runtime flow (secd embeds an ATL `.rgs` script: `CLSID\{CE6AF8E5}='SecDaemon Class'` + `LocalServer32='%MODULE%'` + `TypeLib={71529314-...}`) and runs **only on first install**.

### 3. The Apple bug: the registration is lost after reinstall and never recreated

**After uninstalling/reinstalling iCloud, the isolated-view registration is wiped, and iCloud's runtime registrar never re-runs successfully** (verified: restarting all iCloud processes, toggling the Passwords switch, and signing out/in do not recreate it). From then on:

```
helper's CoCreateInstance → RPCSS can't find the CLSID in any view → 0x80040154 (CLASSNOTREG)
→ helper throws _com_error → replies {"cmd":10} → extension shows the "enable Passwords" error → popup never appears
```

**Comparison evidence**: on a healthy machine that was never reinstalled, RPCSS opens the CLSID from the isolated view (confirmed via ETW, `Status=0x0`); on the broken machine every path returned `0xC0000034`. The healthy machine's real registry (HKCR, PackagedCom, HKCU Classes) also lacks this registration — it exists only in the isolated view.

> Note: an earlier hypothesis blamed the `p222-contactsws.icloud.com` DNS decommission (account-init slowness for China-region accounts) — disproven: the healthy machine has the same NXDOMAIN yet works fine. p222 only explains slow app startup, not the missing popup.

---

## How the Fix Works

### Key discovery: PackagedCom is where packaged COM declarations are materialized

`<com:Class>` declarations in the MSIX package manifest (`AppxManifest.xml`) are materialized into the real registry at `HKLM\SOFTWARE\Classes\PackagedCom\` (readable by SCM/RPCSS). The iCloud package's other four COM servers (iCloudHome / iCloudDrive / iCloudPhotos / APSDaemon) **all work through manifest declarations + PackagedCom materialization** — **only secd was left out by Apple** (it depends on the isolated-view runtime registration, which is lost after reinstall).

### What the script does

It adds the missing "packaged COM declaration" for secd under `PackagedCom` (simulating a manifest declaration):

```
HKLM\SOFTWARE\Classes\PackagedCom\Package\AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa\
├── Class\{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}   ← CLSID declaration (ServerId → Server below)
├── Server\5                                        ← ExeServer: Executable=iCloud\secd.exe
├── Interface\{E095A809-7CDD-4B6D-A528-5D4AC9420D91} ← ISecDaemon (UseUniversalMarshaler)
├── TypeLib\{71529314-E4B7-400B-8FD7-9A5F695AF311}\1.0 ← Win32Path=iCloud\secd.exe
└── ClassIndex / InterfaceIndex / TypeLibIndex entries
```

**Effect** (confirmed via ETW kernel process events): clicking the extension makes RPCSS resolve the CLSID from PackagedCom and launch secd **with its packaged identity**:

```
Process 5064 started by parent 1968 (RPCSS/DcomLaunch)
ImageName: ...\AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa\iCloud\secd.exe
PackageFullName: AppleInc.iCloud_15.9.60.0_x64__nzyj5cx40ttqa   ← packaged identity!
```

**Identical to healthy machines** — the helper's CoCreateInstance succeeds → PAKE → GeneratePIN → the verification popup appears.

### Why marshal registration is needed (HKCU/HKLM TypeLib + Interface)

The helper and secd communicate cross-process via COM. Marshaling ISecDaemon relies on the TypeLib (Universal Marshaler): `LoadTypeLib` reads the TLB location from `TypeLib\{71529314}\1.0\0\win32`, and `Interface\{E095A809}` provides the TypeLib reference and proxy information. Instrumentation showed helper/secd **querying these keys repeatedly** on startup; missing them breaks the call. The script writes them to **both HKCU and HKLM** so both the packaged user view and the system view resolve.

### Why CKKS Passwords State = 1

After a reinstall, the iCloud app recreates `HKCU\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords` but with **State = 0** (feature-not-activated flag). Setting it to 1 completes the verification flow (it was the final piece — the popup appeared for the first time only after this).

---

## Registry Changes

**The script only adds new keys and changes one value — it never overwrites any existing Apple registration.**

### Added (11 keys)

| # | Location | Content | Purpose |
|---|---|---|---|
| 1 | `HKLM\...\PackagedCom\Package\<pkg>\Class\{CE6AF8E5}` | ServerId / DisplayName / DeploymentVersion | Packaged CLSID declaration (core) |
| 2 | `...\Server\<N>` (N chosen dynamically) | Executable=`iCloud\secd.exe`, ApplicationId, TrustLevel=1, RuntimeBehavior=1, BnoIsolation=0, etc. | ExeServer definition for secd |
| 3 | `...\Interface\{E095A809}` | UseUniversalMarshaler=1, TypeLibId, TypeLibVersionNumber=1.0 | ISecDaemon interface declaration |
| 4 | `...\TypeLib\{71529314}\1.0` | Win32Path/Win64Path=`iCloud\secd.exe` | TypeLib declaration |
| 5–7 | `PackagedCom\ClassIndex/InterfaceIndex/TypeLibIndex\{GUID}\<pkg>` | empty keys | Indexes (used by SCM lookup) |
| 8 | `HKCU\Software\Classes\TypeLib\{71529314}\1.0` | `0\win32`/`0\win64`=absolute secd.exe path, FLAGS, HELPDIR | TypeLib loading for marshaling |
| 9 | `HKLM\SOFTWARE\Classes\TypeLib\{71529314}\1.0` | same as above | system-view fallback |
| 10 | `HKCU\Software\Classes\Interface\{E095A809}` | TypeLib={71529314}, TypeLib\Version=1.0, Version=1.0, ProxyStubClsid32={00020424-...} | interface marshal resolution |
| 11 | `HKLM\SOFTWARE\Classes\Interface\{E095A809}` | same as above | system-view fallback |

### Modified (1 value)

| Location | Change |
|---|---|
| `HKCU\...\Internet Services\CKKS\Features\Passwords\State` | 0 → 1 (key recreated by Apple after reinstall; value only) |

### What `-Undo` removes

- All 11 added keys above (indexes and empty parent keys included)
- **State is left untouched** (set it back to 0 manually if needed)
- Idempotent: running Undo twice is safe; re-running Fix reuses the existing ServerId (no orphan entries)

---

## Script Design

- **Auto-elevation**: when not admin, relaunches itself via UAC (`Start-Process -Verb RunAs` with `cmd /c` output redirection; `-Verb RunAs` and `-RedirectStandardOutput` are mutually exclusive parameter sets, hence the cmd wrapper). The elevated interpreter is chosen adaptively (pwsh first, PowerShell 5.1 otherwise).
- **PS 5.1 compatible**: `#requires -Version 5.1` + **UTF-8 with BOM** (5.1 reads BOM-less files as ANSI, which garbles Chinese text — a known pitfall).
- **Dynamic values**: package name (`Get-AppxPackage`), ServerId (max existing + 1, or reuse if already registered), DeploymentVersion (read from existing Class entries), secd.exe path (from `InstallLocation`).
- **Interactive menu**: live status detection (Class registered / State / marshal keys complete), with Fix / Undo / detailed status / exit; `-Fix` / `-Undo` switches for scripted use.

---

## Compatibility & Limitations

| Item | Tested |
|---|---|
| Windows | 11 Pro 10.0.26100 (24H2) |
| iCloud for Windows | 15.9.60.0 |
| Edge / Chrome | latest stable |
| PowerShell | 5.1 / 7.x |

- The three GUIDs (CLSID/interface/TypeLib) are stable identifiers within the iCloud product line, but if a **future version changes them**, please report it (the latest values can be extracted from the `.rgs` script embedded in `secd.exe`).
- After an iCloud **upgrade/reinstall**, `PackagedCom` switches to the new version-numbered directory → **run the script once more**.
- If it still fails after fixing: check whether `CKKS\Features\Passwords\State` was reset to 0 by the app (set it to 1, then restart Edge).

---

## Known Issues

- **Popup text shows resource names** (`Dlg_PinTitle` / `Dlg_PinText` / `Dlg_Dismiss`): when localization via WinRT `ApplicationModel.Resources` fails to load, the UI falls back to showing resource names. The PRI resources are complete (zh-cn/en-US both present) — the failure is at runtime (likely a helper process identity/package-context issue after reinstalling Edge; Apple side). **The code digits and functionality are unaffected** — purely cosmetic.
- **p222 DNS decommission**: `p222-contactsws.icloud.com` returns NXDOMAIN, making the iCloud app stall ~30 s on contacts fetch at startup (China-region account routing bug; unrelated to the popup).

---

## Verifying the Fix

```powershell
# 1. Registry check (all should be True; State should be 1)
Test-Path "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$((Get-AppxPackage AppleInc.iCloud).PackageFullName)\Class\{CE6AF8E5-3A75-4AF5-BD59-C42E7228B4F4}"
(Get-ItemProperty 'HKCU:\Software\Apple Inc.\Internet Services\CKKS\Features\Passwords').State

# 2. Restart Edge → click the extension icon → the verification popup (#32770, 6-digit code) appears
# 3. Enter the code → auto-fill succeeds
```

Function chain: extension click → helper `CoCreateInstance` (succeeds; secd launched with packaged identity) → PAKE session → 6-digit code generated → PINDialog popup → input → verify → auto-fill.

---

## License

MIT.
