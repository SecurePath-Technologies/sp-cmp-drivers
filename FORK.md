# cmp-drivers: SecurePath fork of cmpunlocker

Patched NVIDIA open GPU kernel modules for the **NVIDIA CMP 170HX**, based on
[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) tag **v0.5** (`17535a0`), plus the
host tooling for our box `sp-ai01` (see `sp-ai01/`). Licensed GPLv2 like upstream; see `LICENSE` and `CREDITS.md`.
Upstream's README below this file still describes installation; this file lists what differs.

## Changes on top of upstream v0.5
| Commit | Change |
|---|---|
| Open the FBPA memory-PLL PLMs | `sec2-postbl-plm-ss-cfg.patch` also opens FBPA_PLL0/1/2 so [170tune](https://github.com/cachenetics/170tune)'s live `hbm_mclk` can tune HBM clocks. Map from [asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock); its build-time NDIV bake is **not** used. Fixes the PLM loop that was hardcoded to 12 entries. |
| build.sh build-only mode | `CMPUNLOCKER_BUILD_ONLY=<dir>` compiles without root and without touching `/lib/modules`, depmod or the initramfs; `CMPUNLOCKER_JOBS` limits `make -j`. |
| tools/check-patches.sh | Dry-runs the whole patch series against any open-gpu-kernel-modules release. |

## Status (2026-11-05)
- Running on sp-ai01: upstream v0.5 on 610.57.04. The FBPA PLL change is built and pending a live test.
- 10GB cards (10de:2082) unlock to 40 GB. **80 GB does not work** (upstream branches `80`/`80-new`: memory above
  40 GiB aliases and GSP crashes); not pursued here.
- `nvidia-smi` ECC status/counters on CMPs are synthesized by `ecc-reporting.patch` (always 0); qualify memory with a
  bit-exact readback test, not ECC counters.

## Building
```bash
# test build (no root, installs nothing):
CMPUNLOCKER_DRIVER_VERSION=610.57.04 CMPUNLOCKER_CARD_PROFILE=8gb CMPUNLOCKER_JOBS=4 \
  CMPUNLOCKER_BUILD_ONLY=$PWD/out driver/build.sh
# real install: upstream's install.sh (detects the installed userspace driver version)
```
`CMPUNLOCKER_DRIVER_VERSION` must match the installed NVIDIA userspace (`nvidia-smi`), or the first entry of
`driver/VERSION` is built. Never install a module whose version differs from userspace.

Updating to a new open-driver release: see [docs/UPDATING.md](docs/UPDATING.md).
