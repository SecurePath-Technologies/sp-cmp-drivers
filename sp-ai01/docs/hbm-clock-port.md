# HBM memory-clock port: open the FBPA PLL window on our cmpunlocker v0.5 / 610.57.04 (2026-11-05)

Goal: let 170tune's live `hbm_mclk` raise the 10GB CMP (86:00.0, 10de:2082) memory clock above stock
NDIV 45 = 1215 MHz, then qualify a step with its hot correctness gate. Status: PLANNED, nothing built or installed.

## Why only one patch changes
- Today: `sudo hbm_mclk -b 0000:86:00.0 get` -> `NDIV 45 (1215 MHz) ... PLM 0xffffffcf (host-write BLOCKED)`.
- asm64-hooligan/cmpunlocker@mem_overclock (d7f5eca; 765ffba "Allow mem oc on any VBIOS and on 10gb cards")
  opens three extra priv-level masks in its PLM table: FBPA_PLL0/1/2 = 0x9a3c7c / 0x9a3c80 / 0x9a3c84.
  That is the "FBPA_PLL PLM in the post-BooterLoad window" 170tune's README credits. It is all 170tune needs.
- Its 0009/0010 patches BAKE a fixed NDIV at build time (`--mclk-ndiv`). NOT used (DS41.md rule: live tuning only).
- Our table has 3 entries the fork lacks (RECONFIG_PLM, PJTAG_PLM, PJTAG_SEC_PLM): keep them, add the 3 PLL ones.
- GOTCHA fixed: our loop is hardcoded `plmIdx < 12`; extra entries would be skipped silently.
  Now `plmIdx < NV_ARRAY_ELEMENTS(plmTable)` (as in the fork). Hunk header +143 -> +148.

Files here: `sec2-postbl-plm-ss-cfg.patch.fbpa-pll` (replacement patch), `plm-fbpa-pll.diff` (what changed).
Verified: all 14 patches in build.sh's PATCH_ORDER apply to pristine 610.57.04 (only pcie-gen2 fuzz 1, pre-existing).
NOT compiled yet (compile = heavy CPU load on this box; ask first).

## Steps (maintenance window: one driver serves all 3 GPUs; nothing GPU-side runs now except sp-power/persistenced)
1. Build in a scratch copy, never in /opt directly:
   copy /opt/sp-ai01-gpu/cmpunlocker -> scratch, drop in the new patch, `CMPUNLOCKER_BUILD_DIR=<scratch>/.build driver/build.sh`
   (check how install.sh calls build.sh: profile/geometry substitution must stay identical). CPU heavy: run on
   node-1 cores with low -j, watch temps (no CPU0 load without asking).
2. Back up the live module: /lib/modules/7.0.0-34-generic/updates/cmpunlocker/nvidia.ko (+ nvidia-uvm/drm/modeset)
   and /boot/initrd.img-7.0.0-34-generic.
3. Live test without a reboot: stop sp-power + nvidia-persistenced, rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia,
   insmod/modprobe the NEW module. Check dmesg: `SEC2_DEBUG: PLM[12..14] FBPA_PLL0..2 ... reg=0xffffffff`, no
   "FAILED to open". Check 40960 MiB, all 3 GPUs, 3b BAR1 8 GB, Blackwells fine. Then `hbm_mclk get` must NOT say BLOCKED.
   Restart persistenced + sp-power. (nvflash lesson: rmmod leaves Falcon halted ONLY for nvflash, driver reloads are fine.)
4. If good: install the module, rebuild the initramfs (nvidia loads from it), reboot once, re-check step 3.
   Rollback: copy the backed-up .ko files back, dracut -f, reboot.
5. Qualify (170tune; HBM must stay <= 75 C under load, OC corrupts hotter): `170tune -i 2 preflight`, then
   `mclk-try` one step at a time from NDIV 45 (27 MHz per step), then `mclk-gate N 12` (12 hot sweeps).
   10GB cards ship Samsung HBM2 at a lower stock point than the 20c2 Hynix cards (1215 vs 1458/1728): headroom unknown,
   do not assume the old cards' NDIV 70 limit.
   Community data (bayley/cmpunlocker NDIV table): NDIV 45 = 1215 MHz stock 10GB; NDIV 60 = 1620 MHz "works on ~60%
   of 10gb cards" (unverified per card). Realistic target range 45-60, gated one step at a time.
6. Persist: add a per-card-serial HBM NDIV to sp-power (applied after the safe stage, behind the same boot-loop guard),
   since 170tune-persist is now disabled.
7. Measure: prefill + multi-stream tok/s vs stock. Batch-1 decode was latency-bound on the old cards; expect little there.

## Risks
- Blocking or wrong PLL writes hang the memory -> GPU lost until a cold power cycle. Only 170tune's gated path writes.
- The new driver affects the Blackwells too (shared module).
- ECC telemetry is fake (ecc-reporting.patch), so only gpu_selftest's bit-exact readback qualifies a step.
