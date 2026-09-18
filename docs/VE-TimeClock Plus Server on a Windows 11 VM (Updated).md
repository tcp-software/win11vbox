# TimeClock Plus Server on a Windows 11 VM — 2026 Update (Addendum)

This is an **addendum** to `VE-TimeClock Plus Server on a Windows 11 VM-110626-171548.md`. Read
that original guide top to bottom for the full manual install; this file only records what has
**changed or been newly discovered** since it was written — the current toolchain (.NET 10 and
Visual Studio 2026), the prerequisites from the *Workstation Setup Guide*, and the
server-config and startup details that a fresh manual build now depends on. Where this addendum
and the original differ, this addendum wins. Everything not mentioned here is unchanged, so
follow the original for it.

Read the two together in this order: the original for the overall flow, and the matching
section here whenever you reach the toolchain install, the server build, or starting the
servers.

For a fully automated alternative that performs every step hands-free, use `build-vm.sh` (see
the project README); each fix below is also implemented there.

## At a Glance — What Changed

- **Visual Studio 2026 replaces Visual Studio 2022.** Visual Studio 2022 cannot target .NET
  10 projects, so 2026 is required.
- **Install the .NET 10 SDK**, in addition to the .NET Framework 3.5 and the .NET 5 and 6
  SDKs the original guide installs.
- **`MSBUILD_PATH` now points at the Visual Studio 18 path** (the 2026 install), not the 2022
  path.
- **Added prerequisites from the Workstation Setup Guide:** GitHub account with two-factor
  authentication and repo access, the `D:` working partition, Git for Windows specifics, and
  the GitHub CLI.
- **Four WebEdition servers, each on its own port** (AppServerApi 8008, TerminalHubApi 8010,
  AdmServerApi 8012, WorkstationHubApi 8014) — the original only starts the app and admin
  servers.
- **Each server reads a per-server cfg directory** (`Src\Interface\<Server>\cfg`), not the
  shared `cfg`; without it all four default to port 8008 and collide.
- **AppServerApi targets .NET 10**, whose config loader rejects XML namespaces and needs its
  config readable/writable by the server account (strip `xsd`/`xsi`, grant access).
- **The build and restore need `git`, `dotnet`, `MSBuild`, `nant`, and `sqlcmd` on PATH**, and
  the database restore must run elevated (so `dev` is a SQL sysadmin).

## Before You Start (from the Workstation Setup Guide)

You must have Administrator permissions on the machine. If you do not, request them through
the IT service portal.

### GitHub account, two-factor authentication, and repo access

- Use an existing GitHub identity or create a new one, then join the `tcp-software` GitHub org.
- **Two-factor authentication is required** to join the org. Use an authenticator app (Authy,
  Duo, Google Authenticator, or similar) for the TOTP codes.
- Your GitHub profile picture and username must be work-appropriate.
- Email your manager and Philip DeVries to request access to the TCP GitHub repositories.

### Working partition

- The dev machine may need a `D:` drive created. Inside `D:` create a `Tools` directory and a
  `Work` directory (`D:\Tools` and `D:\Work`).
- Email `ITCase@TCPSoftware.com` if you need the partition created.

### Git for Windows

Install Git for Windows (Git Bash), and during the installer:

1. Choose your preferred default editor.
2. Choose **Override the default branch name** and accept `main`.
3. For line endings, select **Check out Windows-style, commit Unix-style line endings**.
4. On **Configuring extra options**, enable file system caching and symbolic links.
5. On **Configure experimental options**, enable both the pseudo console and the file system
   monitor.

Note: a Visual Studio installation or update can overwrite Git settings. If that happens,
reinstall the latest Git for Windows. Confirm Git is intact by checking that `git-lfs.exe`
still exists in the Git path.

### GitHub CLI

In Git Bash (run as Administrator if it fails):

```
winget install -i --id GitHub.cli
```

## .NET 10 and Visual Studio 2026 (replaces the original .NET 5/6 + VS 2022 steps)

### Install the .NET 10 SDK

winget:

```
winget install Microsoft.DotNet.SDK.10
```

or Chocolatey:

```
choco install dotnet-10.0-sdk -y --force
```

Keep the .NET Framework 3.5 (from Windows Features) and the .NET 5 and 6 SDKs per the
original guide.

### Visual Studio 2026 (not 2022)

Install Visual Studio 2026. Visual Studio 2022 cannot target .NET 10. During installation,
select the workloads, including **Web development build tools** (required), along with the
workloads called for in the original guide (ASP.NET and web development, .NET desktop, Desktop
development with C++, and Node.js). To see what a prior Visual Studio 2022 install had
selected, open the 2022 entry in the installer, click Modify, and review its workloads.

### Update MSBUILD_PATH

Open the Environment Variables window (search for "edit system environment variables," or run
`rundll32.exe sysdm.cpl,EditEnvironmentVariables`). Under System variables, set `MSBUILD_PATH`
to the Visual Studio 18 path:

```
C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin
```

or, on some installs:

```
C:\Program Files (x86)\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin
```

If `MSBUILD_PATH` does not exist, create it and append `%MSBUILD_PATH%` to `Path`. If `Path`
still has the old 2022 MSBuild entry
(`C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin`),
replace it.

The edition segment depends on the channel you installed: a GA Visual Studio 2026 Professional
install uses `...\18\Professional\...`, while the Insiders channel uses `...\18\Insiders\...`
(`build-vm.sh` installs the Insiders channel, so its scripts reference
`C:\Program Files\Microsoft Visual Studio\18\Insiders\MSBuild\Current\Bin`). Set `MSBUILD_PATH`
to wherever `MSBuild.exe` actually landed — confirm with:

```
dir "C:\Program Files\Microsoft Visual Studio\18\*\MSBuild\Current\Bin\MSBuild.exe"
```

## Running the Four WebEdition Servers

The dev stack runs four WebEdition servers. Each listens on its own port. A clock device such
as a linclock connects to TerminalHubApi, which in turn calls AppServerApi and SQL Server.

| Server | Port | Role |
|---|---|---|
| AppServerApi | 8008 | Employee, manager, and webclock backend (targets .NET 10) |
| TerminalHubApi | 8010 | Hub that networked clock devices connect to |
| AdmServerApi | 8012 | Administration |
| WorkstationHubApi | 8014 | Hub for workstation-attached terminals and biometric readers |

The repo launchers live in `server\Etc\Util` (`start-tcpapp-server.sh`, `start-tcpadm-server.sh`,
`start-tcphub-server.sh`, and `start-tcppwh-server.sh`). The original guide doesn't cover these
four servers, their ports, or the per-server config they need — so this whole section is new.

**Where this fits in the manual sequence:** after you've built the server and client and applied
the server config per the original guide, and **before** you start the servers, do the four
things below in order — (1) confirm the build tools are on PATH, (2) give each server its own
cfg directory, (3) fix the AppServerApi config for .NET 10, (4) restore the database from an
elevated shell — then start the servers (last subsection). Each is a step the original guide
predates.

### Build Tools on the PATH

The server build and the database restore shell out to several tools by bare name. They land on
the machine PATH only after their installers finish, so **open a fresh terminal after the
toolchain is installed** (an older shell, or one spawned by an install task, won't have them).
Confirm all of these resolve in the shell that runs the build and restore:

- `git` — `C:\Program Files\Git\cmd` (NAnt's restore and the build prechecks call it)
- `dotnet` — `C:\Program Files\dotnet` (NAnt's `restore` target runs `dotnet`)
- `MSBuild.exe` — the Visual Studio 18 MSBuild `Bin` (NAnt invokes MSBuild by bare name)
- `nant` — the NAnt `bin` in `tcp-we-thirdparty` (`D:\Work\tcp-we-thirdparty\Nant\0.92\bin`)
- `sqlcmd` — the SQL Client SDK ODBC `Binn` (for example, `C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn`)

Symptoms when one is missing: no `git` makes the build precheck report a missing or invalid
checkout even though the clone is fine; no `dotnet` fails `nant restore` with "'dotnet' failed
to start"; no `sqlcmd` fails the database restore with "sqlcmd is not recognized." A quick check:

```
git --version && dotnet --version && nant -help >/dev/null && MSBuild -version && sqlcmd -?
```

### Exclude the Work Tree from Defender

Windows Defender real-time scanning can lock build outputs (for example `Tcp.Update.dll`) while
the build is writing them, causing intermittent `CS2012` "the process cannot access the file ...
because it is being used by another process" failures. Exclude the work tree before building
(elevated PowerShell):

```
Add-MpPreference -ExclusionPath 'D:\Work'
```

### Each Server Reads Its Own cfg Directory

The applied server config (from `cfg.zip`) lands in the shared `server\Src\Interface\cfg`, but
each launcher reads config from a **per-server** directory instead:

- AppServerApi reads `..\..\..\cfg` (from `bin\Debug\net10.0`), which resolves to `server\Src\Interface\AppServerApi\cfg`
- The other three read `..\..\cfg` (from `bin\Debug`), which resolves to `server\Src\Interface\<Server>\cfg`

When that per-server directory is missing, the server writes a default config that uses port
**8008 for all four servers**, so they collide and only the first to start binds. The rest die
with `AddressAlreadyInUseException` on `http://+:8008/`. Copy the applied cfg into each
per-server directory before starting the servers:

```
IFACE=/cygdrive/d/Work/tcp-we-71/server/Src/Interface
for s in AppServerApi AdmServerApi TerminalHubApi WorkstationHubApi; do
  mkdir -p "$IFACE/$s/cfg"
  cp -rf "$IFACE/cfg/." "$IFACE/$s/cfg/"
done
```

After this, each `<Server>.config` carries its correct port (8008, 8012, 8010, and 8014).

Do this **after** the server build and from an **elevated** context. The build's `nant clean`
can wipe these per-server directories, so populate them after building, not before. Recreate
each directory fresh rather than reusing a stale one, so it picks up clean permissions. The
elevated context matters because the servers run elevated (see the boot task) and must be able
to read these files.

### AppServerApi and the .NET 10 Config Parser

AppServerApi targets .NET 10, whose config loader rejects XML namespaces and fails with "XML
namespaces are not supported." The `AppServerApi.config` from `cfg.zip` ships `xmlns:xsd` and
`xmlns:xsi` attributes on its root element. Strip them from the copy AppServerApi reads (the
.NET Framework servers tolerate the namespaces, so leave their configs alone):

```
sed -i 's/ xmlns:xsi="[^"]*"//g; s/ xmlns:xsd="[^"]*"//g' \
  /cygdrive/d/Work/tcp-we-71/server/Src/Interface/AppServerApi/cfg/AppServerApi.config
```

Only `AppServerApi.config` needs this. `TCPCONN.XML` parses fine under .NET 10.

AppServerApi opens its config for read and write, so the file must be writable and its
permissions must grant the account the server runs under. The config that ships in `cfg.zip`
can carry restrictive permissions, and a copy made in a non-elevated context can inherit
permissions the server can't use, so AppServerApi fails to start with
`UnauthorizedAccessException: Access to the path '...AppServerApi.config' is denied`. Clear the
read-only attribute and grant the `dev` account full control on the AppServerApi cfg directory:

```
attrib -r "D:\Work\tcp-we-71\server\Src\Interface\AppServerApi\cfg\*.*" /s
icacls "D:\Work\tcp-we-71\server\Src\Interface\AppServerApi\cfg" /grant dev:(OI)(CI)F /T
```

`build-vm.sh` automates all of the above in `setup_server_cfg.sh`, which `post_build` runs
after the build in its elevated context.

### Database Restore Requires Sysadmin Rights

SQL Server 2022 is installed with sysadmin granted to `BUILTIN\Administrators`. Under User
Account Control, a process that runs without elevation has the Administrators group filtered
out of its token, so it isn't recognized as a sysadmin and the restore fails with "Login
failed for user." Run the restore and the server-start steps from an **elevated** context (for
example, the boot task that runs with highest privileges) so the `dev` account is a sysadmin.

### Starting the Servers

Start all four (or a subset) from Cygwin:

```
C:\Setup\start_servers.sh all          # all four
C:\Setup\start_servers.sh linclock     # AppServerApi + TerminalHubApi (what a clock needs)
```

Confirm they're up by checking that 8008, 8010, 8012, and 8014 are listening (`netstat -ano -p
tcp`). For a clock device, point its NetworkSettings `serverUrl` at this VM's IP and use a
bridged adapter so the device can reach the VM.

### Open the Firewall for the Server Ports

Windows Firewall blocks inbound by default, so a bridged clock device's connection to the hub
is silently dropped (it hangs) even though the server is listening — only port 22 (SSH) is open
after a plain install. Allow inbound TCP for the server ports (elevated):

```
New-NetFirewallRule -DisplayName "TCP WebEdition servers" -Direction Inbound -Protocol TCP -LocalPort 8008,8010,8012,8014 -Action Allow
```

A quick reachability test from another host: `nc -zv <vm-ip> 8010` (it should report open).
`build-vm.sh` adds this rule automatically in `post_build`.

### Bind the Servers to All Interfaces

Each server builds its listen URL from `<ApiServerHost>:<ApiServerPort>` in its `*.config`.
`cfg.zip` ships `AppServerApi`, `TerminalHubApi`, and `WorkstationHubApi` with `ApiServerHost`
set to `127.0.0.1`, so they bind localhost only (e.g. AppServerApi binds `http://127.0.0.1:8008`)
and a remote device can't reach them directly — opening the firewall isn't enough. Only
`AdmServerApi.config` ships `0.0.0.0` in that field, which is why it binds every interface. Set
the other three to match, in the per-server cfg the launcher reads
(`Src\Interface\<Server>\cfg\<Server>.config`, not the shared `Interface\cfg`):

```
<ApiServerHost>0.0.0.0</ApiServerHost>
```

Then restart the server (e.g. `Stop-Process -Name Tcp.AppServerApi -Force`, then re-run
`start_servers.sh` — or just reboot, since the `TCPStartServers` boot task brings them all
back up). `build-vm.sh` rewrites all three to `0.0.0.0` automatically in `setup_server_cfg.sh`.

## Everything Else Is Unchanged

Follow the original guide as written for: VM creation; the Windows 11 install and the
bypass-check registry entries; partitioning into `C:` and `D:`; Guest Additions; the shared
folder; Cygwin (with `wget` and `nano`); SQL Server 2022 Developer, SQL Server Management
Studio, and the SQL Package (DacFx); OpenJDK 11; Git SSH configuration and key generation;
cloning the repositories; the NAnt environment variable; the AWS environment variables; the
`RemoteSigned` execution policy; adding the GitHub NuGet source; building the server and
client; the server config files (`TCPCONN.XML` and `company-connection-map.xml`); restoring a
test database; creating the SQL logins; nginx and its Windows service; and switching versions.
For starting the servers and the config and restore details that a fresh build depends on, see
Running the Four WebEdition Servers above.

## Final Sanity Check (from the .NET 10 rollout plan)

Restart any open terminal, then in `D:\Work\tcp-we-71\server`:

```
nant __clean-obj-bin restore build
```

Confirm everything restores and builds, then open Visual Studio 2026 and start all services
and confirm they launch. If the build fails, diagnose with:

```
MSBuild -version
dotnet --list-sdks
```

and confirm `MSBUILD_PATH` points at the Visual Studio 18 MSBuild and that the .NET 10 SDK is
listed.

## Faster Alternative

`build-vm.sh` automates this entire guide, including the .NET 10 and Visual Studio 2026
changes above: it creates the VM, installs Windows and the full toolchain unattended, clones
and builds the repositories, applies the server config, restores the database, and starts all
WebEdition servers on boot. See the project README.
