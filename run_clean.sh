#!/bin/bash
# ============================================================================
# run_clean.sh - one command for a CLEAN end-to-end Win11 dev-VM build with:
#   * live activity on stdout/stderr (host build log + in-guest step progress)
#   * a screenshot timelapse whose caption shows the REAL step (read live from
#     the guest status file) so the video never looks "stuck" even if the
#     in-guest progress window freezes
#   * an optional OVA export to a durable host folder
#
# Why a wrapper (and not just setup_vm.sh)? setup_vm.sh runs the build INSIDE a
# container and streams its own host-side log, but screen capture, frame
# annotation, video assembly, and following the in-guest install are host-side
# concerns layered here.
#
# Usage:
#   ./run_clean.sh                       # real build + annotated timelapse
#   ./run_clean.sh --dry-run             # ~12-min dummy install (fast end-to-end check)
#   ./run_clean.sh --export DIR          # build, then export an OVA to host DIR
#   ./run_clean.sh --export-only DIR     # DON'T build; just export the VM already built
#                                        #   in the running container to host DIR
#
# Credentials: reads GH_TOKEN (required for the private-repo clone + NuGet) and
# GH_USER from the environment; both fall back to the gh CLI login.
# ffmpeg is auto-resolved (PATH -> ~/.local/bin -> static download); no sudo needed.
# The whole run is tee'd to .videos/run_clean-<timestamp>.log.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

DRY=""; EXPORT_DIR=""; EXPORT_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY="--dry-run"; shift ;;
    --export) EXPORT_DIR="${2:?--export needs a host directory}"; shift 2 ;;
    --export-only) EXPORT_DIR="${2:?--export-only needs a host directory}"; EXPORT_ONLY=1; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

VM=Win11
C=vmbuilder_run
VID="$REPO/.videos"
FRAMES="$VID/frames"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_MP4="$VID/${TS}-clean-run-timelapse.mp4"
MANIFEST="$VID/.frames-${TS}.manifest"
ISO="$(ls "$HOME"/.cache/win11vbox/iso/*.iso 2>/dev/null | head -1)"
FONT="$(find /usr/share/fonts -name 'DejaVuSans.ttf' 2>/dev/null | head -1)"
GHU="${GH_USER:-$(gh api user -q .login 2>/dev/null || true)}"

# Tee the whole run to a timestamped log so nothing is lost to terminal scrollback.
mkdir -p "$VID"; LOG="$VID/run_clean-${TS}.log"
exec > >(tee -a "$LOG") 2>&1

# Resolve ffmpeg WITHOUT root: PATH, then ~/.local/bin, then a one-time static download
# to ~/.local/bin. If none works the run still finishes; only the video is skipped.
ensure_ffmpeg(){
  FFMPEG="$(command -v ffmpeg || true)"
  [[ -z "$FFMPEG" && -x "$HOME/.local/bin/ffmpeg" ]] && FFMPEG="$HOME/.local/bin/ffmpeg"
  if [[ -z "$FFMPEG" ]]; then
    echo "ffmpeg not found - fetching a static build to ~/.local/bin (no sudo)..."
    mkdir -p "$HOME/.local/bin"
    if curl -fsSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz -o /tmp/ff_rc.tar.xz 2>/dev/null \
       && tar -xJf /tmp/ff_rc.tar.xz -C /tmp 2>/dev/null \
       && cp /tmp/ffmpeg-*-amd64-static/ffmpeg "$HOME/.local/bin/ffmpeg" 2>/dev/null; then
      chmod +x "$HOME/.local/bin/ffmpeg"; FFMPEG="$HOME/.local/bin/ffmpeg"
    fi
  fi
  [[ -n "$FFMPEG" ]] && echo "ffmpeg: $FFMPEG" || echo "WARN: ffmpeg unavailable - frames saved, but no video will be assembled."
}

say(){ echo "### $(date +%H:%M:%S) $* ###"; }
echo "### run_clean log: $LOG ###"
ensure_ffmpeg

# VBoxManage inside the container: needs HOME=/root (that's where the VM is registered) and
# the full path (PATH isn't set for a non-login exec).
gx(){ docker exec -e HOME=/root "$C" /usr/bin/VBoxManage "$@"; }

# Power off the existing VM and export it to an OVA, then copy it to the durable host dir
# $EXPORT_DIR (the container can't see it, so export to the container overlay and stream-copy
# out via a helper container bind-mounted there).
do_export(){
  say "Exporting OVA to host:$EXPORT_DIR"
  local OVA="Win11-WebEdition-${TS}.ova" OVERLAY="/root/Win11-WebEdition-${TS}.ova"
  echo "Powering off the VM (servers will be off until the next boot, when TCPStartServers restarts them)..."
  gx controlvm "$VM" acpipowerbutton >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [[ "$(gx showvminfo "$VM" --machinereadable 2>/dev/null | sed -n 's/^VMState=//p' | tr -d '"')" == poweroff ]] && break; sleep 6; done
  gx controlvm "$VM" poweroff >/dev/null 2>&1 || true; sleep 6
  echo "Exporting (large; a few minutes)..."
  gx export "$VM" -o "$OVERLAY" --vsys 0 --product "TCP Win11 Dev VM ($TS)" || { echo "ERROR: export failed" >&2; return 1; }
  docker rm -f ova_dest >/dev/null 2>&1 || true
  docker run -d --name ova_dest -v "$EXPORT_DIR":/out ghcr.io/tcp-software/vmbuilder:latest sleep infinity >/dev/null
  echo "Copying OVA to $EXPORT_DIR ..."
  docker cp "$C:$OVERLAY" - | docker cp - ova_dest:/out
  docker exec ova_dest sh -lc "chmod 644 /out/'$OVA'; ls -lh /out/'$OVA'"
  docker exec "$C" rm -f "$OVERLAY" 2>/dev/null || true
  docker rm -f ova_dest >/dev/null 2>&1 || true
  echo "OVA: $EXPORT_DIR/$OVA"
}

# --export-only: just export the VM already built in the running container, then stop.
if [[ -n "$EXPORT_ONLY" ]]; then
  docker inspect "$C" >/dev/null 2>&1 || { echo "ERROR: container '$C' not found - nothing to export." >&2; exit 1; }
  gx showvminfo "$VM" >/dev/null 2>&1 || { echo "ERROR: VM '$VM' not registered in '$C'." >&2; exit 1; }
  do_export
  exit $?
fi
[[ -n "$ISO" ]] || { echo "No Win11 ISO under ~/.cache/win11vbox/iso" >&2; exit 1; }
[[ -n "${GH_TOKEN:-}" || -n "$DRY" ]] || echo "WARN: GH_TOKEN not set - the private-repo clone/NuGet will be skipped." >&2

say "[1/5] Cleaning any prior VM/container + frames"
docker exec "$C" VBoxManage controlvm "$VM" poweroff >/dev/null 2>&1 || true
docker rm -f "$C" ova_dest >/dev/null 2>&1 || true
rm -rf "$FRAMES"; mkdir -p "$FRAMES"; : > "$MANIFEST"

say "[2/5] Starting build (setup_vm.sh) - host log streams below as [build]"
# setup_vm.sh (no --export here) returns after the VM is started; the guest then
# installs autonomously via its scheduled task. We follow that below.
GHCR_TOKEN="${GHCR_TOKEN:-${GH_TOKEN:-}}" GHCR_USER="${GHCR_USER:-$GHU}" GH_TOKEN="${GH_TOKEN:-}" \
  stdbuf -oL -eL ./setup_vm.sh --iso "$ISO" --unattended --nat \
    ${GHU:+--gh-user "$GHU"} $DRY -y 2>&1 | sed -u 's/^/[build] /' || true

say "[3/5] Following in-guest install + capturing annotated frames (live below as [guest])"
# Fail fast if the build never created the container (e.g. orchestrator aborted) instead
# of spinning while waiting for a VM that will never appear.
if ! docker inspect "$C" >/dev/null 2>&1; then
  echo "ERROR: build did not create container '$C' (see the [build] output above). Aborting." >&2
  exit 1
fi
# Wait for the container + VM to be up.
for _ in $(seq 1 120); do docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true && break; sleep 5; done
gstat(){ docker exec "$C" VBoxManage guestcontrol "$VM" --username dev --password dev \
          run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_status.txt' 2>/dev/null \
          | tr -d '\r' | grep -v WARNING | tail -1; }
# Pull the whole in-guest install log over guestcontrol (no SSH needed - Guest Additions
# already exposes guest files to the host). Append-only, so we print just the new lines.
glog(){ docker exec "$C" VBoxManage guestcontrol "$VM" --username dev --password dev \
          run --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c 'type D:\Tools\install_tools.log' 2>/dev/null \
          | tr -d '\r' | grep -v '^WARNING:'; }
n=0; last=""; idle=0; loglines=0
while true; do
  st="$(gstat)"
  # Stream new in-guest log lines (the actual choco/VS/SQL output) as [log] ...
  full="$(glog)"
  if [[ -n "$full" ]]; then total=$(printf '%s\n' "$full" | wc -l | tr -d ' '); else total=0; fi
  if [[ "$total" -gt "$loglines" ]]; then
    printf '%s\n' "$full" | sed -n "$((loglines+1)),${total}p" | sed 's/^/[log] /'
    loglines=$total
  fi
  rel="frames/$(printf 'frame-%05d.png' "$n")"
  if docker exec "$C" VBoxManage controlvm "$VM" screenshotpng "/work/win11vbox/.videos/$rel" >/dev/null 2>&1 \
     && [[ -s "$FRAMES/$(printf 'frame-%05d.png' "$n")" ]]; then
    echo "$(printf 'frame-%05d.png' "$n")|${st:-(starting)}" >> "$MANIFEST"
    n=$((n+1))
  fi
  if [[ -n "$st" && "$st" != "$last" ]]; then echo "[guest] $(date +%H:%M:%S) $st"; last="$st"; fi
  case "$st" in
    *"Setup complete"*) echo "[guest] reached 8/8"; break ;;
    *ERROR*)            echo "[guest] installer reported ERROR - stopping capture"; break ;;
  esac
  # Give up if the container dies or after ~3h of no completion.
  docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true || { echo "[guest] container stopped"; break; }
  idle=$((idle+1)); [[ $idle -ge 360 ]] && { echo "[guest] 3h cap reached"; break; }
  sleep 30
done

say "[4/5] Annotating frames with their real step + assembling $OUT_MP4"
# Frames are written by the container as root; chown them back via the container itself
# (the frames dir is the mounted repo path) so NO interactive host 'sudo' is ever needed.
docker exec "$C" chown -R "$(id -u):$(id -g)" /work/win11vbox/.videos/frames 2>/dev/null \
  || sudo -n chown -R "$(id -u):$(id -g)" "$FRAMES" 2>/dev/null || true
if [[ -z "${FFMPEG:-}" ]]; then
  echo "video: SKIPPED (ffmpeg unavailable). $n raw frames saved in $FRAMES"
else
  while IFS='|' read -r f s; do
    [[ -s "$FRAMES/$f" ]] || continue
    safe="$(printf '%s' "$s" | tr -cd '[:alnum:] /._-' | cut -c1-70)"
    if ! "$FFMPEG" -y -loglevel error -i "$FRAMES/$f" \
          -vf "drawtext=fontfile=${FONT}:text='${safe}':x=10:y=h-34:fontsize=20:fontcolor=yellow:box=1:boxcolor=black@0.7" \
          "$FRAMES/$f.a.png" 2>/dev/null; then cp "$FRAMES/$f" "$FRAMES/$f.a.png"; fi
    mv "$FRAMES/$f.a.png" "$FRAMES/$f"
  done < "$MANIFEST"
  "$FFMPEG" -y -loglevel error -framerate 10 -pattern_type glob -i "$FRAMES/frame-*.png" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" "$OUT_MP4"
  echo "video: $OUT_MP4 ($(ls -lh "$OUT_MP4" 2>/dev/null | awk '{print $5}'), $n frames)"
fi

if [[ -n "$EXPORT_DIR" ]]; then
  do_export
else
  say "[5/5] Done (no --export requested)"
fi
