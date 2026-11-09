#!/bin/sh
# Socket/NUMA pinning flags for GPU containers. Source it, then add the flags to `docker run`:
#   . ./cmp-pin.sh
#   docker run $CMP_PIN --gpus '"device=<cmp index>"' ...
#   docker run $RTX_PIN --gpus '"device=<other index>"' ...
# Keep each GPU's host threads and pinned buffers on the CPU socket its PCIe root port hangs off, so H2D/D2H copies
# don't cross the socket interconnect. Find the node with: cat /sys/bus/pci/devices/<BDF>/numa_node
# and its CPUs with: lscpu -e=CPU,NODE. Bare metal: numactl --cpunodebind=<node> --membind=<node> <cmd>.
# Defaults below are an example for a 2-socket, 16-core-per-socket box with SMT; override to match your topology.
CMP_PIN="--cpuset-cpus ${CMP_CPUS:-8-15,24-31} --cpuset-mems ${CMP_MEMS:-1}"
RTX_PIN="--cpuset-cpus ${RTX_CPUS:-0-7,16-23} --cpuset-mems ${RTX_MEMS:-0}"
