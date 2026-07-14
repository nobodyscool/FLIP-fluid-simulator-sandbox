# 设计说明 — GPU FLIP/PIC 单相流仿真

Godot 4.6 / RenderingDevice Compute。核心求解全部在 GPU 上完成；CPU 每帧只回读
160×120 的显示缓冲和 1 个探针 cell（用于 HUD），100 万粒子始终不离开 GPU。

## 1. 运行方式与文件结构

- 主场景 `scenes/main.tscn`（`scripts/main.gd`）：输入、子步循环、显示回读、HUD、画笔预览/提交。
- 求解器 `scripts/flip_fluid_gpu.gd`（`class_name FlipFluidGPU`）：RenderingDevice、缓冲、管线、dispatch。
- 计算着色器 `shaders/*.glsl`（15 个），均以 `#[compute]` 声明，Godot 导入为 `RDShaderFile`。

窗口 1600×1200，网格 160×120，每 cell = 10×10 像素。

## 2. GPU 数据布局

采用 **SSBO（storage buffer）** 而非纹理：网格只有 19 200 cell，SSBO 便于整型原子操作
（P2G 累加）与 std430 索引。所有着色器共用一套**全局 binding 编号**，每个着色器只声明自己
用到的 binding，GDScript 侧按同样编号构造对应的 uniform set。

| binding | 缓冲 | 类型/大小 | 说明 |
|---|---|---|---|
| 0 | particles | `vec4[capacity]` | `xy=`位置(网格坐标) `zw=`速度；`x<0` 表示空槽 |
| 1 | free_list | `int[capacity]` | 空闲槽索引栈 |
| 2 | counters | `int[4]` | `[0]=free_count` |
| 3 / 5 | grid_u / grid_u_old | `float[(nx+1)*ny]` | X 速度，竖直面上 |
| 4 / 6 | grid_v / grid_v_old | `float[nx*(ny+1)]` | Y 速度，水平面上 |
| 7 / 9 | mom_u / wt_u | `int[(nx+1)*ny]` | P2G 定点累加（动量/权重） |
| 8 / 10 | mom_v / wt_v | `int[nx*(ny+1)]` | 同上（V 面） |
| 11 | mass | `int[nx*ny]` | 定点累加的 cell 粒子质量 |
| 12 | cell_type | `int[nx*ny]` | 0 真空 / 1 固体 / 2 水 / 3 气 |
| 13 | fluid_mask | `int[nx*ny]` | 本步是否为流体 cell（有粒子且非固体） |
| 14 / 15 | pressure_a / pressure_b | `float[nx*ny]` | Jacobi ping-pong |
| 16 | divergence | `float[nx*ny]` | 压力方程 RHS |
| 17 | display | `uint[nx*ny]` | 打包 RGBA8，回读上屏 |
| 18 | probe | `float[8]` | 鼠标 cell 的 [type,u,v,p,density,fluid] |
| 19 | brush_mask | `int[nx*ny]` | 提交时标记被绘制的 cell |

**MAC 交错网格（Harlow–Welch）**：cell `(i,j)` 中心在 `(i+0.5, j+0.5)`；U 面（速度 X）位于
`(i, j+0.5)`，索引 `i + j*(nx+1)`；V 面（速度 Y）位于 `(i+0.5, j)`，索引 `i + j*nx`。
压力/密度/类型存 cell 中心。域边界外一圈视为固体墙（在着色器内判断），粒子位置钳制在
`[0.5, nx-0.5]×[0.5, ny-0.5]`，双重保证不漏出。

**推送常量**：所有着色器共用同一个 96 字节 `Params` 结构（nx/ny/各计数、phys_dt、gravity、
flip_ratio、p_atm、fixed_scale、jacobi_parity、画笔参数、鼠标 cell 等），GDScript 用一个
`_pack_params()` 统一打包，消除 binding/布局不匹配的风险。

## 3. 粒子池与 free-list（“粒子总数”的实现）

`capacity`（默认 1 048 576）是**池容量上限**，不是固定活跃数。空闲槽用一个 GPU 栈管理：

- 初始化 `init_pool.glsl`：所有槽标记为死（`pos.x=-1`），`free_list[i]=i`，`free_count=capacity`。
- 发射（画水）：`emit.glsl` 对每个被绘制的非固体 cell 弹出 `ppc`(默认16) 个槽
  （`atomicAdd(free_count,-1)` 取栈顶索引），在 cell 内抖动放置粒子。
- 回收（画真空/气/固体覆盖水，或后续可扩展的出界）：`free_particles.glsl` 把落在
  `brush_mask` 内的粒子置死并 `atomicAdd(free_count,+1)` 压回栈。

好处：**有界、无碎片、无需前缀和排序**。HUD 显示 `active = capacity - free_count`。

## 4. 每个物理子步的管线（默认 4 子步/帧，phys_dt=1/240 s）

一帧内把所有 dispatch 录进**一个** compute list，dispatch 间插入 `compute_list_add_barrier`，
最后 `submit()+sync()` 一次。顺序：

1. `clear_grid` — 清零 mom/wt/mass/fluid_mask。
2. `p2g` — 粒子→网格散射（见 §5）。
3. `normalize` — `vel = 动量/权重`；先存 `*_old`（FLIP 用），再对 V 面加重力 `+g·dt`。
4. `enforce_solids` — 固体/边界面速度归零（无穿透）。
5. `cell_setup` — 标记 fluid_mask，并对流体 cell 计算散度。
6. `jacobi` ×60 — 压力泊松（见 §6），ping-pong，末次结果落在 `pressure_a`。
7. `project` — 减去压力梯度，使流体无散度；空 cell 用 `p_atm` ghost。
8. `enforce_solids` — 投影后再次封闭固体面。
9. `g2p_advect` — 网格→粒子 + 平流（见 §5）。

之后（每帧一次）`render` 生成显示颜色并写探针。

## 5. P2G / G2P 实现

**P2G（`p2g.glsl`，每粒子一线程，散射）**：对每个粒子，按 MAC 面位置求双线性权重，
分别向周围 4 个 U 面、4 个 V 面累加 `w·vel` 与 `w`。浮点原子加在各平台不通用，改用
**定点整数原子**：`atomicAdd(int, round(value*fixed_scale))`，`fixed_scale=4096`。
归一化时 `vel = (Σw·v)/(Σw)`，比值与 scale 无关，仅影响溢出裕度（本规模远未溢出）。
另外向粒子所在 cell 的 `mass` 累加 1。

**G2P + 平流（`g2p_advect.glsl`，每粒子一线程）**：在粒子位置双线性采样新网格速度
`v_pic` 和 `*_old`；`v_flip = v_particle + (v_pic - v_old)`；
`v_new = mix(v_pic, v_flip, flip_ratio)`（flip_ratio=0.90，FLIP 主导 + 少量 PIC 阻尼）。
平流用 **RK2**（中点采样投影后的速度场），位置钳制回域内；固体碰撞用**分轴**处理
（分别检测 x、y 方向进入固体则取消该分量），避免穿模。

重力只加在 V 面，且在保存 `*_old` **之后**加，从而 FLIP 增量 `v_pic - v_old` 天然包含重力。

## 6. Jacobi 压力求解与 Ghost-Fluid

对每个流体 cell 解 `∇²p = (ρ/dt)·div`（取 ρ=1）。单次 Jacobi：

```
p_new = ( Σ p_neighbour  −  divergence / phys_dt ) / count
```

邻居分三类（`jacobi.glsl`）：
- **流体邻居**：用其当前压力，计入 `count`。
- **空邻居（气/真空）→ 自由液面**：**Ghost-Fluid**，`p = p_atm`（Dirichlet），计入 `count`。
  这样液面边界压力被钳在大气压参考值，不因数值扩散而模糊。
- **固体邻居 / 域外**：Neumann，直接从模板中丢弃（不计入 `count`）。

`count==0`（被固体包围）时取 `p_atm`。非流体 cell 每次迭代写入 `p_atm`（空）或 `0`（固体），
保持 ghost 一致，供投影读取。60 次迭代（偶数）后结果稳定落在 `pressure_a`。

**投影（`project.glsl`）**：对每个内部面 `u -= dt·(p_R − p_L)`，其中固体侧面速度直接置 0，
空 cell 侧用 `p_atm`。之后再跑一次 `enforce_solids`。

## 7. 渲染：数据纹理 + 着色器合成、回读与 HUD

`render.glsl` 每 cell 输出的**不是最终颜色而是数据**（打包 RGBA8）：
`R=`含水覆盖(fluid_mask→0/255)、`G/B=`编码的 cell 中心速度（供折射方向）、
`A=`底材类型码（气 0 / 固体 85 / 真空 170）。CPU 回读该 19 200-uint 缓冲上传到 `_fluid_tex`。

显示由 **`shaders/water_display.gdshader`**（canvas_item）合成，挂在一个带 `ShaderMaterial` 的
**Sprite2D**（`scale=10`）上：
- 底：气 cell 显示**背景**（`background` 图片，未设则 `background_color` 灰）；固体→深灰、真空→黑（NEAREST 采样，清晰方块）。
- 水：`R` 覆盖用 LINEAR 采样得平滑边缘；**半透明**地叠在底之上（`water_opacity`），并按 cell 速度对
  背景做 **UV 偏移的伪折射**（`refraction`）。同一纹理绑两次（`filter_nearest`/`filter_linear`）以兼顾
  清晰方块与平滑水面。

同一 render pass 把鼠标 cell 的物理量写入 `probe` 供 HUD。

> **重要（呈现坑）**：显示 Sprite2D 与 HUD 都挂在 **CanvasLayer** 下。实测本机 D3D12 上，每帧对
> local RenderingDevice 做 `submit()/sync()` 时，主视口的**默认世界 2D 画布不呈现到窗口**（表现为
> “只有 HUD 文本、没有流体画面”；CanvasLayer 则正常呈现）。因此所有可见内容都放进 CanvasLayer。
> 窗口用 `stretch/mode=canvas_items` + `aspect=keep`，逻辑分辨率固定 1600×1200，初始物理窗口
> 1280×960 以适配 1080p 屏幕（可自由缩放/最大化，等比缩放保持清晰）。

**材质语义补充**：
- **默认背景 = 气**（`cell_type` 初始全填 `AIR`），液面自由边界仍用 `p_atm` ghost。
- **真空 = 排水口**：`drain.glsl` 每子步把落在 VACUUM cell 的水粒子回收（active 数下降），实现“液体
  接触真空即消失”。

## 8. 画笔预览与提交（两阶段交互）

- 拖拽中：`main.gd` 用 CPU 把画笔圆覆盖的 cell 累积进集合（`_painted`），每帧画进一张**独立的透明
  overlay 纹理**（半透明色块预览 + 跟随鼠标的半径光标，cell 分辨率），叠在流体 Sprite2D 之上。此阶段
  **完全不碰仿真缓冲**。
- 松开：把 `_painted` 打包成 `brush_mask` 上传 GPU，按材质分派：水→`emit`；真空/气/固体→
  `free_particles`+`brush_apply`；压力笔→`pressure_impulse`。之后才参与物理演算。

## 9. 可调参数

**`main.gd` 检视器 `@export`（默认值与代码一致，运行时可改）**：
- Simulation：`particle_capacity`(1 048 576，仅启动时生效)、`flip_ratio`(0.90)、`jacobi_iters`(60)、
  `gravity`(40)。后三者每帧同步到求解器，可运行时实时调。
- Rendering：`background`(Texture2D，空则用灰)、`background_color`(0.5 灰=气)、`water_color`、
  `water_opacity`(0.55)、`refraction`(0.03)。

**其余在 `FlipFluidGPU` 顶部 / `main.gd` 常量**：`phys_dt`(1/240)、`p_atm`(3.0)、`fixed_scale`(4096)、
`emit_ppc`(16)、`SUBSTEPS`(4)。运行时 HUD 全量显示。
