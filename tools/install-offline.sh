#!/usr/bin/env bash
# Offline installer for the pipeline tools on a Linux x64 Azure DevOps agent (no internet needed).
#
#   sudo bash tools/install-offline.sh [TOOLS_DIR] [PREFIX]
#
#   TOOLS_DIR  directory that contains bin/, wheels/ and SHA256SUMS (default: linux-x64/ next to this script)
#   PREFIX     where binaries are installed (default: /usr/local/bin)
#
# Installs: yq, oasdiff, jq, spectral (standalone, no Node.js required) and yamllint (Python 3 wheels,
# installed with pip --no-index). The IBM API Connect toolkit is NOT included: download the Linux CLI from
# your tenant (API Manager -> Tools for download) and place the `apic` binary in PREFIX as well.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${1:-$HERE/linux-x64}"
PREFIX="${2:-/usr/local/bin}"

[[ -d "$TOOLS_DIR/bin" ]] || { echo "ERROR: $TOOLS_DIR/bin not found" >&2; exit 1; }
mkdir -p "$PREFIX"

echo "== Verifying checksums"
( cd "$TOOLS_DIR" && sha256sum -c SHA256SUMS )

echo "== Installing binaries to $PREFIX"
for t in yq oasdiff jq spectral; do
  install -m 0755 "$TOOLS_DIR/bin/$t" "$PREFIX/$t"
  printf '   %-8s %s\n' "$t" "$("$PREFIX/$t" --version 2>&1 | head -n1)"
done

echo "== Installing yamllint from bundled wheels"
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "WARNING: python3 not found - yamllint (stage 1) not installed. Install Python 3.9+ and re-run." >&2
else
  "$PY" -m pip install --quiet --no-index --find-links "$TOOLS_DIR/wheels" yamllint \
    || "$PY" -m pip install --quiet --user --no-index --find-links "$TOOLS_DIR/wheels" yamllint
  printf '   %-8s %s\n' yamllint "$("$PY" -m yamllint --version 2>&1)"
  command -v yamllint >/dev/null 2>&1 || echo "NOTE: add \$($PY -m site --user-base)/bin to PATH so 'yamllint' resolves for the agent user"
fi

echo "== Checking the IBM API Connect toolkit"
if command -v apic >/dev/null 2>&1; then
  apic --accept-license version 2>&1 | head -n 3 | sed 's/^/   /'
else
  echo "   apic not found on PATH: download it from API Manager -> Tools for download and copy it to $PREFIX/apic (chmod +x)"
fi
echo "Done."
