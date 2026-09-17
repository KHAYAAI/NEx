#!/usr/bin/env bash
# Phase 6 (CLAUDE.md §5): "Stand up the F-Droid repo (or
# Obtainium-compatible feed) for distributing 'App' (MCP integration)
# packages."
#
# What's real: a genuine `fdroid init`-generated signing keystore (real
# 4096-bit RSA, via fdroidserver — the actual F-Droid tooling), real
# tarballs of the hub's actual MCP apps (hub/apps/file-search/,
# notes/, smart-home/ — real source, not placeholders), and a real
# cryptographic signature (jarsigner, the same primitive F-Droid's own
# index-v1.jar signing uses) over an index listing their real sha256
# hashes.
#
# What's NOT real, disclosed rather than faked: this is not a
# spec-compliant F-Droid or Obtainium index. Both formats are built
# around distributing signed Android APKs, and these "Apps" are Python
# MCP servers, not Android packages — there is no way to make that
# honestly spec-compliant without lying about what the packages are.
# Building an actual placeholder APK to satisfy the format was tried
# and abandoned: `aapt2 link` needs `android.jar` to resolve any
# `android:` manifest attribute (versionCode, minSdkVersion, even
# `label`), and no android.jar is available — apt's `android-sdk`
# package ships build-tools and platform-tools only, not a platform,
# and dl.google.com (where the platform normally comes from) is
# blocked by this environment's network policy, same restriction
# documented in pocket/client/README.md for the same reason. Verified
# by trying it (`aapt package -M AndroidManifest.xml` fails with "No
# resource identifier found for attribute 'versionCode'" and eight
# more like it), not assumed.
#
# So: real signing infrastructure, real packages, a real signature —
# over this project's own custom (clearly labeled as such) index
# format, not a fabricated claim of fitting a format built for
# something these packages aren't.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORKDIR="$(mktemp -d /tmp/nex-fdroid-repo.XXXXXX)"

RESULTS=()
PASS=0
FAIL=0
log() { echo "[fdroid-repo] $*"; }
result() {
  local id="$1" status="$2" detail="${3:-}"
  RESULTS+=("$id: $status${detail:+ — $detail}")
  if [ "$status" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
require jarsigner; require keytool

PYTHON_FDROID=python3.12
if ! $PYTHON_FDROID -c "import fdroidserver" 2>/dev/null; then
  echo "fdroidserver not importable under python3.12 (apt install fdroidserver)" >&2
  exit 1
fi

cd "$WORKDIR"
log "fdroid init: generating a real signing keystore (4096-bit RSA) and repo config"
mkdir repo
$PYTHON_FDROID -m fdroidserver init --no-prompt -d "CN=NEx Hub Apps, OU=NEx, O=NEx" >/dev/null 2>&1
if [ -f keystore.p12 ]; then
  result "Real signing keystore generated (fdroidserver init)" PASS
else
  result "Real signing keystore generated (fdroidserver init)" FAIL "no keystore.p12 produced"
fi

APPS=(file-search notes smart-home)
log "packaging real tarballs of the hub's actual MCP apps"
declare -A SHA256S
for app in "${APPS[@]}"; do
  tar czf "repo/${app}-0.1.0.tar.gz" -C "$REPO_ROOT/hub/apps/$app" .
  SHA256S[$app]=$(sha256sum "repo/${app}-0.1.0.tar.gz" | awk '{print $1}')
done
if [ "$(ls repo/*.tar.gz | wc -l)" -eq 3 ]; then
  result "Real tarballs built for all 3 apps" PASS
else
  result "Real tarballs built for all 3 apps" FAIL
fi

log "building the repo index (this project's own format — not F-Droid/Obtainium spec-compliant; see script header)"
python3 - "$WORKDIR" "${SHA256S[file-search]}" "${SHA256S[notes]}" "${SHA256S[smart-home]}" <<'PYEOF'
import json, sys, time

workdir, h_fs, h_notes, h_home = sys.argv[1:5]
index = {
    "repo": {
        "name": "NEx Hub Apps (demo)",
        "description": "Phase 6 demo repo — see infra/fdroid-repo/README.md for what this is and isn't.",
        "timestamp": int(time.time()),
    },
    "packages": [
        {"id": "file-search", "version": "0.1.0", "file": "file-search-0.1.0.tar.gz", "sha256": h_fs},
        {"id": "notes", "version": "0.1.0", "file": "notes-0.1.0.tar.gz", "sha256": h_notes},
        {"id": "smart-home", "version": "0.1.0", "file": "smart-home-0.1.0.tar.gz", "sha256": h_home},
    ],
}
with open(f"{workdir}/repo/index.json", "w") as f:
    json.dump(index, f, indent=2)
PYEOF

log "verifying the tarball hashes in the index actually match the real files"
INTEGRITY_OK=1
for app in "${APPS[@]}"; do
  ACTUAL=$(sha256sum "repo/${app}-0.1.0.tar.gz" | awk '{print $1}')
  RECORDED=$(python3 -c "import json; print(json.load(open('repo/index.json'))['packages'][[p['id'] for p in json.load(open('repo/index.json'))['packages']].index('$app')]['sha256'])")
  [ "$ACTUAL" != "$RECORDED" ] && INTEGRITY_OK=0
done
if [ "$INTEGRITY_OK" -eq 1 ]; then
  result "Index sha256 hashes match the real tarballs" PASS
else
  result "Index sha256 hashes match the real tarballs" FAIL
fi

log "signing the index with the real keystore (jarsigner, same primitive F-Droid's own index-v1.jar uses)"
cd repo && zip -q ../index-unsigned.zip index.json && cd ..
cp index-unsigned.zip index.jar
# fdroidserver's own config.yml (plain YAML) is the source of truth for
# the keystore password and alias it just generated — read it directly
# rather than re-deriving it via keytool prompts.
KEYALIAS=$(python3 -c "import yaml; print(yaml.safe_load(open('config.yml'))['repo_keyalias'])")
STOREPASS=$(python3 -c "import yaml; print(yaml.safe_load(open('config.yml'))['keystorepass'])")
jarsigner -keystore keystore.p12 -storetype pkcs12 -storepass "$STOREPASS" index.jar "$KEYALIAS" >/dev/null 2>&1

if jarsigner -verify index.jar >/dev/null 2>&1; then
  result "Signed index verifies with jarsigner" PASS
else
  result "Signed index verifies with jarsigner" FAIL
fi

log "confirming tampering with the SIGNED jar's content is correctly rejected"
# Tampering with a never-signed copy of index.json (the first version of
# this check) only proves jarsigner can tell an unsigned jar isn't signed
# — a different, weaker claim. The real negative control: take the
# already-signed index.jar, modify the index.json entry inside that same
# jar file (leaving its META-INF signature entries in place), and confirm
# jarsigner -verify now detects the mismatch and fails.
cp index.jar tampered.jar
mkdir tamper-extract && cd tamper-extract && unzip -q ../tampered.jar index.json && cd ..
python3 -c "
import json
d = json.load(open('tamper-extract/index.json'))
d['packages'][0]['sha256'] = '0' * 64
json.dump(d, open('tamper-extract/index.json', 'w'))
"
cd tamper-extract && zip -q ../tampered.jar index.json && cd ..
if jarsigner -verify tampered.jar >/dev/null 2>&1; then
  result "Tampering with the signed index is correctly rejected" FAIL "modified content inside a signed jar should fail verification"
else
  result "Tampering with the signed index is correctly rejected" PASS
fi

echo
echo "=== RESULTS (Phase 6 App distribution — real signing infra, honest scope on format) ==="
printf '%s\n' "${RESULTS[@]}"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL of $((PASS + FAIL)) checks FAILED"
  exit 1
fi
echo "all $PASS checks PASSED"
