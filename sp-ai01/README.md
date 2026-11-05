# sp-ai01 host tooling

Box-specific scripts for sp-ai01 (2x Xeon 4215R; RTX PRO 4500 Blackwells + CMP 170HX on one patched driver). They are
here as working examples and are written for that box; check paths, PCI IDs and limits before using them elsewhere.

| File | Installed as | What it does |
|---|---|---|
| `bin/sp-power` + `etc/sp-power.conf` + `systemd/sp-power.service` | `/usr/local/sbin/sp-power`, `/etc/sp-power.conf` | One daemon for CPU RAPL caps/turbo, CMP power limits, CMP boot stages with a boot-loop guard, a busy/idle CMP clock governor, GPU fan quieting, and thermal overrides that only ever lower limits. `sp-power status`. |
| `bin/sp-gpu-rebar.sh` + `etc/*rebar*` | `/usr/local/sbin`, `/etc/modprobe.d`, `/etc/dracut.conf.d` | Runs from the `install nvidia` modprobe hook in the initramfs: grows BAR1 where possible, and when firmware left a BAR1 unassigned (not enough MMIO space for two 32 GB BAR1s on one root complex) steps the ReBAR size down with setpci and re-enumerates until it fits. |
| `bin/sp-ai01-gpu.sh` | `~/gpu-setup/` | Idempotent installer/fixer for the driver, ReBAR hook, Gen2 retrain, persistence, package holds; `--status` reports only. |
| `bin/sp-cmp-gen2.sh` + `systemd/sp-cmp-gen2.service` | | Retrains CMP links to PCIe Gen2 after the driver binds. |
| `bin/cmp-pin.sh` | | Docker CPU/NUMA pinning flags for CMP vs RTX containers. |
| `docs/hbm-clock-port.md` | | Plan for the FBPA PLL port and HBM clock qualification. |
