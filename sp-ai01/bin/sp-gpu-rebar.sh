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
