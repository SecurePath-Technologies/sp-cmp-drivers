# CMP 170HX HBM overclocking: research notes

Status: experimental. The method works on our test card. The numbers below are from one card and are not a
qualification for yours.

## What the driver change does
170tune's live tools write the HBM memory PLL (`hbm_mclk`) and the DRAM timing registers (`fbpa_regs`) through
BAR0. Firmware normally blocks those writes with priv-level masks (PLMs). `sec2-postbl-plm-ss-cfg.patch` opens
them in the post-BooterLoad window:
- **FBPA_PLL0/1/2** (`0x9a3c7c` / `0x9a3c80` / `0x9a3c84`): the HBM clock (NDIV; 1 step = 27 MHz). The map comes
  from [asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock).
  Its build-time NDIV bake (`--mclk-ndiv`) is not used; we only tune live.
- **FBPA_MEM** (`0x9a0168`): the DRAM CONFIG timing registers, so timings can be loosened along with the clock.
- The PLM loop used to be hardcoded to 12 entries, which skipped any entry added after that. It now loops over
  `NV_ARRAY_ELEMENTS(plmTable)`.

Check after loading the module: `dmesg` shows `SEC2_DEBUG: PLM[..] FBPA_PLL0..2 ... reg=0xffffffff` and no
`FAILED to open`, and `hbm_mclk get` no longer says `host-write BLOCKED`.

## Method
1. Snapshot the card's real stock timings first (`170tune snapshot-stock`). 10GB (2082) and 8GB (20c2) cards differ,
   and reverting to the wrong card's stock values is a bug.
2. Raise NDIV one step at a time. Scale the row/command timings to hold the stock **nanoseconds**:
   `cycles = ceil(stock_cycles * N / stock_N)`, with the bus turnarounds (W2R_BUS/R2W_BUS) at 12.
3. Gate each step hot: `170tune -i <idx> hbm-gate --ndiv N --timings "FIELD cycles ..." --sweeps 12`. The gate
   soaks the card to temperature, runs full-VRAM bit-exact pattern sweeps, then a compute check. Add
   `--workload "<your real serving command>"` as the final rung. A synthetic pass is necessary but not enough.
4. Run one step **below** the highest pass, and only promote a step after a long gate plus a real-workload run.
5. Persist per card serial (sp-power `CMP_HBM_*`, applied in the guarded perf stage). The VBIOS stock clock comes back
   on every boot, so a tripped boot guard leaves the card at stock.

## Findings (one 10GB 2082 card, VBIOS 92.00.66, stock NDIV 45 = 1215 MHz)
| NDIV | MHz | Result (4 hot sweeps + compute, timings scaled) |
|---|---|---|
| 48 | 1296 | pass; read bandwidth +8.3% for +0.6 W |
| 51 / 54 / 57 / 60 | 1377 / 1458 / 1539 / 1620 | pass, peak HBM about 61 C |
| 63 | 1701 | **wedged the card**: GSP RPC timeout, then every GSP boot failed until a reboot |

- Bandwidth scales with the clock. LLM token generation is memory-bound, so the HBM clock is the main lever on these
  cards. The SM clock matters much less.
- Community data suggests NDIV 60 works on many but not all 10GB cards. Headroom varies per card.
- The 10GB card's SM clock is capped at 1410 MHz by its VBIOS (VF offset range locked to 0), and these patches don't
  change that. The 8GB 20c2 cards on the 300 W 92.00.6D VBIOS have a higher clock range.
- Open: NDIV 61/62 on this card, and tightening timings at a fixed clock (refresh interval, row timings).

## Risks
- A bad PLL or timing step can hang the memory controller. The GPU is then lost until a reboot or cold power cycle.
  On a shared driver, reloading to recover takes every GPU down.
- On CMPs, `nvidia-smi` ECC status/counters are synthesized by `ecc-reporting.patch` (always 0). Only a bit-exact
  readback (170tune's gate) can qualify a step. Unqualified overclocks can corrupt model output silently.
- Keep HBM below about 75 C under load. Margins shrink as it heats, so a gate run cold proves nothing.
- A boot-loop guard only catches a host that dies. A wedged card on a host that stays up won't trip it.
