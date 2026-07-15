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
| 18 | probe | `float[8]` | 鼠标 cell 的 [type,u,v,p,density,fluid,rho] |
| 19 | brush_mask | `int[nx*ny]` | 提交时标记被绘制的 cell |
| 20 | phase | `int[capacity]` | 每粒子相 id：0 水 / 1 柠檬汁 / 2 蜂蜜 |
| 21 | phase_count | `int[nx*ny*3]` | 每 cell 各相粒子数（定色 + 算密度） |
| 22 | rho_cell | `float[nx*ny]` | 每 cell 平均密度（变密度压力解用） |
| 23 | solid_mask | `int[nx*ny]` | 本帧可移动固体占据的 cell（CPU 栅格化上传） |
| 24 | solid_vel | `float[nx*ny*2]` | 可移动固体在该 cell 的速度（运动边界用） |

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

**投影（`project.glsl`）**：对每个内部面 `u -= dt·(p_R − p_L)/ρ_face`，其中固体侧面速度直接置 0，
空 cell 侧用 `p_atm`。之后再跑一次 `enforce_solids`。

## 6.5 多相液体：变密度投影（水 / 柠檬汁 / 蜂蜜）

三种液体只在**密度**上不同（`RHO = {水 1.0, 柠檬汁 1.4, 蜂蜜 2.0}`，见 `cell_setup.glsl`/`render.glsl`
顶部常量）。密度只进入**压力投影**，浮力/分层由此自然涌现——重力对所有面均匀加速度（`v += g·dt`，
与质量无关，物理正确），压力解在密度不均处产生修正速度场，使重的下沉、轻的上浮。

- **粒子相标签**：每粒子一个 `phase`（binding 20），发射时由画笔材质写入（`emit.glsl`：水 2→0、
  柠檬 4→1、蜂蜜 5→2）。相随粒子平流，不参与速度插值，故 G2P/平流无需改动。
- **每 cell 密度**：P2G 顺带按相累加计数 `phase_count[3·cell+phase]`（binding 21）；`cell_setup`
  取计数加权平均得 `rho_cell = Σ(n_p·ρ_p)/Σn_p`（binding 22）。
- **变密度泊松（`jacobi.glsl`）**：解 `div((1/ρ)∇p) = div(u*)/dt`。每个邻居权重从常密度的 `1`
  改为 `1/ρ_face`（`ρ_face = 相邻两 fluid cell 密度均值；液/空面用液体自身密度`）：
  `p_c = (Σ w_n·p_n − div_c/dt) / Σ w_n`，`w_n = 1/ρ_face`。所有密度相等时退化为原常密度模板。
- **变密度投影（`project.glsl`）**：面梯度除以 `ρ_face`，即 `u -= dt·Δp/ρ_face`。
- **上色（一格一色）**：`render.glsl` 取该 cell 的**主相**（三计数 argmax）编码进 A 通道
  （190/210/230 = 水/柠檬/蜂蜜），显示着色器直接取对应 tint。用主相而非平均密度，混合区读作
  离散的两色而非“浑浊的中间色”，settle 后即是干净的分层色带。

> 局限（第一版）：无表面张力、无粘性、P2G 未按质量加权，故低粘的界面会有数值扩散/搅混
> （能量大时更明显）。稳定分层能长期保持，主相上色让分层清晰可读。若要更锐利界面可后续加
> 质量加权 P2G 或表面张力。多相扩展到 N 种只需扩 `RHO`/相计数维度，求解器不变。

## 6.6 可移动固体：运动边界 + 浮沉（酒瓶 / 柠檬块 / 冰块）

固体分两种：**静态**（画笔 2 画的墙，`cell_type==SOLID`，速度恒 0）与**可移动**
（`MovableSolid` 对象，见 `scripts/movable_solid.gd`）。可移动固体每帧在 CPU 上栅格化成
`solid_mask`（占据的 cell）+ `solid_vel`（该 cell 的刚体速度 `v+ω×r`），上传 GPU。

**流体侧（共用，见相关着色器改动）**：任何 cell 只要 `cell_type==SOLID` 或 `solid_mask==1`
都当墙。`enforce_solids` 把贴墙的面速度设为**墙速**（静态=0，可移动=`solid_vel`）而非一律 0；
`cell_setup` 把可移动固体 cell 排除出流体；`jacobi`/`project` 把它当 Neumann 墙丢弃；
`g2p_advect` 让撞墙的粒子取墙速（墙"带着"液体走）。散度在 `cell_setup` 里自动含入运动墙速，
故投影得到的是相对运动边界无散度的场——**液体被推动/晃荡/倾倒**由此而来。

**固体侧（两种"驱动"，见 `main.gd`）**：
- **运动学**（酒瓶，或任何被 `C` 抓住拖拽的物体）：位姿由用户输入直接给，速度 = 位姿差/dt。
  单向——流体不反推它。
- **动力学**（柠檬块 / 冰块）：CPU 上一个小刚体，受力 = 重力 + **浮力** + 流体阻力/力矩，
  半隐式积分。浮力**复用回读的 display**：没入判定用**固体两侧自由列**量到的**环境液面** `L`
  （`_ambient_level`，而非穿过固体那列的液面——否则平顶上的一层积水会把整块判成没入而"浮空"），
  `y≥L` 的 cell 贡献 `ρ_fluid·g`（向上），`ρ_fluid` 取该 cell 同深度邻格的相码密度（水1.0/柠檬1.4/蜂蜜2.0）。
  净力 `F_y = g·(ρ_body·N − Σρ_fluid)`：`ρ_body<ρ_fluid` 则浮（冰 0.85），`>` 则沉（柠檬块 1.15）。
  与静态墙/边界的碰撞用分轴回退（用 display 里 A==85 判静态固体）。
- **固体互撞**：所有刚体每帧积分后跑一个**分离 pass**（`_separate_bodies`）——检测占据格重叠，沿质心
  连线把**动力学体**推开（运动学/被抓住的体不动，于是移动的酒瓶能把漂浮块挤开），并消去指向对方的
  速度分量；迭代 2 次。

> **性能（随固体数）**：固体物理全在 CPU/GDScript，与 GPU 流体步串行。为随数量放缓：①每帧每体的
> 占据格 `_cells` **按位姿缓存**，各 pass（浮力/分离/栅格化/绘制）共享，避免重复 AABB 扫描；②分离先用
> **包围圆 broad-phase** 剔除远离的对，近对再用 `_overlap_direct`（拿 a 的格逐个测 b 的形状，不建字典）；
> ③浮力的密度/速度**每体只采样一次**（非逐格）；④`_body_blocked` 用**缓存格平移**代替重扫；⑤液面扫描
> 逐列 top-down **命中即断**。实测把每帧固体开销约减半。真正挤成一堆时分离仍有不可免的开销。

**渲染**：可移动固体不进 `render.glsl`（其 cell 被排除出流体，显示为背景），而是每帧按当前位姿
在 **overlay** 上画不透明色块（棕=酒瓶 / 黄绿=柠檬块 / 淡青=冰块），盖在液面之上。

> 局限：CPU 栅格化 → 旋转有锯齿、薄壁 <1 cell 会漏液、快速薄壁可能被粒子穿透；双向浮力靠阻尼收敛，
> 未做冲量级加固；分离 pass 只推动力学体、运动学体挤压时可能把动力学体压进墙缝。这些刻意留到后续。

## 7. 渲染：数据纹理 + 着色器合成、回读与 HUD

`render.glsl` 每 cell 输出的**不是最终颜色而是数据**（打包 RGBA8）：
`R=`含水充盈度(粒子密度→泡沫)、`G/B=`编码的 cell 中心速度（供折射方向）、
`A=`类型/液体码（气 0 / 固体 85 / 真空 170 / **液体 190+20·主相** = 水190/柠檬210/蜂蜜230）。
CPU 回读该 19 200-uint 缓冲上传到 `_fluid_tex`。

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
- **三种液体（水/柠檬汁/蜂蜜）= 粒子 + 相标签**，不是 `cell_type`（cell_type 只存真空/固体/气）。
  按键 `3/5/6` 选水/柠檬/蜂蜜画笔，均走 `emit` 发射，密度不同→自动分层（见 §6.5）。
- **真空 = 排水口**：`drain.glsl` 每子步把落在 VACUUM cell 的液体粒子回收（active 数下降），实现“液体
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
- Liquids 多相：`lemon_color`(泛绿)、`honey_color`(泛黄)——三液体的显示色。**密度**（决定分层顺序）
  是 `cell_setup.glsl`/`render.glsl` 顶部的 `RHO` 常量（水1.0/柠檬1.4/蜂蜜2.0），非检视器项。

**其余在 `FlipFluidGPU` 顶部 / `main.gd` 常量**：`phys_dt`(1/240)、`p_atm`(3.0)、`fixed_scale`(4096)、
`emit_ppc`(16)、`SUBSTEPS`(4)。运行时 HUD 全量显示。
