# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spartan Edge MLP inference on a Seeed Spartan Edge Accelerator Board (XC7S15). An int8-quantized MLP (128→16→4) classifies 4 button-press gestures (USER1/USER2 × long-press/double-click) from 2 user buttons, displaying results on 2 SK6805 RGB LEDs + 2 regular LEDs.

## One-line Commands

```bash
# Train + export weights & test vectors (requires numpy)
python3 train/train_and_export.py
# Produces: rtl/mem/*.mem, rtl/mem/params.vh, sim/vectors/test_vectors.txt

# RTL simulation (requires iverilog)
cd sim && ln -sf ../rtl/mem mem
iverilog -g2012 -I ../rtl -o tb_mlp.vvp tb_mlp.v ../rtl/mlp_inference.v
vvp tb_mlp.vvp     # Expected: PASS bit-true match

# Vivado synthesis + implementation + bitstream
cd vivado && vivado -mode batch -source build.tcl
# Produces: vivado/build/spartan_edge_mlp.bit
```

## Architecture — Data Flow

```
BTN0/BTN1 (GPIO, active-low, pulled up)
  → ~btn (invert in top.v)
  → debounce.v (50 Hz tick synchronizer, N=16 stable samples)
  → button_capture.v (64-frame window triggered on edge, each frame = {BTN0,BTN1})
  → 128-bit vector
  → mlp_inference.v (serial MAC state machine, see below)
  → class_id [1:0]
  → top.v maps class to {RGB1, RGB2} colors + led_status
  → ws2812_driver.v (2-LED daisy-chained SK6805, GRB bit order, ~800 kHz)
```

Clock: 100 MHz on-board oscillator (H4) → clk_div.v generates 50 Hz tick (used only for debounce/capture, not inference). Inference runs at effective 50 MHz (internal CE divide-by-2).

## MLP Inference Engine (mlp_inference.v)

The core module. Key design decisions:

- **Serial MAC**: One 8×8 signed multiply → 32-bit accumulate shared across all dot products. FC1 takes 128×16=2048 CE-cycles; FC2 takes 16×4=64 CE-cycles. Total ~2200 CE-cycles ≈ 44 µs physical time.
- **Clock Enable (CE)**: Spartan-7 -1 cannot close timing at 100 MHz (critical path ~12.2 ns). Internal toggle flip-flop (`ce <= ~ce`) divides the effective rate to 50 MHz (20 ns period). State machine advances only on `ce=1`. Multi-cycle path constraints in `constraints.xdc` inform STA to check 2-cycle setup.
- **Start latching**: `vec_valid` is a single-cycle pulse. `start_req` SR latch inside mlp_inference stretches it until the next CE cycle.
- **Power-on blink**: `top.v` lights both regular LEDs for ~0.67s at boot so the user sees the FPGA is configured before any button press.
- **State machine**: `S_IDLE → S_FC1 → S_REQ → S_FC2 → S_BIAS2 → S_ARGM → S_DONE`. Weights stored in BRAM (`$readmemh` at init — baked into bitstream, immutable at runtime).
- **Int8 quantization** (see `train_and_export.py` `infer_hw()` for the exact bit-true reference):
  - Input: binary 0/1 → int8 {0, 127} (x_q = x_bit × 127)
  - Weights: symmetric int8 per-tensor (scale = max(|W|)/127)
  - Bias: int32 (accumulator scale), pre-scaled to match weight×input product
  - ReLU + requant: `clip((max(0, acc) × REQ_MUL) >> REQ_SHIFT, 0, 127)`
  - FC2 output: argmax over raw int32 logits (no final requant needed)
- **Bit-true validation**: The Python `infer_hw()` function in `train_and_export.py` is the reference. The RTL testbench (`tb_mlp.v`) compares against it using `test_vectors.txt`. Every change to quantization logic must be verified bit-true.

## Weight Generation Pipeline

1. `train_and_export.py` synthesizes 8000 training samples (4 classes × 2000, with 1% bit-flip noise)
2. Trains a 2-layer MLP (128→16→4) with hand-written SGD in numpy (no framework deps)
3. Quantizes to int8 using symmetric per-tensor quantization
4. Computes `REQ_MUL`/`REQ_SHIFT` as fixed-point approx of `SX × s1 / s_h` with 15-bit shift
5. Exports: `w1.mem`, `w2.mem`, `b1.mem`, `b2.mem` (hex, row-major), `params.vh` (Verilog defines), `test_vectors.txt` (50 samples for RTL verification)

## Pinout

| Signal | Pin | Notes |
|---|---|---|
| sysclk | H4 | 100 MHz oscillator |
| btn0 (USER1) | C3 | Active low, internal pullup, inverted in top.v |
| btn1 (USER2) | M4 | Active low, internal pullup, inverted in top.v |
| ws2812_din | N11 | Daisy-chained to 2 SK6805 RGB LEDs |
| led_status[0] | J1 | FPGA_LED1 (green) |
| led_status[1] | A13 | FPGA_LED2 (red) |
| FPGA_RST | D14 | Not connected in top-level (POR counter used instead) |

## Important Conventions

- **Button polarity**: Physical buttons are active-low. `top.v` inverts them (`~btn`) so all downstream RTL sees active-high.
- **Debounce timing**: Default `N=2` in `debounce.v` → 2 × 20ms = 40ms at 50Hz tick. This filters mechanical bounce (~5-10ms) reliably. Long-press (25+ frames) and double-click patterns have enough margin for this delay.
- **Vector bit order**: MSB = frame 0 BTN0, matching Python's `bits = (bits << 1) | int(x[k])` loop.
- **GRB color order**: WS2812/SK6805 protocol sends G[7:0] first, then R, then B. The `led1_color`/`led2_color` functions follow `{G, R, B}`.
- **Generated files**: `rtl/mem/*.mem` and `rtl/mem/params.vh` and `sim/vectors/test_vectors.txt` are auto-generated. Edit `train_and_export.py` and re-run to change them — never hand-edit.
- **Vivado non-project mode**: `build.tcl` uses in-memory project (no `.xpr` file). The script uses `[info script]` for script-relative absolute paths — works regardless of CWD.

## Board Reference

`Board/Spartan Edge Accelerator Board v1.0.pdf` — manufacturer schematic. All pins cross-checked against this PDF (page 1 FPGA pinout + page 3 LED module).

## Timing & Constraints

- **Spartan-7 -1 speed grade**: The 32-bit accumulator path in mlp_inference fails 100 MHz setup timing (~12.2 ns vs 10 ns). This is solved by the internal CE divide-by-2 (effective 50 MHz for the inference engine).
- **Multi-cycle constraints** in `constraints.xdc`: u_mlp internal reg→reg paths get `set_multicycle_path -setup 2` (20 ns budget) and `-hold 1`. This MUST stay in sync with the CE scheme — if you remove the CE, remove these constraints.
- **Clock constraint**: `create_clock -period 10.000` matches the 100 MHz oscillator. Do NOT change this period to work around timing — use the CE + multi-cycle approach instead.
- **WS2812 timing**: Parameters are computed as `(CLK_HZ/100000) * dur_ns / 10000` to avoid 32-bit integer overflow. At 100 MHz this yields T0H=40, T0L=85, T1H=80, T1L=45, TRS=6000 cycles.

---

## Behavioral Guidelines

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
