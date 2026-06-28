#!/usr/bin/env bash
# launch-vm.sh - start the TimeClock Plus Win11 VM the way it should run for real device testing:
#   - BRIDGED networking by default (a clock device must reach the VM on the LAN). Adapter is
#     taken from --adapter, else auto-detected (the host's default-route interface, falling back
#     to the first "Up" non-docker bridged interface). No NAT.
#   - L1D cache flush on VM entry (--l1d-flush-on-vm-entry on).
#   - Nested paging turned OFF (--nested-paging off).
# Together the last two are the classic L1TF mitigation posture (disable EPT + flush L1D).
#
# Run this on the HOST (host VirtualBox), after the VM is registered there - e.g. imported from
# the OVA that build-vm.sh exports. The in-container build uses NAT only because the container has
# no bridged DHCP; this launcher is the bridged counterpart for actually running the VM.
#
# Usage: ./launch-vm.sh [--vm NAME] [--adapter NAME] [--headless] [--force]
set -euo pipefail

VM="Win11"
ADAPTER=""
START_TYPE=""
FORCE=false

usage() {
  cat <<'USAGE'
Start the Win11 VM with bridged networking, L1D flush on VM entry, and nested paging OFF.

Usage: ./launch-vm.sh [--vm NAME] [--adapter NAME] [--headless|--gui] [--force]
  --vm NAME        VM to launch (default: Win11; must be registered on this host)
  --adapter NAME   bridged host adapter (default: auto-detect the default-route interface)
  --headless/--gui front-end (default: gui if a display is present, else headless)
  --force          power off the VM first if it's running/saved, then re-launch
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM="$2"; shift 2 ;;
    --adapter|--bridge-adapter) ADAPTER="$2"; shift 2 ;;
    --headless) START_TYPE="headless"; shift ;;
    --gui) START_TYPE="gui"; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

command -v VBoxManage >/dev/null 2>&1 || { echo "ERROR: VBoxManage not found on PATH (install VirtualBox on this host)." >&2; exit 1; }

# The VM must be registered on this host's VirtualBox.
if ! VBoxManage showvminfo "$VM" >/dev/null 2>&1; then
  echo "ERROR: VM '$VM' is not registered on this host." >&2
  echo "Registered VMs:" >&2; VBoxManage list vms >&2
  echo "Import the exported OVA first (or pass --vm NAME)." >&2
  exit 1
fi

# CPU/NIC settings can only be changed while the VM is powered off.
state="$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^VMState=//p' | tr -d '"')"
if [[ "$state" == "running" || "$state" == "paused" || "$state" == "saved" ]]; then
  if [[ "$FORCE" == true ]]; then
    echo "VM '$VM' is $state; powering it off (--force)..."
    VBoxManage controlvm "$VM" poweroff >/dev/null 2>&1 || true
    VBoxManage discardstate "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      [[ "$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^VMState=//p' | tr -d '"')" == "poweroff" ]] && break
      sleep 1
    done
  else
    echo "ERROR: VM '$VM' is currently '$state'. Power it off first (or pass --force), then re-launch." >&2
    exit 1
  fi
fi

# Auto-detect the bridged adapter: prefer the host's default-route interface (if it's a bridged
# interface), else the first "Up" interface that isn't a docker/veth/virbr bridge, else the first.
if [[ -z "$ADAPTER" ]]; then
  mapfile -t _ifs < <(VBoxManage list bridgedifs 2>/dev/null | sed -n 's/^Name: *//p')
  _route_if="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
  if [[ -n "$_route_if" ]]; then
    for _i in "${_ifs[@]}"; do [[ "$_i" == "$_route_if" ]] && ADAPTER="$_i" && break; done
  fi
  if [[ -z "$ADAPTER" ]]; then
    # first Up interface that looks like a real NIC (skip docker/veth/virbr/bridge)
    while IFS= read -r line; do
      case "$line" in Name:*) _n="${line#Name: }"; _n="${_n#"${_n%%[![:space:]]*}"}" ;; Status:*) [[ "$line" == *Up* && -n "${_n:-}" && "$_n" != docker* && "$_n" != veth* && "$_n" != virbr* && "$_n" != *bridge* ]] && { ADAPTER="$_n"; break; } ;; esac
    done < <(VBoxManage list bridgedifs 2>/dev/null)
  fi
  [[ -z "$ADAPTER" && "${#_ifs[@]}" -gt 0 ]] && ADAPTER="${_ifs[0]}"
  [[ -z "$ADAPTER" ]] && { echo "ERROR: no bridged adapter found. Pass --adapter NAME (see: VBoxManage list bridgedifs)." >&2; exit 1; }
  echo "Auto-detected bridged adapter: $ADAPTER"
fi

# Default front-end: GUI when a display is present, headless otherwise.
[[ -z "$START_TYPE" ]] && { [[ -n "${DISPLAY:-}" ]] && START_TYPE="gui" || START_TYPE="headless"; }

echo "Configuring '$VM': bridged via '$ADAPTER' (no NAT), L1D flush on VM entry, nested paging OFF..."
VBoxManage modifyvm "$VM" --nic1 bridged --bridgeadapter1 "$ADAPTER" --cableconnected1 on
VBoxManage modifyvm "$VM" --l1d-flush-on-vm-entry on
VBoxManage modifyvm "$VM" --nested-paging off

echo "Starting '$VM' ($START_TYPE)..."
VBoxManage startvm "$VM" --type "$START_TYPE"
echo "Started. Settings in effect: bridged=$ADAPTER, l1d-flush-on-vm-entry=on, nested-paging=off."
