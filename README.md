# Windows 11 TimeClock Plus Dev VM Builder

`build-vm.sh` builds a Windows 11 VirtualBox virtual machine and installs a complete
TimeClock Plus WebEdition development environment, hands-free, from a single command.

It runs as an orchestrator on a Linux host: it performs the actual build **inside the
`vmbuilder` container**, so the host itself needs almost nothing. From one command it pulls
the Windows 11 ISO and the server config from the registry, creates and boots the VM,
installs Windows unattended, installs the full toolchain, clones the private repositories,
builds the server and client, restores a test database, and starts the runtime servers on
every boot. It can also export the finished VM as a portable OVA appliance.

This file is the single source of truth; it replaces the older setup guides.

## Prerequisites (host)

- A Linux host with the VirtualBox kernel module loaded (`/dev/vboxdrv` present).
- Docker.
- The GitHub CLI (`gh`) logged in, or a GitHub token. Credentials are auto-sourced from the
  `gh` login when present and are used for the private-repo clone and the GitHub NuGet source.
- Network access to GitHub Container Registry (`ghcr.io`).

Everything else (the VirtualBox userland, build tools, and the Windows ISO) is provided by
the container or pulled automatically.

## Quick Start

```bash
# Complete hands-free build. GitHub credentials are taken from your gh login; the ISO and
# server config are pulled from ghcr; the VM is created and Windows + the full toolchain are
# installed; the repos are cloned and built; and all servers start on boot.
./build-vm.sh --unattended -y

# Supply credentials explicitly instead of relying on the gh login:
GH_TOKEN=ghp_xxxxxxxx GH_USER=you ./build-vm.sh --unattended -y

# Build, then export a portable OVA appliance to a durable host folder:
./build-vm.sh --unattended --export /mnt/docker.data/win11-ova -y

# Fast end-to-end dry run (dummy installs, ~minutes, no credentials needed) to verify the flow:
./build-vm.sh --unattended --dry-run -y

# Resume a half-finished build (just re-run with the same VM name; the in-guest install is idempotent):
./build-vm.sh --unattended -y
```

A full real build takes roughly two to three hours (Visual Studio and SQL Server dominate).

### Live progress and a timelapse video

Add `--watch` for a live progress stream plus an annotated screenshot timelapse:

```bash
./build-vm.sh --unattended --watch -y                              # build + annotated timelapse
./build-vm.sh --unattended --watch --dry-run -y                    # fast validation with video
./build-vm.sh --unattended --watch --export /mnt/docker.data/win11-ova -y   # build, video, then export
```

With `--watch`, the run streams the in-guest install step (`[guest]`) and the raw installer
log (`[log]`) to the terminal; captures a screenshot every 30 seconds; burns the real step
into each frame as a caption (so the video never looks "stuck" even if the in-guest progress
window freezes); and assembles an mp4 under `.videos/`. The whole host run is tee'd to
`.videos/build-vm-<timestamp>.log`. ffmpeg is resolved automatically (PATH, then
`~/.local/bin`, then a one-time static download) with no `sudo` required.

## Options

| Flag | Meaning |
|---|---|
| `--unattended` | Hands-free install: auto C:/D: partitions, local admin `dev`/`dev`, Guest Additions, full toolchain, clone, build, and server auto-start |
| `--iso PATH` | Windows 11 ISO. Optional; auto-pulled from `ghcr.io/tcp-software/win11-iso:25h2` if omitted |
| `--cfg PATH` | `cfg.zip` server config. Optional; auto-pulled from `ghcr.io/tcp-software/we-cfg:latest` if omitted |
| `--gh-token TOKEN` / `--gh-user USER` | GitHub credentials for the clone and NuGet source. Required for a real run; auto-sourced from the `gh` login or `$GH_TOKEN`/`$GH_USER` |
| `--aws-access-key KEY` / `--aws-secret-key SECRET` | Optional. Set as guest environment variables only. Not needed to build or run the dev server (AWS is used only by runtime features such as S3 and SES) |
| `--watch` | Follow the install live (`[guest]`/`[log]`) and build an annotated screenshot timelapse under `.videos/` |
| `--export DIR` | After the build, power off and export a portable OVA into host directory `DIR` |
| `--export-only DIR` | Skip the build; export the VM already in the running container into `DIR` |
| `--dry-run` | Stage a marker so the in-guest tool install runs dummy steps (each sleeps a few seconds) to verify the whole flow in minutes; no credentials needed |
| `--cpus N` | vCPUs. Default: host cores / 4 (minimum 1) |
| `--memory MB` / `--vram MB` | Guest RAM / video RAM. Defaults: 8192 / 128 |
| `--disk-size MB` / `--disk-type fixed\|dynamic` | Disk size and allocation. Defaults: 262144 (256 GB) / dynamic |
| `--nat` / `--bridge-adapter NAME` | Networking. NAT is the default inside the container (bridged has no DHCP there); choose a bridged adapter so an external clock device can reach the VM |
| `--cache-dir PATH` | In-guest download cache (build-time only). Defaults to a durable host folder so cached installers survive the container and speed up rebuilds |
| `--shared-folder PATH` | Share a host folder into the guest at `G:` |
| `--host-iocache on\|off` | Force the VirtualBox host I/O cache. Default: auto (on for overlay, union, and ZFS filesystems) |
| `--log-file PATH` | Tee the in-guest build transcript here. The host run is also logged to `.videos/build-vm-<timestamp>.log` |
| `--vm-name NAME` / `--base-folder PATH` | VM name and parent directory |
| `--skip-install` | Do not create a VM; only ensure VirtualBox is installed |
| `-y`, `--yes` | Do not prompt for confirmation |
| `-h`, `--help` | Full description, all options, and examples |

## What Gets Installed, Built, and Run

**Windows and accounts:** Windows 11 Pro, installed unattended; the disk is partitioned into
`C:` (Windows) and `D:` (Work); local administrator `dev` / `dev` with auto-logon; Guest
Additions.

**Toolchain:** Cygwin (with `wget` and `nano`) at `D:\Tools\cygwin`; the .NET Framework 3.5;
the .NET SDKs 5, 6, and 10; Visual Studio 2026 Professional (ASP.NET and web, Node.js, .NET
desktop, and Desktop C++ workloads); SQL Server 2022 Developer with SQL Server Management
Studio and the SQL Package (DacFx); OpenJDK 11; Git; Node.js; and Python. The environment
variables `MSBUILD_PATH`, `NANT_BIN`, and `AWS_DEFAULT_REGION` are set.

**Source and build:** the private repositories are cloned to `D:\Work` over HTTPS; the
GitHub NuGet source is added; the server config from `cfg.zip` is applied (`TCPCONN.XML` with
`Integrated` set to true, the hub configs, and the trimmed `company-connection-map.xml`); the
server and client are built; a test database is restored; the SQL logins are created; and
nginx is installed as a Windows service.

**Servers:** all four WebEdition servers start on every boot through a scheduled task
(`TCPStartServers`), so the full stack is up after the build, after a reboot, and in an
exported OVA. Server logs are written to `D:\Tools\serverlogs`.

| Server | Role |
|---|---|
| `AppServerApi` | Employee, manager, and webclock backend. Web UI at `http://localhost:8081/app/manager` |
| `AdmServerApi` | Administration. Web UI at `http://localhost:8018/app/admin` |
| `TerminalHubApi` | Hub that networked clock devices (linclock, winclock, RDTg, POS) connect to |
| `WorkstationHubApi` | Hub for workstation-attached terminals and biometric readers |

The staged credentials are deleted from the guest after use, so an exported OVA carries none.

## Running the Servers and Connecting a Clock Device

The servers start automatically on boot. To start or restart a subset by hand, run in Cygwin:

```bash
C:\Setup\start_servers.sh all          # all four servers
C:\Setup\start_servers.sh linclock     # AppServerApi + TerminalHubApi (what a clock needs)
# also: app | adm | terminal | workstation
```

A clock device such as a **linclock** connects to `TerminalHubApi` (which in turn uses
`AppServerApi` and SQL Server). To point a device at this VM, set its NetworkSettings
`serverUrl` to the VM's IP address. The device must be able to reach the VM on the network,
so build with a **bridged** adapter (`--bridge-adapter NAME`) for real-device testing; NAT is
host-only and is used by default only because bridged has no DHCP inside the container.

## Exporting an OVA Appliance

Add `--export DIR` to a build, or export a VM that is already built without rebuilding:

```bash
./build-vm.sh --unattended --export /mnt/docker.data/win11-ova -y   # build, then export
./build-vm.sh --export-only /mnt/docker.data/win11-ova              # export the existing VM, no rebuild
```

Export powers the VM off (the servers restart on the next boot), exports the VM to an OVA in
the container, and stream-copies it to the host folder. The OVA imports into any VirtualBox
through File > Import Appliance.

## Networking, Server Config, and Cache

- **Networking:** the build runs inside the container, where bridged networking has no DHCP,
  so the guest uses **NAT** by default to get outbound internet. Pass `--bridge-adapter NAME`
  when an external device must reach the VM.
- **Server config (`cfg.zip`):** auto-pulled from ghcr and applied during the build. Provide
  a local copy with `--cfg PATH` to override.
- **Cache:** the download cache defaults to a durable host folder
  (`/mnt/docker.data/win11vbox-cache`, override with `$CACHE_HOST_DIR`) that the orchestrator
  bind-mounts in, so cached installers survive the container and speed up rebuilds. The
  finished VM does not need the cache to run.

## Still Manual

These need a human because they require an interactive sign-in or a deliberate choice:

1. Set a real password for the `dev` account and turn off auto-logon.
2. Sign in to Visual Studio 2026 with a Professional license (Visual Studio installs and
   builds unactivated; sign-in is only for license compliance and cannot be scripted).
3. Optional: use SSH instead of HTTPS for git (`C:\Setup\setup_cygwin_ssh.sh` plus
   `ssh-keygen`, then add the key to GitHub).
4. Optional: add the Cygwin and "Cygwin as Admin" Windows Terminal profiles and the
   `~/.bashrc` / `~/.bash_aliases` convenience configuration.
5. Take a VM snapshot once everything builds and runs.

To try a different release branch later, run `C:\Setup\select_we.sh` in Cygwin (no argument
for an interactive menu of `release/7.x` branches, or pass a branch name). It checks out the
branch and rebuilds the server, the client, and the test database for that version; then
restart the servers with `C:\Setup\start_servers.sh all`.

## Watching Progress and Troubleshooting

- **Progress (headless build):** once Guest Additions are up, read the status file:
  ```bash
  docker exec vmbuilder_run VBoxManage guestcontrol Win11 --username dev --password dev \
    run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c "type D:\Tools\install_status.txt"
  ```
  The status protocol in `install_status.txt` is `N/8 <step>`, `WAIT <msg>`, `ERROR <msg>`,
  or `8/8 Setup complete`. The host run is logged to `.videos/build-vm-<timestamp>.log`; the
  full in-guest install log is `D:\Tools\install_tools.log`.
- **`WAIT Network unavailable`** means the guest has no internet. Inside the container that
  means a bridged NIC with no DHCP; use NAT (the default). A running VM can be switched live
  with `VBoxManage controlvm Win11 nic1 nat`.
- **Screen recording is not used.** VirtualBox's built-in recorder destabilized the guest, so
  the timelapse is built from non-intrusive periodic screenshots instead.
- **`l1d-flush-on-vm-entry` is forced off.** Turning it on cripples VM speed and aborts the
  guest during early boot, so it is intentionally not an option.
- **Resume:** if a VM with the same name exists, the build resumes the idempotent in-guest
  install rather than recreating the VM. To force a clean rebuild, remove it first:
  ```bash
  VBoxManage controlvm Win11 poweroff; VBoxManage unregistervm Win11 --delete
  ```

## Security Note

The GitHub token and any AWS keys are staged in plain text onto the install media and into
`C:\Setup` during the build, then deleted from the guest after use. Treat any credentials
that appeared in the older guides as compromised and rotate them.
