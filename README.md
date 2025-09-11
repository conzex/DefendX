# Wazuh Windows Agent — Build & Customization Guide

**Last updated:** September 11, 2025

---

## Purpose & scope
This document captures an end-to-end, repeatable process to **build the Wazuh Windows agent (winagent) from sources on Ubuntu 22.04**, generate a customized MSI on Windows, and ship/install that MSI across endpoints. It includes prerequisites, commands, troubleshooting, a sample automation script, and links to relevant tools.

Target audience: build engineers, Windows/Endpoint admins, security engineers who want a pre-bundled, branded, pre-configured Wazuh Windows agent.

---

## Quick checklist (tools & links)
- Wazuh source (example v4.12.0): `https://github.com/wazuh/wazuh/archive/v4.12.0.tar.gz`
- Wazuh docs (build/install from sources)
- Ubuntu 22.04 build VM or container (root or sudo access)
- MinGW cross-compilers (mingw-w64 packages)
- NSIS (optional packaging helper)
- WiX Toolset (Windows installer generator)
- Microsoft .NET Framework 3.5 (required on some WiX/MSI toolchains)
- Microsoft Windows SDK (required for some signing/build operations)
- Optional: code-signing certificate + `signtool.exe`
- Tools for transferring file to Windows: `scp`, `rsync`, `WinSCP`, SMB share

---

## 1) Ubuntu 22.04 — prepare build environment

1. Update package indexes:

```bash
sudo apt-get update
```

2. Install required packages (install the mingw packages explicitly used when cross-compiling for Windows):

```bash
sudo apt-get install -y \
  curl make cmake zip unzip nsis \
  gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 \
  g++-mingw-w64-x86-64 g++-mingw-w64-i686
```

> Note: package names above are for Ubuntu Jammy (22.04). If a package cannot be found, run `apt search mingw-w64` or install the meta-package `mingw-w64`.

3. Verify the cross-compilers are present:

```bash
which x86_64-w64-mingw32-gcc
which i686-w64-mingw32-gcc

# and check versions
x86_64-w64-mingw32-gcc -v
i686-w64-mingw32-gcc -v
```

If `which` returns empty, the compilers are not installed or the package names differ; install the appropriate `gcc-mingw-w64-*` packages.

---

## 2) Download Wazuh sources and build (Ubuntu)

1. Download and extract the Wazuh release you want to use:

```bash
curl -Ls https://github.com/wazuh/wazuh/archive/v4.12.0.tar.gz | tar zx
cd wazuh-4.12.0/src
```

2. Install the build-time dependencies required by the Wazuh Makefile:

```bash
# From the repo root (src/)
make deps TARGET=winagent
```

If the Makefile complains `*** No windows cross-compiler found!. Stop.`, confirm MinGW packages are installed (see verification above).

3. Build the Windows agent binaries:

```bash
make TARGET=winagent
```

If for any reason the build system cannot autodetect the compilers, force them explicitly (example using the 64-bit cross-compiler):

```bash
make TARGET=winagent CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++
```

Successful build output should include a line like:

```
Done building winagent
```

4. Package the repository for transfer to Windows:

```bash
cd ../..   # to the wazuh-4.12.0 top-level folder
zip -r wazuh.zip wazuh-4.12.0
```

---

## 3) Transfer to Windows build machine

Options:
- `scp`:
  ```bash
  scp wazuh.zip user@windows-host:C:\Users\builder\Downloads\
  ```
- `smb` share copy, or use `WinSCP`/`FileZilla` for interactive transfer.

Unzip on Windows and open a Developer/Administrator PowerShell prompt in the `src\win32` folder.

---

## 4) Windows build environment (requirements)

Install the following on the Windows machine that will generate the MSI:

- **WiX Toolset** — used by Wazuh to build the MSI from WiX sources. (Download and install WiX 3.x/3.14 or WiX 4.x depending on the repo files.)
- **.NET Framework 3.5** (if required by WiX tooling in your environment)
- **Microsoft Windows SDK** (for tools like `signtool.exe` if you plan to sign the MSI)

Official installers:
- WiX Toolset: https://wixtoolset.org/ or https://github.com/wixtoolset
- Microsoft Windows SDK: via Microsoft developer site

> Run the following once prerequisites are installed from an elevated PowerShell prompt inside `wazuh-4.12.0\src\win32`:

```powershell
# open folder
cd C:\path\to\wazuh-4.12.0\src\win32
.\wazuh-installer-build-msi.bat
```

The script will prompt for `VERSION` and `REVISION` (e.g., `4.12.0` and `1`) and then create an MSI such as `wazuh-agent-4.12.0-1.msi`.

---

## 5) Customizations before building MSI (how & where)

Before running `wazuh-installer-build-msi.bat`, edit the files in `src\win32`:

- **Default `ossec.conf`** (pre-configure the agent manager, name, or other defaults):
  - Path: `src\win32\etc\ossec.conf`
  - Replace the `<client>` block to pre-set the manager address, protocol, etc. Example snippet:

```xml
<client>
  <server>
    <address>10.10.10.5</address>
    <port>1514</port>
    <protocol>tcp</protocol>
  </server>
</client>
```

- **Branding (ProductName, Manufacturer, logo)**:
  - WiX source files live in `src\win32\installer\` or similar. Look for `.wxs` files (WiX XML). Edit the `Product` element `Id`, `Name`, `Manufacturer` and change `ProductName`/`CompanyName` constants in batch or `.wxs` files.
  - To include a logo, add the file into the WiX `Media`/`Binary` elements and reference it in the UI dialogs.

- **Installer name**: modify `wazuh-installer-build-msi.bat` to change `SET MSI_NAME=...` or set the environment variable before invoking the script.

- **Custom install/uninstall scripts**: add PowerShell/CMD scripts under `installer/scripts/` and register them as WiX CustomActions in the `.wxs` files.

- **Signing**: by default the `signtool` call in the batch script may be commented. To sign the MSI, uncomment the `signtool` line and ensure `signtool.exe` is available in PATH (from the Windows SDK) and a certificate is installed or available.

Example `signtool` command line used in the Wazuh script:

```powershell
:: signtool sign /a /tr http://timestamp.digicert.com /d "%MSI_NAME%" /fd SHA256 /td SHA256 "%MSI_NAME%"
```

> If you don't have a code-signing cert yet, you can sign later via your CI/CD or sign-image pipeline.

---

## 6) Build the MSI on Windows

1. From an elevated Developer PowerShell in `src\win32`:

```powershell
.\wazuh-installer-build-msi.bat
# Enter VERSION and REVISION when prompted, example: 4.12.0 and 1
```

2. Verify MSI exists (example):

```powershell
dir .\wazuh-agent-*.msi
```

3. Optional: sign the MSI (if not already signed by the script):

```powershell
signtool sign /a /tr http://timestamp.digicert.com /d "Wazuh Agent" /fd SHA256 /td SHA256 "wazuh-agent-4.12.0-1.msi"
```

---

## 7) Deploy & Enrollment

You can deploy the MSI through your usual management system (GPO, Intune, SCCM, PDQ, etc.) — providing preconfigured `ossec.conf` means agents will try to connect to the manager automatically.

Manual silent install example (Windows CMD):

```powershell
msiexec.exe /i wazuh-agent-4.12.0-1.msi /qn WAZUH_MANAGER="10.0.0.2"
# or
wazuh-agent-4.12.0-1.msi /q WAZUH_MANAGER="10.0.0.2"
```

Wazuh CLI deployment example (from docs):

```powershell
wazuh-agent-4.12.0-1.msi /q WAZUH_MANAGER="10.0.0.2"
```

After install, check agent service status (in elevated PowerShell):

```powershell
Get-Service -Name wazuh-agent
# or using sc.exe
sc query "wazuh-agent"
```

Refer to the Wazuh Agent Enrollment docs for manager-side registration or auto-registration if using `authd`.

---

## 8) Uninstall (unattended)

Use the original MSI for unattended uninstall:

```powershell
msiexec.exe /x wazuh-agent-4.12.0-1.msi /qn
```

---

## 9) Troubleshooting (common problems)

- **`No windows cross-compiler found!. Stop.`**
  - Ensure `gcc-mingw-w64-x86-64` and `gcc-mingw-w64-i686` are installed. Run `which x86_64-w64-mingw32-gcc` and `which i686-w64-mingw32-gcc`.
  - If `make` still fails, explicitly set `CC`/`CXX` variables when invoking `make`.

- **WiX build failing**
  - Confirm WiX is installed and `candle.exe` / `light.exe` are in PATH. Use a Developer PowerShell 64-bit shell if you installed Visual Studio integrations.

- **Signing errors**
  - Confirm `signtool.exe` is available (comes from Windows SDK) and certificate is accessible.

- **Agent cannot contact manager after install**
  - Check `ossec.conf` values, firewall rules, and that manager is listening on the configured port.

---

## 10) Automation: sample `build-winagent.sh` (Ubuntu)

Save the following as `build-winagent.sh`, make it executable (`chmod +x build-winagent.sh`) and run on a clean Ubuntu 22.04 build VM.

```bash
#!/usr/bin/env bash
set -euo pipefail

# variables
WAZUH_VER="4.12.0"
ROOT_DIR="$PWD"

sudo apt-get update
sudo apt-get install -y curl make cmake zip unzip nsis \
  gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 \
  g++-mingw-w64-x86-64 g++-mingw-w64-i686

# fetch sources
curl -Ls "https://github.com/wazuh/wazuh/archive/v${WAZUH_VER}.tar.gz" | tar zx
cd "wazuh-${WAZUH_VER}/src"

# build deps & winagent
make deps TARGET=winagent
make TARGET=winagent

cd ../..
zip -r "wazuh.zip" "wazuh-${WAZUH_VER}"

echo "Built and packaged wazuh-${WAZUH_VER} -> wazuh.zip"
```

---

## 11) Customization checklist for CI/CD
- Add a pipeline step to run the Ubuntu build script in a clean container/VM.
- Archive the built `wazuh.zip` as artifact and transfer to a Windows runner.
- On Windows runner, run a script to unpack, modify branding `ossec.conf` and WiX values, then run `wazuh-installer-build-msi.bat`.
- Optionally sign the MSI using `signtool.exe` with your enterprise certificate.
- Publish signed MSI to internal package repository or distribution location.

---

## 12) References & helpful links
- Wazuh docs — building from sources / agent installation: https://documentation.wazuh.com/current/deployment-options/wazuh-from-sources/wazuh-agent/index.html
- Wazuh GitHub (tarball): https://github.com/wazuh/wazuh/archive/v4.12.0.tar.gz
- Wazuh release notes (4.12.0): https://documentation.wazuh.com/current/release-notes/release-4-12-0.html
- WiX Toolset: https://wixtoolset.org/
- WiX GitHub repo: https://github.com/wixtoolset
- Ubuntu mingw-w64 package info: https://launchpad.net/ubuntu/jammy/%2Bpackage/gcc-mingw-w64-x86-64
- NSIS (Nullsoft Scriptable Install System): https://nsis.sourceforge.io/
- Signtool docs (Microsoft): look up `SignTool.exe` in the Windows SDK docs or use the SDK installer

---

## 13) Notes & maintenance
- Keep the Wazuh version pinned in your build pipeline to ensure repeatability.
- Test the generated MSI in a clean VM before broad deployment.
- Store the original MSI used for unattended uninstall and for compliance/audit purposes.

---

If you want, I can:
- produce a ready-to-run Windows PowerShell script that applies your company branding and runs the WiX build automatically, or
- convert this document into a PDF/README file and provide a download link.


