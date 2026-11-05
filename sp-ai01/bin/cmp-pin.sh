#!/bin/sh
# Socket/NUMA pinning for sp-ai01 GPU workloads. Source it, then add the flags to `docker run`:
#   . ~/gpu-setup/cmp-pin.sh
#   docker run $CMP_PIN --gpus '"device=2"' ...      # CMP 170HX 86:00.0 / af:00.0 (device=2,3) -> socket 1
#   docker run $RTX_PIN --gpus '"device=0"' ...      # RTX PRO 3b:00.0 / 5f:00.0 (device=0,1)   -> socket 0
# Both CMPs hang off CPU 1 (NUMA node 1); keeping their host threads and pinned buffers on node 1
# avoids every H2D/D2H copy crossing UPI. Bare-metal: numactl --cpunodebind=1 --membind=1 <cmd>.
CMP_PIN="--cpuset-cpus 8-15,24-31 --cpuset-mems 1"
RTX_PIN="--cpuset-cpus 0-7,16-23 --cpuset-mems 0"
