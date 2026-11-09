# Host tooling (research examples)

Scripts from our CMP 170HX research host (dual-socket Xeon; CMP 170HX cards alongside other NVIDIA GPUs on one
patched driver). They're published as working examples of what the driver patches make possible. They are not a
supported installer: check paths, PCI IDs, CPU topology and limits before using them anywhere else.

| File | Installed as | What it does |
|---|---|---|
| `bin/sp-power` + `etc/sp-power.conf` + `systemd/sp-power.service` | `/usr/local/sbin/sp-power`, `/etc/sp-power.conf` | One daemon for CPU RAPL caps/turbo, CMP power limits, CMP boot stages with a boot-loop guard, a busy/idle CMP clock governor, an optional per-card HBM clock/timing profile, GPU fan quieting, and thermal overrides that only ever lower limits. `sp-power status`. |
| `bin/sp-gpu-rebar.sh` + `etc/*rebar*` | `/usr/local/sbin`, `/etc/modprobe.d`, `/etc/dracut.conf.d` | Runs from the `install nvidia` modprobe hook in the initramfs. It grows BAR1 where it can. When firmware left a BAR1 unassigned (for example, not enough MMIO space for two 32 GB BAR1s on one root complex), it steps the ReBAR size down with setpci and re-enumerates until the card fits. |
| `bin/cmp-host-setup.sh` | | Idempotent installer/fixer for the driver, ReBAR hook, Gen2 retrain, persistence and package holds. `--status` only reports. Written for one box; read every step first. |
| `bin/sp-cmp-gen2.sh` + `systemd/sp-cmp-gen2.service` | `/usr/local/sbin` | Retrains CMP links (20c2 and 2082) to PCIe Gen2 after the driver binds. |
| `bin/cmp-pin.sh` | | Docker CPU/NUMA pinning flags so CMP and non-CMP containers stay on their local socket. |
| `docs/hbm-overclock-research.md` | | Notes on live HBM clock/timing tuning through the FBPA PLL/MEM PLMs: method, findings and risks. |
