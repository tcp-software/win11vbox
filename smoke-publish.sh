#!/usr/bin/env bash
# smoke-publish.sh -- validate the GHCR publish plumbing (oras install + PAT login + push + pull
# + delete) with a TINY throwaway artifact, BEFORE committing to a multi-hour build and an ~80 GB
# OVA push. Uses the exact same oras/credential path as publish-ova.sh, just on a 1-line file and a
# disposable ref, so a failure here is a plumbing failure (auth/scope/network), not a build issue.
#
# Pushes to a disposable ref, verifies by pulling it back, then DELETES the test package version via
# the GitHub API (needs delete:packages; if that scope is absent it just warns and leaves the tag).
#
# Credentials: GHCR needs a PAT (write:packages; delete:packages to auto-clean). GHCR rejects the gh
# OAuth token. Provide GHCR_USER + GHCR_PAT (GH_TOKEN accepted), else it prompts.
#
#   GHCR_USER=oosman-tcps GHCR_PAT=<pat> ./smoke-publish.sh
set -euo pipefail

ORAS_VERSION="1.2.0"
REGISTRY="ghcr.io"
ORG="tcp-software"
PKG="win11-ova-smoketest"
TAG="${SMOKE_TAG:-$(date +%Y%m%d-%H%M%S)}"
SMOKE_REF="${SMOKE_REF:-ghcr.io/${ORG}/${PKG}:${TAG}}"
export GODEBUG="${GODEBUG:-http2client=0}"

fail(){ echo "SMOKE RESULT: FAIL -- $*" >&2; exit 1; }

# --- oras (install if missing, pinned) ---
install_oras(){
  local sudo tmp; sudo="$(command -v sudo || true)"; tmp="$(mktemp -d)"
  echo ">> oras not found -- installing v${ORAS_VERSION}..."
  ( cd "$tmp" \
    && curl -fsSLO "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf "oras_${ORAS_VERSION}_linux_amd64.tar.gz" oras \
    && ${sudo} install -m755 oras /usr/local/bin/oras )
  rm -rf "$tmp"
}
command -v oras >/dev/null 2>&1 || install_oras

# --- credentials ---
GHCR_USER="${GHCR_USER:-}"; GHCR_PAT="${GHCR_PAT:-${GH_TOKEN:-}}"
[ -n "$GHCR_USER" ] || read -rp "GHCR username: " GHCR_USER
[ -n "$GHCR_PAT" ]  || { read -rsp "GHCR token: " GHCR_PAT; echo; }
[ -n "$GHCR_USER" ] && [ -n "$GHCR_PAT" ] || fail "GHCR username and token are required."

# --- 1. tiny dummy artifact ---
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FILE="smoke-test.txt"
printf 'ghcr publish smoke test\n  when: %s\n  host: %s\n  by:   %s\n' \
  "$(date -u +%FT%TZ)" "$(hostname 2>/dev/null || echo ?)" "$GHCR_USER" > "$WORK/$FILE"
echo ">> dummy artifact ($(wc -c < "$WORK/$FILE") bytes):"; sed 's/^/     /' "$WORK/$FILE"

# --- 2. login ---
echo ">> logging in to ${REGISTRY} as ${GHCR_USER} (token ****${GHCR_PAT: -4})..."
printf '%s' "$GHCR_PAT" | oras login "$REGISTRY" -u "$GHCR_USER" --password-stdin \
  || fail "oras login failed (bad PAT, or the token lacks package scopes)."

# --- 3. push ---
echo ">> pushing to ${SMOKE_REF} ..."
( cd "$WORK" && oras push "$SMOKE_REF" --artifact-type application/vnd.tcp.smoketest "${FILE}:text/plain" ) \
  || fail "oras push failed (write:packages scope? repo perms? network?)."

# --- 4. verify by pulling it back ---
echo ">> pulling it back to verify ..."
mkdir -p "$WORK/pulled"
( cd "$WORK/pulled" && oras pull "$SMOKE_REF" ) || fail "oras pull failed (pushed but not retrievable)."
diff -q "$WORK/$FILE" "$WORK/pulled/$FILE" >/dev/null 2>&1 || fail "round-trip mismatch (pulled file differs)."
echo ">> round-trip OK (pushed == pulled)."

# --- 5. clean up: delete the whole throwaway package (best-effort; needs delete:packages) ---
# Delete the PACKAGE, not the single version: GitHub returns HTTP 400 when you try to delete a
# package's last remaining version ("delete the package instead"). This is a disposable smoke-test
# package, so removing it wholesale is correct.
echo ">> cleaning up the test package from ghcr ..."
code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $GHCR_PAT" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${ORG}/packages/container/${PKG}" 2>/dev/null || true)"
case "$code" in
  204) echo ">> deleted the test package '${PKG}'." ;;
  403) echo ">> NOTE: could not delete (token lacks delete:packages) -- remove '${PKG}' manually if you like." ;;
  404) echo ">> NOTE: package '${PKG}' not found to delete (already gone?)." ;;
  *)   echo ">> NOTE: delete returned HTTP ${code} -- remove '${PKG}' manually if needed." ;;
esac

echo "SMOKE RESULT: SUCCESS -- ghcr publish plumbing works (push + pull round-trip verified)."
