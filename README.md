# GPU FLIP/PIC 2D Multi-Phase Fluid Simulation Sandbox (Godot 4.6)

English | [中文](README-zh.md)

A technical sandbox for a hybrid FLIP/PIC fluid solver built on `RenderingDevice` compute shaders.
Features a MAC staggered grid, Jacobi pressure projection, and a Ghost-Fluid free surface, with
up to 1 million particles resident on the GPU throughout the simulation.

![demo](docs/images/demo.gif)

## Running

Open this project with Godot 4.6 and run it directly (main scene `scenes/main.tscn`).
Window size: 1600×1200.

## Controls

| Input | Action |
|---|---|
| Hold left click + drag | Preview paint with the current brush (does not write to the simulation) |
| Release left click | Commit the current paint stroke to the simulation |
| `Space` | Pause/resume physics stepping (brush still works) |
| `1` `2` `3` `4` | Switch brush to Vacuum / Solid / Water / Air |
| `5` `6` | Switch brush to Lemon Juice / Honey (denser than water, layers automatically) |
| `0` | Pressure impulse brush (applies a radial velocity impulse to the painted area) |
| Mouse wheel | Increase/decrease brush radius (in grid units, shown as a ring) |
| `P` | Clear the velocity field (water stops instantly) |
| `V` | Clear the pressure field |

**Multi-phase liquids**: Water, lemon juice, and honey have different densities (1.0 / 1.4 / 2.0)
and automatically stratify (denser fluids sink) via variable-density pressure projection. Each
cell is colored by its dominant phase (blue/green/yellow). See `docs/DESIGN.md` §6.5 for
implementation details.

On startup, a container plus a water/lemon-juice/honey stratification demo is preloaded
(`TEST_MULTIPHASE` in `main.gd`; set it to `false` to revert to a single dam-break block).
You can also paint your own solid container and use `3/5/6` to draw different liquids and
observe stratification.

## Documentation

- `docs/DESIGN.md` — Implementation details: data layout, P2G/G2P, Jacobi pressure solve, etc.
- `docs/SELFTEST.md` — Self-test report against acceptance criteria F1–F10 (including F9 stability
  and F10 performance measurements with deviation notes).
- `docs/images/` — Self-test screenshots.

## Structure

```
scenes/main.tscn           Main scene
scripts/main.gd             Input / substep loop / readback display / HUD / brush preview & commit
scripts/flip_fluid_gpu.gd   FlipFluidGPU: RenderingDevice, buffers, pipelines, dispatch
shaders/*.glsl              15 compute shaders
```

Parameters are centralized at the top of `FlipFluidGPU` (capacity / phys_dt / gravity /
flip_ratio / p_atm / jacobi_iters / emit_ppc) and `SUBSTEPS` in `main.gd`; all are shown live
in the runtime HUD.

## Benchmarks (RTX 4060 / D3D12)

Simulation time per frame ≈ 2.2–2.6 ms (4 substeps × 60 Jacobi iterations + 1M particle pool),
≈ 220–250 fps with vsync off — well above real-time. See `docs/SELFTEST.md` for details.

## License

Copyright (C) 2026 nobodyscool

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE) for the full text.
