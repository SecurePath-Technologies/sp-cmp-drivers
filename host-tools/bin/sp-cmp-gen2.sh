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
