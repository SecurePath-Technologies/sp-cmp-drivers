#!/bin/bash
# sp-ai01 GPU setup: fix driver load, ReBAR, patched 610 driver + CMP 170HX unlock
# (64GB / FMA / Gen2), Gen2 link retrain, persistence. Idempotent: safe to re-run;
# each step checks current state first and skips what is already done.
#
#   sudo ~/gpu-setup/sp-ai01-gpu.sh            # do everything
#   sudo ~/gpu-setup/sp-ai01-gpu.sh --status   # report only, change nothing
#
# Also the "things got wonky" fixer: re-run it after a bad boot, a lost unlock, a stock driver
# sneaking back in, or a link that fell to Gen1. Safe while models run: any step that has to
# unload the driver stops and asks you to stop containers first; everything else applies live.
#
# Log: /var/log/sp-ai01-gpu.log   Backups of every file touched: /var/backups/sp-ai01-gpu/
set -uo pipefail

LOG=/var/log/sp-ai01-gpu.log
BACKUP=/var/backups/sp-ai01-gpu/$(date +%Y%m%d-%H%M%S)
SRC=/opt/sp-ai01-gpu                       # third-party repos land here
CMPUNLOCKER_REPO=https://github.com/amoghmunikote/cmpunlocker.git
TUNE_REPO=https://github.com/cachenetics/170tune.git
CMP_IDS='10de:(20c2|2082)'                # CMP 170HX: 20c2 = 8GB card (64 GB unlock), 2082 = 10GB card (40 GB)
DRV_BRANCH=610

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok: %s\n' "$*"; }
skip() { printf '   skip: %s\n' "$*"; }
warn() { printf '   \033[33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mSTOP: %s\033[0m\n' "$*"; exit 1; }
backup() { for f; do [ -e "$f" ] || continue; mkdir -p "$BACKUP$(dirname "$f")"; cp -a "$f" "$BACKUP$f"; done; }

cmp_bdfs()  { lspci -Dn | awk -v r="$CMP_IDS" '$3 ~ r {print $1}'; }
is_cmp_dev() { case "$(cat /sys/bus/pci/devices/$1/device)" in 0x20c2|0x2082) return 0;; esac; return 1; }
nv_bdfs()   { lspci -D -d 10de: | awk '$2 ~ /^(VGA|3D)/ {print $1}'; }
vram_ok() { timeout 30 nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk -F', ' -v want="$(cmp_bdfs | sed 's/^0000://' | tr 'A-Z' 'a-z' | xargs)" \
              'BEGIN{t=split(want,w," ")} {b=tolower($1); for(i=1;i<=t;i++) if (index(b,w[i]) && $2 > 39000) n++} END{exit !(t>0 && n==t)}'; }
bar1_mb()   { awk 'NR==2{s=strtonum($2)-strtonum($1); print (s>0)?int((s+1)/1048576):0}' /sys/bus/pci/devices/$1/resource; }
# RTX PROs whose BAR1 is below 32 GB (ReBAR not applied; only a driver reload fixes it)
# RTX PROs with BAR1 below 8 GB. Since 2026-11-05 both RTX PROs share root complex 3a (64 GB window), so 3b
# can only get 8 GB (the rebar helper fits it at boot); 8 GB is normal, not a fault.
small_bars() { local d; for d in $(nv_bdfs); do is_cmp_dev $d && continue
               [ "$(bar1_mb $d)" -lt 8192 ] && echo "$d"; done; }
drv_of()    { local l=/sys/bus/pci/devices/$1/driver; [ -e "$l" ] && basename "$(readlink "$l")" || echo none; }
# rmmod, not modprobe -r: after the 595 purge the loaded modules have no files on disk,
# and modprobe -r silently fails on modules it cannot find in the index.
# Host services that keep /dev/nvidia* open (quiet-fans holds an NVML handle on GPU0 all the time).
# Stopped before an unload and started again on exit, even if a later step fails.
GPU_SERVICES="quiet-fans.service nvidia-persistenced.service"
STOPPED_SVCS=
unload_nvidia() {
  local m s
  [ -n "$(docker ps -q 2>/dev/null)" ] && die "this step must unload the NVIDIA driver, but containers are running ($(docker ps --format '{{.Names}}' | xargs)). Stop them (docker stop <name>) and re-run."
  for s in $GPU_SERVICES; do
    systemctl is-active --quiet $s && systemctl stop $s && STOPPED_SVCS="$STOPPED_SVCS $s" && ok "stopped $s (holds the driver)"
  done
  for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
    [ -d /sys/module/$m ] && { rmmod $m || { fuser -v /dev/nvidia* 2>&1 | sed 's/^/   /'; die "could not unload $m; the processes above still hold /dev/nvidia*"; }; }
  done
  [ -d /sys/module/nvidia ] && die "nvidia module still loaded"
  ok "nvidia modules unloaded"
}

status() {
  say "Status"
  for d in $(nv_bdfs); do
    p=/sys/bus/pci/devices/$d
    bar1=$(awk 'NR==2{s=strtonum($2)-strtonum($1); print (s>0)?(s+1)/1048576:0}' "$p/resource")
    printf '   %s %-28s drv=%-8s link=%s x%s  BAR1=%s MiB\n' "$d" \
      "$(lspci -s "$d" | sed 's/.*\[\(.*\)\].*/\1/' | cut -c1-28)" "$(drv_of "$d")" \
      "$(cat "$p/current_link_speed" | cut -d' ' -f1)" "$(cat "$p/current_link_width")" "$bar1"
  done
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,driver_version,power.limit --format=csv,noheader | sed 's/^/   /'
  else
    echo "   nvidia-smi: driver not loaded"
  fi
}
[ "${1:-}" = "--status" ] && { status; exit 0; }

say "Preflight"
[ "$(nv_bdfs | wc -l)" -eq 4 ] || die "expected 4 NVIDIA GPUs, found $(nv_bdfs | wc -l)"
[ "$(cmp_bdfs | wc -l)" -ge 1 ] || die "no CMP 170HX on the bus"
[ "$(cmp_bdfs | wc -l)" -eq 2 ] || warn "only $(cmp_bdfs | wc -l) CMP 170HX on the bus (slots 1/2 empty since the 2026-11-05 swap)"
ok "4 NVIDIA GPUs present (2x CMP 170HX)"
if [ -n "$(docker ps -q 2>/dev/null)" ]; then
  warn "containers running ($(docker ps --format '{{.Names}}' | xargs)): live fixes only; driver reloads will stop and ask"
else ok "no containers running"; fi
if [ -d /sys/module/nvidia ]; then
  LOADED=$(cat /sys/module/nvidia/srcversion 2>/dev/null)
  PATCHED=$(modinfo -F srcversion /lib/modules/$(uname -r)/updates/cmpunlocker/nvidia.ko 2>/dev/null || true)
  if [ -n "$PATCHED" ] && [ "$LOADED" = "$PATCHED" ]; then ok "patched cmpunlocker driver is the one loaded"
  else warn "loaded nvidia module is NOT the patched cmpunlocker build; steps 5-6 will reinstall/reload it"; rm -f $SRC/.cmpunlocker-installed; fi
else warn "nvidia driver not loaded; step 6 will load it"; fi

# Some fixes only apply on a driver reload (ReBAR on the RTX PROs, a lost 64GB unlock). A reboot stops the
# models anyway, so offer to do it here: stop the containers, let step 6 reload, restart them at the end.
FORCE_RELOAD=; RESTART=
STOPFILE=/run/sp-ai01-gpu.stopped-containers          # survives a killed run, not a reboot
[ -s $STOPFILE ] && { RESTART=$(cat $STOPFILE); warn "an earlier run stopped containers and did not restart them: $RESTART (restarted at the end)"; }
restart_containers() {
  [ -n "$STOPPED_SVCS" ] && { systemctl start $STOPPED_SVCS && echo "   ok: restarted$STOPPED_SVCS" || echo "   WARN: could not restart$STOPPED_SVCS"; STOPPED_SVCS=; }
  [ -n "$RESTART" ] || return 0
  echo; echo "Restarting containers stopped for the driver reload: $RESTART"
  docker start $RESTART >/dev/null && echo "   ok: started (models take a few minutes to load; then ~/check-bindings.sh)" \
    || echo "   WARN: docker start failed; start them with ~/start-sm12x.sh, ~/start-gemma.sh, ~/start-ocr.sh"
  RESTART=; rm -f $STOPFILE
}
trap restart_containers EXIT
trap 'exit 130' INT TERM
need=
[ -n "$(small_bars)" ] && need="BAR1 below 8 GB on $(small_bars | xargs)"
if [ -n "$need" ]; then
  running=$(docker ps --format '{{.Names}}' 2>/dev/null | xargs)
  if [ -z "$running" ]; then FORCE_RELOAD=1; ok "driver reload needed ($need); no containers running, step 6 will do it"
  elif [ -t 0 ]; then
    warn "driver reload needed: $need"
    read -rp "   Stop containers ($running), reload the driver, then restart them? [y/N] " a
    if [ "$a" = y ]; then
      docker stop $running >/dev/null || die "docker stop failed"
      RESTART=$running; echo "$RESTART" > $STOPFILE; FORCE_RELOAD=1; ok "stopped: $running (restarted at the end, even if a step fails)"
    else warn "skipping the reload; $need stays until the next reload or reboot"; fi
  else warn "driver reload needed ($need) but containers are running; re-run from a terminal to be asked"; fi
fi

# --- 1. Remove the stale ReBAR-shrink hook (targets 0000:b4:00.0, which no longer exists).
# It exits 1, and because modprobe.d chains it with '&&', nvidia never loads.
say "1. Remove stale gpu-rebar-shrink hook"
if [ -e /etc/modprobe.d/gpu-rebar-before-nvidia.conf ]; then
  backup /etc/modprobe.d/gpu-rebar-before-nvidia.conf
  rm -f /etc/modprobe.d/gpu-rebar-before-nvidia.conf; ok "removed modprobe hook (backed up)"
else skip "modprobe hook already gone"; fi
if [ -e /etc/systemd/system/gpu-rebar-shrink.service ]; then
  systemctl disable gpu-rebar-shrink.service 2>/dev/null
  backup /etc/systemd/system/gpu-rebar-shrink.service
  rm -f /etc/systemd/system/gpu-rebar-shrink.service; systemctl daemon-reload; ok "removed gpu-rebar-shrink.service"
else skip "gpu-rebar-shrink.service already gone"; fi

# --- 2. ReBAR: grow BAR1 on the RTX PRO 4500s to their max before nvidia binds.
# Non-fatal by design ('; modprobe', not '&&') so a failed resize can never block the driver again.
say "2. ReBAR helper for RTX PRO 4500s"
cat > /usr/local/sbin/sp-gpu-rebar.sh.new <<'EOF'
#!/bin/sh
# BAR1 sizing for non-CMP NVIDIA GPUs, run by the modprobe hook BEFORE nvidia loads. Never fails.
#  - BAR1 assigned by the firmware: try to grow it to the largest supported size.
#  - BAR1 left UNASSIGNED by the firmware (not enough PCI address space, e.g. since 2026-11-05 both
#    RTX PROs share root complex 3a, whose 64 GB window can't hold 2x 32 GB BAR1 + BAR3s): step the
#    ReBAR size down via setpci and re-enumerate the card until the kernel can place it
#    (3b lands at 8 GB). The card resets to 32 GB on every power cycle, so this runs every boot.
# Runs from the initramfs: only shell builtins plus cat/sleep/setpci (setpci is added by dracut).
log() { logger -t sp-gpu-rebar "$*" 2>/dev/null || echo "sp-gpu-rebar: $*" > /dev/kmsg 2>/dev/null; }
is_cmp() { case "$(cat $1/device)" in 0x20c2|0x2082|0x20b0) return 0;; esac; return 1; }
bar1_start() { { read -r _ ; read -r s _ ; } < $1/resource; echo $(( s )); }
SETPCI=$(command -v setpci 2>/dev/null || echo /usr/bin/setpci)

# Only one instance at a time (udev can fire a second 'modprobe nvidia' while we re-enumerate).
LOCK=/run/sp-gpu-rebar.lock; n=0
while ! mkdir $LOCK 2>/dev/null; do sleep 0.2; n=$((n+1)); [ $n -ge 150 ] && exit 0; done
trap 'rmdir $LOCK 2>/dev/null' EXIT

for p in /sys/bus/pci/devices/*; do
  [ "$(cat $p/vendor)" = 0x10de ] || continue
  case "$(cat $p/class)" in 0x0300*|0x0302*) ;; *) continue;; esac
  is_cmp $p && continue                                  # CMP BAR1 is handled by cmpunlocker
  [ -e $p/driver ] && continue                           # only unbound devices
  [ -e $p/resource1_resize ] || continue
  d=${p##*/}
  mask=$(( 0x$(cat $p/resource1_resize) )); max=-1; i=0
  while [ $i -lt 48 ]; do [ $(( (mask >> i) & 1 )) -eq 1 ] && max=$i; i=$((i+1)); done
  [ $max -ge 0 ] || continue

  if [ "$(bar1_start $p)" -ne 0 ]; then                  # assigned: try to grow (harmless if no room)
    echo $max > $p/resource1_resize 2>/dev/null && log "$d BAR1 -> bit $max"
    continue
  fi

  # Unassigned: shrink until it fits.
  ctl=$($SETPCI -s $d ECAP15+8.L 2>/dev/null) || { log "$d BAR1 unassigned, setpci unavailable"; continue; }
  [ $(( 0x$ctl & 7 )) -eq 1 ] || { log "$d ReBAR entry 0 is not BAR1 (ctl=$ctl); skipped"; continue; }
  parent=$(cd -P $p/.. && pwd -P); parent=${parent##*/}
  cur=$(( (0x$ctl >> 8) & 0x3f )); b=$((cur - 1)); fixed=0
  while [ $b -ge 8 ]; do                                 # bit 8 = 256 MiB floor
    if [ $(( (mask >> b) & 1 )) -eq 1 ]; then
      ctl=$($SETPCI -s $d ECAP15+8.L)
      $SETPCI -s $d ECAP15+8.L=$(printf '%08x' $(( (0x$ctl & ~0x3F00) | (b << 8) )))
      echo 1 > /sys/bus/pci/devices/$d/remove
      echo 1 > /sys/bus/pci/devices/$parent/rescan
      n=0; while [ ! -e /sys/bus/pci/devices/$d ] && [ $n -lt 25 ]; do sleep 0.2; n=$((n+1)); done
      p=/sys/bus/pci/devices/$d
      [ -e $p/resource ] || { log "$d did not come back after rescan"; break; }
      if [ "$(bar1_start $p)" -ne 0 ]; then
        log "$d BAR1 unassigned by firmware at bit $cur; fitted at bit $b ($(( 1 << (b - 10) )) GiB)"
        fixed=1; break
      fi
    fi
    b=$((b - 1))
  done
  [ $fixed -eq 1 ] || log "$d BAR1 could not be fitted at any size"
done
exit 0
EOF
chmod 755 /usr/local/sbin/sp-gpu-rebar.sh.new
cmp -s /usr/local/sbin/sp-gpu-rebar.sh.new /usr/local/sbin/sp-gpu-rebar.sh 2>/dev/null \
  && { rm /usr/local/sbin/sp-gpu-rebar.sh.new; skip "rebar helper up to date"; } \
  || { mv /usr/local/sbin/sp-gpu-rebar.sh.new /usr/local/sbin/sp-gpu-rebar.sh; ok "installed /usr/local/sbin/sp-gpu-rebar.sh"; }
HOOK='install nvidia /usr/local/sbin/sp-gpu-rebar.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS'
if [ "$(cat /etc/modprobe.d/sp-gpu-rebar.conf 2>/dev/null)" != "$HOOK" ]; then
  echo "$HOOK" > /etc/modprobe.d/sp-gpu-rebar.conf; ok "installed non-fatal modprobe hook"
else skip "modprobe hook in place"; fi
# dracut puts nvidia.ko and this modprobe hook in the initramfs, so nvidia loads before the root fs
# is mounted and the helper must be in there too (otherwise: "sp-gpu-rebar.sh: not found", 256 MiB BAR1).
DC=/etc/dracut.conf.d/sp-gpu-rebar.conf
WANTDC='install_items+=" /usr/local/sbin/sp-gpu-rebar.sh /usr/bin/logger /usr/bin/setpci "'
INITRD=/boot/initrd.img-$(uname -r)
if [ "$(cat $DC 2>/dev/null)" != "$WANTDC" ]; then echo "$WANTDC" > $DC; ok "dracut: helper added to initramfs config"; fi
if lsinitrd -f usr/local/sbin/sp-gpu-rebar.sh "$INITRD" 2>/dev/null | cmp -s - /usr/local/sbin/sp-gpu-rebar.sh; then
  skip "initramfs has the current rebar helper"
else
  backup "$INITRD"
  dracut -f --kver "$(uname -r)" >/dev/null 2>&1 || die "dracut failed; old initramfs is in $BACKUP/boot"
  lsinitrd -f usr/local/sbin/sp-gpu-rebar.sh "$INITRD" 2>/dev/null | cmp -s - /usr/local/sbin/sp-gpu-rebar.sh \
    && ok "initramfs rebuilt with rebar helper (applies next boot; backup in $BACKUP/boot)" \
    || die "helper still missing from $INITRD after rebuild; old initramfs is in $BACKUP/boot"
fi

# --- 3. Kernel cmdline: iomem=relaxed lets 170tune write BAR0 from userspace. Needs a plain reboot to apply.
say "3. Kernel cmdline"
GD=/etc/default/grub.d/sp-ai01-gpu.cfg
WANT='GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT iomem=relaxed"'
if [ "$(cat $GD 2>/dev/null)" != "$WANT" ]; then echo "$WANT" > $GD; update-grub >/dev/null 2>&1 && ok "added iomem=relaxed (applies next reboot)"
else skip "iomem=relaxed already configured"; fi
grep -qw iomem=relaxed /proc/cmdline || warn "iomem=relaxed not active until next reboot (only 170tune needs it)"

# --- 4. Driver: swap 595 for 610 userspace without DKMS (cmpunlocker builds the kernel module).
say "4. NVIDIA 610 userspace"
# Capture to a variable first: 'dpkg -l | grep -q' under pipefail reports failure when grep exits early.
OLD595=$(dpkg -l | awk '$1 ~ /^(ii|rc|iU)$/ {print $2}' | grep -E -- '-595(-|:|$)|595\.' || true)
if [ -n "$OLD595" ]; then
  apt-get purge -y $OLD595 && ok "purged 595 packages: $(echo $OLD595)" || die "apt purge of 595 failed"
else skip "no 595 packages"; fi
PKGS="libnvidia-compute-$DRV_BRANCH libnvidia-cfg1-$DRV_BRANCH nvidia-utils-$DRV_BRANCH nvidia-compute-utils-$DRV_BRANCH nvidia-kernel-common-$DRV_BRANCH"
PKGS="$PKGS $(apt-cache search --names-only "^nvidia-firmware-$DRV_BRANCH-" | awk '{print $1}' | sort -V | tail -1)"
PKGS="$PKGS build-essential dkms linux-headers-$(uname -r) pciutils git python3"
missing=$(for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)
if [ -n "$missing" ]; then apt-get update -qq && apt-get install -y --no-install-recommends $missing || die "apt install failed"; ok "installed: $(echo $missing)"
else skip "610 userspace + build deps present"; fi
dpkg -s "nvidia-dkms-$DRV_BRANCH-open" >/dev/null 2>&1 && die "nvidia-dkms-$DRV_BRANCH got pulled in; its stock nvidia.ko would shadow the patched one. apt-get purge it and re-run."
RUNNING=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1)
USERVER=$(dpkg-query -W -f='${Version}' nvidia-utils-$DRV_BRANCH | cut -d- -f1); ok "userspace version $USERVER"
if [ -n "$RUNNING" ] && [ "$RUNNING" != "$USERVER" ]; then
  echo "   running kernel module is $RUNNING, userspace is $USERVER: unloading the old module"
  unload_nvidia
fi

# --- 5. cmpunlocker: third-party code, runs as root and builds a patched nvidia.ko for ALL GPUs.
say "5. cmpunlocker (patched 610 module, 64GB / FMA / Gen2 unlock)"
mkdir -p $SRC
[ -d $SRC/cmpunlocker/.git ] || git clone -q $CMPUNLOCKER_REPO $SRC/cmpunlocker || die "clone failed"
# No auto-pull: a new upstream commit would rebuild and reload the driver under running models.
# To upgrade on purpose: git -C /opt/sp-ai01-gpu/cmpunlocker pull, then re-run this script.
REV=$(git -C $SRC/cmpunlocker rev-parse --short HEAD)
KVER=$(modinfo -F version nvidia 2>/dev/null || true)
if [ -f $SRC/.cmpunlocker-installed ] && [ "$(cat $SRC/.cmpunlocker-installed)" = "$REV $(uname -r) $USERVER" ] && [ "$KVER" = "$USERVER" ]; then
  skip "cmpunlocker $REV already installed for $(uname -r), module $KVER"
else
  echo "   About to run cmpunlocker install.sh as root: $CMPUNLOCKER_REPO @ $REV"
  echo "   This is unreviewed third-party code. Inspect $SRC/cmpunlocker first if you want."
  if [ -t 0 ]; then read -rp "   Continue? [y/N] " a; [ "$a" = y ] || die "aborted by user"; fi
  unload_nvidia
  (cd $SRC/cmpunlocker && ./install.sh --profile=8gb) || die "cmpunlocker install.sh failed; see output above. Its README lists the exact driver version it wants — if it rejects $USERVER, that is why."
  depmod -a
  KVER=$(modinfo -F version nvidia 2>/dev/null || true)
  [ "$KVER" = "$USERVER" ] || die "kernel module $KVER != userspace $USERVER; nvidia-smi would fail with a version mismatch"
  echo "$REV $(uname -r) $USERVER" > $SRC/.cmpunlocker-installed; ok "patched module $KVER installed ($(modinfo -n nvidia))"
fi
systemctl list-unit-files cmpunlocker.service >/dev/null 2>&1 && systemctl enable cmpunlocker.service >/dev/null 2>&1 && ok "cmpunlocker.service enabled (re-applies unlock each boot)"

# --- 6. Bring the cards up WITHOUT a power pull. Each CMP must be clean BEFORE nvidia initialises it:
# GSP boot registers restored and, if the ACR version stamp is stuck (write-protected once set), a reset.
# Not via cmpunlocker's passthrough.sh restore: that is for VM handoff. It loads nvidia partway through
# its loop (so on 2026-09-25 af:00.0 was probed while still dirty and failed with Booter error 0x29),
# then re-arms VM mode: persistence off and resets blocked, so our reset of af could not run.
say "6. Load driver (clean CMP GSP state, no power cycle)"
GSP_RESTORE=/usr/local/lib/cmpunlocker/gsp-restore
cmp_clean() {   # $1 = CMP BDF, not bound to any driver
  local d=$1 p=/sys/bus/pci/devices/$1 m
  rmmod cmp_no_bus_reset 2>/dev/null
  $GSP_RESTORE restore $d >/dev/null 2>&1 && { ok "$d GSP state clean"; return 0; }
  for m in flr bus; do
    printf default > $p/reset_method 2>/dev/null; printf $m > $p/reset_method 2>/dev/null || continue
    echo 1 > $p/reset 2>/dev/null || continue
    sleep 2
    if $GSP_RESTORE restore $d >/dev/null 2>&1; then
      printf default > $p/reset_method 2>/dev/null; ok "$d ACR stamp was stuck; cleared by $m reset"; return 0
    fi
  done
  printf default > $p/reset_method 2>/dev/null
  warn "$d ACR stamp still stuck after FLR and bus reset"; return 1
}
cmp_up() {      # $1 = CMP BDF: visible to nvidia-smi with the 64GB unlock
  timeout 30 nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' -v b="${1#0000:}" 'index(tolower($1), b) && $2 > 39000 {f=1} END{exit !f}'
}
if [ -n "$FORCE_RELOAD" ] || [ ! -d /sys/module/nvidia ]; then
  unload_nvidia
  for d in $(cmp_bdfs); do cmp_clean $d; done
  modprobe nvidia && modprobe nvidia_uvm && ok "nvidia loaded" || die "modprobe nvidia failed: dmesg | grep -i nvrm"
  sleep 5
fi
# Live per-card repair (e.g. after a failed reload): only the broken, idle CMP is touched; models keep running.
for d in $(cmp_bdfs); do
  p=/sys/bus/pci/devices/$d
  if cmp_up $d; then ok "$d up, 64GB"; continue; fi
  if timeout 30 nvidia-smi --query-compute-apps=gpu_bus_id --format=csv,noheader 2>/dev/null | grep -qi "${d#0000:}"; then
    warn "$d is not at 64GB but has CUDA processes; not touching it"; continue
  fi
  warn "$d not up at 64GB; repairing this card only"
  idx=$(timeout 30 nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | awk -F', ' -v b="${d#0000:}" 'index(tolower($2), b) {print $1}')
  [ -n "$idx" ] && timeout 30 nvidia-smi -i $idx -pm 0 >/dev/null 2>&1      # let persistenced let go of it
  [ -e $p/driver ] && echo $d > $p/driver/unbind
  cmp_clean $d
  echo $d > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null
  sleep 10
  cmp_up $d && ok "$d back up, 64GB" \
    || warn "$d still down (dmesg | grep -i nvrm). Last resort: shutdown -h now, unplug PSU 60 s, power on, re-run."
done

# --- 7. PCIe Gen2 on the CMPs. The link can only train at Gen2 AFTER the patched driver loads: before
# that the card advertises Gen1 only (LnkCap2 0x2; the driver sets 0x6). cmpunlocker's gen2.service
# runs at sysinit, before the driver, so it never succeeds (600 attempts, then a 45 s timeout on the
# 2026-09-25 boot). Ours runs after the driver is bound; it is what reached Gen2 on 2026-09-24.
say "7. PCIe Gen2"
if systemctl is-enabled --quiet gen2.service 2>/dev/null; then
  systemctl disable gen2.service >/dev/null 2>&1 && ok "disabled cmpunlocker gen2.service (runs before the driver, cannot reach Gen2)"
else skip "cmpunlocker gen2.service not enabled"; fi
cat > /usr/local/sbin/sp-cmp-gen2.sh.new <<'EOF'
#!/bin/sh
# Retrain each CMP 170HX link at Gen2 via its upstream bridge (LnkCtl2 target speed, LnkCtl retrain).
# Only works once the patched nvidia driver is bound, so wait for that first (up to 90 s per card).
for d in $(lspci -Dn | awk '$3 ~ /10de:(20c2|2082)/ {print $1}'); do
  p=/sys/bus/pci/devices/$d
  n=0; while [ ! -e $p/driver ] && [ $n -lt 90 ]; do sleep 1; n=$((n+1)); done
  [ -e $p/driver ] || { logger -t sp-cmp-gen2 "$d: no driver bound after 90 s; skipped"; continue; }
  case "$(cat $p/current_link_speed)" in 5.0*) logger -t sp-cmp-gen2 "$d: already Gen2"; continue;; esac
  br=$(basename "$(dirname "$(readlink -f $p)")")
  i=0
  while [ $i -lt 10 ]; do
    i=$((i+1))
    lc2=$(setpci -s $br CAP_EXP+30.w); setpci -s $br CAP_EXP+30.w=$(printf '%04x' $(( (0x$lc2 & ~0xf) | 2 )))
    lc=$(setpci -s $br CAP_EXP+10.w);  setpci -s $br CAP_EXP+10.w=$(printf '%04x' $(( 0x$lc | 0x20 )))
    sleep 1
    case "$(cat $p/current_link_speed)" in 5.0*) break;; esac
  done
  logger -t sp-cmp-gen2 "$d: $(cat $p/current_link_speed) x$(cat $p/current_link_width) after $i attempt(s)"
done
exit 0
EOF
chmod 755 /usr/local/sbin/sp-cmp-gen2.sh.new
cmp -s /usr/local/sbin/sp-cmp-gen2.sh.new /usr/local/sbin/sp-cmp-gen2.sh 2>/dev/null \
  && { rm /usr/local/sbin/sp-cmp-gen2.sh.new; skip "Gen2 retrain helper up to date"; } \
  || { mv /usr/local/sbin/sp-cmp-gen2.sh.new /usr/local/sbin/sp-cmp-gen2.sh; ok "installed /usr/local/sbin/sp-cmp-gen2.sh"; }
UNIT='[Unit]
Description=Retrain CMP 170HX PCIe links at Gen2 (after the patched driver loads)
After=systemd-modules-load.service cmpunlocker.service nvidia-persistenced.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sp-cmp-gen2.sh
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target'
if [ "$(cat /etc/systemd/system/sp-cmp-gen2.service 2>/dev/null)" != "$UNIT" ]; then
  echo "$UNIT" > /etc/systemd/system/sp-cmp-gen2.service; systemctl daemon-reload; ok "installed sp-cmp-gen2.service"
else skip "sp-cmp-gen2.service in place"; fi
systemctl is-enabled --quiet sp-cmp-gen2.service 2>/dev/null && skip "sp-cmp-gen2.service enabled" \
  || { systemctl enable sp-cmp-gen2.service >/dev/null 2>&1 && ok "enabled sp-cmp-gen2.service"; }
# Live retrain: a link retrain under a running CUDA job on that card can hang it, so skip busy CMPs.
for d in $(cmp_bdfs); do
  case "$(cat /sys/bus/pci/devices/$d/current_link_speed)" in 5.0*) continue;; esac
  if nvidia-smi --query-compute-apps=gpu_bus_id --format=csv,noheader 2>/dev/null | grep -qi "${d#0000:}"; then
    warn "$d is at Gen1 but has CUDA processes; not retraining live. Stop them and re-run."
    busy=1
  fi
done
[ -z "${busy:-}" ] && /usr/local/sbin/sp-cmp-gen2.sh
for d in $(cmp_bdfs); do s=$(cat /sys/bus/pci/devices/$d/current_link_speed)
  case "$s" in 5.0*) ok "$d at $s";; *) warn "$d at $s (expected 5.0 GT/s; journalctl -t sp-cmp-gen2)";; esac; done

# --- 8. Persistence mode so the unlocked state and clocks are held between jobs.
say "8. nvidia-persistenced"
id nvidia-persistenced >/dev/null 2>&1 || { useradd --system --no-create-home --home-dir / --shell /usr/sbin/nologin nvidia-persistenced && ok "created nvidia-persistenced user"; }
# Ubuntu's unit runs the daemon with --no-persistence-mode, which leaves persistence off. Override it.
DROP=/etc/systemd/system/nvidia-persistenced.service.d/persistence-on.conf
WANTDROP='[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --persistence-mode --verbose'
if [ "$(cat $DROP 2>/dev/null)" != "$WANTDROP" ]; then
  mkdir -p "$(dirname $DROP)"; echo "$WANTDROP" > $DROP; systemctl daemon-reload
  systemctl restart nvidia-persistenced 2>/dev/null; ok "persistenced override: --persistence-mode"
else skip "persistenced override in place"; fi
systemctl enable nvidia-persistenced >/dev/null 2>&1
systemctl is-active --quiet nvidia-persistenced || systemctl start nvidia-persistenced 2>/dev/null
systemctl is-active --quiet nvidia-persistenced && ok "persistenced running" || warn "persistenced not running: journalctl -u nvidia-persistenced"
off=$(nvidia-smi --query-gpu=index,persistence_mode --format=csv,noheader 2>/dev/null | awk -F', ' '$2!="Enabled"{print $1}' | xargs)
if [ -n "$off" ]; then nvidia-smi -pm 1 >/dev/null 2>&1; ok "persistence mode turned on for GPU(s) $off"
else skip "persistence mode on for all GPUs"; fi

# --- 8a. cmpunlocker's VM-passthrough arming turns CMP persistence off every boot. No VMs here, so disable it.
say "8a. Disable cmpunlocker VM-passthrough arming"
if systemctl is-enabled --quiet cmpunlocker-passthrough.service 2>/dev/null; then
  systemctl disable cmpunlocker-passthrough.service >/dev/null 2>&1 && ok "disabled cmpunlocker-passthrough.service (takes effect next boot)"
else skip "cmpunlocker-passthrough.service not enabled"; fi

# --- 8b. Hold the kernel. The patched nvidia.ko is built for $(uname -r) only and cmpunlocker removed
# DKMS, so an unattended kernel upgrade would boot with no NVIDIA driver at all.
say "8b. Pin kernel, driver and container toolkit"
# ...and the 610 userspace: a point release would no longer match the patched kernel module.
HOLD="linux-generic linux-image-generic linux-headers-generic linux-image-$(uname -r) linux-headers-$(uname -r) linux-modules-$(uname -r)"
HOLD="$HOLD $(dpkg -l | awk '$1=="ii"{print $2}' | grep -E -- "-$DRV_BRANCH(-|:|$)|$DRV_BRANCH\." | cut -d: -f1 || true)"
HOLD="$HOLD $(dpkg -l | awk '$1=="ii"{print $2}' | grep -E '^(libnvidia-container|nvidia-container)' | cut -d: -f1 || true)"
held=$(apt-mark showhold)
todo=$(for p in $HOLD; do dpkg -s $p >/dev/null 2>&1 && ! echo "$held" | grep -qx "$p" && echo $p; done)
if [ -n "$todo" ]; then apt-mark hold $todo >/dev/null && ok "held: $(echo $todo)"; else skip "kernel, driver and toolkit already held"; fi
echo "   To upgrade later: apt-mark unhold, upgrade kernel + nvidia-*-610 together, reboot, re-run cmpunlocker install.sh, then this script."

# --- 9. 170tune: staged only. Qualifying HBM clock/timings is a multi-hour stress run; do it deliberately.
say "9. 170tune (staged, not run)"
[ -d $SRC/170tune/.git ] || git clone -q $TUNE_REPO $SRC/170tune && ok "170tune at $SRC/170tune ($(git -C $SRC/170tune rev-parse --short HEAD))"
grep -qw iomem=relaxed /proc/cmdline || warn "170tune needs iomem=relaxed: reboot once before using it"

say "Health"
for d in $(cmp_bdfs); do
  case "$(cat /sys/bus/pci/devices/$d/current_link_speed)" in
    5.0*) ok "$d Gen2";;
    *) warn "$d fell back to $(cat /sys/bus/pci/devices/$d/current_link_speed). Re-run this script with that card idle (recovery: boot with systemd.mask=sp-cmp-gen2.service)";;
  esac
done
for d in $(nv_bdfs); do
  is_cmp_dev $d && continue
  mb=$(bar1_mb $d)
  [ "$mb" -ge 8192 ] && ok "$d BAR1 ${mb} MiB" || warn "$d BAR1 only ${mb} MiB; re-run from a terminal and accept the driver reload (journalctl -t sp-gpu-rebar)"
done
nvidia-smi --query-gpu=pci.bus_id,memory.total,name --format=csv,noheader,nounits 2>/dev/null \
  | awk -F', ' '$3 ~ /CMP/ && $2 < 39000 {print "   \033[33mWARN: " $1 " shows only " $2 " MiB (unlock lost; re-run with containers stopped)\033[0m"}'

status
cat <<EOF

Done. Re-run any time; finished steps are skipped.  Log: $LOG
EOF
[ -z "$RESTART" ] && [ -z "$(docker ps -q 2>/dev/null)" ] && echo "No containers running. Start them with ~/start-sm12x.sh, ~/start-gemma.sh, ~/start-ocr.sh."
node1_mb=$(awk '/MemTotal/ {print int($4/1024)}' /sys/devices/system/node/node1/meminfo 2>/dev/null)
if [ "${node1_mb:-0}" -gt 0 ]; then
  echo "CMP workloads: pin to CPU socket 1 with --cpuset-cpus 8-15,24-31 --cpuset-mems 1 (node 1 has ${node1_mb} MB RAM)."
else
  echo "CMP workloads: pin to CPU socket 1 with --cpuset-cpus 8-15,24-31 (node 1 has no RAM,"
  echo "so memory will still come from socket 0)."
fi
