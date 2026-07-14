# GPU FLIP/PIC 二维单相流仿真小玩具 (Godot 4.6)

基于 `RenderingDevice` Compute Shader 的 FLIP/PIC 混合流体求解器技术沙盒。MAC 交错网格、
Jacobi 压力投影、Ghost-Fluid 自由液面，100 万粒子全程驻留 GPU。

## 运行

用 Godot 4.6 打开本项目直接运行（主场景 `scenes/main.tscn`）。窗口 1600×1200。

## 操作

| 操作 | 行为 |
|---|---|
| 按住左键拖动 | 用当前画笔预览绘制（不写仿真） |
| 松开左键 | 提交本次绘制到仿真场 |
| `空格` | 暂停/恢复物理步进（画笔仍可用） |
| `1` `2` `3` `4` | 画笔切换 真空 / 固体 / 水 / 气 |
| `5` `6` | 画笔切换 柠檬汁 / 蜂蜜（密度依次高于水，会自动分层） |
| `0` | 压力扰动画笔（对绘制区施加径向速度冲量） |
| 滚轮 | 增减画笔半径（网格单位，圆环指示） |
| `P` | 清空速度场（水立即停滞） |
| `V` | 清空压力场 |

**多相液体**：水/柠檬汁/蜂蜜三种液体密度不同（1.0 / 1.4 / 2.0），靠变密度压力投影自动分层
（重者下沉），每格按主相着色 蓝/绿/黄。实现细节见 `docs/DESIGN.md` §6.5。

启动时预置一个容器 + 水/柠檬汁/蜂蜜三层分层演示（`main.gd` 里 `TEST_MULTIPHASE`，
设为 `false` 则回到单块水溃坝）；可自行绘制固体容器、用 `3/5/6` 画不同液体观察分层。

## 文档

- `docs/DESIGN.md` — 数据布局、P2G/G2P、Jacobi 压力求解等实现细节。
- `docs/SELFTEST.md` — 对照验收标准 F1–F10 的自测报告（含 F9 稳定性、F10 性能实测与偏差说明）。
- `docs/images/` — 自测截图。

## 结构

```
scenes/main.tscn         主场景
scripts/main.gd          输入 / 子步循环 / 显示回读 / HUD / 画笔预览提交
scripts/flip_fluid_gpu.gd  FlipFluidGPU：RenderingDevice、缓冲、管线、dispatch
shaders/*.glsl           15 个计算着色器
```

参数集中在 `FlipFluidGPU` 顶部（capacity / phys_dt / gravity / flip_ratio / p_atm /
jacobi_iters / emit_ppc）与 `main.gd` 的 `SUBSTEPS`，运行时 HUD 全量显示。

## 实测（RTX 4060 / D3D12）

单帧仿真 ≈ 2.2–2.6 ms（4 子步 × 60 Jacobi + 100 万粒子池），关 vsync 整帧 ≈ 220–250 fps，
远超实时。详见 `docs/SELFTEST.md`。
