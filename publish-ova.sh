#!/usr/bin/env bash
# publish-ova.sh -- push a SANITIZED Win11 dev-VM OVA to GHCR as an OCI artifact:
#   ghcr.io/tcp-software/win11-ova:<tag>
#
# SECURITY GATE: refuses to push unless a '<ova>.sanitized' marker sits next to the OVA. build-vm.sh
# writes that marker ONLY after `--sanitize` removed the clear-text GitHub NuGet token AND its gate
# confirmed no GitHub token / AWS key remains in the image. So an un-sanitized OVA -- which carries
# the build's GitHub PAT in dev's NuGet.Config -- can never be published by accident. Build it with:
#   ./build-vm.sh --unattended --container --stop-at all --clean \
#       --iso <iso> --cfg <cfg> --export <DIR> --sanitize
# (mirrors the secret gate in clockware-toolchains/publish-builder.sh). Cloned repos + the test DB
# are intentionally kept.
#
# CREDENTIALS: GHCR needs a PAT with write:packages -- the gh OAuth token is NOT accepted. Provide
# GHCR_USER + GHCR_PAT (GH_TOKEN is accepted as the PAT), else the script prompts.
#
# Usage: ./publish-ova.sh [OVA path] [oci-ref]
#   OVA path  default: newest *.ova under $EXPORT_DIR, then /data/win11vbox-vm, then .
#   oci-ref   default: $GHCR_REF or ghcr.io/tcp-software/win11-ova:latest
set -euo pipefail

ORAS_VERSION="1.2.0"
REGISTRY="ghcr.io"
GHCR_REF_DEFAULT="ghcr.io/tcp-software/win11-ova:latest"
ARTIFACT_TYPE="application/vnd.tcp.win11-ova"
MEDIA_TYPE="application/octet-stream"
# Disable the Go HTTP/2 client: large ghcr blob uploads are far more reliable over HTTP/1.1,
# especially on flaky links (an HTTP/2 stream reset restarts the whole multi-GB blob).
export GODEBUG="${GODEBUG:-http2client=0}"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# --- locate the OVA (arg 1, else newest under EXPORT_DIR / the default export dir) ---
OVA="${1:-}"
if [ -z "$OVA" ]; then
  for d in "${EXPORT_DIR:-}" /data/win11vbox-vm .; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    OVA="$(ls -t "$d"/*.ova 2>/dev/null | head -1 || true)"
    [ -n "$OVA" ] && break
  done
fi
[ -n "$OVA" ] && [ -s "$OVA" ] || { echo "ERROR: no OVA found (pass a path, or set EXPORT_DIR)." >&2; exit 1; }
OCI_REF="${2:-${GHCR_REF:-$GHCR_REF_DEFAULT}}"

# --- SECURITY GATE: require the sanitize marker (no marker => never push) ---
if [ ! -f "${OVA}.sanitized" ]; then
  {
    echo "ERROR: refusing to publish '${OVA}' -- no '${OVA}.sanitized' marker found."
    echo "       An un-sanitized OVA contains the build's GitHub token (clear-text in NuGet.Config)."
    echo "       Rebuild it sanitized:"
    echo "         ./build-vm.sh --unattended --container --stop-at all --clean \\"
    echo "             --iso <iso> --cfg <cfg> --export \"$(dirname "$OVA")\" --sanitize"
  } >&2
  exit 1
fi
echo ">> sanitize marker present:"; sed 's/^/     /' "${OVA}.sanitized"

# --- install oras if missing (pinned) ---
install_oras() {
  local sudo tmp; sudo="$(command -v sudo || true)"; tmp="$(mktemp -d)"
  echo ">> oras not found -- installing v${ORAS_VERSION}..."
  ( cd "$tmp" \
    && curl -fsSLO "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf "oras_${ORAS_VERSION}_linux_amd64.tar.gz" oras \
    && ${sudo} install -m755 oras /usr/local/bin/oras )
  rm -rf "$tmp"
}
command -v oras >/dev/null 2>&1 || install_oras

# --- credentials (PAT required; GH_TOKEN accepted) ---
GHCR_USER="${GHCR_USER:-}"; GHCR_PAT="${GHCR_PAT:-${GH_TOKEN:-}}"
[ -n "$GHCR_USER" ] || read -rp "GHCR username: " GHCR_USER
[ -n "$GHCR_PAT" ]  || { read -rsp "GHCR token (write:packages): " GHCR_PAT; echo; }
[ -n "$GHCR_USER" ] && [ -n "$GHCR_PAT" ] || { echo "ERROR: GHCR username and token are required." >&2; exit 1; }

echo ">> logging in to ${REGISTRY} as ${GHCR_USER} (token ****${GHCR_PAT: -4})..."
printf '%s' "$GHCR_PAT" | oras login "$REGISTRY" -u "$GHCR_USER" --password-stdin

# oras reads the file relative to cwd; its basename becomes the artifact entry the puller writes.
dir="$(cd "$(dirname "$OVA")" && pwd)"; base="$(basename "$OVA")"
echo ">> pushing ${base} ($(du -h "$OVA" | cut -f1)) to ${OCI_REF} ..."
echo "   (large; a slow/flaky uplink can take hours -- this is a full VM image)"
( cd "$dir" && oras push "$OCI_REF" --artifact-type "$ARTIFACT_TYPE" "${base}:${MEDIA_TYPE}" )
echo ">> pushed. Pull it back with:  oras pull ${OCI_REF} -o ."
