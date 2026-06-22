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
CACHE_HOST_DIR="${CACHE_HOST_DIR:-/mnt/docker.data/win11vbox-cache}"
# The VM (.vdi etc.) goes on a DURABLE host mount, not the container's overlay layer. On the
# overlay, a hard container kill (OOM/exit-137) loses unflushed VirtualBox writes and rolls
# the guest disk back (we lost an 8/8 build to this). A bind-mounted host dir + host I/O cache
# (buffered writes) survives a container restart.
VMSTORE_HOST_DIR="${VMSTORE_HOST_DIR:-/mnt/docker.data/win11vbox-vm}"
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
EXPORT_FILE=""
# cfg.zip (server config: TCPCONN.XML etc.) is pulled from ghcr so the post-build step is
# fully automated - no manual download needed.
CFG_REF="${CFG_REF:-ghcr.io/tcp-software/we-cfg:latest}"
# Credentials are REQUIRED (from these flags or the matching env vars) for a real run; they
# are folded into the guest (clone + NuGet + AWS env) and DELETED from the guest after use,
# so an exported OVA carries none. (--dry-run does not need them.)
GH_USER="${GH_USER:-}"
AWS_ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"

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
                         ($CACHE_HOST_DIR, default /mnt/docker.data/win11vbox-cache) that the
                         orchestrator bind-mounts in, so it survives the container.
  --aws-access-key KEY   AWS access key id  -> guest env var. OPTIONAL: the WebEdition build
  --aws-secret-key SECRET   and local run do NOT need AWS; these are only for runtime AWS
                         features (S3/SES). (or set $AWS_ACCESS_KEY_ID / $AWS_SECRET_ACCESS_KEY)
  --watch                Follow the in-guest install live ([guest]/[log]) and build an
                         annotated screenshot timelapse under .videos/ (needs no extra tools;
                         ffmpeg is auto-resolved without sudo)
  --export DIR           Wait until EVERYTHING is done (repos cloned, server compiled, all 4
                         servers listening), then power off and export a portable OVA into DIR.
                         Refuses to export a half-built VM.
  --export-only DIR      Skip the build; export the VM already in the running container now
                         (no readiness wait - you're asserting it's ready)
  --dry-run              Stage a marker so the in-guest tool install runs DUMMY steps (each
                         sleeps ~3s) - verifies the whole flow in minutes, no credentials
                         needed. (Formerly --test.)
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
  ./build-vm.sh --unattended --watch --export /mnt/docker.data/win11-ova -y

  # Fast end-to-end DRY RUN (dummy installs, ~minutes; no credentials needed):
  ./build-vm.sh --unattended --dry-run --watch -y

  # Resume a half-finished build (just re-run with the same --vm-name):
  ./build-vm.sh --unattended -y

  # Export only - the VM is already built in the running container, no rebuild:
  ./build-vm.sh --export-only /mnt/docker.data/win11-ova
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
  ensure_docker
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
HVID="$HREPO/.videos"
# '|| true' is REQUIRED: under 'set -euo pipefail', if /usr/share/fonts is absent (as in the
# container) find exits non-zero, pipefail propagates it, and the bare assignment would make
# set -e kill the whole script here - silently, before ensure_virtualbox even runs.
HFONT="$(find /usr/share/fonts -name 'DejaVuSans.ttf' 2>/dev/null | head -1 || true)"
WATCH=false; EXPORT_DIR=""; EXPORT_ONLY=""; _pv=""
for _a in "$@"; do
  case "$_pv" in
    --export)      EXPORT_DIR="$_a" ;;
    --export-only) EXPORT_DIR="$_a"; EXPORT_ONLY=1 ;;
  esac
  [[ "$_a" == "--watch" ]] && WATCH=true
  _pv="$_a"
done

# VBoxManage inside the container (HOME=/root is where the VM is registered; full path because
# a non-login exec has no PATH).
gx(){ docker exec -e HOME=/root "$HC" /usr/bin/VBoxManage "$@"; }
gst(){ gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_status.txt' 2>/dev/null | tr -d '\r' | grep -v WARNING | tail -1; }
glg(){ gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_tools.log' 2>/dev/null | tr -d '\r' | grep -v '^WARNING:'; }

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
  log_info "Waiting for the build to fully finish before export: clone -> compile -> all 4 servers listening."
  log_info "(This runs well past 8/8 - it can take 1-2h more for the clone, server build, and startup.)"
  local i cs ns clone_ok=false p ready
  # 420 min (~7h): the in-container VirtualBox apt-install, Windows install, the toolchain
  # (SQL + VS), and the serial clone can all run slow under host I/O contention (a 4h cap timed
  # out a healthy-but-slow run). Generous so a slow run still finishes and exports.
  for i in $(seq 1 420); do
    docker inspect -f '{{.State.Running}}' "$HC" 2>/dev/null | grep -q true || { log_error "container '$HC' stopped while waiting - not exporting."; return 1; }
    if [[ "$clone_ok" != true ]]; then
      cs="$(gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Work\clone_status.txt' 2>/dev/null | tr -d '\r' | grep -v WARNING || true)"
      case "$cs" in
        *CLONE-OK*)     clone_ok=true; log_info "repos cloned + verified." ;;
        *CLONE-FAILED*) log_error "in-guest clone FAILED - not exporting (fix the token/network, re-run)."; return 1 ;;
      esac
    fi
    ns="$(gx guestcontrol "$HVM" --username dev --password dev run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'netstat -ano -p tcp' 2>/dev/null | tr -d '\r' || true)"
    ready=true
    for p in 8008 8010 8012 8014; do printf '%s\n' "$ns" | grep -E ":$p\b" | grep -q LISTENING || ready=false; done
    if [[ "$ready" == true ]]; then log_success "all four servers are listening (8008/8010/8012/8014) - build complete."; return 0; fi
    [[ $((i % 5)) -eq 0 ]] && log_info "still building... (clone_ok=$clone_ok, ~${i} min elapsed)"
    sleep 60
  done
  log_error "timed out (~7h) waiting for the servers to come up - not exporting; VM left running for inspection."
  return 1
}

# Follow the in-guest install (streaming [guest]/[log]), capture a screenshot every 30s, then
# annotate each frame with its real step and assemble a timelapse mp4. Non-intrusive: built-in
# VBox recording is never used (it destabilized the guest).
watch_capture(){
  local FRAMES="$HVID/frames" ts MAN OUT n=0 last="" idle=0 loglines=0 full total st rel f s safe
  ts="$(date +%Y%m%d-%H%M%S)"; MAN="$HVID/.frames-${ts}.manifest"; OUT="$HVID/${ts}-timelapse.mp4"
  # Clear any stale frames from a prior run so the glob doesn't mix two runs into one video.
  rm -rf "$FRAMES"; mkdir -p "$FRAMES"; : > "$MAN"
  docker inspect "$HC" >/dev/null 2>&1 || { log_warn "no '$HC' container to watch."; return 0; }
  log_info "Following the in-guest install + capturing frames (live [guest]/[log] below)..."
  while true; do
    st="$(gst || true)"
    full="$(glg || true)"
    if [[ -n "$full" ]]; then total=$(printf '%s\n' "$full" | wc -l | tr -d ' '); else total=0; fi
    if [[ "$total" -gt "$loglines" ]]; then printf '%s\n' "$full" | sed -n "$((loglines+1)),${total}p" | sed 's/^/[log] /'; loglines=$total; fi
    rel="frames/$(printf 'frame-%05d.png' "$n")"
    if gx controlvm "$HVM" screenshotpng "/work/win11vbox/.videos/$rel" >/dev/null 2>&1 && [[ -s "$FRAMES/$(printf 'frame-%05d.png' "$n")" ]]; then
      echo "$(printf 'frame-%05d.png' "$n")|${st:-(starting)}" >> "$MAN"; n=$((n+1))
    fi
    [[ -n "$st" && "$st" != "$last" ]] && { echo "[guest] $(date +%H:%M:%S) $st"; last="$st"; }
    case "$st" in *"Setup complete"*) echo "[guest] reached 8/8"; break ;; *ERROR*) echo "[guest] installer reported ERROR - stopping capture"; break ;; esac
    docker inspect -f '{{.State.Running}}' "$HC" 2>/dev/null | grep -q true || { echo "[guest] container stopped"; break; }
    idle=$((idle+1)); [[ $idle -ge 360 ]] && { echo "[guest] 3h cap reached"; break; }
    sleep 30
  done
  # Frames are written by the container as root; chown via the container (no host sudo prompt).
  docker exec "$HC" chown -R "$(id -u):$(id -g)" /work/win11vbox/.videos/frames 2>/dev/null \
    || sudo -n chown -R "$(id -u):$(id -g)" "$FRAMES" 2>/dev/null || true
  if [[ -z "${FFMPEG:-}" ]]; then log_warn "ffmpeg unavailable - $n frames saved in $FRAMES, no video."; return 0; fi
  while IFS='|' read -r f s; do
    [[ -s "$FRAMES/$f" ]] || continue
    safe="$(printf '%s' "$s" | tr -cd '[:alnum:] /._-' | cut -c1-70)"
    "$FFMPEG" -y -loglevel error -i "$FRAMES/$f" -vf "drawtext=fontfile=${HFONT}:text='${safe}':x=10:y=h-34:fontsize=20:fontcolor=yellow:box=1:boxcolor=black@0.7" "$FRAMES/$f.a.png" 2>/dev/null || cp "$FRAMES/$f" "$FRAMES/$f.a.png"
    mv "$FRAMES/$f.a.png" "$FRAMES/$f"
  done < "$MAN"
  "$FFMPEG" -y -loglevel error -framerate 10 -pattern_type glob -i "$FRAMES/frame-*.png" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" "$OUT"
  log_success "timelapse: $OUT ($n frames)"
}

# Run host-side orchestration unless we are already inside the container.
if [[ -z "${VMBUILDER_INNER:-}" ]]; then
  mkdir -p "$HVID"
  HLOG="$HVID/build-vm-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$HLOG") 2>&1
  log_info "Host transcript: $HLOG"

  if [[ -n "$EXPORT_ONLY" ]]; then
    docker inspect "$HC" >/dev/null 2>&1 || { log_error "container '$HC' not found - nothing to export."; exit 1; }
    gx showvminfo "$HVM" >/dev/null 2>&1 || { log_error "VM '$HVM' not registered in '$HC'."; exit 1; }
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
  # VM already exists: don't recreate it - RESUME the in-guest install instead.
  # The guest installer is idempotent, so it continues from the last incomplete
  # step. (To force a clean rebuild, remove the VM first:
  #   VBoxManage controlvm "$VM_NAME" poweroff; VBoxManage unregistervm "$VM_NAME" --delete)
  RESUME=true
  UNATTENDED=true   # ensure the helper scripts + install_tools are (re)generated for the push
  log_info "VM '$VM_NAME' already exists - RESUME mode: skipping ISO/VM creation; will re-run the in-guest installer."
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
VBoxManage modifyvm "$VM_NAME" --secure-boot on || true

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
#   Usage: start_servers.sh [app|adm|terminal|workstation|linclock|all]   (default: all)
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

sel="${1:-all}"
declare -a SCRIPTS
case "$sel" in
  app)          SCRIPTS=(start-tcpapp-server.sh) ;;
  adm|admin)    SCRIPTS=(start-tcpadm-server.sh) ;;
  terminal)     SCRIPTS=(start-tcphub-server.sh) ;;
  workstation)  SCRIPTS=(start-tcppwh-server.sh) ;;
  linclock)     SCRIPTS=(start-tcpapp-server.sh start-tcphub-server.sh) ;;
  all)          SCRIPTS=(start-tcpapp-server.sh start-tcpadm-server.sh start-tcphub-server.sh start-tcppwh-server.sh) ;;
  *) echo "usage: start_servers.sh [app|adm|terminal|workstation|linclock|all]"; exit 1 ;;
esac

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
echo ==== post_build %DATE% %TIME% ==== >> "%LOG%"
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
"!BASH!" -lc "/cygdrive/c/Setup/build_server.sh" >> "%LOG%" 2>&1
echo post_build: building client... >> "%LOG%"
"!BASH!" -lc "/cygdrive/c/Setup/build_client.sh" >> "%LOG%" 2>&1
echo post_build: restoring test DB... >> "%LOG%"
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
if exist "%~dp0setup_server_cfg.sh" ( "!BASH!" -lc "/cygdrive/c/Setup/setup_server_cfg.sh" >> "%LOG%" 2>&1 ) else ( echo post_build: setup_server_cfg.sh missing - skipping per-server cfg >> "%LOG%" )

rem --- Auto-start all WebEdition servers on EVERY boot (persistent) via a scheduled task
rem that runs at startup as dev. start_servers.sh backgrounds the servers and returns, and
rem Task Scheduler does not kill the detached children, so they keep running. Then run it
rem once now so the stack is up immediately after this build (no reboot needed). nginx is
rem already a Windows service; SQL Server auto-starts; this brings up the 4 .NET servers.
echo post_build: installing TCPStartServers boot task ^(all servers^)... >> "%LOG%"
schtasks /create /tn TCPStartServers /tr "\"D:\Tools\cygwin\bin\bash.exe\" -lc /cygdrive/c/Setup/start_servers.sh all" /sc onstart /ru dev /rp dev /rl highest /f >> "%LOG%" 2>&1
echo post_build: starting all servers now... >> "%LOG%"
schtasks /run /tn TCPStartServers >> "%LOG%" 2>&1

echo ==== post_build done %DATE% %TIME% ==== >> "%LOG%"
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
  rem Non-interactive credential config: AWS env vars + GitHub NuGet source (no-op if no creds staged).
  if exist "%~dp0configure_credentials.cmd" cmd /c "%~dp0configure_credentials.cmd"
)
echo ==== STEP8-MARKER-A: env vars set, entering completion check %DATE% %TIME% ==== >> "%LOG%"

if defined TESTMODE (
  echo ==== install_tools TEST finished %DATE% %TIME% ==== >> "%LOG%"
  echo [TEST] would clone repos: tcp-cs-60, tcp-tl-70 >> "%LOG%"
  >"%STATUS%" echo 8/8 Setup complete - tools installed, repos cloned [test]
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
  >"%STATUS%" echo 8/8 Setup complete - tools installed, repos cloned
  schtasks /delete /tn TCPInstallTools /f >nul 2>&1
  schtasks /delete /tn TCPSetupWindow /f >nul 2>&1
)
rem Clone repos LAST, AFTER the status is recorded. This validation step has hung the
rem installer before the completion write, so it must never gate completion/export.
echo ==== cloning repos %DATE% %TIME% ==== >> "%LOG%"
if exist "%~dp0clone_repos.cmd" (
  cmd /c "%~dp0clone_repos.cmd" >> "%LOG%" 2>&1
  if errorlevel 1 (
    echo ==== CLONE STAGE FAILED - working tree incomplete, build stage must not run %DATE% %TIME% ==== >> "%LOG%"
    if not exist D:\Work md D:\Work
    >"D:\Work\clone_status.txt" echo CLONE-FAILED
  ) else (
    echo ==== CLONE STAGE OK %DATE% %TIME% ==== >> "%LOG%"
    if not exist D:\Work md D:\Work
    >"D:\Work\clone_status.txt" echo CLONE-OK
    rem Optional post-build chain (only if --post-build staged the marker), after a verified clone.
    if exist "%~dp0post_build.do" if exist "%~dp0post_build.cmd" cmd /c "%~dp0post_build.cmd"
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
           build_client.sh setup_server_cfg.sh start_servers.sh select_we.sh post_build.cmd clone_repos.sh clone_repos.cmd setup_cygwin_ssh.sh setup_nginx.sh firstlogon.cmd \
           install_cygwin.cmd install_tools.cmd show_progress.ps1 run_setup.cmd setup-x86_64.exe README.md; do
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
  : > "$STAGE_DIR/post_build.do"
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