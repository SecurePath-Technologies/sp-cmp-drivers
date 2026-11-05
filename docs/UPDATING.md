# Moving to a new NVIDIA open-driver release

NVIDIA tags each release at https://github.com/NVIDIA/open-gpu-kernel-modules/tags. The patches are plain
`patch -p1` diffs against that tree, applied in the order of `PATCH_ORDER` in `driver/build.sh`.

1. **Check the series:** `tools/check-patches.sh <new-version>` (downloads the tarball). `ok`/`offset` are fine;
   `FUZZ` works but re-read that hunk; `FAIL` stops at the first patch that no longer applies.
2. **Rebase a failing patch:** extract the tarball, apply the series up to the failing patch, apply the failing one
   with `patch -p1 --merge` (or by hand), then regenerate it with `diff -ruN a/ b/` for just the files it touches.
   Watch for: renamed functions/HAL files, moved anchors in `kernel_gsp.c` / `kernel_gsp_tu102.c`, changed
   structure layouts. Re-run step 1 until the whole series applies.
3. **Allow the version:** add it to the top of `driver/VERSION` (build.sh refuses unlisted versions; with no
   `CMPUNLOCKER_DRIVER_VERSION` set it builds the first entry).
4. **Test build:** `CMPUNLOCKER_DRIVER_VERSION=<v> CMPUNLOCKER_BUILD_ONLY=$PWD/out CMPUNLOCKER_JOBS=4 driver/build.sh`.
5. **Userspace must match:** the matching `nvidia-*-<branch>` userspace/firmware packages (incl. the GSP firmware) must
   be installed at exactly the same version. On sp-ai01 these are apt-held; unhold, upgrade kernel + driver together.
6. **Live test before install:** stop GPU users, `rmmod` the nvidia modules, `insmod` the built ones; check `dmesg` for
   `SEC2_DEBUG ... PLM` lines (no `FAILED to open`), expected memory size per card, and that non-CMP GPUs still work.
   Then install with `install.sh`, which also rebuilds the initramfs.
7. Open a PR here with the rebased patches and the `driver/VERSION` change.
