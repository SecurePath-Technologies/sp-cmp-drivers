#!/bin/bash
# Dry-run the cmpunlocker patch series against an open-gpu-kernel-modules release, without building.
# Use it when NVIDIA ships a new open driver: it shows which patches still apply, which need fuzz/offset,
# and which fail and must be rebased by hand.  Usage: tools/check-patches.sh <version> [tarball]
#   e.g. tools/check-patches.sh 610.57.04
# Reads the patch order from driver/build.sh (PATCH_ORDER) so it always matches the real build.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="${1:?usage: $0 <driver-version> [tarball]}"
TB="${2:-${REPO}/driver/.build/open-gpu-kernel-modules-${V}.tar.gz}"
if [[ ! -f "$TB" ]]; then
  mkdir -p "$(dirname "$TB")"
  echo "downloading open-gpu-kernel-modules ${V}"
  curl -fL -o "$TB" "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${V}.tar.gz"
fi
mapfile -t ORDER < <(awk '/^PATCH_ORDER=\(/{f=1;next} f&&/^\)/{exit} f{gsub(/[[:space:]]/,""); if($0!="") print}' "${REPO}/driver/build.sh")
[[ ${#ORDER[@]} -gt 0 ]] || { echo "could not read PATCH_ORDER from driver/build.sh" >&2; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
tar -xzf "$TB" -C "$T"; cd "$T"/open-gpu-kernel-modules-"$V"
fail=0
for p in "${ORDER[@]}"; do
  out="$(patch -p1 --no-backup-if-mismatch < "${REPO}/driver/patches/${p}" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "FAIL    ${p}"; echo "$out" | grep -iE 'FAILED|reject|malformed' | sed 's/^/        /'; fail=1; break
  elif echo "$out" | grep -qi 'fuzz'; then
    echo "FUZZ    ${p}: $(echo "$out" | grep -i fuzz | head -1)"
  elif echo "$out" | grep -qi 'offset'; then
    echo "offset  ${p}"
  else
    echo "ok      ${p}"
  fi
done
[[ $fail -eq 0 ]] && echo "all ${#ORDER[@]} patches apply to ${V}" || echo "series stops at the first failure: rebase it on ${V}, then re-run"
exit $fail
