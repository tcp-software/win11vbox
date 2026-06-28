#!/bin/bash
set -euo pipefail

VM_NAME="Win11"
ISO_PATH=""
DISK_SIZE_MB=262144
DISK_TYPE="dynamic"
# Default vCPUs = host cores / 4 (min 1), so the guest never monopolizes the host.
# Override explicitly with --cpus. (Computed where the VM is created - inside the
# vmbuilder container, whose nproc reflects the host's cores.)
CPU_COUNT=$(( $(nproc 2>/dev/null || echo 4) / 4 )); [[ "$CPU_COUNT" -lt 1 ]] && CPU_COUNT=1
MEMORY_MB=6144   # 6 GB: enough for the toolchain build, low enough to avoid OOM-killing the container on a ~31 GB host (8 GB + nant/MSBuild peak exceeded it)
VRAM_MB=128
SHARED_FOLDER_PATH=""
BRIDGE_ADAPTER=""
BASE_FOLDER=""
SKIP_INSTALL=false
UNATTENDED=false
# Download cache shared into the guest (build-time only - see --help). Defaults to a
# DURABLE host path that the orchestrator bind-mounts into the container, so cached
# downloads survive the container and speed up rebuilds. NOTE: the finished VM/OVA does
# NOT need this path to run later - it's only used while installing.
CACHE_HOST_DIR="${CACHE_HOST_DIR:-/mnt/data/win11vbox-cache}"
# The VM (.vdi etc.) goes on a DURABLE host mount, not the container's overlay layer. On the
# overlay, a hard container kill (OOM/exit-137) loses unflushed VirtualBox writes and rolls
# the guest disk back (we lost an 8/8 build to this). A bind-mounted host dir + host I/O cache
# (buffered writes) survives a container restart.
VMSTORE_HOST_DIR="${VMSTORE_HOST_DIR:-/mnt/data/win11vbox-vm}"
CACHE_DIR="${CACHE_DIR:-${HOME}/.cache/win11vbox}"
FORCE_NAT=false
VBOX_PKG="virtualbox-7.1"
DRY_RUN=false
ASSUME_YES=false
LOG_FILE=""
START_TYPE=""
HOST_IOCACHE=""
CFG_PATH=""
GH_TOKEN="${GH_TOKEN:-}"
RESUME=false
CLEAN=false
EXPORT_FILE=""
# --stop-at: stop the build after a chosen stage (default 'all' = full pipeline). --servers:
# which WebEdition servers to start (default 'all'). Both are validated by validate_build_opts.
STOP_AT="all"
SERVERS_SPEC="all"
# cfg.zip (server config: TCPCONN.XML etc.) is pulled from ghcr so the post-build step is
# fully automated - no manual download needed.
CFG_REF="${CFG_REF:-ghcr.io/tcp-software/we-cfg:latest}"
# Credentials are REQUIRED (from these flags or the matching env vars) for a real run; they
# are folded into the guest (clone + NuGet + AWS env) and DELETED from the guest after use,
# so an exported OVA carries none. (--dry-run does not need them.)
GH_USER="${GH_USER:-}"
AWS_ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# Ordered pipeline stages a build can stop AT. 'all' is an alias for 'servers' (the full run).
# 'tools' stops right after the toolchain install, BEFORE the repo clone (the guest skips the
# clone step). 'clone' stops after the toolchain + clone. Both skip post_build; the rest are
# post_build phases. Used by both the host and the in-container parse.
BUILD_STAGES="tools clone server client db cfg servers"
# Echo the 0-based position of stage $1 in BUILD_STAGES, or -1 if unknown.
stage_index(){ local i=0 s; for s in $BUILD_STAGES; do [[ "$s" == "$1" ]] && { echo "$i"; return; }; i=$((i+1)); done; echo -1; }
# Validate a --servers spec (comma/space list of known server tokens). Returns nonzero on a bad token.
valid_servers_spec(){ local t; for t in ${1//,/ }; do case "$t" in app|adm|admin|terminal|workstation|linclock|all) ;; *) return 1 ;; esac; done; return 0; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $*"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*"; }

# Brief usage for argument errors (full docs are in --help).
usage() {
  echo "Usage: ./build-vm.sh --iso /path/to/Win11.iso --unattended [options]"
  echo "Run './build-vm.sh --help' for the full description, all options, and examples."
  exit 1
}

print_help() {
cat <<'EOF'
build-vm.sh - build a Windows 11 VirtualBox developer VM (TimeClock Plus toolchain), unattended.

WHAT IT DOES
  A complete, hands-free end-to-end build. With just your GitHub credentials it: pulls the
  Win11 ISO and cfg.zip from ghcr; creates the VM; remasters the ISO for a no-prompt
  unattended Windows install; boots it; auto-installs Guest Additions and the full dev
  toolchain (Cygwin, Git, Node.js, Python, OpenJDK 11, the .NET SDKs, Visual Studio 2026,
  SQL Server 2022); clones the private tcp-software repos; adds the GitHub NuGet source;
  applies the server config and builds server + client, restores the test DB, creates SQL
  logins, scaffolds nginx, and installs a boot task that starts all four WebEdition servers
  (App, Admin, TerminalHub, WorkstationHub) on every boot (the post-build step, on by
  default); then deletes the staged credentials. Optionally exports the VM as a portable OVA.
  A linclock/clock device connects to TerminalHubApi - which is up automatically.

  Run on the host, the script is an ORCHESTRATOR: it does the actual build inside the
  vmbuilder container (it needs /dev/vboxdrv + docker). If a VM with the same name
  already exists it RESUMES the (idempotent) in-guest install instead of recreating it.

  NOTE: screen recording is intentionally NOT built in - VirtualBox's recorder
  destabilized the guest. For a live progress view + a timelapse video, add --watch.

USAGE
  GH_TOKEN=... GH_USER=... ./build-vm.sh --unattended -y      # ISO + cfg auto-pulled

REQUIRED CREDENTIALS (real run; not needed for --dry-run)
  --gh-token TOKEN       GitHub token for the private-repo clone + GitHub NuGet source
                         (or set $GH_TOKEN). Plaintext-staged in the guest, deleted after use.
  --gh-user USER         GitHub username for the NuGet source (or set $GH_USER)

OPTIONS
  --unattended           Hands-free install: auto C:/D: partitions, local admin dev/dev,
                         Guest Additions + full toolchain + clone + post-build, no keypresses
  --iso PATH             Windows 11 ISO (OPTIONAL - auto-pulled from ghcr win11-iso:25h2 if omitted)
  --cfg PATH             cfg.zip server config (OPTIONAL - auto-pulled from ghcr we-cfg:latest if omitted)
  --vm-name NAME         VM name (default: Win11)
  --cpus N               vCPUs (default: host cores / 4, min 1)
  --memory MB            Guest RAM in MB (default: 8192)
  --vram MB              Video RAM in MB (default: 128)
  --disk-size MB         Virtual disk size in MB (default: 262144)
  --disk-type fixed|dynamic   Disk allocation (default: dynamic)
  --nat                  Force a NAT NIC instead of bridged (use in containers/CI with no DHCP)
  --bridge-adapter NAME  Use a specific bridged adapter (default: auto-detect)
  --shared-folder PATH   Share a host folder into the guest at G:
  --cache-dir PATH       In-guest download cache (build-time only; the finished VM/OVA does
                         NOT need it to run later). Default: a DURABLE host folder
                         ($CACHE_HOST_DIR, default /mnt/data/win11vbox-cache) that the
                         orchestrator bind-mounts in, so it survives the container.
  --aws-access-key KEY   AWS access key id  -> guest env var. OPTIONAL: the WebEdition build
  --aws-secret-key SECRET   and local run do NOT need AWS; these are only for runtime AWS
                         features (S3/SES). (or set $AWS_ACCESS_KEY_ID / $AWS_SECRET_ACCESS_KEY)
  --watch                Follow the in-guest install live ([guest]/[log]) and build an
                         annotated screenshot timelapse under .logs/ (needs no extra tools;
                         ffmpeg is auto-resolved without sudo)
  --export DIR           Wait until EVERYTHING is done (repos cloned, server compiled, all 4
                         servers listening), then power off and export a portable OVA into DIR.
                         Refuses to export a half-built VM.
  --export-only DIR      Skip the build; export the VM already in the running container now
                         (no readiness wait - you're asserting it's ready)
  --dry-run              Stage a marker so the in-guest tool install runs DUMMY steps (each
                         sleeps ~3s) - verifies the whole flow in minutes, no credentials
                         needed. (Formerly --test.)
  --no-container         Build directly on this host's VirtualBox instead of inside the vmbuilder
                         container (alias: --host-build). The host must have VirtualBox + the
                         ISO-remaster tools. Defaults to BRIDGED networking (the host has real
                         DHCP, unlike the container) so the VM is device-reachable; pass --nat or
                         --bridge-adapter NAME to override. The VM lands in VirtualBox's default
                         machine folder. Pair with a fresh --vm-name to avoid clobbering an existing VM.
  --clean                Remove an existing VM of the same name (and any leftover VM files)
                         before building, instead of resuming it. Without it, an existing VM is
                         resumed, and leftover files abort creation with a clear message.
  --stop-at STAGE        Stop the build after STAGE (default: all = full pipeline). Each stage
                         includes all earlier ones; stopping before 'servers' starts none. Stages,
                         in order:
                           tools   - install the full toolchain only, then stop BEFORE cloning
                                     anything (the guest skips the clone step). D:\Work is empty.
                           clone   - + clone the repos to D:\Work, then stop before any compile.
                           server  - + compile the WebEdition server solution (nant build of
                                     tcp-we-7.sln): the four .NET API servers and their deps.
                                     AppServerApi is net10.0; the hubs/admin are .NET Framework
                                     4.7.2 (built by VS MSBuild via nant, not 'dotnet build').
                           client  - + build the browser client (npm): the manager/admin/webclock
                                     web UI assets that nginx serves. Independent of 'server'.
                           db      - + restore the Tcp70ProdTest test database (nant
                                     __restore-db-prod-test), create the SQL logins, and install
                                     nginx as a Windows service.
                           cfg     - + write each server's per-instance cfg and open the firewall
                                     ports. Servers are fully configured but NOT started.
                           servers - + start the selected servers and install the boot task
                                     (= the full run; this is the default).
  --servers SPEC         Which WebEdition servers to start, comma-separated (default: all). The
                         selection persists (D:\Tools\servers.spec) so the boot task starts the
                         same set on every boot. Tokens (raw listen port in parens):
                           app          - AppServerApi      :8008  employee/manager/webclock backend
                           terminal     - TerminalHubApi    :8010  clock-device hub (linclock/POS
                                          connect here; the device-facing port)
                           adm          - AdmServerApi      :8012  admin backend
                           workstation  - WorkstationHubApi :8014  workstation-attached terminals
                           linclock     - app + terminal (8008 + 8010; what a clock device needs)
                           all          - all four
                         e.g. --servers app,terminal. All servers run as the local admin 'dev'
                         with an ELEVATED token (the TCPStartServers task uses /rl highest), which
                         is required because SQL Server grants sysadmin to BUILTIN\Administrators -
                         a non-elevated dev hits "Login failed". They bind 0.0.0.0 (all interfaces).
  --headless             Start the VM headless (auto-selected when no X DISPLAY is present)
  --host-iocache on|off  Force VirtualBox host I/O cache (default: auto - on for
                         overlay/union/ZFS filesystems that can't do O_DIRECT)
  --log-file PATH        Tee a full transcript of the run here (default: ./build-vm-<ts>.log)
  --base-folder PATH     Parent directory for the VM
  --skip-install         Don't create a VM; just ensure VirtualBox is installed
  -y, --yes              Assume yes; don't prompt for confirmation
  -h, --help             Show this help and exit

  Note: cfg.zip (server config) is auto-pulled from ghcr (we-cfg) and applied during the
  default post-build. l1d-flush is forced OFF (turning it on aborts the guest at early boot)
  and screen recording is not used (it destabilized the guest) - both are intentionally not options.

EXAMPLES
  # Complete hands-free build (ISO + cfg auto-pulled; clone + build + post-build by default).
  # Credentials come from the environment - the minimal-interaction default:
  export GH_TOKEN=ghp_xxx GH_USER=myuser
  ./build-vm.sh --unattended -y

  # Live progress + an annotated timelapse video:
  ./build-vm.sh --unattended --watch -y

  # Build, then export a portable OVA appliance into a host folder:
  ./build-vm.sh --unattended --watch --export /mnt/data/win11-ova -y

  # Fast end-to-end DRY RUN (dummy installs, ~minutes; no credentials needed):
  ./build-vm.sh --unattended --dry-run --watch -y

  # Resume a half-finished build (just re-run with the same --vm-name):
  ./build-vm.sh --unattended -y

  # Export only - the VM is already built in the running container, no rebuild:
  ./build-vm.sh --export-only /mnt/data/win11-ova
EOF
}

auto_detect_bridge_adapter() {
  local adapter
  adapter=$(VBoxManage list bridgedifs 2>/dev/null | grep -m1 "^Name:" | sed 's/^Name: *//')
  echo "${adapter:-}"
}

# VirtualBox's default async disk I/O uses O_DIRECT, which overlay/union (and a
# few other) filesystems don't support - I/O then hangs, the guest's AHCI
# controller resets, and the VM aborts during early boot. Enable host I/O cache
# (buffered I/O) on those filesystems so VMs run inside containers (overlayfs).
detect_hostiocache() {
  local dir="$1"
  while [[ -n "$dir" && ! -d "$dir" ]]; do dir=$(dirname "$dir"); done
  local fstype; fstype=$(stat -f -c %T "$dir" 2>/dev/null || echo "")
  case "$fstype" in
    overlayfs|overlay|aufs|tmpfs|fuseblk|zfs|UNKNOWN*) echo on ;;
    *) echo off ;;
  esac
}

# Install VirtualBox 7.x from Oracle's apt repository when VBoxManage isn't on
# PATH. Debian/Ubuntu (apt) only; on anything else we surface a clear message
# instead of guessing. Safe to call when VirtualBox is already present (no-op).
ensure_virtualbox() {
  command -v VBoxManage >/dev/null 2>&1 && return 0

  if ! command -v apt-get >/dev/null 2>&1; then
    log_error "Automatic VirtualBox install supports Debian/Ubuntu (apt) only. Install VirtualBox 7.x manually, then re-run."
    exit 1
  fi

  log_info "VBoxManage not found; installing VirtualBox ${VBOX_PKG#virtualbox-} from Oracle's repository..."

  # Oracle's Debian repo is keyed by distro codename. Use this host's codename,
  # falling back to a recent LTS Oracle publishes if it can't be detected.
  local codename=""
  command -v lsb_release >/dev/null 2>&1 && codename=$(lsb_release -cs 2>/dev/null)
  [[ -z "$codename" && -r /etc/os-release ]] && codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
  case "$codename" in
    jammy|noble|focal|bionic|bookworm|bullseye|trixie) : ;;
    *) log_warn "Unrecognized distro codename '${codename:-unknown}'; defaulting to jammy."; codename="jammy" ;;
  esac

  sudo apt-get update
  sudo apt-get install -y wget gnupg2 lsb-release apt-transport-https ca-certificates dkms curl
  # Kernel headers let dkms build vboxdrv; absent inside containers, which is fine
  # for VBoxManage itself but means VMs can't actually start there.
  sudo apt-get install -y linux-headers-"$(uname -r)" 2>/dev/null \
    || log_warn "Kernel headers for $(uname -r) unavailable; the vboxdrv module may not build (expected inside containers)."
  wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian ${codename} contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y "$VBOX_PKG" || sudo apt-get install -y virtualbox
  sudo /sbin/vboxconfig 2>/dev/null \
    || log_warn "vboxconfig could not load the kernel modules; VMs can't start until vboxdrv is available (a container has no host kernel access)."

  if ! command -v VBoxManage >/dev/null 2>&1; then
    log_error "VirtualBox install ran but VBoxManage is still not on PATH. Install it manually and re-run."
    exit 1
  fi
  log_info "VirtualBox installed: $(VBoxManage --version | head -1)"
}

# VBoxManage's own "unattended install" engine reuses the prompting EFI boot
# image, so the VM still stops at "Press any key to boot from CD or DVD" and
# times out to the EFI boot picker. Instead we remaster the ISO ourselves, which
# needs these tools.
check_unattended_deps() {
  local missing=()
  command -v xorriso >/dev/null 2>&1 || missing+=("xorriso")
  command -v wimlib-imagex >/dev/null 2>&1 || missing+=("wimtools")
  command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 || missing+=("p7zip-full")
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Unattended install needs: ${missing[*]}"
    log_error "Install them with: sudo apt-get install -y ${missing[*]}"
    exit 1
  fi
}

# Build a fully hands-free Windows install ISO from the source ISO:
#   - swaps the prompting EFI boot image (efisys.bin) for efisys_noprompt.bin so
#     EFI boots the DVD with no keypress
#   - drops autounattend.xml at the media root so Setup runs unattended
#   - splits install.wim into <4 GB .swm parts (Setup auto-detects them) so the
#     rebuild needs no UDF, which this xorriso's mkisofs mode can't write
build_noprompt_iso() {
  local src_iso="$1" answer_file="$2" out_iso="$3" stage_dir="${4:-}"
  local work extract volid
  work=$(mktemp -d)
  extract="${work}/iso"
  mkdir -p "$extract"

  log_info "Remastering ISO (no-prompt boot + embedded answer file). This takes a few minutes..."
  7z x "$src_iso" -o"$extract" -bd -y >/dev/null

  if [[ ! -f "${extract}/efi/microsoft/boot/efisys_noprompt.bin" ]]; then
    log_error "ISO has no efisys_noprompt.bin; cannot build a no-prompt installer."
    rm -rf "$work"; return 1
  fi
  rm -rf "${extract}/[BOOT]"   # 7z dumps El Torito images here; not part of the FS tree

  if [[ -f "${extract}/sources/install.wim" ]] \
     && [[ $(stat -c%s "${extract}/sources/install.wim") -gt 4000000000 ]]; then
    log_info "Splitting install.wim into <4 GB .swm parts..."
    wimlib-imagex split "${extract}/sources/install.wim" "${extract}/sources/install.swm" 3800 >/dev/null
    rm -f "${extract}/sources/install.wim"
  fi

  cp "$answer_file" "${extract}/autounattend.xml"

  # Ship helper scripts under \setup\ so first-logon automation can stage them.
  # Convert Windows scripts to CRLF - cmd.exe mis-parses batch files with bare LF.
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    mkdir -p "${extract}/setup"
    cp -r "$stage_dir"/. "${extract}/setup/"
    find "${extract}/setup" -type f \( -name '*.cmd' -o -name '*.bat' -o -name '*.ps1' -o -name '*.reg' \) \
      -exec sed -i 's/\r$//; s/$/\r/' {} +
  fi

  volid=$(xorriso -indev "$src_iso" -report_el_torito plain 2>/dev/null \
            | sed -n "s/^Volume id *: *'\(.*\)'.*/\1/p" | head -1)
  [[ -n "$volid" ]] || volid="CCCOMA_X64FRE_EN-US_DV9"

  ( cd "$extract" && xorriso -as mkisofs \
      -iso-level 3 \
      -volid "$volid" \
      -J -joliet-long \
      -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table -hide boot.catalog \
      -eltorito-alt-boot -eltorito-platform efi \
      -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
      -o "$out_iso" \
      . ) >/dev/null 2>&1

  local rc=$?
  rm -rf "$work"
  [[ $rc -eq 0 && -f "$out_iso" ]]
}

# ============================================================================
# HOST ORCHESTRATOR
# When run on the host (i.e. NOT already inside the vmbuilder container), keep the
# host footprint minimal - only the vboxdrv kernel module + Docker + oras - then
# fetch the Win11 ISO (oras, cached) and the vmbuilder image (docker), run the
# container, and re-invoke THIS script inside it (VMBUILDER_INNER=1) to do the real
# VM build. Everything else installs in the container, never on the host.
# Set VMBUILDER_INNER=1 (done automatically for the in-container exec) to skip this
# and run the build logic directly.
# ============================================================================
VMBUILDER_IMAGE="${VMBUILDER_IMAGE:-ghcr.io/tcp-software/vmbuilder:latest}"
WIN11_ISO_REF="${WIN11_ISO_REF:-ghcr.io/tcp-software/win11-iso:25h2}"
HOST_ISO_PATH=""

ensure_host_vboxdrv() {
  # The host kernel must provide /dev/vboxdrv (containers cannot load kernel modules).
  if [[ ! -e /dev/vboxdrv ]]; then
    log_info "vboxdrv missing on host; installing VirtualBox for the kernel module..."
    ensure_virtualbox
    sudo /sbin/vboxconfig 2>/dev/null || sudo modprobe vboxdrv 2>/dev/null || true
  fi
  [[ -e /dev/vboxdrv ]] || { log_error "/dev/vboxdrv still missing. Install VirtualBox on the host and run: sudo /sbin/vboxconfig"; exit 1; }
  # Make the device group-accessible so the container's user can open it.
  sudo chgrp vboxusers /dev/vboxdrv 2>/dev/null || true
  sudo chmod 660 /dev/vboxdrv 2>/dev/null || true
  log_success "Host vboxdrv ready ($(ls -l /dev/vboxdrv 2>/dev/null))"
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 && { log_info "Docker present: $(docker --version 2>/dev/null)"; return 0; }
  log_info "Installing Docker (get.docker.com)..."
  curl -fsSL https://get.docker.com | sudo sh || { log_error "Docker install failed; install Docker and re-run."; exit 1; }
}

ensure_oras() {
  command -v oras >/dev/null 2>&1 && { log_info "oras present: $(oras version 2>/dev/null | head -1)"; return 0; }
  log_info "Installing oras..."
  local ver="1.2.0" tmp; tmp=$(mktemp -d)
  if curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ver}/oras_${ver}_linux_amd64.tar.gz" -o "$tmp/oras.tgz" \
     && tar -xzf "$tmp/oras.tgz" -C "$tmp" oras; then
    sudo install -m755 "$tmp/oras" /usr/local/bin/oras && log_success "oras installed: $(oras version 2>/dev/null | head -1)"
  else
    log_error "Could not install oras (needed to pull the Win11 ISO)."; rm -rf "$tmp"; exit 1
  fi
  rm -rf "$tmp"
}

ghcr_login() {
  [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]] || { log_warn "GHCR_USER/GHCR_TOKEN not set; assuming ghcr is already authenticated."; return 0; }
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 \
    && log_info "docker logged in to ghcr.io" || log_warn "docker login to ghcr failed."
  echo "$GHCR_TOKEN" | oras login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 \
    && log_info "oras logged in to ghcr.io" || log_warn "oras login to ghcr failed."
}

oras_pull_iso() {
  # Fetch the Win11 ISO from ghcr via oras, CACHED: skip the pull if one is present.
  mkdir -p "$CACHE_DIR/iso"
  HOST_ISO_PATH=$(ls "$CACHE_DIR"/iso/*.iso 2>/dev/null | head -1 || true)
  if [[ -n "$HOST_ISO_PATH" ]]; then
    log_info "Win11 ISO already cached: $HOST_ISO_PATH (skipping oras pull)"; return 0
  fi
  log_info "Pulling Win11 ISO from $WIN11_ISO_REF via oras (large, one-time)..."
  ( cd "$CACHE_DIR/iso" && oras pull "$WIN11_ISO_REF" ) || { log_error "oras pull of the Win11 ISO failed."; exit 1; }
  HOST_ISO_PATH=$(ls "$CACHE_DIR"/iso/*.iso 2>/dev/null | head -1 || true)
  [[ -n "$HOST_ISO_PATH" ]] || { log_error "No .iso found after 'oras pull $WIN11_ISO_REF'."; exit 1; }
  log_success "Win11 ISO ready: $HOST_ISO_PATH"
}

oras_pull_cfg() {
  # Fetch cfg.zip (server config: TCPCONN.XML etc.) from ghcr so the post-build step needs
  # no manual file. Cached next to the ISO so it's mounted into the container at /iso/cfg.zip.
  mkdir -p "$CACHE_DIR/iso"
  if [[ -s "$CACHE_DIR/iso/cfg.zip" ]]; then
    log_info "cfg.zip already cached (skipping pull)."; return 0
  fi
  log_info "Pulling cfg.zip from $CFG_REF via oras..."
  if ( cd "$CACHE_DIR/iso" && oras pull "$CFG_REF" ) && [[ -s "$CACHE_DIR/iso/cfg.zip" ]]; then
    log_success "cfg.zip ready: $CACHE_DIR/iso/cfg.zip"
  else
    log_warn "Could not fetch cfg.zip from $CFG_REF; the post-build server config will be skipped."
  fi
}

run_host_orchestrator() {
  export LOGNAME="${LOGNAME:-$(whoami)}" USER="${USER:-$(whoami)}"
  log_info "Host orchestrator: minimal host setup, then build inside the vmbuilder container."

  # Auto-source GitHub credentials from the gh CLI / its stored config, so the user doesn't
  # have to set $GH_TOKEN / $GH_USER by hand. Tries the env first, then `gh auth token`, then
  # the oauth_token/user in ~/.config/gh/hosts.yml. (Explicit --gh-token/--gh-user still win.)
  local _hosts="${HOME}/.config/gh/hosts.yml"
  if [[ -z "$GH_TOKEN" ]]; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    [[ -z "$GH_TOKEN" && -f "$_hosts" ]] && GH_TOKEN="$(sed -n 's/^[[:space:]]*oauth_token:[[:space:]]*//p' "$_hosts" | head -1)"
  fi
  if [[ -z "$GH_USER" ]]; then
    GH_USER="$(gh api user -q .login 2>/dev/null || true)"
    [[ -z "$GH_USER" && -f "$_hosts" ]] && GH_USER="$(sed -n 's/^[[:space:]]*user:[[:space:]]*//p' "$_hosts" | head -1)"
  fi
  [[ -n "$GH_TOKEN" && -n "$GH_USER" ]] && log_info "Using GitHub credentials from the gh CLI (user: $GH_USER)."

  # Fail fast on missing GitHub credentials (required for a real run), before any heavy work.
  local _dry=false _a _pv=""
  for _a in "$@"; do [[ "$_a" == "--dry-run" ]] && _dry=true; done
  if [[ "$_dry" != true ]]; then
    local _tok="$GH_TOKEN" _usr="$GH_USER"
    for _a in "$@"; do
      [[ "$_pv" == "--gh-token" ]] && _tok="$_a"
      [[ "$_pv" == "--gh-user"  ]] && _usr="$_a"
      _pv="$_a"
    done
    if [[ -z "$_tok" || -z "$_usr" ]]; then
      log_error "GitHub credentials required and none found. Log in once with 'gh auth login',"
      log_error "or set \$GH_TOKEN + \$GH_USER (or pass --gh-token/--gh-user), or use --dry-run. See --help."
      exit 1
    fi
  fi

  ensure_host_vboxdrv
  [[ "$NO_CONTAINER" == true ]] || ensure_docker
  ensure_oras
  ghcr_login
  oras_pull_iso
  # cfg.zip: use a provided --cfg (placed where the /iso mount can see it), else pull from ghcr.
  local _cfg="" _pcfg=""
  for _a in "$@"; do [[ "$_pcfg" == "--cfg" ]] && _cfg="$_a"; _pcfg="$_a"; done
  if [[ -n "$_cfg" ]]; then
    [[ -f "$_cfg" ]] || { log_error "--cfg file not found: $_cfg"; exit 1; }
    mkdir -p "$CACHE_DIR/iso"; cp -f "$_cfg" "$CACHE_DIR/iso/cfg.zip"
    log_success "Using provided cfg.zip: $_cfg"
  else
    oras_pull_cfg
  fi
  # An explicit --iso on the command line overrides the oras-fetched ISO.
  local a prev=""
  for a in "$@"; do [[ "$prev" == "--iso" ]] && HOST_ISO_PATH="$a"; prev="$a"; done

  # --no-container: build directly on the host instead of inside the vmbuilder container. Same
  # inner build path, just with host paths and host VirtualBox, and bridged by default (the host
  # has real DHCP, unlike the container). No docker pull / run / exec.
  if [[ "$NO_CONTAINER" == true ]]; then
    log_info "Host build (--no-container): using host VirtualBox; VM in the default machine folder."
    local repo_dir; repo_dir=$(cd "$(dirname "$0")" && pwd)
    local inner_args=(); prev=""
    for a in "$@"; do
      if [[ "$prev" == "--iso" || "$prev" == "--cfg" || "$prev" == "--export" || "$prev" == "--export-only" ]]; then prev=""; continue; fi
      case "$a" in
        --iso|--cfg|--export|--export-only) prev="$a"; continue ;;   # flag + value: re-added / host-side
        --watch|--no-container|--host-build) continue ;;             # host-side / not inner flags
      esac
      inner_args+=("$a"); prev=""
    done
    inner_args+=(--iso "$HOST_ISO_PATH" --cache-dir "$CACHE_DIR")
    # Networking: the host has real bridged DHCP, so default to bridged (device-reachable) unless
    # the caller chose --nat / --bridge-adapter. Prefer the default-route interface; skip docker/veth.
    local _net_specified=false
    for a in "$@"; do [[ "$a" == "--nat" || "$a" == "--bridge-adapter" ]] && _net_specified=true; done
    if [[ "$_net_specified" == false ]]; then
      local _routeif _adp=""
      _routeif="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
      while IFS= read -r _n; do [[ "$_n" == "$_routeif" ]] && { _adp="$_n"; break; }; done < <(VBoxManage list bridgedifs 2>/dev/null | sed -n 's/^Name: *//p')
      [[ -z "$_adp" ]] && _adp="$(VBoxManage list bridgedifs 2>/dev/null | sed -n 's/^Name: *//p' | grep -vE '^(docker|veth|virbr)' | head -1)"
      if [[ -n "$_adp" ]]; then inner_args+=(--bridge-adapter "$_adp"); log_info "Host build: bridged via auto-detected adapter '$_adp'."
      else inner_args+=(--nat); log_warn "No bridged adapter found; falling back to NAT."; fi
    fi
    # The ISO remaster extracts the ~8 GB ISO and splits install.wim in $TMPDIR (default /tmp).
    # On a host /tmp is often small (here / has ~11 GB), which runs out mid-split. Point TMPDIR at
    # the roomy cache volume (the container has a large overlay /tmp, so this only matters on host).
    # Use the cache volume's parent (writable by this user) - the cache dir itself may be root-owned
    # from prior container builds. Fall back to default /tmp with a warning if it isn't writable.
    local _hosttmp; _hosttmp="$(dirname "$CACHE_HOST_DIR")/win11-build-tmp"
    if ! mkdir -p "$_hosttmp" 2>/dev/null || [[ ! -w "$_hosttmp" ]]; then
      log_warn "Could not use $_hosttmp for temp; falling back to default \$TMPDIR (ensure /tmp has ~15 GB free)."
      _hosttmp=""
    else
      log_info "Host build: remaster/temp dir -> $_hosttmp (avoids small /tmp)."
    fi
    log_info "Running the build on the host: ./build-vm.sh $(printf '%q ' "${inner_args[@]}")"
    VMBUILDER_INNER=1 LOGNAME="$(whoami)" USER="$(whoami)" TMPDIR="$_hosttmp" \
      GH_TOKEN="${GH_TOKEN:-}" GH_USER="${GH_USER:-}" \
      AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY:-}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY:-}" \
      bash "$0" "${inner_args[@]}"
    return $?
  fi

  log_info "Pulling container image: $VMBUILDER_IMAGE"
  # Refresh the image, but DON'T abort on a pull failure (transient DNS/registry, or
  # offline) when a local copy already exists - fall back to it so the build is resilient.
  if ! docker pull "$VMBUILDER_IMAGE"; then
    if docker image inspect "$VMBUILDER_IMAGE" >/dev/null 2>&1; then
      log_warn "docker pull failed (registry/DNS?); using the locally cached image."
    else
      log_error "docker pull $VMBUILDER_IMAGE failed and no local image is present."; exit 1
    fi
  fi
  # Re-pass all original args but point --iso at the in-container mount path.
  local repo_dir iso_dir iso_base; repo_dir=$(cd "$(dirname "$0")" && pwd)
  iso_dir=$(dirname "$HOST_ISO_PATH"); iso_base=$(basename "$HOST_ISO_PATH")
  # Strip host-only flags: --iso/--cfg (the orchestrator places those itself) and the
  # watch/export flags (handled host-side after the build, never inside the container).
  local inner_args=(); prev=""
  for a in "$@"; do
    if [[ "$prev" == "--iso" || "$prev" == "--cfg" || "$prev" == "--export" || "$prev" == "--export-only" ]]; then prev=""; continue; fi
    case "$a" in
      --iso|--cfg|--export|--export-only) prev="$a"; continue ;;   # flag + its value dropped
      --watch) continue ;;                                          # boolean flag dropped
    esac
    inner_args+=("$a"); prev=""
  done
  inner_args+=(--iso "/iso/$iso_base")
  # Durable host folder for the download cache, bind-mounted into the container, so cached
  # installers survive the container and speed up rebuilds. (docker auto-creates the path.)
  inner_args+=(--cache-dir /cache)
  # The build ALWAYS runs inside the vmbuilder container, where bridged networking gets no
  # DHCP (so the guest would have no internet and the tool install would stall at netwait).
  # Force NAT by default so the guest has outbound internet. A user who deliberately wants
  # bridged (e.g. so a real clock device can reach the VM on the LAN) can pass
  # --bridge-adapter NAME, which suppresses this. NOTE: a NAT guest is host-only - a separate
  # linclock on the network can't reach it without port-forwarding.
  local _net_specified=false
  for a in "$@"; do [[ "$a" == "--nat" || "$a" == "--bridge-adapter" ]] && _net_specified=true; done
  [[ "$_net_specified" == false ]] && { inner_args+=(--nat); log_info "Defaulting guest NIC to NAT (container has no bridged DHCP). Use --bridge-adapter to override."; }
  # Put the VM on the durable host mount (survives a container restart) + buffered host I/O
  # cache (so writes flush) - unless the caller chose their own --base-folder.
  local _bf_specified=false
  for a in "$@"; do [[ "$a" == "--base-folder" ]] && _bf_specified=true; done
  if [[ "$_bf_specified" == false ]]; then
    inner_args+=(--base-folder /vmstore --host-iocache on)
    log_info "VM store -> host:$VMSTORE_HOST_DIR (durable; survives container restart)."
  fi
  mkdir -p "$VMSTORE_HOST_DIR" 2>/dev/null || sudo mkdir -p "$VMSTORE_HOST_DIR" 2>/dev/null || true
  local cname="vmbuilder_run"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  log_info "Starting container '$cname' (cache -> host:$CACHE_HOST_DIR) and running the build inside it..."
  docker run -d --name "$cname" --user root \
    --device /dev/vboxdrv --device /dev/vboxdrvu \
    -v "$repo_dir:/work/win11vbox" -v "$iso_dir:/iso" -v "$CACHE_HOST_DIR:/cache" -v "$VMSTORE_HOST_DIR:/vmstore" \
    "$VMBUILDER_IMAGE" sleep infinity >/dev/null || { log_error "docker run failed."; exit 1; }
  docker exec -e VMBUILDER_INNER=1 -e LOGNAME=root -e USER=root \
    -e GH_TOKEN="${GH_TOKEN:-}" -e GH_USER="${GH_USER:-}" \
    -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY:-}" -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY:-}" \
    "$cname" bash -lc "cd /work/win11vbox && ./build-vm.sh $(printf '%q ' "${inner_args[@]}")"
}

# --help / -h must be instant and side-effect-free: handle it BEFORE any host
# orchestration (no docker pull, no container start).
for _a in "$@"; do case "$_a" in -h|--help) print_help; exit 0 ;; esac; done

# ===================== Host-side extras (only used by the orchestrator) =====================
# --watch       : follow the in-guest install live and build an annotated screenshot timelapse
# --export DIR  : after the build, export a portable OVA to host DIR
# --export-only DIR : skip the build; just export the VM already in the running container
HC="vmbuilder_run"
HVM="$VM_NAME"
HREPO="$(cd "$(dirname "$0")" && pwd)"
HVID="$HREPO/.logs"
# Canned Windows-install screenshots prepended to the --watch timelapse. The live capture
# (capture_screens.ps1) only starts at the dev auto-logon, so it misses the pre-logon OS
# install; these frames fill that gap. Tracked in git (unlike .logs/). See its README.
HINTRO="$HREPO/assets/timelapse-install-frames"
# '|| true' is REQUIRED: under 'set -euo pipefail', if /usr/share/fonts is absent (as in the
# container) find exits non-zero, pipefail propagates it, and the bare assignment would make
# set -e kill the whole script here - silently, before ensure_virtualbox even runs.
HFONT="$(find /usr/share/fonts -name 'DejaVuSans.ttf' 2>/dev/null | head -1 || true)"
WATCH=false; EXPORT_DIR=""; EXPORT_ONLY=""; DRYRUN=false; NO_CONTAINER=false; _pv=""
for _a in "$@"; do
  case "$_pv" in
    --export)      EXPORT_DIR="$_a" ;;
    --export-only) EXPORT_DIR="$_a"; EXPORT_ONLY=1 ;;
    --stop-at)     STOP_AT="$_a" ;;
    --servers)     SERVERS_SPEC="$_a" ;;
  esac
  [[ "$_a" == "--watch" ]] && WATCH=true
  [[ "$_a" == "--dry-run" ]] && DRYRUN=true
  [[ "$_a" == "--no-container" || "$_a" == "--host-build" ]] && NO_CONTAINER=true
  _pv="$_a"
done
# Normalize + validate the new options up front so a typo fails fast (before the container spins
# up) - but only on a build run. --export-only ignores these flags entirely, so a stale value in
# the user's shell history must not reject a pure re-export.
WAIT_PORTS=""
if [[ -z "$EXPORT_ONLY" ]]; then
  # 'all' is the full pipeline; map it to its concrete final stage 'servers'. An empty/whitespace
  # --servers means 'all' (matching start_servers.sh), so the host's readiness gate covers the
  # same servers the guest actually starts rather than diverging to the no-servers path.
  [[ "$STOP_AT" == "all" ]] && STOP_AT="servers"
  [[ -z "${SERVERS_SPEC// /}" ]] && SERVERS_SPEC="all"
  if [[ "$(stage_index "$STOP_AT")" == "-1" ]]; then
    log_error "--stop-at: unknown stage '$STOP_AT'. Valid: ${BUILD_STAGES// /, }, all (default)."; exit 2
  fi
  valid_servers_spec "$SERVERS_SPEC" || { log_error "--servers: unknown token in '$SERVERS_SPEC'. Valid: app, adm, terminal, workstation, linclock, all (comma-separated)."; exit 2; }
  # Ports the host should wait for (export gate + --watch stop). Only the SELECTED servers start,
  # and only when the build runs through the 'servers' stage; an earlier --stop-at starts none.
  if [[ "$STOP_AT" == "servers" ]]; then
    for _t in ${SERVERS_SPEC//,/ }; do
      case "$_t" in
        app) WAIT_PORTS+=" 8008" ;; adm|admin) WAIT_PORTS+=" 8012" ;; terminal) WAIT_PORTS+=" 8010" ;;
        workstation) WAIT_PORTS+=" 8014" ;; linclock) WAIT_PORTS+=" 8008 8010" ;;
        all) WAIT_PORTS="8008 8010 8012 8014" ;;
      esac
    done
    WAIT_PORTS="$(printf '%s\n' $WAIT_PORTS | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  fi
  [[ "$STOP_AT" != "servers" ]] && log_info "--stop-at $STOP_AT: build will stop after that stage (servers not started)."
  [[ "$STOP_AT" == "servers" && "$SERVERS_SPEC" != "all" ]] && log_info "--servers $SERVERS_SPEC: starting only [$WAIT_PORTS]."
fi

# VBoxManage wrapper used by the host-side helpers (gst/glg, wait_for_ready, watch_capture,
# do_export). With --no-container it's the host's VBoxManage directly; otherwise it runs inside
# the vmbuilder container (HOME=/root is where the container's VM is registered; full path
# because a non-login exec has no PATH).
if [[ "$NO_CONTAINER" == true ]]; then
  gx(){ VBoxManage "$@"; }
  # In host mode the "is the build infra alive?" check is just "is the VM still registered?".
  infra_alive(){ VBoxManage showvminfo "$HVM" >/dev/null 2>&1; }
else
  gx(){ docker exec -e HOME=/root "$HC" /usr/bin/VBoxManage "$@"; }
  infra_alive(){ docker inspect -f '{{.State.Running}}' "$HC" 2>/dev/null | grep -q true; }
fi
gst(){ gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_status.txt' 2>/dev/null | tr -d '\r' | grep -v WARNING | tail -1; }
glg(){ gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_tools.log' 2>/dev/null | tr -d '\r' | grep -v '^WARNING:'; }
# type a guest file if it exists (empty output if absent); $1 = Windows path.
gcat(){ gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c "if exist $1 type $1" 2>/dev/null | tr -d '\r' | grep -v WARNING || true; }
# Probe guest build readiness for the current --stop-at/--servers selection. Echoes one of:
#   ready  - selected servers all LISTENING, or (no servers expected) D:\Tools\build.done present
#   failed - guest reported CLONE-FAILED (build can't finish)
#   wait   - not done yet
# Shared by wait_for_ready (the --export gate) and watch_capture (the --watch stop) so the two
# never drift, and so BOTH honor CLONE-FAILED and a subset/no-server selection.
probe_build_ready(){
  local ns ok p
  case "$(gcat 'D:\Work\clone_status.txt')" in *CLONE-FAILED*) echo failed; return ;; esac
  if [[ -z "$WAIT_PORTS" ]]; then
    [[ -n "$(gcat 'D:\Tools\build.done')" ]] && { echo ready; return; }
  else
    ns="$(gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'netstat -ano -p tcp' 2>/dev/null | tr -d '\r' || true)"
    ok=true; for p in $WAIT_PORTS; do printf '%s\n' "$ns" | grep -E ":$p\b" | grep -q LISTENING || ok=false; done
    [[ "$ok" == true ]] && { echo ready; return; }
  fi
  echo wait
}

ensure_ffmpeg(){
  FFMPEG="$(command -v ffmpeg || true)"
  [[ -z "$FFMPEG" && -x "$HOME/.local/bin/ffmpeg" ]] && FFMPEG="$HOME/.local/bin/ffmpeg"
  if [[ -z "$FFMPEG" ]]; then
    log_info "Fetching a static ffmpeg to ~/.local/bin (no sudo)..."
    mkdir -p "$HOME/.local/bin"
    if curl -fsSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz -o /tmp/ff_bv.tar.xz 2>/dev/null \
       && tar -xJf /tmp/ff_bv.tar.xz -C /tmp 2>/dev/null \
       && cp /tmp/ffmpeg-*-amd64-static/ffmpeg "$HOME/.local/bin/ffmpeg" 2>/dev/null; then
      chmod +x "$HOME/.local/bin/ffmpeg"; FFMPEG="$HOME/.local/bin/ffmpeg"
    fi
  fi
  [[ -n "$FFMPEG" ]] && log_info "ffmpeg: $FFMPEG" || log_warn "ffmpeg unavailable - frames will be saved, but no video assembled."
}

# Power off the existing VM, export it to an OVA, and stream-copy it to host $EXPORT_DIR
# (the container can't see that path, so export to the overlay and copy via a helper).
do_export(){
  local ts OVA OVERLAY
  ts="$(date +%Y%m%d-%H%M%S)"; OVA="Win11-WebEdition-${ts}.ova"; OVERLAY="/root/$OVA"
  log_info "Exporting OVA to host:$EXPORT_DIR (powers the VM off; servers restart on the next boot)"
  gx controlvm "$HVM" acpipowerbutton >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [[ "$(gx showvminfo "$HVM" --machinereadable 2>/dev/null | sed -n 's/^VMState=//p' | tr -d '"')" == poweroff ]] && break; sleep 6; done
  gx controlvm "$HVM" poweroff >/dev/null 2>&1 || true; sleep 6
  log_info "Exporting (large; a few minutes)..."
  if [[ "$NO_CONTAINER" == true ]]; then
    # Host build: VBoxManage is local, so export straight into the host folder - no copy dance.
    mkdir -p "$EXPORT_DIR"
    gx export "$HVM" -o "$EXPORT_DIR/$OVA" --vsys 0 --product "TCP Win11 Dev VM ($ts)" || { log_error "export failed"; return 1; }
    chmod 644 "$EXPORT_DIR/$OVA" 2>/dev/null || true
    log_success "OVA: $EXPORT_DIR/$OVA ($(du -h "$EXPORT_DIR/$OVA" 2>/dev/null | cut -f1))"
    return 0
  fi
  gx export "$HVM" -o "$OVERLAY" --vsys 0 --product "TCP Win11 Dev VM ($ts)" || { log_error "export failed"; return 1; }
  docker rm -f ova_dest >/dev/null 2>&1 || true
  docker run -d --name ova_dest -v "$EXPORT_DIR":/out "$VMBUILDER_IMAGE" sleep infinity >/dev/null
  log_info "Copying OVA to $EXPORT_DIR ..."
  docker cp "$HC:$OVERLAY" - | docker cp - ova_dest:/out
  docker exec ova_dest sh -lc "chmod 644 /out/'$OVA'; ls -lh /out/'$OVA'"
  docker exec "$HC" rm -f "$OVERLAY" 2>/dev/null || true
  docker rm -f ova_dest >/dev/null 2>&1 || true
  log_success "OVA: $EXPORT_DIR/$OVA"
}

# Block until the in-guest build is FULLY done before exporting: repos cloned, the server
# compiled, and all four WebEdition servers actually LISTENING. Returns non-zero on a clone
# failure, a dead container, or a timeout - so --export never produces a half-built OVA.
# (This is "everything is finally done": 8/8 alone is just the toolchain, written before the
# clone/compile/server-start even run.)
wait_for_ready(){
  local i
  # A dry run installs nothing and starts no servers (and writes no build.done), so "done" simply
  # means the dummy install loop reached 8/8. Without this, the port/build.done wait below would
  # loop to the timeout and refuse to export a dry-run VM.
  if [[ "$DRYRUN" == true ]]; then
    log_info "Dry run: waiting for the install to reach 8/8 before export (no servers start)."
    for i in $(seq 1 60); do
      infra_alive || { log_error "build infra gone while waiting (container stopped / VM unregistered) - not exporting."; return 1; }
      case "$(gst || true)" in *"Setup complete"*) log_success "dry run reached 8/8 - ready to export."; return 0 ;; esac
      sleep 30
    done
    log_error "dry run did not reach 8/8 in time - not exporting."; return 1
  fi
  if [[ -z "$WAIT_PORTS" ]]; then
    log_info "Waiting for the build to finish before export (--stop-at $STOP_AT; no servers start)."
  else
    log_info "Waiting for the build to fully finish before export: clone -> compile -> servers listening ($WAIT_PORTS)."
  fi
  log_info "(This runs well past 8/8 - it can take 1-2h more for the clone, server build, and startup.)"
  # 420 min (~7h): the in-container VirtualBox apt-install, Windows install, the toolchain
  # (SQL + VS), and the serial clone can all run slow under host I/O contention (a 4h cap timed
  # out a healthy-but-slow run). Generous so a slow run still finishes and exports.
  for i in $(seq 1 420); do
    infra_alive || { log_error "build infra gone while waiting (container stopped / VM unregistered) - not exporting."; return 1; }
    case "$(probe_build_ready)" in
      ready)  log_success "build ready (${WAIT_PORTS:-stopped per --stop-at $STOP_AT}) - exporting."; return 0 ;;
      failed) log_error "in-guest clone FAILED - not exporting (fix the token/network, re-run)."; return 1 ;;
    esac
    [[ $((i % 5)) -eq 0 ]] && log_info "still building... (~${i} min elapsed)"
    sleep 60
  done
  log_error "timed out (~7h) waiting for the build to finish - not exporting; VM left running for inspection."
  return 1
}

# Encode a timelapse mp4 from a frame glob ($2, e.g. "$GDIR/shot-*.png"), prepending the canned
# Windows-install frames from $HINTRO when present so the video covers the pre-logon OS install
# the live capture can't see. The intro frames are scaled to the live-capture size (scale2ref)
# so mismatched resolutions still concat cleanly. Echoes the number of intro frames prepended.
encode_timelapse(){
  local out="$1" glob="$2" intro_n=0 first w h
  [[ -d "$HINTRO" ]] && intro_n=$(ls "$HINTRO"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$intro_n" -gt 0 ]]; then
    # Scale BOTH legs to the live-capture size, then concat - so all frames survive (scale2ref
    # would couple the two streams' frame counts and truncate the longer one). Probe the size
    # from the first live frame; fall back to this VM's default 1024x768 if ffprobe is absent.
    first=$(ls $glob 2>/dev/null | head -1)
    if [[ -n "$first" && -x "${FFMPEG%ffmpeg}ffprobe" ]]; then
      IFS=',' read -r w h < <("${FFMPEG%ffmpeg}ffprobe" -v error -select_streams v \
        -show_entries stream=width,height -of csv=p=0 "$first" 2>/dev/null)
    fi
    w="${w:-1024}"; h="${h:-768}"
    "$FFMPEG" -y -loglevel error \
      -framerate 10 -start_number 0 -i "$HINTRO/frame-%05d.png" \
      -framerate 10 -pattern_type glob -i "$glob" \
      -filter_complex "[0:v]scale=${w}:${h},setsar=1[i];[1:v]scale=${w}:${h},setsar=1[s];[i][s]concat=n=2:v=1:a=0,format=yuv420p[v]" \
      -map "[v]" "$out"
  else
    "$FFMPEG" -y -loglevel error -framerate 10 -pattern_type glob -i "$glob" \
      -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" "$out"
  fi
  echo "$intro_n"
}

# Point a stable "latest-*" symlink at the freshest artifact (relative target so it stays valid
# if .logs is moved/copied). Used for the newest build log and the newest timelapse video.
link_latest(){ ln -sfn "$(basename "$2")" "$HVID/$1" 2>/dev/null || true; }

# Follow the in-guest install (streaming [guest]/[log]) and assemble a timelapse mp4. Frames
# come from capture_screens.ps1 running INSIDE the guest's interactive session - it grabs the
# live desktop and burns the step caption in. That is reliable; host-side VBoxManage
# screenshotpng in headless mode FREEZES on one image because the SVGA framebuffer isn't
# refreshed without a display front-end attached (the timelapse used to get stuck on the SQL
# step). Host screenshots are still taken as a fallback in case the guest capture didn't run.
watch_capture(){
  local FRAMES="$HVID/frames" GSHOTS="$HVID/gshots" ts MAN OUT n=0 last="" idle=0 loglines=0 full total st rel f s safe post88=false ns ready p bd
  ts="$(date +%Y%m%d-%H%M%S)"; MAN="$HVID/.frames-${ts}.manifest"; OUT="$HVID/${ts}-timelapse.mp4"
  # Clear stale frames from a prior run so the glob doesn't mix two runs into one video.
  rm -rf "$FRAMES" "$GSHOTS"; mkdir -p "$FRAMES"; : > "$MAN"
  infra_alive || { log_warn "build infra not available to watch (no container / VM)."; return 0; }
  log_info "Following the in-guest install (frames captured inside the guest; live [guest]/[log] below)..."
  while true; do
    st="$(gst || true)"
    full="$(glg || true)"
    if [[ -n "$full" ]]; then total=$(printf '%s\n' "$full" | wc -l | tr -d ' '); else total=0; fi
    if [[ "$total" -gt "$loglines" ]]; then printf '%s\n' "$full" | sed -n "$((loglines+1)),${total}p" | sed 's/^/[log] /'; loglines=$total; fi
    rel="frames/$(printf 'frame-%05d.png' "$n")"
    if gx controlvm "$HVM" screenshotpng "/work/win11vbox/.logs/$rel" >/dev/null 2>&1 && [[ -s "$FRAMES/$(printf 'frame-%05d.png' "$n")" ]]; then
      echo "$(printf 'frame-%05d.png' "$n")|${st:-(starting)}" >> "$MAN"; n=$((n+1))
    fi
    [[ -n "$st" && "$st" != "$last" ]] && { echo "[guest] $(date +%H:%M:%S) $st"; last="$st"; }
    # Keep capturing past 8/8 through the post-build phases; stop once the selected servers
    # listen (or the build is marked done when no servers start). A dry run does no clone/build
    # and never starts servers, so stop at 8/8 instead of waiting.
    case "$st" in *"Setup complete"*)
      if [[ "$DRYRUN" == true ]]; then echo "[guest] reached 8/8 (dry-run; no servers start) - capture complete"; break; fi
      [[ "$post88" != true ]] && echo "[guest] reached 8/8 - capturing through clone, build, and server startup..."; post88=true ;;
    esac
    if [[ "$post88" == true ]]; then
      # Same readiness probe the export gate uses: selected ports listening, or build.done when no
      # servers start, and it also catches CLONE-FAILED so a failed clone-only run stops promptly
      # instead of spinning to the idle cap.
      case "$(probe_build_ready)" in
        ready)  echo "[guest] build ready (${WAIT_PORTS:-stopped per --stop-at}) - capture complete"; break ;;
        failed) echo "[guest] in-guest clone FAILED - stopping capture"; break ;;
      esac
    fi
    case "$st" in *ERROR*) echo "[guest] installer reported ERROR - stopping capture"; break ;; esac
    infra_alive || { echo "[guest] build infra gone (container stopped / VM unregistered)"; break; }
    idle=$((idle+1)); [[ $idle -ge 600 ]] && { echo "[guest] ~5h cap reached - stopping capture"; break; }
    sleep 30
  done
  # Tell the in-guest capture to stop, then pull its frames (live desktop, already captioned).
  gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c "echo stop> D:\\Tools\\capture.stop" >/dev/null 2>&1 || true
  mkdir -p "$GSHOTS"
  # copyfrom target: host mode pulls straight to the host .logs; container mode pulls to the
  # container's mount of it (/work/win11vbox/.logs), which is the same host directory.
  if [[ "$NO_CONTAINER" == true ]]; then
    gx guestcontrol "$HVM" --username dev --password dev copyfrom --recursive --target-directory "$GSHOTS" "D:\\Tools\\shots" >/dev/null 2>&1 || true
  else
    gx guestcontrol "$HVM" --username dev --password dev copyfrom --recursive --target-directory /work/win11vbox/.logs/gshots "D:\\Tools\\shots" >/dev/null 2>&1 || true
    # Frames are written by the container as root; chown via the container (no host sudo prompt).
    docker exec "$HC" chown -R "$(id -u):$(id -g)" /work/win11vbox/.logs 2>/dev/null \
      || sudo -n chown -R "$(id -u):$(id -g)" "$HVID" 2>/dev/null || true
  fi
  if [[ -z "${FFMPEG:-}" ]]; then log_warn "ffmpeg unavailable - frames saved under $HVID, no video."; return 0; fi
  # Prefer the guest's live captures (already captioned in-guest, never frozen).
  local GDIR=""
  ls "$GSHOTS"/shots/shot-*.png >/dev/null 2>&1 && GDIR="$GSHOTS/shots"
  [[ -z "$GDIR" ]] && ls "$GSHOTS"/shot-*.png >/dev/null 2>&1 && GDIR="$GSHOTS"
  if [[ -n "$GDIR" ]]; then
    local gn intro_n; gn=$(ls "$GDIR"/shot-*.png 2>/dev/null | wc -l | tr -d ' ')
    intro_n=$(encode_timelapse "$OUT" "$GDIR/shot-*.png")
    link_latest latest-timelapse.mp4 "$OUT"
    if [[ "$intro_n" -gt 0 ]]; then
      log_success "timelapse (live in-guest capture + ${intro_n} install-phase frames): $OUT ($((gn+intro_n)) frames)"
    else
      log_success "timelapse (live in-guest capture): $OUT ($gn frames)"
    fi
    return 0
  fi
  # Fallback: assemble from host screenshots (caption each from the manifest). May be frozen.
  log_warn "no in-guest captures found - assembling from host screenshots (these can be frozen in headless mode)."
  while IFS='|' read -r f s; do
    [[ -s "$FRAMES/$f" ]] || continue
    safe="$(printf '%s' "$s" | tr -cd '[:alnum:] /._-' | cut -c1-70)"
    "$FFMPEG" -y -loglevel error -i "$FRAMES/$f" -vf "drawtext=fontfile=${HFONT}:text='${safe}':x=10:y=h-34:fontsize=20:fontcolor=yellow:box=1:boxcolor=black@0.7" "$FRAMES/$f.a.png" 2>/dev/null || cp "$FRAMES/$f" "$FRAMES/$f.a.png"
    mv "$FRAMES/$f.a.png" "$FRAMES/$f"
  done < "$MAN"
  local intro_n; intro_n=$(encode_timelapse "$OUT" "$FRAMES/frame-*.png")
  link_latest latest-timelapse.mp4 "$OUT"
  log_success "timelapse (host screenshots, fallback): $OUT ($((n+intro_n)) frames, incl. ${intro_n} install-phase)"
}

# Run host-side orchestration unless we are already inside the container.
if [[ -z "${VMBUILDER_INNER:-}" ]]; then
  mkdir -p "$HVID"
  HLOG="$HVID/build-vm-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$HLOG") 2>&1
  # Stable pointer to this run's log (the timelapse gets latest-timelapse.mp4 after assembly).
  ln -sfn "$(basename "$HLOG")" "$HVID/latest.log" 2>/dev/null || true
  log_info "Host transcript: $HLOG (also linked as .logs/latest.log)"

  if [[ -n "$EXPORT_ONLY" ]]; then
    if [[ "$NO_CONTAINER" != true ]]; then
      docker inspect "$HC" >/dev/null 2>&1 || { log_error "container '$HC' not found - nothing to export."; exit 1; }
    fi
    gx showvminfo "$HVM" >/dev/null 2>&1 || { log_error "VM '$HVM' not registered (host build: on this host; container build: in '$HC')."; exit 1; }
    do_export; exit $?
  fi

  [[ "$WATCH" == true ]] && ensure_ffmpeg
  run_host_orchestrator "$@" || exit $?
  [[ "$WATCH" == true ]] && watch_capture
  if [[ -n "$EXPORT_DIR" ]]; then
    # Only export once everything is truly done (clone + compile + servers listening).
    wait_for_ready || { log_error "Build did not reach 'all servers running' - NOT exporting."; exit 1; }
    do_export
  fi
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --iso) ISO_PATH="$2"; shift 2 ;;
    --disk-size) DISK_SIZE_MB="$2"; shift 2 ;;
    --disk-type) DISK_TYPE="$2"; shift 2 ;;
    --cpus) CPU_COUNT="$2"; shift 2 ;;
    --memory) MEMORY_MB="$2"; shift 2 ;;
    --vram) VRAM_MB="$2"; shift 2 ;;
    --shared-folder) SHARED_FOLDER_PATH="$2"; shift 2 ;;
    --bridge-adapter) BRIDGE_ADAPTER="$2"; shift 2 ;;
    --nat) FORCE_NAT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --clean) CLEAN=true; shift ;;
    --stop-at) STOP_AT="$2"; shift 2 ;;
    --servers) SERVERS_SPEC="$2"; shift 2 ;;
    --headless) START_TYPE=headless; shift ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --host-iocache) HOST_IOCACHE="$2"; shift 2 ;;
    --cfg) CFG_PATH="$2"; shift 2 ;;
    --gh-token) GH_TOKEN="$2"; shift 2 ;;
    --gh-user) GH_USER="$2"; shift 2 ;;
    --aws-access-key) AWS_ACCESS_KEY="$2"; shift 2 ;;
    --aws-secret-key) AWS_SECRET_KEY="$2"; shift 2 ;;
    --export) EXPORT_FILE="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --base-folder) BASE_FOLDER="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --unattended) UNATTENDED=true; shift ;;
    --no-container|--host-build) shift ;;   # host-side flag; ignored inside the build path
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# Tee the whole run to a host-side log file. (The in-guest tool installer keeps
# its own separate log at D:\Tools\install_tools.log.) Honor an explicit
# --log-file first, then fall back to a writable location (CWD may be read-only,
# e.g. a root-owned bind mount) so a transcript is always produced.
LOG_TS=$(date +%Y%m%d-%H%M%S)
if [[ -n "$LOG_FILE" ]]; then
  LOG_CANDIDATES=("$LOG_FILE" "${HOME}/build-vm-${LOG_TS}.log" "/tmp/build-vm-${LOG_TS}.log")
else
  LOG_CANDIDATES=("$(pwd)/build-vm-${LOG_TS}.log" "${HOME}/build-vm-${LOG_TS}.log" "/tmp/build-vm-${LOG_TS}.log")
fi
LOG_FILE=""
for _cand in "${LOG_CANDIDATES[@]}"; do
  if ( : >> "$_cand" ) 2>/dev/null; then LOG_FILE="$_cand"; break; fi
done
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "Logging this run to: $LOG_FILE"
else
  log_warn "Could not open a log file in any candidate location; continuing without a transcript."
fi

if [[ "$SKIP_INSTALL" == false ]]; then
  if command -v VBoxManage >/dev/null 2>&1; then
    export LOGNAME=$(whoami)
    VBOX_VERSION=$(VBoxManage --version | head -1)
    VBOX_MAJOR=$(echo "$VBOX_VERSION" | cut -d. -f1)
    if [[ "$VBOX_MAJOR" -lt 7 ]]; then
      log_warn "VirtualBox $VBOX_VERSION found but 7.x is required."
      read -rp "Remove old version and install VirtualBox 7? [y/N] " upgrade_confirm
      [[ "$upgrade_confirm" =~ ^[Yy]$ ]] || exit 0
      sudo apt-get remove -y --purge 'virtualbox*' || true
      sudo apt-get autoremove -y || true
    fi
  fi

  ensure_virtualbox

  VBOX_VER_CLEAN=$(VBoxManage --version | sed 's/r.*//' | sed 's/_.*$//')
  if ! VBoxManage list extpacks 2>/dev/null | grep -q "VirtualBox Extension Pack"; then
    # Cache the Extension Pack so repeat runs don't re-download it. Only treat a
    # real gzip tarball as valid - a 404 returns an HTML page, which must never be
    # cached or installed. VirtualBox 7.1+ dropped "VM_" from the file name, so try
    # the new name first, then the legacy one.
    mkdir -p "$CACHE_DIR"
    EXTPACK_FILE="${CACHE_DIR}/Oracle_VirtualBox_Extension_Pack-${VBOX_VER_CLEAN}.vbox-extpack"
    if ! gzip -t "$EXTPACK_FILE" 2>/dev/null; then
      rm -f "$EXTPACK_FILE"
      for name in "Oracle_VirtualBox_Extension_Pack-${VBOX_VER_CLEAN}.vbox-extpack" \
                  "Oracle_VM_VirtualBox_Extension_Pack-${VBOX_VER_CLEAN}.vbox-extpack"; do
        url="https://download.virtualbox.org/virtualbox/${VBOX_VER_CLEAN}/${name}"
        if { wget -q -O "$EXTPACK_FILE" "$url" || curl -fsSL -o "$EXTPACK_FILE" "$url"; } \
           && gzip -t "$EXTPACK_FILE" 2>/dev/null; then
          break
        fi
        rm -f "$EXTPACK_FILE"
      done
    fi
    if gzip -t "$EXTPACK_FILE" 2>/dev/null; then
      echo "y" | sudo VBoxManage extpack install --replace "$EXTPACK_FILE" || true
    else
      log_warn "Could not download a valid Extension Pack; skipping (it is optional)."
    fi
  fi

  CURRENT_USER="${USER:-$(whoami)}"
  if getent group vboxusers >/dev/null && ! id -nG "$CURRENT_USER" | grep -qw vboxusers; then
    sudo usermod -aG vboxusers "$CURRENT_USER"
    log_warn "User added to vboxusers. Log out/in or run: newgrp vboxusers"
  fi
else
  ensure_virtualbox
fi

[[ -n "$ISO_PATH" ]] || { log_error "No ISO. Run on the host (it auto-pulls win11-iso from ghcr), or pass --iso."; exit 1; }
[[ -f "$ISO_PATH" ]] || { log_error "ISO file not found: $ISO_PATH"; exit 1; }
[[ "$DISK_TYPE" == "dynamic" || "$DISK_TYPE" == "fixed" ]] || { log_error "Disk type must be fixed or dynamic"; exit 1; }

# GitHub credentials are REQUIRED for a real run (private-repo clone + GitHub NuGet source).
# AWS keys are OPTIONAL - the WebEdition build/local run does not need them (they're only
# for runtime AWS features), so we just set them when supplied. --dry-run needs neither.
if [[ "$DRY_RUN" != true ]]; then
  _miss=()
  [[ -n "$GH_TOKEN" ]] || _miss+=("--gh-token (or \$GH_TOKEN)")
  [[ -n "$GH_USER"  ]] || _miss+=("--gh-user (or \$GH_USER)")
  if [[ ${#_miss[@]} -gt 0 ]]; then
    log_error "Missing required GitHub credentials: ${_miss[*]}"
    log_error "Supply them, or use --dry-run for a credential-free flow check. See --help."
    exit 1
  fi
fi
if VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
  if [[ "$CLEAN" == true ]]; then
    # --clean: tear the existing VM down (power off + unregister + delete media) so we rebuild
    # from scratch instead of resuming.
    log_info "--clean: removing the existing registered VM '$VM_NAME' for a fresh build."
    VBoxManage controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
    VBoxManage unregistervm "$VM_NAME" --delete >/dev/null 2>&1 || true
  else
    # VM already exists: don't recreate it - RESUME the in-guest install instead.
    # The guest installer is idempotent, so it continues from the last incomplete
    # step. (To force a clean rebuild, pass --clean, or remove the VM first:
    #   VBoxManage controlvm "$VM_NAME" poweroff; VBoxManage unregistervm "$VM_NAME" --delete)
    RESUME=true
    UNATTENDED=true   # ensure the helper scripts + install_tools are (re)generated for the push
    log_info "VM '$VM_NAME' already exists - RESUME mode: skipping ISO/VM creation; will re-run the in-guest installer."
  fi
fi

if [[ "$FORCE_NAT" == true ]]; then
  BRIDGE_ADAPTER=""
elif [[ -z "$BRIDGE_ADAPTER" ]]; then
  BRIDGE_ADAPTER=$(auto_detect_bridge_adapter)
fi

if [[ -n "$BASE_FOLDER" ]]; then
  VM_DIR="${BASE_FOLDER}/${VM_NAME}"
else
  DEFAULT_FOLDER=$(VBoxManage list systemproperties | grep "Default machine folder" | sed 's/Default machine folder: *//')
  VM_DIR="${DEFAULT_FOLDER}/${VM_NAME}"
fi
DISK_PATH="${VM_DIR}/${VM_NAME}.vdi"

# Handle leftover VM files. The orchestrator recreates the vmbuilder container each run, so a
# VM from a previous build is no longer *registered* (the resume check above misses it) but its
# files still sit on the durable VM-store mount - and 'createvm' then aborts with
# "Machine settings file '...vbox' already exists". --clean wipes them for a fresh build (we run
# as root inside the container, so no host sudo needed); otherwise fail fast with a clear message
# instead of the raw VBoxManage error.
if [[ "$RESUME" != true ]]; then
  if [[ "$CLEAN" == true ]]; then
    [[ -e "$VM_DIR" ]] && { log_info "--clean: clearing existing VM directory $VM_DIR"; rm -rf "$VM_DIR" 2>/dev/null || true; }
  elif [[ -e "${VM_DIR}/${VM_NAME}.vbox" || -e "$DISK_PATH" ]]; then
    log_error "A VM named '$VM_NAME' already has files at: $VM_DIR"
    log_error "(left over from a previous build; the VM isn't registered in this container, so it can't be resumed)."
    log_error "Re-run with --clean to remove it and rebuild from scratch, e.g.:"
    log_error "    ./build-vm.sh --unattended --watch --dry-run --clean -y"
    log_error "Or clear it yourself (the files are root-owned):"
    log_error "    docker run --rm --user root --entrypoint rm -v \"\${VMSTORE_HOST_DIR:-/mnt/data/win11vbox-vm}\":/vmstore ${VMBUILDER_IMAGE:-ghcr.io/tcp-software/vmbuilder:latest} -rf /vmstore/${VM_NAME}"
    exit 1
  fi
fi

echo "VM Name: $VM_NAME"
echo "ISO Path: $ISO_PATH"
echo "Disk Size: ${DISK_SIZE_MB} MB"
echo "Disk Type: $DISK_TYPE"
echo "CPUs: $CPU_COUNT"
echo "Memory: ${MEMORY_MB} MB"
echo "VRAM: ${VRAM_MB} MB"
echo "Bridge Adapter: ${BRIDGE_ADAPTER:-none}"
echo "Shared Folder: ${SHARED_FOLDER_PATH:-none}"
echo "VM Directory: $VM_DIR"
if [[ "$ASSUME_YES" != true ]]; then
  if [[ "$RESUME" == true ]]; then
    read -rp "VM '$VM_NAME' exists. Resume the in-guest install (no recreate)? [y/N] " confirm
  else
    read -rp "Proceed with VM creation? [y/N] " confirm
  fi
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

if [[ "$RESUME" != true ]]; then
CREATE_ARGS=(--name "$VM_NAME" --ostype Windows11_64 --register)
[[ -n "$BASE_FOLDER" ]] && CREATE_ARGS+=(--basefolder "$BASE_FOLDER")
VBoxManage createvm "${CREATE_ARGS[@]}"
VBoxManage modifyvm "$VM_NAME" \
  --memory "$MEMORY_MB" \
  --vram "$VRAM_MB" \
  --cpus "$CPU_COUNT" \
  --ioapic on \
  --boot1 dvd \
  --boot2 disk \
  --boot3 none \
  --boot4 none \
  --firmware efi \
  --clipboard-mode bidirectional \
  --draganddrop bidirectional \
  --graphicscontroller vboxsvga \
  --audio-driver default \
  --audio-enabled on \
  --usb-ehci on

# l1d-flush-on-vm-entry (L1TF mitigation) is intentionally left OFF (the VirtualBox
# default). Forcing it ON imposes a huge per-VM-entry penalty that makes the guest crawl
# (~5% speed) until VBox's timer catch-up gives up at the AHCI HBA reset and ABORTS the
# guest during early boot. It is NOT exposed as an option, by design - turning it on is the
# very thing that caused the early-boot aborts we eliminated.
VBoxManage modifyvm "$VM_NAME" --nested-paging on
VBoxManage modifyvm "$VM_NAME" --tpm-type 2.0

VBoxManage modifyvm "$VM_NAME" --firmware efi64
VBoxManage modifynvram "$VM_NAME" inituefivarstore
VBoxManage modifynvram "$VM_NAME" enrollmssignatures
VBoxManage modifynvram "$VM_NAME" enrollorclpk
# Enable Secure Boot. The option moved between VirtualBox versions: older builds use
# `modifyvm --secure-boot on`; 7.1.x uses `modifynvram secureboot --enable`. Try both.
VBoxManage modifyvm "$VM_NAME" --secure-boot on 2>/dev/null \
  || VBoxManage modifynvram "$VM_NAME" secureboot --enable 2>/dev/null \
  || log_warn "Could not enable Secure Boot (continuing; Win11 install uses bypass_checks)."

VARIANT="Standard"
[[ "$DISK_TYPE" == "fixed" ]] && VARIANT="Fixed"
VBoxManage createmedium disk --filename "$DISK_PATH" --size "$DISK_SIZE_MB" --format VDI --variant "$VARIANT"

# Resolve host I/O cache (auto-detects overlay/union filesystems, e.g. a container).
[[ -z "$HOST_IOCACHE" ]] && HOST_IOCACHE=$(detect_hostiocache "$VM_DIR")
log_info "Host I/O cache: $HOST_IOCACHE (VM dir: $VM_DIR)"

VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci --portcount 2 --hostiocache "$HOST_IOCACHE"
VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$DISK_PATH" --nonrotational on
VBoxManage storagectl "$VM_NAME" --name "IDE Controller" --add ide --controller PIIX4 --hostiocache "$HOST_IOCACHE"
VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "$ISO_PATH"

if [[ -n "$BRIDGE_ADAPTER" ]]; then
  VBoxManage modifyvm "$VM_NAME" --nic1 bridged --bridgeadapter1 "$BRIDGE_ADAPTER"
else
  VBoxManage modifyvm "$VM_NAME" --nic1 nat
fi

if [[ -n "$SHARED_FOLDER_PATH" ]]; then
  [[ -d "$SHARED_FOLDER_PATH" ]] || mkdir -p "$SHARED_FOLDER_PATH"
  VBoxManage sharedfolder add "$VM_NAME" --name "shared" --hostpath "$SHARED_FOLDER_PATH" --automount --auto-mount-point "G:"
fi

# Persistent cache shared folder. In-guest installers (Chocolatey, SQL media, VS
# payloads) write their downloads here, so rebuilds reuse them instead of
# re-downloading. Reached as \\vboxsvr\cache once Guest Additions are installed.
mkdir -p "$CACHE_DIR"
VBoxManage sharedfolder add "$VM_NAME" --name "cache" --hostpath "$CACHE_DIR" || true
fi  # end fresh-VM hardware creation (skipped in RESUME mode)

mkdir -p "$VM_DIR"

cat > "${VM_DIR}/bypass_checks.reg" <<'EOF'
Windows Registry Editor Version 5.00
[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001
EOF

cat > "${VM_DIR}/setup_env_vars.cmd" <<'EOF'
@echo off
rem NANT_BIN points into the cloned tcp-we-thirdparty repo (set after clone_repos.sh).
setx NANT_BIN "D:\Work\tcp-we-thirdparty\Nant\0.92\bin"
setx AWS_DEFAULT_REGION "us-east-1"
echo.
echo Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY manually with:
echo   setx AWS_ACCESS_KEY_ID "your-access-key"
echo   setx AWS_SECRET_ACCESS_KEY "your-secret-key"
echo.
echo MSBUILD_PATH is set by install_tools.cmd to the VS 2026 path:
echo   C:\Program Files\Microsoft Visual Studio\18\Insiders\MSBuild\Current\Bin
pause
EOF

cat > "${VM_DIR}/setup_powershell.ps1" <<'EOF'
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Write-Host "Execution policy updated for CurrentUser."
Write-Host "Reminder: enable .NET Framework 3.5 from Windows Features if not already enabled."
EOF

cat > "${VM_DIR}/setup_nuget_source.cmd" <<'EOF'
@echo off
set /p GITHUB_USER=GitHub username:
set /p GITHUB_PAT=GitHub PAT (read:packages):
dotnet nuget remove source github_tcp 2>nul
dotnet nuget add source "https://nuget.pkg.github.com/tcp-software/index.json" --name github_tcp --username "%GITHUB_USER%" --password "%GITHUB_PAT%" --store-password-in-clear-text
pause
EOF

# Non-interactive credential configuration, called by install_tools.cmd at completion.
# Reads the plaintext credential files staged into C:\Setup (gh_user.txt, gh_token.txt,
# aws_access_key.txt, aws_secret_key.txt) and applies them with no prompts. Each block is
# skipped when its files are absent, so this is a no-op unless creds were injected.
cat > "${VM_DIR}/configure_credentials.cmd" <<'EOF'
@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "LOG=D:\Tools\install_tools.log"
echo ==== configure_credentials %DATE% %TIME% ==== >> "%LOG%"

rem --- AWS keys -> machine environment variables (region is set separately in step 8) ---
if exist "%HERE%aws_access_key.txt" if exist "%HERE%aws_secret_key.txt" (
  set /p AWSID=<"%HERE%aws_access_key.txt"
  set /p AWSSECRET=<"%HERE%aws_secret_key.txt"
  setx /M AWS_ACCESS_KEY_ID "!AWSID!" >> "%LOG%" 2>&1
  setx /M AWS_SECRET_ACCESS_KEY "!AWSSECRET!" >> "%LOG%" 2>&1
  set "AWSID=" & set "AWSSECRET="
  echo configure_credentials: AWS keys set >> "%LOG%"
) else ( echo configure_credentials: no AWS keys staged - skipping >> "%LOG%" )

rem --- GitHub NuGet package source (read:packages), non-interactive ---
if exist "%HERE%gh_token.txt" (
  set "DOTNET=C:\Program Files\dotnet\dotnet.exe"
  if not exist "!DOTNET!" set "DOTNET=dotnet"
  set "GHUSER=tcp"
  if exist "%HERE%gh_user.txt" set /p GHUSER=<"%HERE%gh_user.txt"
  set /p GHT=<"%HERE%gh_token.txt"
  "!DOTNET!" nuget remove source github_tcp >> "%LOG%" 2>&1
  "!DOTNET!" nuget add source "https://nuget.pkg.github.com/tcp-software/index.json" --name github_tcp --username "!GHUSER!" --password "!GHT!" --store-password-in-clear-text >> "%LOG%" 2>&1
  set "GHT="
  echo configure_credentials: GitHub NuGet source added >> "%LOG%"
) else ( echo configure_credentials: no gh_token.txt - skipping NuGet source >> "%LOG%" )
endlocal
exit /b 0
EOF

cat > "${VM_DIR}/create_sql_logins.sql" <<'EOF'
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'tcadmin')
BEGIN
  CREATE LOGIN [tcadmin] WITH PASSWORD='tcadmin', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'Q3WShUtj8K')
BEGIN
  CREATE LOGIN [Q3WShUtj8K] WITH PASSWORD='Q3WShUtj8K', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF;
END
GO
EOF

cat > "${VM_DIR}/run_sql_logins.cmd" <<'EOF'
@echo off
sqlcmd -S localhost -E -i create_sql_logins.sql
pause
EOF

cat > "${VM_DIR}/build_server.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
REPO=/cygdrive/d/Work/tcp-we-71
# The repo was cloned by Windows git; that same git.exe is what runs here. It cannot parse
# Cygwin '/cygdrive/...' paths in '-C' (fails "cannot change to"), so pass a Windows path.
REPOW="$(cygpath -w "$REPO" 2>/dev/null || echo "$REPO")"

# Git (Windows git, installed by Chocolatey) lives in C:\Program Files\Git\cmd. The elevated
# install_tools task that calls this script captured its PATH BEFORE Git was installed, so a
# bare 'git' isn't resolvable in this shell. Put its known location on PATH up front - without
# it the rev-parse below fails and a perfectly good clone looks "incomplete" (it isn't).
export PATH="/cygdrive/c/Program Files/Git/cmd:${PATH}"
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on PATH (looked in C:\\Program Files\\Git\\cmd). Install Git, then re-run." >&2; exit 1; }
git config --global --add safe.directory '*' >/dev/null 2>&1 || true   # avoid 'dubious ownership'

# --- Precondition: the repo must be fully cloned and checked out before we
# build. A half-finished clone leaves a .git directory but no working-tree
# files, so a '.git exists' check alone is not enough: verify a valid HEAD and
# the known build file. (git is now guaranteed present, so a rev-parse failure
# here means a genuinely broken clone, not a missing git.) ---
if [[ ! -f "$REPO/.git/HEAD" ]]; then
  echo "ERROR: $REPO is not cloned (.git/HEAD missing). Run the clone step first." >&2
  exit 1
fi
if ! git -C "$REPOW" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "ERROR: $REPO has no valid HEAD (clone incomplete)." >&2
  exit 1
fi
if [[ ! -f "$REPO/server/tcp-we-7.build" ]]; then
  echo "ERROR: $REPO/server/tcp-we-7.build is missing - the working tree was not checked out." >&2
  exit 1
fi
echo "Precheck passed: $REPO checked out at $(git -C "$REPOW" rev-parse --short HEAD) on $(git -C "$REPOW" rev-parse --abbrev-ref HEAD)."

# --- PATH for the build. NAnt orchestrates MSBuild, which it invokes as the
# bare name "MSBuild.exe" (msbuild.filename in tcp-we-7.build), so the VS MSBuild
# bin must be on PATH. NAnt's 'restore' target also runs "dotnet" by bare name, so
# the .NET SDK dir must be on PATH too - the elevated install task that calls this
# captured its PATH BEFORE the .NET SDK installed, so a bare 'dotnet' isn't found
# and the restore fails with "'dotnet' failed to start". The database schema project
# also shells out to "sed"; running inside Cygwin provides sed/grep/coreutils. ---
MSBUILD_BIN="/cygdrive/c/Program Files/Microsoft Visual Studio/18/Insiders/MSBuild/Current/Bin"
NANT_BIN_CYG="/cygdrive/d/Work/tcp-we-thirdparty/Nant/0.92/bin"
DOTNET_BIN="/cygdrive/c/Program Files/dotnet"
export PATH="${DOTNET_BIN}:${PATH}:${NANT_BIN_CYG}:${MSBUILD_BIN}"
command -v dotnet >/dev/null 2>&1 || echo "WARNING: dotnet not found on PATH (looked in C:\\Program Files\\dotnet) - NAnt restore will fail." >&2
command -v MSBuild.exe >/dev/null 2>&1 || echo "WARNING: MSBuild.exe not found on PATH - NAnt restore/build will fail." >&2
command -v sed >/dev/null 2>&1 || echo "WARNING: sed not found on PATH - the database schema build will fail (run this inside Cygwin)." >&2

cd "$REPO/server"
nant restore clean
cd Etc/Util
cmd /c "msbuild Util.sln /t:Rebuild"
cd ../..
nant build
echo "Server build complete."
EOF
chmod +x "${VM_DIR}/build_server.sh"

cat > "${VM_DIR}/build_client.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
REPO=/cygdrive/d/Work/tcp-we-71

# --- Precondition: confirm the client tree is actually checked out (see
# build_server.sh for why a .git check alone is not enough, and why git's -C needs a
# Windows path - Windows git.exe can't parse Cygwin /cygdrive paths). ---
REPOW="$(cygpath -w "$REPO" 2>/dev/null || echo "$REPO")"
# Put Windows git on PATH (see build_server.sh: the caller's PATH predates the Git install, so
# a bare 'git' isn't found and a good clone would otherwise look like it has "no valid HEAD").
export PATH="/cygdrive/c/Program Files/Git/cmd:${PATH}"
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on PATH (looked in C:\\Program Files\\Git\\cmd). Install Git, then re-run." >&2; exit 1; }
git config --global --add safe.directory '*' >/dev/null 2>&1 || true
if [[ ! -f "$REPO/.git/HEAD" ]] || ! git -C "$REPOW" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "ERROR: $REPO is not cloned / has no valid HEAD. Run the clone step first." >&2
  exit 1
fi
if [[ ! -f "$REPO/client/package.json" ]]; then
  echo "ERROR: $REPO/client/package.json is missing - the working tree was not checked out." >&2
  exit 1
fi

# --- Client build, matching client/Jenkinsfile. The npm project lives at
# client/ (not client/app), and the JS bundles are produced by the
# build-all-js grunt task. npm ci reads client/.npmrc, which points at a
# private registry with a committed auth token. ---
export PATH="/cygdrive/c/Program Files/nodejs:${PATH}"
cd "$REPO/client"
npm install grunt -g --loglevel=error
npm prune
npm ci --loglevel=error
npm run build-all-js
echo "Client build complete."
EOF
chmod +x "${VM_DIR}/build_client.sh"

# Give each WebEdition server its OWN per-instance cfg dir, populated from the applied cfg.
# Run from post_build AFTER the build (so the build's nant clean can't wipe it) and from
# post_build's ELEVATED context (so the files are accessible to the servers, which also run
# elevated via TCPStartServers). The repo launchers read each server's config from a per-server
# dir - AppServerApi (net10.0) from ..\..\..\cfg (bin\Debug\net10.0) and the .NET FW servers
# from ..\..\cfg (bin\Debug), both resolving to Src\Interface\<Server>\cfg - NOT the shared
# Src\Interface\cfg where cfg.zip is applied. If that per-server dir is missing the server
# writes a default config that uses port 8008 for ALL of them and they collide. Recreate the
# dirs FRESH (a stale dir keeps bad ACLs), then: strip the xsd/xsi XML namespaces from
# AppServerApi.config (net10.0's config loader rejects XML namespaces - the .NET FW servers
# tolerate them); and clear read-only + grant the dev account full control, because AppServerApi
# opens its config read/write and the cfg.zip-extracted source can carry restrictive ACLs
# (a missing/locked AppServerApi.config makes net10.0 fail with UnauthorizedAccessException).
cat > "${VM_DIR}/setup_server_cfg.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
IFACE=/cygdrive/d/Work/tcp-we-71/server/Src/Interface
SHARED="$IFACE/cfg"
[[ -f "$SHARED/AppServerApi.config" ]] || { echo "WARNING: $SHARED/AppServerApi.config missing - was cfg.zip applied?" >&2; }
for s in AppServerApi AdmServerApi TerminalHubApi WorkstationHubApi; do
  d="$IFACE/$s/cfg"
  rm -rf "$d" 2>/dev/null
  mkdir -p "$d"
  cp -rf "$SHARED/." "$d/" 2>/dev/null
  chmod -R 777 "$d" 2>/dev/null
  dw="$(cygpath -w "$d" 2>/dev/null || echo "$d")"
  cmd /c "attrib -r \"$dw\\*.*\" /s" >/dev/null 2>&1 || true
  cmd /c "icacls \"$dw\" /grant dev:(OI)(CI)F /T" >/dev/null 2>&1 || true
  echo "cfg ready: $s port=$(grep -oE '<ApiServerPort>[0-9]+</ApiServerPort>' "$d/$s.config" 2>/dev/null | head -1)"
done
# AppServerApi (net10.0) rejects XML namespaces in its config; strip them from its copy.
sed -i 's/ xmlns:xsi="[^"]*"//g; s/ xmlns:xsd="[^"]*"//g' "$IFACE/AppServerApi/cfg/AppServerApi.config" 2>/dev/null
# Each server builds its bind URL from <ApiServerHost>:<ApiServerPort>, and cfg.zip ships
# AppServerApi/TerminalHubApi/WorkstationHubApi with ApiServerHost=127.0.0.1, so they bind
# localhost only - a clock device on a bridged network then can't reach them. AdmServerApi
# ships 0.0.0.0 in the same field (which is why it binds all interfaces); match that for the
# rest so every server listens on all interfaces.
for s in AppServerApi TerminalHubApi WorkstationHubApi; do
  sed -i 's#<ApiServerHost>127\.0\.0\.1</ApiServerHost>#<ApiServerHost>0.0.0.0</ApiServerHost>#' "$IFACE/$s/cfg/$s.config" 2>/dev/null
  echo "$s bind host: $(grep -oE '<ApiServerHost>[^<]*</ApiServerHost>' "$IFACE/$s/cfg/$s.config" 2>/dev/null | head -1)"
done
echo "AppServerApi cfg line2: $(sed -n 2p "$IFACE/AppServerApi/cfg/AppServerApi.config" 2>/dev/null)"
echo "per-server cfg setup complete"
EOF
chmod +x "${VM_DIR}/setup_server_cfg.sh"

# Start the WebEdition runtime servers that clients (incl. clock devices like linclock)
# connect to. Each is a long-running .NET server reading the cfg dir; we launch them in the
# background and log to D:\Tools\serverlogs. The guide only documents starting App + Admin;
# the device-facing hubs (TerminalHub, WorkstationHub) are added here. A linclock terminal
# connects to TerminalHubApi (which needs AppServerApi + SQL Server up), so the 'linclock'
# selector starts exactly those two.
cat > "${VM_DIR}/start_servers.sh" <<'EOF'
#!/bin/bash
# Start WebEdition runtime servers by DELEGATING to the repo's own canonical launchers in
# server/Etc/Util (start-tcp{app,adm,hub,pwh}-server.sh). Those scripts know each server's
# framework and run the built Tcp.<Name>.exe from bin\Debug, provisioning cfg as needed.
#   Usage: start_servers.sh [TOKEN ...]   where TOKEN in app|adm|terminal|workstation|linclock|all
#     Accepts several tokens or a comma list, e.g. 'start_servers.sh app terminal' or 'app,terminal'.
#     With no args it reads D:\Tools\servers.spec (written by the build / --servers), else 'all'.
#     linclock = AppServerApi + TerminalHubApi (what a clock device needs)
# IMPORTANT: only AppServerApi targets net10.0; AdmServerApi/TerminalHubApi/WorkstationHubApi
# are .NET Framework 4.7.2 (OutputType=Exe). They are built by 'nant build' (VS MSBuild) -
# NOT 'dotnet build' (which can't resolve System.Web.Http for the v4.7.2 projects). So this
# script does NOT build; build with build_server.sh / post_build first.
set -uo pipefail
WE=/cygdrive/d/Work/tcp-we-71
UTIL="$WE/server/Etc/Util"
[[ -d "$UTIL" ]] || { echo "ERROR: $UTIL not found - clone + build the server first." >&2; exit 1; }
export PATH="$PATH:/cygdrive/c/Program Files/dotnet"
# AppServerApi (net10.0) lands in bin/Debug/<framework>; its launcher reads this.
export APP_FRAMEWORK_VERSION="${APP_FRAMEWORK_VERSION:-net10.0}"

# Selection: explicit args (one or more tokens, or a comma list) win; else the persisted
# D:\Tools\servers.spec (written by post_build from --servers; the boot task passes no arg); else 'all'.
sel="$*"
if [[ -z "$sel" && -f /cygdrive/d/Tools/servers.spec ]]; then sel="$(tr -d '\r\n' < /cygdrive/d/Tools/servers.spec)"; fi
sel="${sel:-all}"
declare -a SCRIPTS=()
for tok in ${sel//,/ }; do
  case "$tok" in
    app)          SCRIPTS+=(start-tcpapp-server.sh) ;;
    adm|admin)    SCRIPTS+=(start-tcpadm-server.sh) ;;
    terminal)     SCRIPTS+=(start-tcphub-server.sh) ;;
    workstation)  SCRIPTS+=(start-tcppwh-server.sh) ;;
    linclock)     SCRIPTS+=(start-tcpapp-server.sh start-tcphub-server.sh) ;;
    all)          SCRIPTS=(start-tcpapp-server.sh start-tcpadm-server.sh start-tcphub-server.sh start-tcppwh-server.sh) ;;
    *) echo "usage: start_servers.sh [app|adm|terminal|workstation|linclock|all ...]  (tokens or a comma list)"; exit 1 ;;
  esac
done
# De-dupe while preserving order (e.g. 'app linclock' would otherwise list AppServerApi twice).
declare -a UNIQ=(); for s in "${SCRIPTS[@]}"; do case " ${UNIQ[*]} " in *" $s "*) ;; *) UNIQ+=("$s") ;; esac; done
SCRIPTS=("${UNIQ[@]}")

echo "Starting via repo launchers: ${SCRIPTS[*]}"
for s in "${SCRIPTS[@]}"; do
  if [[ -f "$UTIL/$s" ]]; then
    echo ">>> $s"
    ( cd "$UTIL" && bash "./$s" ) || echo "  (launcher $s reported a problem - check the server's bin/Debug .out/.err)"
  else
    echo "  skip $s (not found - server may not be built yet)"
  fi
done
cat <<MSG

Endpoints (raw ports per cfg; nginx fronts the web UIs over HTTPS):
  AppServerApi(8008)  manager UI http://localhost:8081/app/manager
  AdmServerApi(8012)  admin UI   http://localhost:8018/app/admin
  TerminalHubApi(8010)  clock-device hub  <-- linclock/winclock/RDTg/POS connect here
  WorkstationHubApi(8014)  workstation-attached terminals/biometric readers
Per-server output is in each bin/Debug as Tcp.<Name>.out / .err. If a server didn't start,
make sure it was built by 'nant build' (build_server.sh / post_build), not 'dotnet build'.
For a linclock: 'start_servers.sh linclock' with SQL Server running; point the device's
NetworkSettings serverUrl at this VM's IP.
MSG
EOF
chmod +x "${VM_DIR}/start_servers.sh"

# Version switcher: pick a release/7.x branch of tcp-we-71, then rebuild server + client and
# restore the test DB for that version (the guide's select_we.sh). Run from Cygwin.
cat > "${VM_DIR}/select_we.sh" <<'EOF'
#!/bin/bash
# Switch the tcp-we-71 working copy to another release branch and rebuild for it.
# Usage: select_we.sh [branch]   (no arg -> interactive menu of release/7.x branches)
set -uo pipefail
# Windows git on PATH (a stale caller PATH may predate the Git install; see build_server.sh).
export PATH="/cygdrive/c/Program Files/Git/cmd:${PATH}"
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on PATH (looked in C:\\Program Files\\Git\\cmd)." >&2; exit 1; }
WE=/cygdrive/d/Work/tcp-we-71
[[ -d "$WE/.git" ]] || { echo "ERROR: $WE is not a clone - run the build first." >&2; exit 1; }
cd "$WE"
git fetch --all --prune

branch="${1:-}"
if [[ -z "$branch" ]]; then
  # Offer release/7.x branches >= 7.1.56, plus develop.
  mapfile -t branches < <(git branch -r 2>/dev/null | sed 's#^[ *]*origin/##' \
    | grep -E '^release/7\.' | sort -uV)
  branches+=("develop")
  echo "Select a branch:"
  i=0; for b in "${branches[@]}"; do echo "  [$i] $b"; i=$((i+1)); done
  read -rp "Index: " sel
  [[ "$sel" =~ ^[0-9]+$ && "$sel" -lt "${#branches[@]}" ]] || { echo "Invalid selection." >&2; exit 1; }
  branch="${branches[$sel]}"
fi

echo ">>> Checking out $branch"
git checkout "$branch" || { echo "ERROR: checkout failed." >&2; exit 1; }
git pull --ff-only 2>/dev/null || true

echo ">>> Rebuilding server"; /cygdrive/c/Setup/build_server.sh || { echo "server build failed" >&2; exit 1; }
echo ">>> Rebuilding client"; /cygdrive/c/Setup/build_client.sh || { echo "client build failed" >&2; exit 1; }
echo ">>> Restoring test DB"; ( cd "$WE/server" && nant __restore-db-prod-test ) || echo "WARN: DB restore failed (check cfg)."
# Repopulate the per-server cfg dirs: the rebuild's nant clean can wipe them, and AppServerApi
# (net10.0) needs its namespace-stripped, accessible config. Run elevated (Cygwin-as-admin) so
# the servers can read it; start_servers also needs elevation for SQL integrated auth.
echo ">>> Refreshing per-server cfg"; /cygdrive/c/Setup/setup_server_cfg.sh || echo "WARN: per-server cfg refresh failed."
echo ">>> Done. Restart the servers (elevated): C:\\Setup\\start_servers.sh all"
EOF
chmod +x "${VM_DIR}/select_we.sh"

# Install the guide's Cygwin bash config for the dev user: ~/.bash_aliases (img-041) and a curated
# ~/.bashrc (git-branch prompt, colors, LESS/history tweaks; sources .bash_aliases). Runs as a
# Cygwin login shell, so $HOME is /home/dev. Idempotent (backs the stock .bashrc up once).
cat > "${VM_DIR}/setup_bash_config.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
cat > "$HOME/.bash_aliases" <<'ALIASES'
alias df='df -h'
alias free='free -m'
alias grep='grep --color=auto'
alias ls='ls --group-directories-first --time-style=+"%d.%m.%Y %H:%M" --color=auto -F'
alias l='ls -lh'
alias la='ls -lha'
alias auth='git blame -CCC --color-lines --color-by-age -- '
alias ia='git add'
alias ib='git branch'
alias ic='git commit'
alias ica='git commit --amend'
alias idi='git diff'
alias idic='git diff --cached'
alias il='git log'
alias io='git checkout'
alias ipull='git pull --rebase'
alias ir='git rebase'
alias iri='git rebase -i'
alias is='git status'
alias ist='git stash'
alias isuir='git submodule update --init --recursive'
alias popcomhard='git reset --hard HEAD^'
alias popcomsoft='git reset HEAD^'

alias make="make -j$(nproc)"
alias wk='cd /cygdrive/d/Work'
ALIASES
# Back up the stock (heavily-commented) .bashrc once, then install the guide's curated version.
[ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.bashrc.orig" ] && cp -f "$HOME/.bashrc" "$HOME/.bashrc.orig"
cat > "$HOME/.bashrc" <<'BASHRC'
# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

# Make bash append rather than overwrite the history on disk
shopt -s histappend
# check the window size after each command; update LINES and COLUMNS if needed.
shopt -s checkwinsize

# helper function for git branch in prompt
git_branch() {
  branch=$(git branch 2>/dev/null | grep '^*' | colrm 1 2)
  if [ ! -z "$branch" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      color="31"  # Red for changes
    elif [ "$(git stash list)" ]; then
      color="33"  # Yellow for stashed changes
    else
      color="32"  # Green for a clean state
    fi
    echo -e "\e[0;${color}m${branch}\e[0m"
  fi
}

# Prompt with git branch
#PS1="\u@\h \w \$(git_branch)\$ "
# Color prompt with git branch
#PS1="\[\e[1;34m\]\w\[\e[m\] \$(git_branch)\[\e[m\] \[\e[1;32m\]\$ \[\e[m\]\[\e[0m\] "
# Color prompt with user
#PS1="\[\e[1;36m\]\u\[\e[1;35m\] \[\e[1;34m\]\w\[\e[m\] \[\e[m\] \[\e[1;32m\]\$ \[\e[m\]\[\e[0m\] "
# Color prompt with user and git branch
#PS1="\[\e[1;36m\]\u\[\e[1;35m\] \[\e[1;34m\]\w\[\e[m\] \$(git_branch)\[\e[m\] \[\e[1;32m\]\$ \[\e[m\]\[\e[0m\] "
# Color prompt without user or git branch
PS1="\[\e[1;34m\]\w\[\e[m\] \[\e[m\] \[\e[1;32m\]\$ \[\e[m\]\[\e[0m\] "

# set LS_COLORS
eval "$(dircolors -b)"
# grep colorization
export GREP_COLORS="mt=1;33"
# Default parameters for "less": -R ANSI colors, -i case-insensitive, -X keep text on exit, -F no pager if one screen
export LESS="-R -i -X -F"
# No double entries in the shell history.
export HISTCONTROL="$HISTCONTROL erasedups:ignoreboth"
# disable sending stats to Microsoft
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# colored man pages
export LESS_TERMCAP_mb=$(printf "\e[1;37m")
export LESS_TERMCAP_md=$(printf "\e[1;37m")
export LESS_TERMCAP_me=$(printf "\e[0m")
export LESS_TERMCAP_se=$(printf "\e[0m")
export LESS_TERMCAP_so=$(printf "\e[1;47;30m")
export LESS_TERMCAP_ue=$(printf "\e[0m")
export LESS_TERMCAP_us=$(printf "\e[0;36m")
export GROFF_NO_SGR=1

# source the aliases
if [ -f ~/.bash_aliases ]; then
  . ~/.bash_aliases
fi
BASHRC
echo "bash config installed: $HOME/.bashrc (+ .bash_aliases; stock backed up to .bashrc.orig)"
EOF
chmod +x "${VM_DIR}/setup_bash_config.sh"

# Add the guide's two Windows Terminal profiles ("Cygwin" and "Cygwin as Admin", the latter
# elevated) to the dev user's settings.json and make "Cygwin" the default profile. Run as dev so
# LOCALAPPDATA resolves to dev's. Merges into an existing settings.json (by GUID) or creates a
# minimal one WT layers over its defaults. Both point at the Cygwin login bash; admin sets elevate.
cat > "${VM_DIR}/setup_terminal_profiles.ps1" <<'EOF'
$ErrorActionPreference = 'SilentlyContinue'
$base = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$f = Join-Path $base 'settings.json'
$cygGuid = '{c1c1c1c1-0000-0000-0000-000000000001}'
$admGuid = '{c1c1c1c1-0000-0000-0000-000000000002}'
$cmd  = 'D:\Tools\cygwin\bin\bash.exe -i -l'
$icon = 'D:\Tools\cygwin\Cygwin.ico'
$j = $null
if (Test-Path $f) { try { $j = Get-Content $f -Raw | ConvertFrom-Json } catch { $j = $null } }
if (-not $j) {
  $j = [pscustomobject]@{ '$schema' = 'https://aka.ms/terminal-profiles-schema'; defaultProfile = $cygGuid; profiles = [pscustomobject]@{ list = @() } }
}
# Normalize: profiles may be an array (old schema) or an object with a .list array.
if ($j.profiles -is [System.Array]) { $j.profiles = [pscustomobject]@{ list = @($j.profiles) } }
if (-not $j.profiles) { $j | Add-Member profiles ([pscustomobject]@{ list = @() }) -Force }
if (-not ($j.profiles.PSObject.Properties.Name -contains 'list')) { $j.profiles | Add-Member list @() -Force }
$list = [System.Collections.ArrayList]@($j.profiles.list)
function Has-Guid($g) { foreach ($p in $list) { if ($p.guid -eq $g) { return $true } } return $false }
if (-not (Has-Guid $cygGuid)) { [void]$list.Add([pscustomobject]@{ guid = $cygGuid; name = 'Cygwin'; commandline = $cmd; icon = $icon; startingDirectory = '%USERPROFILE%' }) }
if (-not (Has-Guid $admGuid)) { [void]$list.Add([pscustomobject]@{ guid = $admGuid; name = 'Cygwin as Admin'; commandline = $cmd; icon = $icon; elevate = $true; startingDirectory = '%USERPROFILE%' }) }
$j.profiles.list = @($list)
# Make Cygwin the default profile (overwrite any existing default).
$j | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $cygGuid -Force
$json = $j | ConvertTo-Json -Depth 32
[System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("terminal profiles written to " + $f)
EOF

cat > "${VM_DIR}/post_install_setup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
DOWNLOADS="/cygdrive/d/downloads"
SCRIPTS="/cygdrive/d/scripts"
mkdir -p "$DOWNLOADS" "$SCRIPTS" /cygdrive/d/Tools
echo "Download helper placeholder. Add your existing downloader content here."
echo "This script should remain the main place to download installers inside the VM."
EOF
chmod +x "${VM_DIR}/post_install_setup.sh"

cat > "${VM_DIR}/clone_repos.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
repo_root="/cygdrive/d/Work"
mkdir -p "${repo_root}"

# --- clone_and_verify <git-url> <branch> <dest-dir> [must-exist-relpath] ---
# Clones, checks out the branch, then verifies the result before returning.
# Any failure aborts the whole script (set -e + explicit exits) so the build
# stage never runs against an incomplete checkout. A bare ".git exists" test is
# deliberately avoided: an interrupted clone leaves .git behind with no files.
clone_and_verify() {
  local url="$1" branch="$2" dest="$3" must="${4:-}"
  echo ">>> Cloning ${url} (${branch}) into ${dest}"
  rm -rf "${dest}"
  if ! git clone -b "${branch}" "${url}" "${dest}"; then
    echo "ERROR: clone failed for ${url}" >&2; return 1
  fi
  if [[ ! -f "${dest}/.git/HEAD" ]] || ! git -C "${dest}" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "ERROR: ${dest} has no valid HEAD after clone." >&2; return 1
  fi
  if [[ -n "${must}" && ! -e "${dest}/${must}" ]]; then
    echo "ERROR: ${dest}/${must} missing - working tree not fully checked out." >&2; return 1
  fi
  local missing
  missing=$(git -C "${dest}" status --porcelain 2>/dev/null | grep -c '^ D ' || true)
  if [[ "${missing}" != "0" ]]; then
    echo "ERROR: ${missing} tracked files missing from ${dest} - checkout incomplete." >&2; return 1
  fi
  # Pull any LFS content and confirm no pointer files remain unresolved.
  git -C "${dest}" lfs pull >/dev/null 2>&1 || true
  echo "OK: ${dest} at $(git -C "${dest}" rev-parse --short HEAD) (${branch})"
}

clone_and_verify "git@github.com:tcp-software/tcp-cs-60.git"                we-70-base "${repo_root}/tcp-cs-60-70"
clone_and_verify "git@github.com:tcp-software/tcp-we-70.git"               develop    "${repo_root}/tcp-we-71"          "server/tcp-we-7.build"
clone_and_verify "git@github.com:tcp-software/tcp-we-integration-legacy.git" main     "${repo_root}/tcp-we-integration"
clone_and_verify "git@github.com:tcp-software/tcp-we-thirdparty-new.git"   main       "${repo_root}/tcp-we-thirdparty"
echo "All repositories cloned and verified."
EOF
chmod +x "${VM_DIR}/clone_repos.sh"

# Windows clone helper used by install_tools.cmd (and runnable by hand). Clones the
# repos reachable with the injected token over HTTPS, then scrubs the token from the
# saved remote. git output is sent to NUL so the token never lands in a log.
cat > "${VM_DIR}/clone_repos.cmd" <<'EOF'
@echo off
setlocal enabledelayedexpansion
set "GIT=C:\Program Files\Git\cmd\git.exe"
if not exist "!GIT!" set "GIT=git"
if not exist "%~dp0gh_token.txt" ( echo No gh_token.txt - skipping clone & exit /b 0 )
set /p GHT=<"%~dp0gh_token.txt"
if not exist D:\Work md D:\Work
set "FAILS=0"

rem Format: "repo|branch|dest-dir|must-exist-relpath" (must-exist may be empty).
rem The must-exist path is a known working-tree file used to prove the checkout
rem actually completed - an interrupted clone leaves .git behind with no files,
rem so checking for .git alone is not enough.
call :clone_one "tcp-cs-60"               "we-70-base" "tcp-cs-60-70"     ""
call :clone_one "tcp-tl-70"               ""           "tcp-tl-70"        ""
call :clone_one "tcp-we-70"               "develop"    "tcp-we-71"        "server\tcp-we-7.build"
call :clone_one "tcp-we-integration-legacy" "main"     "tcp-we-integration" ""
call :clone_one "tcp-we-thirdparty-new"   "main"       "tcp-we-thirdparty" ""

set "GHT="
if not "!FAILS!"=="0" (
  echo CLONE-STAGE-FAILED: !FAILS! repo^(s^) did not clone/verify. Build stage must not run.
  endlocal & exit /b 1
)
echo CLONE-STAGE-OK: all repositories cloned and verified.
endlocal & exit /b 0

:clone_one
rem %1=repo %2=branch %3=dest %4=must-exist-relpath
set "REPO=%~1"
set "BR=%~2"
set "DEST=D:\Work\%~3"
set "MUST=%~4"
set "BROPT="
if not "%BR%"=="" set "BROPT=-b %BR%"
echo Cloning %REPO% %BR% into %DEST% ...
if exist "%DEST%" rmdir /s /q "%DEST%"
"!GIT!" clone %BROPT% "https://!GHT!@github.com/tcp-software/%REPO%.git" "%DEST%" >nul 2>&1
if errorlevel 1 ( echo FAILED %REPO%: git clone returned an error ^(check token access^) & set /a FAILS+=1 & goto :eof )
if not exist "%DEST%\.git\HEAD" ( echo FAILED %REPO%: no .git\HEAD ^(clone incomplete^) & set /a FAILS+=1 & goto :eof )
"!GIT!" -C "%DEST%" rev-parse --verify HEAD >nul 2>&1
if errorlevel 1 ( echo FAILED %REPO%: HEAD is not valid & set /a FAILS+=1 & goto :eof )
if not "%MUST%"=="" if not exist "%DEST%\%MUST%" ( echo FAILED %REPO%: missing %MUST% ^(working tree not checked out^) & set /a FAILS+=1 & goto :eof )
rem A half-finished checkout reports tracked files as deleted - treat that as failure.
"!GIT!" -C "%DEST%" status --porcelain > "%TEMP%\clone_porc.txt" 2>&1
findstr /b /c:" D " "%TEMP%\clone_porc.txt" >nul && ( echo FAILED %REPO%: tracked files missing from working tree ^(checkout incomplete^) & set /a FAILS+=1 & goto :eof )
"!GIT!" -C "%DEST%" lfs pull >nul 2>&1
"!GIT!" -C "%DEST%" remote set-url origin "https://github.com/tcp-software/%REPO%.git" >nul 2>&1
echo CLONED %REPO% - verified
goto :eof
EOF

cat > "${VM_DIR}/setup_cygwin_ssh.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
WINSSH="${USERPROFILE}\\.ssh"
CYGSSH="${HOME}/.ssh"
test -d "$CYGSSH" && mv "$CYGSSH" "${USERPROFILE}" || true
test -d "$WINSSH" || mkdir "$WINSSH"
chmod 700 "$WINSSH"
ln -s "$WINSSH" "$CYGSSH" || true
echo "Now run:"
echo "  ssh-keygen -t ed25519 -C \"your_email@example.com\""
echo "Then add the public key to GitHub."
EOF
chmod +x "${VM_DIR}/setup_cygwin_ssh.sh"

cat > "${VM_DIR}/setup_nginx.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
cd /cygdrive/d/Tools
cmd /c "mklink /D nginx nginx-1.24.0" || true
mkdir -p /cygdrive/d/Tools/nginx/https /cygdrive/d/Tools/nginx/service
if [[ -f /cygdrive/d/Work/tcp-we-71/overall/deploy/tst/etc/tst/etc/server/nginx.exe ]]; then
  cp /cygdrive/d/Work/tcp-we-71/overall/deploy/tst/etc/tst/etc/server/nginx.exe /cygdrive/d/Tools/nginx/service/nginxservice.exe
fi
/cygdrive/d/Tools/nginx/service/nginxservice install || true
cd /cygdrive/d/Tools/nginx/html
cmd /c "mklink /D app D:\\Work\\tcp-we-71\\client\\app" || true
echo "Place nginx.conf, headers.include, nginx.tcp.crt, and nginx.tcp.key manually."
EOF
chmod +x "${VM_DIR}/setup_nginx.sh"

# Post-build chain (runs by default after 8/8 + a verified clone): apply the server config
# from cfg.zip (pulled from ghcr, staged to C:\Setup), build server + client, restore the
# test DB, create SQL logins, scaffold nginx. All logged to install_tools.log.
cat > "${VM_DIR}/post_build.cmd" <<'EOF'
@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "LOG=D:\Tools\install_tools.log"
set "BASH=D:\Tools\cygwin\bin\bash.exe"
set "IFACE=D:\Work\tcp-we-71\server\Src\Interface"
rem PHASE: a short label for the timelapse caption (capture_screens.ps1 reads build_phase.txt).
set "PHASE=D:\Tools\build_phase.txt"
rem --stop-at / --servers, from markers the orchestrator stages next to this script. STOPAT is
rem the last phase to run (server|client|db|cfg|servers); 'servers' (default) is the full run.
rem SRVSPEC is which servers to start (a comma list); written to D:\Tools\servers.spec so the
rem boot task (and start_servers.sh) reads the same selection on every boot.
set "STOPAT=servers"
if exist "%HERE%post_build.stop" set /p STOPAT=<"%HERE%post_build.stop"
set "SRVSPEC=all"
if exist "%HERE%servers.spec" set /p SRVSPEC=<"%HERE%servers.spec"
echo ==== post_build %DATE% %TIME% (stop-at=%STOPAT% servers=%SRVSPEC%) ==== >> "%LOG%"
if not exist "!BASH!" ( echo post_build: Cygwin bash missing - cannot build >> "%LOG%" & endlocal & exit /b 1 )

rem --- Apply server config from cfg.zip (extract to ...\Interface, then the guide's edits:
rem TCPCONN.PROD.XML -> TCPCONN.XML with Integrated=true, and drop the PROD line from
rem company-connection-map.xml). Extraction uses PowerShell; the text edits use Cygwin sed.
if exist "%HERE%cfg.zip" (
  echo post_build: applying cfg.zip server config... >> "%LOG%"
  if not exist "!IFACE!" md "!IFACE!"
  rem cfg.zip already contains a top-level cfg\ folder (TCPCONN.XML, *.config, etc.), so it
  rem lands at ...\Interface\cfg\. This zip ships TCPCONN.XML directly (there is no
  rem TCPCONN.PROD.XML), so we just make sure Integrated is true in the shipped file - we do
  rem NOT rename PROD->XML (that assumption left TCPCONN.XML missing before).
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path 'C:\Setup\cfg.zip' -DestinationPath '!IFACE!' -Force" >> "%LOG%" 2>&1
  "!BASH!" -lc "cd /cygdrive/d/Work/tcp-we-71/server/Src/Interface/cfg && { [ -f TCPCONN.XML ] || { [ -f TCPCONN.PROD.XML ] && cp -f TCPCONN.PROD.XML TCPCONN.XML; }; [ -f TCPCONN.XML ] && sed -i 's_Integrated>false</Integrated_Integrated>true</Integrated_g' TCPCONN.XML; echo cfg applied:; ls -1; }" >> "%LOG%" 2>&1
) else ( echo post_build: no cfg.zip staged - skipping server config ^(DB restore/run may fail^) >> "%LOG%" )

rem Exclude the work tree from Defender real-time scanning: it was locking build outputs
rem (e.g. Tcp.Update.dll) and causing intermittent CS2012 "file in use" build failures.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-MpPreference -ExclusionPath 'D:\Work' -ErrorAction SilentlyContinue" >> "%LOG%" 2>&1

echo post_build: building server... >> "%LOG%"
>"%PHASE%" echo Building server...
"!BASH!" -lc "/cygdrive/c/Setup/build_server.sh" >> "%LOG%" 2>&1
if /i "%STOPAT%"=="server" goto :stopped
echo post_build: building client... >> "%LOG%"
>"%PHASE%" echo Building client...
"!BASH!" -lc "/cygdrive/c/Setup/build_client.sh" >> "%LOG%" 2>&1
if /i "%STOPAT%"=="client" goto :stopped
echo post_build: restoring test DB... >> "%LOG%"
>"%PHASE%" echo Restoring test database...
rem nant + sqlcmd + git must be on PATH for this inline step (the caller's PATH predates those
rem installs, so bare 'sqlcmd'/'git' aren't found - that's why the DB restore failed before).
rem sqlcmd ships under the SQL Client SDK ODBC Binn, in a version-named dir (glob it at runtime).
"!BASH!" -lc "SQLBINN=$(ls -d '/cygdrive/c/Program Files/Microsoft SQL Server/Client SDK/ODBC/'*/Tools/Binn 2>/dev/null | head -1); export PATH=\"/cygdrive/c/Program Files/Git/cmd:$PATH:/cygdrive/d/Work/tcp-we-thirdparty/Nant/0.92/bin:/cygdrive/c/Program Files/Microsoft Visual Studio/18/Insiders/MSBuild/Current/Bin:$SQLBINN\"; cd /cygdrive/d/Work/tcp-we-71/server && nant __restore-db-prod-test" >> "%LOG%" 2>&1
echo post_build: creating SQL logins... >> "%LOG%"
rem sqlcmd ships with the SQL Client SDK but isn't on PATH; find and use its full path.
for /d %%v in ("C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\*") do if exist "%%v\Tools\Binn\SQLCMD.EXE" set "SQLCMD=%%v\Tools\Binn\SQLCMD.EXE"
if defined SQLCMD ( if exist "%HERE%create_sql_logins.sql" "%SQLCMD%" -S localhost -E -i "%HERE%create_sql_logins.sql" >> "%LOG%" 2>&1 ) else ( echo post_build: sqlcmd not found - skipping SQL logins >> "%LOG%" )
echo post_build: scaffolding nginx... >> "%LOG%"
"!BASH!" -lc "/cygdrive/c/Setup/setup_nginx.sh" >> "%LOG%" 2>&1
if /i "%STOPAT%"=="db" goto :stopped

rem --- Give each server its OWN per-instance cfg dir, from the applied cfg (setup_server_cfg.sh) ---
rem The repo launchers read each server's config from a PER-SERVER dir Src\Interface\<Server>\cfg
rem (AppServerApi: ..\..\..\cfg from bin\Debug\net10.0 ; the .NET FW servers: ..\..\cfg from
rem bin\Debug), NOT the shared Src\Interface\cfg where cfg.zip was applied. If that dir is missing
rem the server writes a default config on port 8008 and all four collide. setup_server_cfg.sh
rem recreates each per-server dir FRESH from the applied cfg, strips the XML namespaces from
rem AppServerApi.config (net10.0 rejects them), and clears read-only + grants the dev account
rem access (AppServerApi opens its config read/write; the cfg.zip source can carry restrictive
rem ACLs -> UnauthorizedAccessException). Runs here, AFTER the build (nant clean can't wipe it)
rem and in post_build's ELEVATED context (so the files are accessible to the elevated servers).
echo post_build: setting up per-server cfg dirs... >> "%LOG%"
>"%PHASE%" echo Configuring per-server cfg...
if exist "%~dp0setup_server_cfg.sh" ( "!BASH!" -lc "/cygdrive/c/Setup/setup_server_cfg.sh" >> "%LOG%" 2>&1 ) else ( echo post_build: setup_server_cfg.sh missing - skipping per-server cfg >> "%LOG%" )

rem Install the dev user's Cygwin bash config (curated .bashrc + the guide's .bash_aliases).
echo post_build: installing bash config for dev... >> "%LOG%"
if exist "%~dp0setup_bash_config.sh" ( "!BASH!" -lc "/cygdrive/c/Setup/setup_bash_config.sh" >> "%LOG%" 2>&1 )
rem Add the two Windows Terminal Cygwin profiles to dev's settings.json (runs as dev for LOCALAPPDATA).
echo post_build: adding Windows Terminal Cygwin profiles... >> "%LOG%"
if exist "%~dp0setup_terminal_profiles.ps1" ( powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_terminal_profiles.ps1" >> "%LOG%" 2>&1 )

rem --- Open inbound TCP for the WebEdition server ports so a clock device on a bridged network
rem can reach them. Windows Firewall blocks inbound by default and the install only opens port 22
rem (sshd), so without this a bridged device's connection to the hub is silently dropped (it
rem hangs) even though the server is listening. TerminalHubApi (8010) is the device-facing port;
rem all four servers bind all interfaces (see setup_server_cfg.sh - ApiServerHost 0.0.0.0), so a
rem device can reach any of them directly. Idempotent (keyed by rule name).
echo post_build: opening firewall for WebEdition ports (8008/8010/8012/8014)... >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-NetFirewallRule -Name TCPWebEdition -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name TCPWebEdition -DisplayName 'TCP WebEdition servers' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 8008,8010,8012,8014 }" >> "%LOG%" 2>&1
if /i "%STOPAT%"=="cfg" goto :stopped

rem --- Auto-start the SELECTED WebEdition servers on EVERY boot (persistent) via a scheduled task
rem that runs at startup as dev. start_servers.sh backgrounds the servers and returns, and
rem Task Scheduler does not kill the detached children, so they keep running. Then run it
rem once now so the stack is up immediately after this build (no reboot needed). nginx is
rem already a Windows service; SQL Server auto-starts; this brings up the 4 .NET servers.
rem Persist the server selection where start_servers.sh reads it on every boot (D: survives in
rem the OVA; the boot task passes no arg, so the script picks the selection up from this file).
>"D:\Tools\servers.spec" echo %SRVSPEC%
echo post_build: installing TCPStartServers boot task ^(servers: %SRVSPEC%^)... >> "%LOG%"
schtasks /create /tn TCPStartServers /tr "\"D:\Tools\cygwin\bin\bash.exe\" -lc /cygdrive/c/Setup/start_servers.sh" /sc onstart /ru dev /rp dev /rl highest /f >> "%LOG%" 2>&1
echo post_build: starting servers now ^(%SRVSPEC%^)... >> "%LOG%"
>"%PHASE%" echo Starting WebEdition servers...
schtasks /run /tn TCPStartServers >> "%LOG%" 2>&1

>"%PHASE%" echo Servers started - waiting for ports
>"D:\Tools\build.done" echo started %SRVSPEC%
echo ==== post_build done %DATE% %TIME% ==== >> "%LOG%"
endlocal
exit /b 0

rem --stop-at landed before 'servers': record the stopping point so the host watcher/exporter
rem knows the build is finished even though no ports will ever come up, and tag the timelapse.
:stopped
>"%PHASE%" echo Stopped at %STOPAT% (--stop-at)
>"D:\Tools\build.done" echo stopped %STOPAT%
echo ==== post_build done (stopped at %STOPAT%) %DATE% %TIME% ==== >> "%LOG%"
endlocal
exit /b 0
EOF

echo
echo "=================================================="
echo "VM CREATION COMPLETE"
echo "=================================================="
echo "Generated in: $VM_DIR"
echo "  bypass_checks.reg"
echo "  post_install_setup.sh"
echo "  setup_env_vars.cmd"
echo "  setup_powershell.ps1"
echo "  setup_nuget_source.cmd"
echo "  create_sql_logins.sql"
echo "  run_sql_logins.cmd"
echo "  build_server.sh"
echo "  build_client.sh"
echo "  clone_repos.sh"
echo "  setup_cygwin_ssh.sh"
echo "  setup_nginx.sh"
if [[ "$UNATTENDED" == true ]]; then
  # Per the guide: C: ~90 GB, D: takes the remainder. On a smaller --disk-size,
  # fall back to a 60% split so D: still gets a usable share.
  EFI_MSR_MB=116
  CDRIVE_MB=92160
  if [[ $(( DISK_SIZE_MB - EFI_MSR_MB - CDRIVE_MB )) -lt 30720 ]]; then
    CDRIVE_MB=$(( (DISK_SIZE_MB - EFI_MSR_MB) * 60 / 100 ))
  fi
  if [[ "$CDRIVE_MB" -lt 40960 ]]; then
    log_error "Disk too small for an unattended C:/D: split (need --disk-size >= ~70000 MB). Got C: would be ${CDRIVE_MB} MB."
    exit 1
  fi

  AUTOUNATTEND="${VM_DIR}/autounattend.xml"
  cat > "$AUTOUNATTEND" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">

    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Size>${CDRIVE_MB}</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>4</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>4</Order>
              <PartitionID>4</PartitionID>
              <Label>Work</Label>
              <Letter>D</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows 11 Pro</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>

      <UserData>
        <ProductKey>
          <Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>Developer</FullName>
        <Organization>TCP</Organization>
      </UserData>

    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>WIN11-DEV</ComputerName>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>dev</Name>
            <Group>Administrators</Group>
            <DisplayName>Developer</DisplayName>
            <Password>
              <Value>dev</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>dev</Username>
        <LogonCount>2</LogonCount>
        <Password>
          <Value>dev</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <TimeZone>UTC</TimeZone>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\setup\firstlogon.cmd call %d:\setup\firstlogon.cmd</CommandLine>
          <Description>Stage helper scripts and install Guest Additions</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>

</unattend>
EOF

  DDRIVE_MB=$(( DISK_SIZE_MB - EFI_MSR_MB - CDRIVE_MB ))
  log_info "Unattended install: C: ~${CDRIVE_MB} MB, D: ~${DDRIVE_MB} MB (Windows 11 Pro)"
  log_info "Answer file: $AUTOUNATTEND"

  # First-logon automation (runs once as the auto-logon dev user): copy the
  # helper scripts to C:\Setup, run the prerequisite-free PowerShell setup, then
  # silently install Guest Additions (pre-trusting the Oracle driver certs so no
  # dialog appears) and reboot so they activate. The credential/software-gated
  # scripts (Cygwin, dotnet, SQL, GitHub) stay manual — they're staged, not run.
  cat > "${VM_DIR}/firstlogon.cmd" <<'EOF'
@echo off
setlocal enableextensions enabledelayedexpansion

rem Locate the staged \setup folder on the install media. Optical drive letters
rem aren't stable at first logon, so scan all drives and retry until the media is
rem ready instead of trusting %~dp0 (which can point at the wrong drive here).
set "SRC="
for /l %%t in (1,1,15) do if not defined SRC (
  for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z C) do if exist "%%d:\setup\firstlogon.cmd" set "SRC=%%d:\setup"
  if not defined SRC ping -n 3 127.0.0.1 >nul
)

if not exist "C:\Setup" md "C:\Setup"
if defined SRC xcopy /e /i /y "!SRC!\*" "C:\Setup\" >nul

rem Put a README shortcut on the desktop (user profile, no elevation needed).
if exist "C:\Setup\README.md" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$l=(New-Object -ComObject WScript.Shell).CreateShortcut($env:USERPROFILE+'\Desktop\README.lnk'); $l.TargetPath='C:\Setup\README.md'; $l.WorkingDirectory='C:\Setup'; $l.Description='TCP dev environment next steps'; $l.Save()"

rem Desktop shortcut to (re)run the dev tools install manually later.
if exist "C:\Setup\run_setup.cmd" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$l=(New-Object -ComObject WScript.Shell).CreateShortcut($env:USERPROFILE+'\Desktop\TCP Dev Environment Setup.lnk'); $l.TargetPath='C:\Setup\run_setup.cmd'; $l.WorkingDirectory='C:\Setup'; $l.WindowStyle=7; $l.Description='Start or resume the TCP Dev Environment Setup'; $l.Save()"

if exist "C:\Setup\setup_powershell.ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Setup\setup_powershell.ps1"

rem Install Cygwin to D:\Tools\cygwin with wget and nano (needs internet; runs
rem elevated here, which Cygwin extraction requires).
if exist "C:\Setup\install_cygwin.cmd" call "C:\Setup\install_cygwin.cmd"

rem Schedule the heavy tool install (VS 2026, SQL Server, etc.) to run elevated at
rem the next logon - after the Guest Additions reboot - so the desktop is usable
rem while it runs. The on-demand copy in C:\Setup can also be run by hand.
if exist "C:\Setup\install_tools.cmd" schtasks /create /tn TCPInstallTools /tr "C:\Setup\install_tools.cmd" /sc onlogon /ru dev /rp dev /rl highest /f >nul 2>&1

rem Show a progress window in the interactive desktop at the next logon (when the
rem tool install runs) so the user knows to wait. An interactive logon task (/it)
rem reliably opens it in the user's session - more so than a RunOnce launch.
if not exist "D:\Tools" md "D:\Tools"
>"D:\Tools\install_status.txt" echo 1/8 Preparing background setup
if exist "C:\Setup\show_progress.ps1" schtasks /create /tn TCPSetupWindow /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Setup\show_progress.ps1" /sc onlogon /it /rl limited /f >nul 2>&1

rem Timelapse capture in the INTERACTIVE session (/it) so it grabs the live desktop - headless
rem host screenshots freeze on one frame. build-vm.sh --watch pulls D:\Tools\shots and assembles.
if exist "C:\Setup\capture_screens.ps1" schtasks /create /tn TCPCaptureScreens /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Setup\capture_screens.ps1" /sc onlogon /it /rl limited /f >nul 2>&1

set "GA="
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist "%%d:\VBoxWindowsAdditions.exe" set "GA=%%d:"
if defined GA (
  "!GA!\cert\VBoxCertUtil.exe" add-trusted-publisher "!GA!\cert\vbox-sha1.cer"   --root "!GA!\cert\vbox-sha1-root.cer"
  "!GA!\cert\VBoxCertUtil.exe" add-trusted-publisher "!GA!\cert\vbox-sha256.cer" --root "!GA!\cert\vbox-sha256-root.cer"
  "!GA!\VBoxWindowsAdditions.exe" /S
)

shutdown /r /t 5 /c "Post-install setup complete; rebooting for Guest Additions."
endlocal
EOF

  cat > "${VM_DIR}/README.md" <<'EOF'
# TCP Software Dev Environment - Next Steps

Windows, the `dev` account, Guest Additions, and the dev toolchain install automatically. The steps below are what **you** still need to do by hand to finish the build, because they need your credentials or choices. Work through them in order.

## What Runs Automatically When Credentials Are Supplied

If `build-vm.sh` was given `--gh-token` (and optionally `--gh-user`, `--aws-access-key`,
`--aws-secret-key`), these previously-manual steps already ran hands-free during setup:

- **Repo clone** - all `tcp-software` repos cloned to `D:\Work` over HTTPS and verified (`clone_repos.cmd`)
- **GitHub NuGet source** - `github_tcp` source added non-interactively (`configure_credentials.cmd`)
- **AWS keys** - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` set as machine env vars (region already set)
- The staged plaintext credentials were then **deleted** from `C:\Setup`, so this appliance carries none.

With `--post-build`, the server + client builds, DB restore, SQL logins, and nginx scaffold
also ran (see `install_tools.log`).

## The Servers (auto-started on every boot)

Everything runs automatically - toolchain, repo clone, server config (cfg.zip), build, DB
restore, SQL logins, nginx (a Windows service), AND all four WebEdition servers, which a
boot task (`TCPStartServers`) starts on **every boot** (and in an exported OVA):

- **AppServerApi** - employee/manager/webclock backend; web UI at http://localhost:8081/app/manager
- **AdmServerApi** - admin; web UI at http://localhost:8018/app/admin
- **TerminalHubApi** - the hub that **linclock / winclock / RDTg / POS** devices connect to
- **WorkstationHubApi** - workstation-attached terminals / biometric readers

Server logs are in `D:\Tools\serverlogs`. To start/stop a subset by hand:

    C:\Setup\start_servers.sh all | linclock | app | adm | terminal | workstation

For a **linclock** to connect: the servers are already up - just set the device's
NetworkSettings `serverUrl` to this VM's IP (use a **bridged** NIC so the device can reach
the VM; NAT is host-only). The clock talks to TerminalHubApi.

## >> Remaining Manual Steps <<

Only these still need a human (interactive sign-in or choices):

1. **Set a real password** for the `dev` account and turn off auto-logon
2. **Sign in to Visual Studio 2026** with your Professional license (VS installs and builds unactivated; sign-in is only for license compliance and can't be scripted)
3. **(Optional) SSH instead of HTTPS** - `C:\Setup\setup_cygwin_ssh.sh` + `ssh-keygen`, add the key to GitHub (the clone already used the token over HTTPS)
4. **Take a VM snapshot** once everything builds and runs

Optional, from the guide: the Cygwin / "Cygwin as Admin" Windows Terminal profiles and the `~/.bashrc` / `~/.bash_aliases` convenience config; and a version-switch helper (the guide's `select_we.sh`).

## What's Already Installed

- Windows 11 Pro (C: ~90 GB, work volume on D:), local admin `dev`, Guest Additions
- Cygwin at `D:\Tools\cygwin` with `wget` and `nano`
- .NET Framework 3.5 and the .NET SDKs 5, 6, and 10
- Visual Studio 2026 Professional with the ASP.NET/web, Node.js, .NET desktop, and Desktop C++ workloads
- SQL Server 2022 Developer (Database Engine, default instance `MSSQLSERVER`, `dev` added as sysadmin, data on D:, TCP and Named Pipes enabled, the `150` to `160` DAC symlink), plus SQL Package and SSMS
- Git, Node.js, Python, and OpenJDK 11
- `MSBUILD_PATH`, `NANT_BIN`, and `AWS_DEFAULT_REGION` set

## Re-running the Install

The toolchain install logs to `D:\Tools\install_tools.log` and shows a progress window with the installed-component summary, an Open-log button, and any errors. It's idempotent, so re-running skips finished pieces. To run or resume it manually, use the **"TCP Dev Environment Setup"** shortcut on the desktop (or `C:\Setup\install_tools.cmd`). `bypass_checks.reg` isn't needed here - the VM has TPM 2.0 and Secure Boot.
EOF

  cat > "${VM_DIR}/install_cygwin.cmd" <<'EOF'
@echo off
rem Unattended Cygwin install to D:\Tools\cygwin with wget and nano. Runs from
rem C:\Setup so %~dp0 is stable. Needs internet and elevation (Cygwin extraction
rem fails without it). Skips gracefully when offline so first logon doesn't hang.
if exist "D:\Tools\cygwin\bin\bash.exe" (echo Cygwin already installed & exit /b 0)
if not exist "%~dp0setup-x86_64.exe" (echo setup-x86_64.exe missing & exit /b 1)
ping -n 1 mirrors.kernel.org >nul 2>&1 || (echo No internet; skipping Cygwin install & exit /b 0)
"%~dp0setup-x86_64.exe" --quiet-mode --no-desktop --no-shortcuts --no-startmenu --root "D:\Tools\cygwin" --local-package-dir "D:\Tools\cygwin\packages" --site "https://mirrors.kernel.org/sourceware/cygwin/" --packages "wget,nano" --wait
EOF

  cat > "${VM_DIR}/install_tools.cmd" <<'EOF'
@echo off
rem ============================================================================
rem  TCP dev tools installer. Follows the two TCP guides (VS 2026 + .NET 10).
rem  Idempotent, network-resilient (waits/resumes on outage), cancellable
rem  (D:\Tools\install.cancel), logged to install_tools.log.
rem  TEST MODE: if "install.test" sits next to this script, every step just sleeps
rem  (a dummy package) so the whole flow verifies in well under a minute.
rem  Status protocol in D:\Tools\install_status.txt (read by show_progress.ps1):
rem    "N/8 msg" | "WAIT msg" | "ERROR msg" | "CANCELLED msg" | "8/8 Setup complete"
rem ============================================================================
setlocal enableextensions enabledelayedexpansion
if not exist "D:\Tools" md "D:\Tools"
set "LOG=D:\Tools\install_tools.log"
set "STATUS=D:\Tools\install_status.txt"
set "CANCEL=D:\Tools\install.cancel"
set "TESTMODE="
if exist "%~dp0install.test" set "TESTMODE=1"
del "%CANCEL%" >nul 2>&1
echo ==== install_tools started %DATE% %TIME% (test=!TESTMODE!) ==== >> "%LOG%"

set "CACHE="
net use V: >nul 2>&1 && net use V: /delete /y >nul 2>&1
net use V: \\vboxsvr\cache >nul 2>&1
if exist "V:\" ( set "CACHE=V:" & for %%p in (choco vscache sqlmedia) do if not exist "V:\%%p" md "V:\%%p" & echo Using cache V: >> "%LOG%" ) else ( echo No cache share >> "%LOG%" )

if not defined TESTMODE if not exist "D:\Tools\cygwin\bin\bash.exe" if exist "C:\Setup\install_cygwin.cmd" (
  call :netwait
  call "C:\Setup\install_cygwin.cmd" >> "%LOG%" 2>&1
)

call :setstep "1/8 Preparing package manager" || goto :cancelled
call :netwait
if defined TESTMODE ( call :dummy chocolatey ) else (
  where choco >nul 2>&1 || powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=3072; iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))" >> "%LOG%" 2>&1
  set "PATH=!PATH!;%ProgramData%\chocolatey\bin"
  if defined CACHE call choco config set cacheLocation "V:\choco" >> "%LOG%" 2>&1
)

rem SQL FIRST - before .NET FW 3.5 / VS, which pend a reboot that makes the choco SQL
rem package abort ("A system reboot is pending"). Installing it before anything pends a
rem reboot is the reliable fix. Retry up to 3x. choco downloads the Developer .iso + runs Setup.
call :setstep "2/8 Installing SQL Server 2022 Developer" || goto :cancelled
if defined TESTMODE ( call :dummy sqlserver2022 sqlpackage & goto :sqldone )
set "SQLTRY=0"
:sqlretry
sc query MSSQLSERVER >nul 2>&1 && goto :sqlpkg
set /a SQLTRY+=1
if !SQLTRY! GTR 3 ( echo SQL Server 2022 did not complete after 3 attempts >> "%LOG%" & goto :sqlpkg )
if exist "%CANCEL%" goto :cancelled
call :netwait
echo SQL 2022 install attempt !SQLTRY! %DATE% %TIME% >> "%LOG%"
rem Cache the SQL media on a LOCAL fixed drive, not the V: shared folder. The package
rem downloads the Developer .iso to the choco cache and Mount-DiskImage's it; mounting an
rem ISO from a network/shared-folder path fails ("parameter is incorrect / path format
rem not supported"), so override --cache-location to D: for this install only.
if not exist D:\chococache md D:\chococache
call choco install sql-server-2022 -y --no-progress --cache-location="D:\chococache" --params="'/INSTANCENAME:MSSQLSERVER /FEATURES:SQLENGINE /SQLSYSADMINACCOUNTS:BUILTIN\Administrators /TCPENABLED:1 /NPENABLED:1 /INSTALLSQLDATADIR:D:\MSSQL /SQLSVCSTARTUPTYPE:Automatic'" >> "%LOG%" 2>&1
goto :sqlretry
:sqlpkg
rem DAC compatibility symlink referenced by the guide (150 -> 160)
if exist "C:\Program Files\Microsoft SQL Server\160\DAC" if not exist "C:\Program Files\Microsoft SQL Server\150\DAC" (
  if not exist "C:\Program Files\Microsoft SQL Server\150" md "C:\Program Files\Microsoft SQL Server\150"
  mklink /D "C:\Program Files\Microsoft SQL Server\150\DAC" "C:\Program Files\Microsoft SQL Server\160\DAC" >> "%LOG%" 2>&1
)
rem SQL Package (DacFx / SqlPackage) per the guide.
reg query "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Data-Tier Application Framework" >nul 2>&1 || (
  curl -L -o "%TEMP%\DacFramework.msi" "https://go.microsoft.com/fwlink/?linkid=2196438" >> "%LOG%" 2>&1
  msiexec /i "%TEMP%\DacFramework.msi" /quiet /norestart >> "%LOG%" 2>&1
)
:sqldone

call :setstep "3/8 Enabling .NET Framework 3.5" || goto :cancelled
if defined TESTMODE ( call :dummy netfx35 ) else ( dism /online /enable-feature /featurename:NetFx3 /all /norestart >> "%LOG%" 2>&1 )

call :setstep "4/8 Installing Git, Node.js and Python" || goto :cancelled
call :netwait
if defined TESTMODE ( call :dummy git nodejs python ) else (
  call choco install -y git        >> "%LOG%" 2>&1
  call choco install -y nodejs-lts >> "%LOG%" 2>&1
  call choco install -y python     >> "%LOG%" 2>&1
)

call :setstep "5/8 Installing OpenJDK 11 and the .NET SDKs (5, 6, 10)" || goto :cancelled
call :netwait
if defined TESTMODE ( call :dummy openjdk11 dotnet5 dotnet6 dotnet10 ) else (
  call choco install -y microsoft-openjdk11 >> "%LOG%" 2>&1
  call choco install -y dotnet-5.0-sdk      >> "%LOG%" 2>&1
  call choco install -y dotnet-6.0-sdk      >> "%LOG%" 2>&1
  call choco install -y dotnet-10.0-sdk --force >> "%LOG%" 2>&1
)

call :setstep "6/8 Installing SQL Server Management Studio" || goto :cancelled
call :netwait
if defined TESTMODE ( call :dummy ssms ) else ( call choco install -y sql-server-management-studio >> "%LOG%" 2>&1 )

rem OpenSSH server (before Visual Studio): install the Windows OpenSSH.Server capability,
rem set sshd (and ssh-agent) to start automatically AT EVERY BOOT, ENABLE PASSWORD LOGINS in
rem sshd_config, open inbound TCP 22, and (re)start the service so it's live now.
echo ==== installing OpenSSH server %DATE% %TIME% ==== >> "%LOG%"
if defined TESTMODE ( call :dummy opensshserver ) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >> "%LOG%" 2>&1
  rem Auto-start at every boot. (sc config also belt-and-suspenders in case the service exists.)
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue; Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service sshd" >> "%LOG%" 2>&1
  sc config sshd start= auto >> "%LOG%" 2>&1
  rem Open inbound TCP 22.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }" >> "%LOG%" 2>&1
  rem Enable password authentication: starting sshd once creates the default sshd_config, then
  rem force 'PasswordAuthentication yes' (replace any existing/commented line, else append) and
  rem restart so it takes effect. PubkeyAuthentication stays on too.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='C:\ProgramData\ssh\sshd_config'; if (Test-Path $f) { $c = Get-Content $f; $c = $c -replace '^\s*#?\s*PasswordAuthentication\s+.*','PasswordAuthentication yes'; if (($c -join \"`n\") -notmatch '(?m)^PasswordAuthentication yes') { $c += 'PasswordAuthentication yes' }; Set-Content -Path $f -Value $c -Encoding ascii }" >> "%LOG%" 2>&1
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Restart-Service sshd -ErrorAction SilentlyContinue" >> "%LOG%" 2>&1
)

call :setstep "7/8 Installing Visual Studio 2026 - largest step, please keep waiting" || goto :cancelled
if defined TESTMODE ( call :dummy visualstudio2026 & goto :vsdone )
rem VS refuses a shared-folder payload cache ("not a fixed drive" -> setup.exe exits 1
rem and installs nothing), so keep its cache on the local fixed disk D:, never V:.
if not exist "D:\vscache" md "D:\vscache"
reg add "HKLM\SOFTWARE\Microsoft\VisualStudio\Setup" /v CachePath /t REG_SZ /d "D:\vscache" /f >> "%LOG%" 2>&1
if defined CACHE reg add "HKLM\SOFTWARE\Microsoft\VisualStudio\Setup" /v KeepDownloadedPayloads /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
rem Retry the VS install up to 3 times: a network drop mid-install otherwise leaves it
rem half-done (no devenv.exe). netwait pauses until connectivity returns before each try.
set "VSTRY=0"
:vsretry
if exist "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\IDE\devenv.exe" goto :vsdone
set /a VSTRY+=1
if !VSTRY! GTR 3 ( echo VS 2026 did not complete after 3 attempts >> "%LOG%" & goto :vsdone )
if exist "%CANCEL%" goto :cancelled
call :netwait
echo VS 2026 install attempt !VSTRY! %DATE% %TIME% >> "%LOG%"
taskkill /f /im vs_installer.exe /im vs_installershell.exe /im vs_setup_bootstrapper.exe /im setup.exe >nul 2>&1
curl -L -o "%TEMP%\vs_boot.exe" https://aka.ms/vs/18/insiders/vs_professional.exe >> "%LOG%" 2>&1
"%TEMP%\vs_boot.exe" --quiet --norestart --wait --add Microsoft.VisualStudio.Workload.NetWeb --add Microsoft.VisualStudio.Workload.Node --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended >> "%LOG%" 2>&1
goto :vsretry
:vsdone

call :setstep "8/8 Finishing up - env vars and cloning repos" || goto :cancelled
if not defined TESTMODE (
  setx /M MSBUILD_PATH "C:\Program Files\Microsoft Visual Studio\18\Insiders\MSBuild\Current\Bin" >> "%LOG%" 2>&1
  setx /M NANT_BIN "D:\Work\tcp-we-thirdparty\Nant\0.92\bin" >> "%LOG%" 2>&1
  setx /M AWS_DEFAULT_REGION "us-east-1" >> "%LOG%" 2>&1
  rem Put the version-switch helper select_we.sh on PATH: copy it to D:\scripts (the guide's
  rem scripts dir) and add that dir to the machine PATH, so 'select_we.sh' runs by name from a
  rem Cygwin shell. PowerShell appends to the MACHINE Path idempotently (no %PATH% bloat).
  if not exist D:\scripts md D:\scripts
  if exist "%~dp0select_we.sh" copy /y "%~dp0select_we.sh" D:\scripts\select_we.sh >> "%LOG%" 2>&1
  powershell -NoProfile -Command "$p=[Environment]::GetEnvironmentVariable('Path','Machine'); if ($p -notmatch [regex]::Escape('D:\scripts')) { [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';D:\scripts'), 'Machine') }" >> "%LOG%" 2>&1
  rem Non-interactive credential config: AWS env vars + GitHub NuGet source (no-op if no creds staged).
  if exist "%~dp0configure_credentials.cmd" cmd /c "%~dp0configure_credentials.cmd"
)
echo ==== STEP8-MARKER-A: env vars set, entering completion check %DATE% %TIME% ==== >> "%LOG%"

if defined TESTMODE (
  echo ==== install_tools TEST finished %DATE% %TIME% ==== >> "%LOG%"
  echo [TEST] would clone repos: tcp-cs-60, tcp-tl-70 >> "%LOG%"
  >"%STATUS%" echo 8/8 Setup complete - tools installed, repos cloned [test]
  rem Dry run starts no servers, so signal the timelapse capture to stop now (no ports to wait on).
  >"D:\Tools\capture.stop" echo stop
  goto :realend
)

set "MISSING="
if not exist "D:\Tools\cygwin\bin\bash.exe" set "MISSING=!MISSING! Cygwin"
rem Check install paths, not %PATH% - this elevated task's PATH isn't refreshed after install.
if not exist "C:\Program Files\Git\cmd\git.exe" set "MISSING=!MISSING! Git"
if not exist "C:\Program Files\nodejs\node.exe" set "MISSING=!MISSING! Node"
if not exist "C:\Program Files\dotnet\dotnet.exe" set "MISSING=!MISSING! dotnet"
if not exist "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\IDE\devenv.exe" set "MISSING=!MISSING! VisualStudio"
sc query MSSQLSERVER >nul 2>&1 || set "MISSING=!MISSING! SQLServer"
echo ==== install_tools finished %DATE% %TIME% (missing:!MISSING!) ==== >> "%LOG%"
if defined MISSING (
  >"%STATUS%" echo ERROR Some tools did not install:!MISSING! - click Retry
) else (
  if exist "%~dp0skip_clone.do" (>"%STATUS%" echo 8/8 Setup complete - tools installed ^(clone skipped^)) else (>"%STATUS%" echo 8/8 Setup complete - tools installed, repos cloned)
  schtasks /delete /tn TCPInstallTools /f >nul 2>&1
  schtasks /delete /tn TCPSetupWindow /f >nul 2>&1
  schtasks /delete /tn TCPCaptureScreens /f >nul 2>&1
)
rem Clone repos LAST, AFTER the status is recorded. This validation step has hung the
rem installer before the completion write, so it must never gate completion/export.
echo ==== cloning repos %DATE% %TIME% ==== >> "%LOG%"
rem skip_clone.do means "the repos are already present - skip the clone step" (independent of
rem whether post_build runs). --stop-at tools stages it with NO post_build.do (toolchain only);
rem an incremental re-run can stage it WITH post_build.do to advance a build phase without paying
rem for a multi-GB re-clone. CLONEFAIL gates post_build so a failed clone never builds.
set "CLONEFAIL="
if exist "%~dp0skip_clone.do" (
  echo ==== clone SKIPPED ^(skip_clone.do; repos assumed present^) %DATE% %TIME% ==== >> "%LOG%"
  if not exist D:\Work md D:\Work
  if not exist D:\Work\clone_status.txt >"D:\Work\clone_status.txt" echo CLONE-OK
) else (
  rem Publish a phase label for the timelapse caption (capture_screens.ps1 reads build_phase.txt).
  >"D:\Tools\build_phase.txt" echo Cloning repositories...
  if exist "%~dp0clone_repos.cmd" (
    cmd /c "%~dp0clone_repos.cmd" >> "%LOG%" 2>&1
    if errorlevel 1 (
      echo ==== CLONE STAGE FAILED - working tree incomplete, build stage must not run %DATE% %TIME% ==== >> "%LOG%"
      if not exist D:\Work md D:\Work
      >"D:\Work\clone_status.txt" echo CLONE-FAILED
      set "CLONEFAIL=1"
    ) else (
      echo ==== CLONE STAGE OK %DATE% %TIME% ==== >> "%LOG%"
      if not exist D:\Work md D:\Work
      >"D:\Work\clone_status.txt" echo CLONE-OK
    )
  )
)
rem Run post_build (if staged) after a non-failed clone/skip; otherwise mark the build done so the
rem host watcher/exporter knows a clone-only or tools-only run is finished. ('tools' when the clone
rem was skipped, 'clone' when it actually cloned.)
if not defined CLONEFAIL (
  if exist "%~dp0post_build.do" if exist "%~dp0post_build.cmd" cmd /c "%~dp0post_build.cmd"
  if not exist "%~dp0post_build.do" (
    if exist "%~dp0skip_clone.do" ( >"D:\Tools\build.done" echo tools ) else ( >"D:\Tools\build.done" echo clone )
  )
)
rem OVA hygiene: delete the plaintext credentials staged in C:\Setup so the exported
rem appliance never carries the GitHub token or AWS keys. Clone + NuGet config already ran.
del "%~dp0gh_token.txt" "%~dp0gh_user.txt" "%~dp0aws_access_key.txt" "%~dp0aws_secret_key.txt" >> "%LOG%" 2>&1
echo ==== staged credentials removed from C:\Setup %DATE% %TIME% ==== >> "%LOG%"
goto :realend

:cancelled
echo ==== cancelled by user %DATE% %TIME% ==== >> "%LOG%"
>"%STATUS%" echo CANCELLED Install cancelled - click Retry to resume
goto :realend

:dummy
echo [TEST] dummy package: %* >> "%LOG%"
ping -n 4 127.0.0.1 >nul
exit /b 0

:setstep
if exist "%CANCEL%" exit /b 1
>"%STATUS%" echo %~1
exit /b 0

:netwait
ping -n 1 chocolatey.org >nul 2>&1 && exit /b 0
:netwait_loop
if exist "%CANCEL%" exit /b 0
>"%STATUS%" echo WAIT Network unavailable - will resume automatically when reconnected
ping -n 6 127.0.0.1 >nul
ping -n 1 chocolatey.org >nul 2>&1 || goto :netwait_loop
exit /b 0

:realend
endlocal
exit /b
EOF

  # Interactive progress window. install_tools runs in a non-interactive task
  # session, so its own windows aren't visible; this runs in the user's desktop
  # session (launched via RunOnce by firstlogon) and reflects install_status.txt.
cat > "${VM_DIR}/show_progress.ps1" <<'EOF'
# Single-instance guard so only one progress window ever shows. Treat an
# abandoned mutex (a previous instance exited without releasing) as acquirable
# rather than letting WaitOne throw and crash this instance.
$mutex = New-Object System.Threading.Mutex($false, 'TCPSetupProgressWindow')
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { exit }

# High priority works properly now that the script isn't pinning the execution thread.
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$statusFile = 'D:\Tools\install_status.txt'
$cancelFile = 'D:\Tools\install.cancel'
$logFile    = 'D:\Tools\install_tools.log'
$phaseFile  = 'D:\Tools\build_phase.txt'
# Ordered post-build phases (post_build.cmd / clone_repos write these to build_phase.txt). The
# toolchain (N/8 in install_status.txt) is the install; these are the "finishing" stages. Driving
# the dialog through them keeps the message box showing the stage actually running - so the
# timelapse shows every stage instead of freezing on "Setup complete" once tools are installed.
$phaseOrder = @(
  'Cloning repositories...',
  'Building server...',
  'Building client...',
  'Restoring test database...',
  'Configuring per-server cfg...',
  'Starting WebEdition servers...',
  'Servers started - waiting for ports'
)
$postBuildShown = $false
$finished = $false

function Trigger-Install {
  schtasks /query /tn TCPInstallTools >$null 2>&1
  if ($LASTEXITCODE -eq 0) { schtasks /run /tn TCPInstallTools >$null 2>&1 }
  else { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','C:\Setup\install_tools.cmd' -Verb RunAs }
}

# Build "tool -> install location" summary by probing known install paths.
function Get-Summary {
  $rows = New-Object System.Collections.Generic.List[string]
  function Loc($name, $globs) {
    foreach ($g in $globs) { $p = Get-Item $g -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p) { $rows.Add(("  {0,-26}{1}" -f $name, $p.FullName)); return } }
    $rows.Add(("  {0,-26}(not installed)" -f $name))
  }
  Loc 'Cygwin (wget, nano)' @('D:\Tools\cygwin\bin\bash.exe')
  Loc 'Git'                @('C:\Program Files\Git\cmd\git.exe')
  Loc 'Node.js'            @('C:\Program Files\nodejs\node.exe')
  Loc 'Python'             @('C:\Python3*\python.exe','C:\Program Files\Python3*\python.exe')
  Loc 'OpenJDK 11'         @('C:\Program Files\Microsoft\jdk-11*\bin\java.exe')
  Loc '.NET 10 SDK'        @('C:\Program Files\dotnet\dotnet.exe')
  Loc 'SSMS'               @('C:\Program Files*\Microsoft SQL Server Management Studio*\*\Common7\IDE\Ssms.exe')
  Loc 'Visual Studio 2026' @('C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\IDE\devenv.exe')
  $svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
  if ($svc) { $rows.Add(("  {0,-26}{1} (service {2})" -f 'SQL Server 2022','C:\Program Files\Microsoft SQL Server','' + $svc.Status)) }
  else { $rows.Add(("  {0,-26}(not installed)" -f 'SQL Server 2022')) }
  return ($rows -join "`r`n")
}

# Pull error-looking lines out of the install log. Read only the TAIL (not a
# Select-String over the whole file) so this can never block the UI thread on a
# multi-MB log - that blocking was a contributor to the window freezing.
function Get-LogErrors {
  if (-not (Test-Path $logFile)) { return '(log not found)' }
  $tail = @(); try { $tail = @(Get-Content $logFile -Tail 400 -ErrorAction Stop) } catch { return '(log unavailable)' }
  $errs = $tail | Where-Object { $_ -match 'error|failed|denied|cannot find|not recognized|unable to' -and $_ -notmatch 'Saving|Progress|0 error|no error|errorlevel' } |
          Select-Object -Last 15 | ForEach-Object { $_.Trim() }
  if ($errs) { return ($errs -join "`r`n") } else { return '(no errors logged)' }
}

# --- GUI Form Setup ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TCP Dev Environment Setup'
$form.Size = New-Object System.Drawing.Size(580,300)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Setting up your development tools'
$title.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true; $title.Location = New-Object System.Drawing.Point(16,14)
$form.Controls.Add($title)

$msg = New-Object System.Windows.Forms.Label
$msg.Text = 'Visual Studio, SQL Server and other tools are installing in the background. This can take up to an hour. Please keep the VM running and avoid starting heavy work or shutting it down until this finishes.'
$msg.Size = New-Object System.Drawing.Size(540,56); $msg.Location = New-Object System.Drawing.Point(16,44)
$form.Controls.Add($msg)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Size = New-Object System.Drawing.Size(540,22); $bar.Location = New-Object System.Drawing.Point(16,108)
$bar.Minimum = 0; $bar.Maximum = 100; $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30
$form.Controls.Add($bar)

$step = New-Object System.Windows.Forms.Label
$step.Text = 'Starting background setup...'
$step.Size = New-Object System.Drawing.Size(540,22); $step.Location = New-Object System.Drawing.Point(16,138)
$form.Controls.Add($step)

$details = New-Object System.Windows.Forms.TextBox
$details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
$details.Font = New-Object System.Drawing.Font('Consolas',9)
$details.Size = New-Object System.Drawing.Size(540,150); $details.Location = New-Object System.Drawing.Point(16,210)
$details.Visible = $false
$form.Controls.Add($details)

$cancelBtn = New-Object System.Windows.Forms.Button
$cancelBtn.Text = 'Cancel install'; $cancelBtn.Size = New-Object System.Drawing.Size(120,30); $cancelBtn.Location = New-Object System.Drawing.Point(16,172)
$cancelBtn.Add_Click({
  New-Item -ItemType File -Path $cancelFile -Force | Out-Null
  schtasks /end /tn TCPInstallTools >$null 2>&1
  $cancelBtn.Enabled = $false; $step.Text = 'Cancelling after the current step...'
})
$form.Controls.Add($cancelBtn)

$logBtn = New-Object System.Windows.Forms.Button
$logBtn.Text = 'Open log'; $logBtn.Size = New-Object System.Drawing.Size(90,30); $logBtn.Location = New-Object System.Drawing.Point(264,172); $logBtn.Visible = $false
$logBtn.Add_Click({ if (Test-Path $logFile) { Start-Process notepad.exe $logFile } })
$form.Controls.Add($logBtn)

$retryBtn = New-Object System.Windows.Forms.Button
$retryBtn.Text = 'Retry'; $retryBtn.Size = New-Object System.Drawing.Size(90,30); $retryBtn.Location = New-Object System.Drawing.Point(364,172); $retryBtn.Visible = $false
$retryBtn.Add_Click({
  Remove-Item $cancelFile -ErrorAction SilentlyContinue
  $retryBtn.Visible=$false; $closeBtn.Visible=$false; $logBtn.Visible=$false; $details.Visible=$false
  $cancelBtn.Enabled=$true; $cancelBtn.Visible=$true; $step.ForeColor=[System.Drawing.Color]::Black
  $form.Size = New-Object System.Drawing.Size(580,300); $bar.Style='Marquee'; $step.Text='Restarting setup...'
  # Enable timer polling again for the retry sequence
  $uiTimer.Start()
  Trigger-Install
})
$form.Controls.Add($retryBtn)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = 'Close'; $closeBtn.Size = New-Object System.Drawing.Size(90,30); $closeBtn.Location = New-Object System.Drawing.Point(464,172); $closeBtn.Visible = $false
$closeBtn.Add_Click({ $form.Close() })
$form.Controls.Add($closeBtn)

function Show-Details($text) {
  $details.Text = $text; $details.Visible = $true
  $details.Select(0,0)
  $form.Size = New-Object System.Drawing.Size(580,420)
  $logBtn.Visible = $true; $closeBtn.Visible = $true
}

# --- Asynchronous Form UI Timer Integration ---
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 1500
$uiTimer.Add_Tick({
  try {
    # Post-build phase tracking. Once post_build starts writing build_phase.txt, the toolchain
    # install (N/8) is done; advance the dialog through the clone/build/restore/start phases so
    # the message box always reflects the stage running now (read from the log via build_phase.txt),
    # rather than sitting frozen on "Step 8 of 8: Setup complete". This is what makes the timelapse
    # show every stage. Checked first so it takes over from the N/8 status once finishing begins.
    $phase = $null
    if (Test-Path $phaseFile) { try { $phase = (Get-Content $phaseFile -ErrorAction Stop | Select-Object -Last 1) } catch {} }
    if ($phase -and -not $script:finished) {
      if (-not $script:postBuildShown) {
        $script:postBuildShown = $true
        $title.Text = 'Finishing setup'
        $msg.Text = 'Tools are installed. Now cloning the repositories, building the server and client, restoring the test database, and starting the WebEdition servers. This also takes a while - please keep the VM running.'
        $cancelBtn.Visible = $false
        $bar.Style = 'Continuous'
      }
      $idx = [array]::IndexOf($phaseOrder, $phase.Trim())
      if ($idx -ge 0) { $bar.Value = [math]::Min(100, [int]((($idx + 1) / $phaseOrder.Count) * 100)) }
      $step.Text = $phase
      # Finalize when the guest marks the build done (D:\Tools\build.done). post_build writes it
      # for every outcome - full run, a --servers subset, or a --stop-at early stop - so the dialog
      # finalizes regardless of which (or how many) servers were started, instead of waiting for
      # all four ports that a subset/early-stop run will never bring up.
      if (Test-Path 'D:\Tools\build.done') {
        $script:finished = $true
        $bar.Value = 100
        $done = ''
        try { $done = (Get-Content 'D:\Tools\build.done' -ErrorAction Stop | Select-Object -Last 1) } catch {}
        $step.Text = if ($done -match 'stopped') { "Build complete - $done" } else { 'Build complete - servers started' }
        $step.ForeColor = [System.Drawing.Color]::DarkGreen
        $uiTimer.Stop()
        Show-Details (Get-Summary)
      }
      return
    }

    $line = $null
    if (Test-Path $statusFile) {
      try { $line = (Get-Content $statusFile -ErrorAction Stop | Select-Object -Last 1) } catch {}
    }

    if (-not $line) { return }

    # Pattern check to see if the engine status yields structural data: "1/5 Installing..."
    if ($line -match '^\s*(\d+)\s*/\s*(\d+)\s+(.*)$') {
      $n = [int]$matches[1]; $total = [int]$matches[2]; $txt = $matches[3]
      $bar.Style = 'Continuous'
      $bar.Value = [math]::Min(100, [math]::Max(0, [int](($n / $total) * 100)))
      $step.Text = ("Step {0} of {1}: {2}" -f $n, $total, $txt)
    } 
    else {
      # Handle special keyword results written to the status file
      switch -regex ($line) {
        'SUCCESS' {
          $uiTimer.Stop()
          $cancelBtn.Visible = $false
          $bar.Style = 'Continuous'; $bar.Value = 100
          $step.Text = 'All tools installed successfully.'
          $step.ForeColor = [System.Drawing.Color]::DarkGreen
          Show-Details (Get-Summary)
        }
        'CANCELLED' {
          $uiTimer.Stop()
          $cancelBtn.Visible = $false
          $bar.Style = 'Continuous'; $bar.Value = 0
          $step.Text = 'Installation cancelled by user.'
          $step.ForeColor = [System.Drawing.Color]::DarkRed
          $retryBtn.Visible = $true
          Show-Details (Get-LogErrors)
        }
        'ERROR' {
          $uiTimer.Stop()
          $cancelBtn.Visible = $false
          $bar.Style = 'Continuous'; $bar.Value = 0
          $step.Text = 'Installation failed with errors.'
          $step.ForeColor = [System.Drawing.Color]::DarkRed
          $retryBtn.Visible = $true
          Show-Details (Get-LogErrors)
        }
        default {
          # Fallback if text line is present but does not match standard patterns
          $step.Text = $line
        }
      }
    }
  } 
  catch {
    # Absolute catch fallback so errors never stall out the async rendering engine
  }
})

# Launch background execution task immediately
Trigger-Install

# Fire up asynchronous monitoring ticks and pass window threads over to the Windows Form lifecycle manager
$uiTimer.Start()
[System.Windows.Forms.Application]::Run($form)
EOF

# Timelapse frame capture, run INSIDE the guest's interactive session (scheduled /it by
# firstlogon). It grabs the live desktop every 20s and burns the current install step into each
# frame, saving to D:\Tools\shots. This replaces host-side VBoxManage screenshotpng, which
# FREEZES on a single image in headless mode (the SVGA framebuffer isn't refreshed without a
# display front-end) - that is why the old timelapse got stuck on the SQL step. build-vm.sh
# --watch (watch_capture) pulls these frames and assembles the mp4. Stops at "8/8 Setup
# complete"/ERROR, when D:\Tools\capture.stop appears, or after a ~4h cap.
cat > "${VM_DIR}/capture_screens.ps1" <<'EOF'
$mutex = New-Object System.Threading.Mutex($false, 'TCPCaptureScreens')
try { $ok = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ok = $true }
if (-not $ok) { exit }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$dir = 'D:\Tools\shots'; $statusFile = 'D:\Tools\install_status.txt'; $stopFile = 'D:\Tools\capture.stop'
$phaseFile = 'D:\Tools\build_phase.txt'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item (Join-Path $dir 'shot-*.png') -Force -ErrorAction SilentlyContinue
Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
Remove-Item $phaseFile -Force -ErrorAction SilentlyContinue
# Keep capturing through the toolchain (N/8), then the post-8/8 phases (clone, server/client
# build, DB restore, server startup). The host (watch_capture) stops us via $stopFile once all
# four servers are listening; $maxFrames (~5.5h at 20s) is just a safety cap.
$n = 0; $maxFrames = 1000; $serverUpCount = 0
$font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190,0,0,0))
while ($n -lt $maxFrames) {
  if (Test-Path $stopFile) { break }
  # Caption from the post-build phase file when present (it has clone/build/server detail),
  # otherwise the N/8 install status.
  $step = ''
  try { if (Test-Path $phaseFile) { $step = (Get-Content $phaseFile -ErrorAction Stop | Select-Object -Last 1) } } catch {}
  try { if (-not $step -and (Test-Path $statusFile)) { $step = (Get-Content $statusFile -ErrorAction Stop | Select-Object -Last 1) } } catch {}
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $txt = ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $step)
    $sz = $g.MeasureString($txt, $font)
    $g.FillRectangle($bg, 6, ($vs.Height - $sz.Height - 10), ($sz.Width + 10), ($sz.Height + 6))
    $g.DrawString($txt, $font, [System.Drawing.Brushes]::Yellow, 10, ($vs.Height - $sz.Height - 7))
    $g.Dispose()
    $bmp.Save((Join-Path $dir ('shot-{0:D5}.png' -f $n)), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $n++
  } catch {}
  # Stop a few frames after the build is marked done (D:\Tools\build.done covers a full run, a
  # --servers subset, and a --stop-at early stop), so the timelapse runs through (and briefly
  # past) the final stage even when the host isn't watching. A subset/early-stop run never brings
  # up all four ports, so keying off build.done - not a 4-port check - is what lets it finish.
  try {
    if (Test-Path 'D:\Tools\build.done') { $serverUpCount++ } else { $serverUpCount = 0 }
    if ($serverUpCount -ge 3) { break }
  } catch {}
  Start-Sleep -Seconds 20
}
EOF

  # Manual launcher (desktop shortcut points here) to (re)run the install later.
  # Shows the progress window (non-elevated) and runs the installer elevated (UAC).
  # install_tools.cmd is idempotent, so already-installed parts are skipped.
  cat > "${VM_DIR}/run_setup.cmd" <<'EOF'
@echo off
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Setup\show_progress.ps1"
powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','C:\Setup\install_tools.cmd' -Verb RunAs"
EOF

  # VBoxManage warns if LOGNAME/USER don't match the effective user.
  RUN_USER=$(whoami)
  export LOGNAME="$RUN_USER" USER="$RUN_USER"

  check_unattended_deps

  # Cygwin's command-line installer, cached on the host so repeat runs reuse it.
  mkdir -p "$CACHE_DIR"
  CYGWIN_CACHE="${CACHE_DIR}/setup-x86_64.exe"
  if [[ ! -s "$CYGWIN_CACHE" ]]; then
    log_info "Downloading Cygwin installer..."
    wget -q -O "$CYGWIN_CACHE" https://www.cygwin.com/setup-x86_64.exe \
      || curl -fsSL -o "$CYGWIN_CACHE" https://www.cygwin.com/setup-x86_64.exe \
      || log_warn "Could not download Cygwin installer; Cygwin auto-install will be skipped."
  fi
  CYGWIN_SETUP="${VM_DIR}/setup-x86_64.exe"
  [[ -s "$CYGWIN_CACHE" ]] && cp "$CYGWIN_CACHE" "$CYGWIN_SETUP"

  # Stage only the helper scripts (not the .vdi/.iso/.vbox) onto the install media.
  STAGE_DIR=$(mktemp -d)
  for f in bypass_checks.reg post_install_setup.sh setup_env_vars.cmd setup_powershell.ps1 \
           setup_nuget_source.cmd configure_credentials.cmd create_sql_logins.sql run_sql_logins.cmd build_server.sh \
           build_client.sh setup_server_cfg.sh start_servers.sh select_we.sh setup_bash_config.sh setup_terminal_profiles.ps1 post_build.cmd clone_repos.sh clone_repos.cmd setup_cygwin_ssh.sh setup_nginx.sh firstlogon.cmd \
           install_cygwin.cmd install_tools.cmd show_progress.ps1 capture_screens.ps1 run_setup.cmd setup-x86_64.exe README.md; do
    [[ -f "${VM_DIR}/${f}" ]] && cp "${VM_DIR}/${f}" "$STAGE_DIR/"
  done
  # Dry run (--dry-run): drop the install.test marker into \setup\ so the in-guest tool
  # installer runs its dummy path (each step sleeps ~3s instead of installing).
  if [[ "$DRY_RUN" == true ]]; then
    : > "$STAGE_DIR/install.test"
    log_info "Dry run: staged the dummy-install marker (in-guest tool install will sleep, not install)."
  fi
  # Inject a GitHub token (plaintext) so the guest can clone private repos over
  # HTTPS without an SSH key. Used by install_tools.cmd's clone step. SECURITY:
  # this writes the token onto the install media and into C:\Setup in the guest.
  if [[ -n "$GH_TOKEN" ]]; then
    printf '%s' "$GH_TOKEN" > "$STAGE_DIR/gh_token.txt"
    log_info "Injected GitHub token for guest clone + NuGet source (staged as gh_token.txt; deleted from the guest after use)."
  fi
  # Optional credentials folded into the guest's non-interactive credential config.
  # All plaintext on the install media; install_tools.cmd deletes them from C:\Setup
  # after use so the exported OVA doesn't carry them.
  if [[ -n "$GH_USER" ]]; then
    printf '%s' "$GH_USER" > "$STAGE_DIR/gh_user.txt"
    log_info "Staged GitHub username for the NuGet source (gh_user.txt)."
  fi
  if [[ -n "$AWS_ACCESS_KEY" && -n "$AWS_SECRET_KEY" ]]; then
    printf '%s' "$AWS_ACCESS_KEY" > "$STAGE_DIR/aws_access_key.txt"
    printf '%s' "$AWS_SECRET_KEY" > "$STAGE_DIR/aws_secret_key.txt"
    log_info "Staged AWS keys for the guest (aws_access_key.txt / aws_secret_key.txt; deleted after use)."
  elif [[ -n "$AWS_ACCESS_KEY" || -n "$AWS_SECRET_KEY" ]]; then
    log_warn "Only one of --aws-access-key / --aws-secret-key was given; need both. Skipping AWS injection."
  fi
  # Post-build runs by DEFAULT now (no flag): after a verified clone the guest builds
  # server+client, applies cfg.zip, restores the DB, creates SQL logins, and scaffolds
  # nginx. (install_tools.cmd only reaches it on a real run; --dry-run short-circuits first.)
  # --stop-at controls how far it goes: 'clone' skips post_build entirely (stop after the
  # toolchain + clone); otherwise post_build runs and reads post_build.stop to know which phase
  # to stop after, and servers.spec to know which servers to start.
  [[ "$STOP_AT" == "all" ]] && STOP_AT="servers"
  [[ -z "${SERVERS_SPEC// /}" ]] && SERVERS_SPEC="all"
  if [[ "$STOP_AT" == "tools" || "$STOP_AT" == "clone" ]]; then
    # Neither stage runs post_build (no post_build.do staged). 'tools' also tells the guest to
    # skip the clone step itself, via the skip_clone.do marker.
    if [[ "$STOP_AT" == "tools" ]]; then
      : > "$STAGE_DIR/skip_clone.do"
      log_info "--stop-at tools: install the toolchain only (skip the repo clone, build, and servers)."
    else
      log_info "--stop-at clone: toolchain + repo clone only (post_build skipped; no build/servers)."
    fi
  else
    : > "$STAGE_DIR/post_build.do"
    printf '%s' "$STOP_AT" > "$STAGE_DIR/post_build.stop"
    printf '%s' "$SERVERS_SPEC" > "$STAGE_DIR/servers.spec"
    [[ "$STOP_AT" != "servers" ]] && log_info "--stop-at $STOP_AT: post_build will stop after that phase (servers not started)."
    [[ "$STOP_AT" == "servers" && "$SERVERS_SPEC" != "all" ]] && log_info "--servers $SERVERS_SPEC: only those servers will start on boot."
  fi
  # Stage cfg.zip (server config) so post_build can apply it: prefer an explicit --cfg,
  # else the copy the orchestrator placed next to the ISO (from --cfg or the ghcr pull).
  CFG_SRC="${CFG_PATH:-$(dirname "$ISO_PATH")/cfg.zip}"
  if [[ -s "$CFG_SRC" ]]; then
    cp "$CFG_SRC" "$STAGE_DIR/cfg.zip"
    log_info "Staged cfg.zip for the post-build server config."
  else
    log_warn "cfg.zip not found next to the ISO; post-build will build without server config (DB restore/run may need it)."
  fi

  if [[ "$RESUME" != true ]]; then
  NOPROMPT_ISO="${VM_DIR}/${VM_NAME}_noprompt.iso"
  if ! build_noprompt_iso "$ISO_PATH" "$AUTOUNATTEND" "$NOPROMPT_ISO" "$STAGE_DIR"; then
    log_error "Failed to build the no-prompt install ISO."
    rm -rf "$STAGE_DIR"; exit 1
  fi
  rm -rf "$STAGE_DIR"
  log_success "No-prompt install ISO: $NOPROMPT_ISO"

  # Attach the Guest Additions ISO to a second optical drive so first-logon can
  # install it. The drive letter is discovered at runtime by firstlogon.cmd.
  GA_ISO=$(VBoxManage list systemproperties 2>/dev/null | sed -n 's/^Default Guest Additions ISO: *//p')
  [[ -f "$GA_ISO" ]] || GA_ISO="/usr/share/virtualbox/VBoxGuestAdditions.iso"
  if [[ -f "$GA_ISO" ]]; then
    VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 1 --device 0 --type dvddrive --medium "$GA_ISO"
    log_info "Guest Additions ISO attached: $GA_ISO"
  else
    log_warn "Guest Additions ISO not found; skipping auto-install. Install it manually later."
  fi

  # Boot the installer directly: swap the optical drive to the remastered ISO
  # and put the disk first in the boot order. A blank disk isn't bootable, so
  # EFI falls through to the no-prompt DVD; once Windows is installed the disk
  # boots first, so Setup never re-runs.
  VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "$NOPROMPT_ISO"
  VBoxManage modifyvm "$VM_NAME" --boot1 disk --boot2 dvd --boot3 none --boot4 none

  # Pick a start type: honor an explicit --headless, otherwise use the GUI only
  # when an X display is available (a container/CI run has none).
  if [[ -z "$START_TYPE" ]]; then
    if [[ -n "${DISPLAY:-}" ]]; then START_TYPE=gui; else START_TYPE=headless; fi
  fi

  # NOTE: VirtualBox's built-in screen recording (--recording) is deliberately NOT
  # used - it intermittently aborts the VM mid-boot. For a timelapse, --watch captures
  # non-intrusive periodic screenshots from the host instead, which never touches the
  # running guest.
  VBoxManage startvm "$VM_NAME" --type "$START_TYPE"
  log_info "VM started (type: $START_TYPE)."

  echo
  echo "Unattended install started — no keypress needed. Account: dev / dev (headless)."
  echo "It now runs hands-free: Windows install -> Guest Additions + reboot -> toolchain"
  echo "(SQL, VS 2026, .NET, ...) -> clone -> apply cfg.zip -> build server+client -> restore"
  echo "DB -> SQL logins -> nginx -> start all 4 servers on boot. Total ~2-3 h."
  echo "Watch progress (once Guest Additions are up):"
  echo "  VBoxManage guestcontrol $VM_NAME --username dev --password dev run \\"
  echo "    --exe C:\\\\Windows\\\\System32\\\\cmd.exe -- cmd.exe /c \"type D:\\Tools\\install_status.txt\""
  echo "Server logs (after post-build): D:\\Tools\\serverlogs. Manual control: C:\\Setup\\start_servers.sh"
  else
    # RESUME: the VM already exists - skip the ISO remaster/boot entirely. Push the
    # freshly generated scripts into C:\Setup (best-effort; picks up fixes), make sure
    # the VM is running, then re-trigger the elevated installer task. install_tools.cmd
    # is idempotent and writes N/8 status, so it continues from the last incomplete step.
    log_info "RESUME: re-running the in-guest installer (it skips already-finished steps)."
    GUEST_STATE=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^VMState=//p' | tr -d '"')
    if [[ "$GUEST_STATE" != "running" ]]; then
      if [[ -z "$START_TYPE" ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then START_TYPE=gui; else START_TYPE=headless; fi
      fi
      VBoxManage startvm "$VM_NAME" --type "$START_TYPE"
      log_info "Started VM ($START_TYPE); waiting for the guest to respond..."
    fi
    GC=(VBoxManage guestcontrol "$VM_NAME" --username dev --password dev)
    GUEST_UP=false
    for _i in $(seq 1 60); do
      if "${GC[@]}" run --exe "C:\\Windows\\System32\\cmd.exe" -- cmd.exe /c "echo ready" >/dev/null 2>&1; then
        GUEST_UP=true; break
      fi
      sleep 10
    done
    if [[ "$GUEST_UP" != true ]]; then
      log_warn "Guest not reachable (Guest Additions / dev session). It may still be installing Windows. Re-run later."
      rm -rf "$STAGE_DIR"
    else
      # Best-effort refresh of the staged scripts so script fixes take effect on resume.
      for _f in "$STAGE_DIR"/*; do
        [[ -f "$_f" ]] && { "${GC[@]}" copyto --target-directory "C:\\Setup\\" "$_f" >/dev/null 2>&1 || true; }
      done
      rm -rf "$STAGE_DIR"
      # Re-trigger the elevated installer task (via cmd.exe - schtasks chokes on argv[0]).
      if "${GC[@]}" run --exe "C:\\Windows\\System32\\cmd.exe" -- cmd.exe /c "schtasks /run /tn TCPInstallTools"; then
        log_success "RESUME: re-triggered TCPInstallTools - continues from the last incomplete step."
      else
        log_warn "RESUME: couldn't run the task. In the guest, run C:\\Setup\\install_tools.cmd elevated (or the desktop 'TCP Dev Environment Setup' shortcut)."
      fi
      echo
      echo "Resume started - the in-guest installer is re-running and skips completed steps."
      echo "Track progress in D:\\Tools\\install_status.txt (target: 8/8 Setup complete)."
    fi
  fi
else
  echo
  echo "NEXT STEPS"
  echo "1. Start the VM: VBoxManage startvm \"$VM_NAME\""
  echo "2. Install Windows 11 from the ISO."
  echo "3. If the installer blocks on requirements, press Shift+F10, run regedit, and import bypass_checks.reg."
  echo "4. Create your C: and D: partitions as described in the guide."
  echo "5. After Windows is installed, run Windows Update."
  echo "6. Install Guest Additions."
  echo "7. Install Cygwin to D:\\Tools\\cygwin with wget and nano."
  echo "8. Copy the generated helper scripts into the VM, ideally through the shared folder."
  echo "9. Run setup_powershell.ps1 and setup_env_vars.cmd."
  echo "10. Install Visual Studio, SQL Server, SSMS, Git, JDK, Node.js, and other tools from the guide."
  echo "11. Run setup_cygwin_ssh.sh, then add your SSH key to GitHub."
  echo "12. Run clone_repos.sh."
  echo "13. Run setup_nuget_source.cmd."
  echo "14. Run post_install_setup.sh to fetch installers inside the VM."
  echo "15. Build server with build_server.sh and client with build_client.sh."
  echo "16. Configure nginx and place required certificate/config files."
  echo "17. Restore the database and run create_sql_logins.sql via run_sql_logins.cmd."
  echo "18. Take a snapshot when everything is working."
fi

# Optional: export the finished VM as a portable OVA appliance. Waits for the in-guest
# install to report completion, then powers off and exports. The OVA imports into any
# VirtualBox via File > Import Appliance.
if [[ -n "$EXPORT_FILE" ]]; then
  log_info "Export requested -> $EXPORT_FILE. Waiting for the guest to finish (can take 1-2h)..."
  EXP_GC=(VBoxManage guestcontrol "$VM_NAME" --username dev --password dev)
  for _i in $(seq 1 240); do
    _st=$("${EXP_GC[@]}" run --exe "C:\\Windows\\System32\\cmd.exe" -- cmd.exe /c "type D:\\Tools\\install_status.txt" 2>/dev/null | tr -d '\r')
    case "$_st" in
      *"Setup complete"*) log_info "Guest reports: $_st"; break ;;
      *ERROR*) log_warn "Guest reports an error ($_st); exporting current state anyway."; break ;;
    esac
    sleep 60
  done
  log_info "Powering off the VM for export..."
  VBoxManage controlvm "$VM_NAME" acpipowerbutton >/dev/null 2>&1 || true
  for _i in $(seq 1 30); do
    [[ "$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^VMState=//p' | tr -d '"')" == "poweroff" ]] && break
    sleep 5
  done
  VBoxManage controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
  sleep 3
  log_info "Exporting to OVA (large file; this can take a while)..."
  if VBoxManage export "$VM_NAME" -o "$EXPORT_FILE" --vsys 0 --product "TCP Win11 Dev VM"; then
    log_success "Appliance exported: $EXPORT_FILE ($(du -h "$EXPORT_FILE" 2>/dev/null | cut -f1))"
  else
    log_error "Export failed."
  fi
fi