extends Node2D

# FLIP/PIC ComputeShader fluid sandbox — orchestration, input and HUD.
# The 160x120 sim result is shown on a retained Sprite2D (nearest-filtered,
# scaled 10x -> crisp 10x10 blocks). The brush preview + radius cursor are
# composited into the image each frame (immediate-mode _draw does not present
# reliably alongside the per-frame local-RenderingDevice submit/sync).

const GRID_W := 160
const GRID_H := 120
const CELL_PX := 10
const SUBSTEPS := 4



# material / mode (indexed by brush material code; 4=lemon, 5=honey are liquids)
const MAT_NAMES := ["Vacuum 真空", "Solid 固体", "Water 水", "Air 气", "Lemon 柠檬汁", "Honey 蜂蜜"]
const MAT_PREVIEW := [
	Color(0, 0, 0, 0.55),          # vacuum
	Color(0.25, 0.25, 0.25, 0.7),  # solid
	Color(0.15, 0.42, 0.9, 0.7),   # water
	Color(0.5, 0.5, 0.5, 0.7),     # air
	Color(0.55, 0.85, 0.30, 0.7),  # lemon juice (greenish)
	Color(0.95, 0.78, 0.18, 0.7),  # honey (golden yellow)
]
const PRESSURE_PREVIEW := Color(0.95, 0.75, 0.1, 0.6)

# --- movable solids (bottle / lemon chunk / ice cube) ---
enum Tool { MATERIAL, LEMON_CHUNK, ICE_CHUNK, DRAW_SOLID, BUBBLE }
const SOLID_BROWN := Color(0.5, 0.32, 0.15)          # drawn movable solid (bottle)
const LEMON_CHUNK_COLOR := Color(0.80, 0.83, 0.22)   # lemon chunk (yellow-green)
const ICE_COLOR := Color(0.75, 0.88, 0.96)           # ice cube (pale cyan)
const ICE_HALF := 4.0        # ice square half-extent (cells) -> ~8x8
const LEMON_R := 6.0         # lemon half-disk radius (cells)
const ICE_DENSITY := 0.85    # < water(1.0) -> floats
const LEMON_DENSITY := 1.15  # > water, < lemon-juice(1.4)/honey(2.0) -> sinks in water
const BODY_LIN_DAMP := 1.5   # linear velocity damping (1/s)
const BODY_ANG_DAMP := 2.5   # angular velocity damping (1/s)
const BODY_DRAG := 0.8       # coupling to surrounding fluid velocity
const ROT_STEP := 0.15       # radians per wheel notch in drag mode

# ---- inspector-tunable parameters (defaults match the in-code values) ----
@export_group("Simulation")
@export var particle_capacity: int = 1048576   # pool size; applied at startup only 524288
@export_range(0.0, 1.0, 0.01) var flip_ratio: float = 0.90
@export var jacobi_iters: int = 60
@export var gravity: float = 40.0

@export_group("Rendering")
@export var background: Texture2D               # background image (null -> background_color)
@export var background_color: Color = Color(0.5, 0.5, 0.5)  # air gray
@export var water_color: Color = Color(0.12, 0.42, 0.85)
@export_range(0.0, 1.0, 0.01) var water_opacity: float = 0.55
@export_range(0.0, 0.2, 0.005) var refraction: float = 0.03
# 水面渲染：false=每个 cell 一种颜色（清晰像素块，默认）；true=cell 间平滑过渡。
@export var smooth_water: bool = false

@export_group("Liquids 多相液体")
# 三种液体的颜色（按密度从轻到重）：水=蓝，柠檬汁=绿，蜂蜜=黄。每格按该格“占多数”的相取色（一格一色）。
# 密度大小固定在 shaders/cell_setup.glsl、render.glsl 的 RHO 常量（水1.0/柠檬1.4/蜂蜜2.0），决定分层顺序。
@export var lemon_color: Color = Color(0.55, 0.85, 0.30)   # 柠檬汁：泛绿，密度>水
@export var honey_color: Color = Color(0.95, 0.78, 0.18)   # 蜂蜜：泛黄，密度>柠檬汁>水

@export_group("Interface Edges 交界描边")
# 交界描边总开关：给液体与气/其它液体相邻的那一圈 cell 叠色（仍一格一色，1 格宽）。
@export var enable_edge: bool = true
# 气液面（液体紧邻空气/背景）叠白量：越大液面泛白越明显（海浪/泡沫感）。
@export_range(0.0, 1.0, 0.01) var gas_edge_white: float = 0.35
# 液液面（紧邻不同液体）叠白量：越大分层交界的白边越亮（柔和过渡缝）。
@export_range(0.0, 1.0, 0.01) var liquid_edge_white: float = 0.35

@export_group("Foam 泡沫泛白")
# 总开关：泡沫（水色蓝→白）。关掉则水面纯蓝，无泛白。
@export var enable_foam: bool = true
# 泡沫颜色，默认白色（极端泡沫=纯白）。
@export var foam_color: Color = Color(1, 1, 1)
# 泡沫最强白度：1=极端处纯白；越小整体泛白越弱。逐 cell 生效，一个格子一种颜色。
@export_range(0.0, 1.0, 0.01) var foam_amount: float = 0.9

# 流速增益：越大，快速运动的浅水/水珠越白（→显著白）。深水由 foam_depth 挡住，不受影响。
@export_range(0.0, 6.0, 0.1) var foam_speed_gain: float = 3.5

# 平静薄水面的泡沫底量：0=只有流动的水才泛白；越大浅水静止时也越白（→微微泛白）。
@export_range(0.0, 1.0, 0.01) var foam_edge_base: float = 0.10

# 深水截止：cell 充盈度(密度)≥此值就完全不泛白（即使流速很快）。越小=越"挑"，只有很薄的水/水珠才泛白。
@export_range(0.05, 1.0, 0.01) var foam_depth: float = 0.2

@export_group("Bubbles 气泡")
# 按 E 切到气泡画笔：在液体处按住左键拖动=添加气泡源，反复涂抹叠加强度（冒泡更密）。
# 气泡从源处不断上浮、摆动，触到液面即消失。画在液体底部就是“从最底层往上冒”。气体(4)画笔可擦除气泡源。
@export var bubble_color: Color = Color(0.85, 0.95, 1.0, 0.9)      # 气泡颜色（浅青白，带透明）
@export_range(1.0, 40.0, 1.0) var bubble_rise: float = 16.0        # 上浮速度（格/秒）
@export_range(0.0, 3.0, 0.1) var bubble_wobble_amp: float = 0.8    # 左右摆动幅度（格）
@export_range(0.0, 20.0, 0.5) var bubble_wobble_freq: float = 7.0  # 摆动频率（弧度/秒）
@export_range(0.1, 10.0, 0.1) var bubble_spawn_rate: float = 2.5   # 生成率（越大冒泡越快）
@export_range(0.1, 10.0, 0.1) var bubble_paint_rate: float = 3.0   # 按住画笔时源强度增长速度
@export_range(0.5, 10.0, 0.5) var bubble_src_max: float = 4.0      # 单格源强度上限
@export_range(0.0, 2.0, 0.05) var bubble_decay: float = 0.01        # 源强度自然衰减（/秒，0=不衰减）
@export var bubble_max: int = 700                                  # 同时存在的气泡数上限

var solver: FlipFluidGPU
var _fluid_tex: ImageTexture
var _overlay_tex: ImageTexture
var _overlay_img: Image
var _display: Sprite2D
var _overlay: Sprite2D
var _mat: ShaderMaterial

# interaction state
var _paused := false
var _brush_material := FlipFluidGPU.T_WATER
var _pressure_mode := false
var _brush_radius := 2.0
var _pressure_strength := 60.0

var _dragging := false
var _painted := {}                 # Vector2i -> true, accumulated during a drag
var _mouse_cell := Vector2i(-1, -1)

# movable-solid state
var _tool := Tool.MATERIAL
var _drag_mode := false             # C: mouse drags/rotates movable solids
var _solids: Array[MovableSolid] = []
var _grabbed: MovableSolid = null
var _grab_offset := Vector2.ZERO
var _solid_mask := PackedByteArray()   # uploaded each frame (int per cell)
var _solid_vel := PackedByteArray()    # uploaded each frame (2 floats per cell)
var _last_display := PackedByteArray() # previous frame's display, for buoyancy
var _preview_lemon: MovableSolid       # ghost outline at the cursor for Q/W tools
var _preview_ice: MovableSolid

# bubble effect (CPU overlay particles: rise through the liquid, pop at the surface)
var _bubble_src := PackedFloat32Array()   # per-cell source strength (E-brush accumulates)
var _bubble_src_cells := {}               # Vector2i -> true, active (non-zero) source cells
var _bubbles: Array = []                  # each: PackedFloat32Array[base_x, y, rise_mul, phase, amp]

# HUD timing
var _frame_dt := 0.0

@onready var _hud: Label = $HUD/Info

const DEBUG_CAPTURE := false   # true = uncapped fps + periodic screenshots/stats
const SELFTEST := false        # true = dispatch every GPU path once at startup
const SHOT_DIR := "user://"
var _fcount := 0
var _step_us_acc := 0.0
var _last_step_us := 0.0


func _ready() -> void:
	if DEBUG_CAPTURE:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	solver = FlipFluidGPU.new()
	solver.capacity = maxi(1024, particle_capacity)  # fixed at startup
	solver.flip_ratio = flip_ratio
	solver.jacobi_iters = jacobi_iters
	solver.gravity = gravity
	solver.init_solver(GRID_W, GRID_H)

	_solid_mask.resize(GRID_W * GRID_H * 4)       # int per cell
	_solid_vel.resize(GRID_W * GRID_H * 2 * 4)    # vec2 per cell
	_bubble_src.resize(GRID_W * GRID_H)           # float per cell (bubble source field)
	_preview_lemon = MovableSolid.make_halfdisk(Vector2.ZERO, LEMON_R, LEMON_CHUNK_COLOR, LEMON_DENSITY, true)
	_preview_ice = MovableSolid.make_square(Vector2.ZERO, ICE_HALF, ICE_COLOR, ICE_DENSITY, true)

	_setup_display()
	_seed_initial_water()

	if SELFTEST:
		# Exercise the remaining GPU paths once so binding errors would surface.
		solver.clear_pressure()
		solver.clear_velocity()
		var m := PackedByteArray()
		m.resize(GRID_W * GRID_H * 4)
		for y in range(60, 70):
			for x in range(60, 70):
				m.encode_s32((x + y * GRID_W) * 4, 1)
		solver.commit_brush(m, 0, 1, 60.0, Vector2(65, 65), 123)  # pressure impulse
		print("SELFTEST: clear_pressure/clear_velocity/pressure_impulse dispatched OK")


# All visible content lives in a CanvasLayer: the default world-2D canvas does
# not present alongside the per-frame local-RenderingDevice submit/sync.
func _setup_display() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)

	_fluid_tex = ImageTexture.create_from_image(
		Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8))
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/water_display.gdshader")
	_mat.set_shader_parameter("fluid_nearest", _fluid_tex)
	_mat.set_shader_parameter("fluid_linear", _fluid_tex)
	_apply_render_params()

	# Fluid layer: 160x120 data texture scaled 10x, composited by the shader.
	_display = Sprite2D.new()
	_display.texture = _fluid_tex
	_display.centered = false
	_display.scale = Vector2(CELL_PX, CELL_PX)
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.material = _mat
	layer.add_child(_display)

	# Overlay layer (brush preview + radius cursor) drawn on top with alpha.
	_overlay_img = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_overlay_tex = ImageTexture.create_from_image(_overlay_img)
	_overlay = Sprite2D.new()
	_overlay.texture = _overlay_tex
	_overlay.centered = false
	_overlay.scale = Vector2(CELL_PX, CELL_PX)
	_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.add_child(_overlay)


func _apply_render_params() -> void:
	_mat.set_shader_parameter("has_bg", background != null)
	if background != null:
		_mat.set_shader_parameter("bg_tex", background)
	_mat.set_shader_parameter("bg_color", background_color)
	_mat.set_shader_parameter("water_tint", water_color)
	_mat.set_shader_parameter("lemon_color", lemon_color)
	_mat.set_shader_parameter("honey_color", honey_color)
	_mat.set_shader_parameter("enable_edge", enable_edge)
	_mat.set_shader_parameter("gas_edge_white", gas_edge_white)
	_mat.set_shader_parameter("liquid_edge_white", liquid_edge_white)
	_mat.set_shader_parameter("water_opacity", water_opacity)
	_mat.set_shader_parameter("refraction", refraction)
	_mat.set_shader_parameter("smooth_water", smooth_water)
	_mat.set_shader_parameter("enable_foam", enable_foam)
	_mat.set_shader_parameter("foam_color", foam_color)
	_mat.set_shader_parameter("foam_amount", foam_amount)
	_mat.set_shader_parameter("foam_speed_gain", foam_speed_gain)
	_mat.set_shader_parameter("foam_edge_base", foam_edge_base)
	_mat.set_shader_parameter("foam_depth", foam_depth)


const TEST_SCENE := false        # true = pre-built solid container + water + air showcase
const TEST_MULTIPHASE := false   # true = honey/lemon sinking through water (density layering)
const TEST_SOLIDS := true        # true = water pool + floating ice / sinking lemon + sloshing bar

func _seed_initial_water() -> void:
	if TEST_SOLIDS:
		_setup_solids_demo()
		return
	if TEST_MULTIPHASE:
		_setup_multiphase_demo()
		return
	if TEST_SCENE:
		_setup_test_scene()
		return
	# A dam-break block on the left so there is motion to observe immediately.
	var mask := PackedByteArray()
	mask.resize(GRID_W * GRID_H * 4)
	for y in range(10, 110):
		for x in range(8, 64):
			mask.encode_s32((x + y * GRID_W) * 4, 1)
	solver.commit_brush(mask, FlipFluidGPU.T_WATER, 0, 0.0, Vector2.ZERO, randi())


func _setup_multiphase_demo() -> void:
	# Solid container to hold the liquids.
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 30, 20, 34, 106)     # left wall
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 126, 20, 130, 106)   # right wall
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 30, 102, 130, 106)   # floor
	# Stable stratification: water (light) on top, lemon juice in the middle,
	# honey (heavy) on the bottom. Correct density ordering should hold as three
	# clean colour bands. Paint 5/6 to drop denser liquid in and watch it sink.
	_paint_rect(FlipFluidGPU.T_WATER, 0, 34, 24, 126, 50)     # top    -> blue
	_paint_rect(FlipFluidGPU.T_LEMON, 0, 34, 50, 126, 76)     # middle -> green
	_paint_rect(FlipFluidGPU.T_HONEY, 0, 34, 76, 126, 102)    # bottom -> yellow


func _setup_solids_demo() -> void:
	# Container + a water pool in the lower half.
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 30, 20, 34, 106)     # left wall
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 126, 20, 130, 106)   # right wall
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 30, 102, 130, 106)   # floor
	_paint_rect(FlipFluidGPU.T_WATER, 0, 34, 58, 126, 102)    # water pool
	# Dynamic bodies dropped just above the water: ice (light) should bob up and
	# float, the lemon chunk (denser than water) should sink to the bottom.
	# two ice cubes (test ice-ice collision + stable floating, no fly-out)
	_add_solid(MovableSolid.make_square(Vector2(54, 42), ICE_HALF, ICE_COLOR, ICE_DENSITY, true))
	_add_solid(MovableSolid.make_square(Vector2(64, 28), ICE_HALF, ICE_COLOR, ICE_DENSITY, true))
	_add_solid(MovableSolid.make_halfdisk(Vector2(102, 44), LEMON_R, LEMON_CHUNK_COLOR, LEMON_DENSITY, true))


func _add_solid(b: MovableSolid) -> void:
	b.prev_pos = b.pos
	b.prev_angle = b.angle
	_solids.append(b)


func _paint_rect(mat: int, mode: int, x0: int, y0: int, x1: int, y1: int) -> void:
	var mask := PackedByteArray()
	mask.resize(GRID_W * GRID_H * 4)
	for y in range(y0, y1):
		for x in range(x0, x1):
			mask.encode_s32((x + y * GRID_W) * 4, 1)
	solver.commit_brush(mask, mat, mode, _pressure_strength,
		Vector2((x0 + x1) * 0.5, (y0 + y1) * 0.5), randi())


func _setup_test_scene() -> void:
	# Solid container (left/right walls + floor) to test F8 containment.
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 40, 55, 43, 116)
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 117, 55, 120, 116)
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 40, 113, 120, 116)
	# A solid shelf outside the container (water from above should land on it).
	_paint_rect(FlipFluidGPU.T_SOLID, 0, 128, 90, 158, 93)
	# An air patch (should render gray) top-right.
	_paint_rect(FlipFluidGPU.T_AIR, 0, 128, 10, 158, 40)
	# Water filling the container, plus a falling column over the shelf.
	_paint_rect(FlipFluidGPU.T_WATER, 0, 44, 58, 116, 92)
	_paint_rect(FlipFluidGPU.T_WATER, 0, 133, 20, 152, 55)


func _exit_tree() -> void:
	if solver:
		solver.cleanup()


func _process(delta: float) -> void:
	_frame_dt = delta
	# live inspector tweaks (capacity is fixed once buffers are allocated)
	solver.flip_ratio = flip_ratio
	solver.jacobi_iters = jacobi_iters
	solver.gravity = gravity

	var mp := get_local_mouse_position()
	_mouse_cell = Vector2i(
		clampi(int(mp.x / CELL_PX), 0, GRID_W - 1),
		clampi(int(mp.y / CELL_PX), 0, GRID_H - 1))

	# movable solids: integrate dynamic bodies (buoyancy from last frame's fluid),
	# then rasterise the current poses and upload them for this step.
	if not _paused:
		_update_solid_dynamics(delta)
	_rasterize_and_upload(delta)

	var t0 := Time.get_ticks_usec()
	solver.step(SUBSTEPS, not _paused, _mouse_cell.x, _mouse_cell.y)
	_last_step_us = float(Time.get_ticks_usec() - t0)

	# upload the fluid DATA texture (shader composites it over the background)
	_last_display = solver.read_display()
	_update_bubbles(delta)   # spawn/rise/pop bubbles against this frame's display
	_fluid_tex.update(Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, _last_display))
	_update_overlay()
	_apply_render_params()

	_update_hud()

	if DEBUG_CAPTURE:
		_debug_tick()


# Brush preview cells + radius cursor, drawn into the transparent overlay image.
func _update_overlay() -> void:
	_overlay_img.fill(Color(0, 0, 0, 0))
	if _dragging:
		var col: Color
		if _tool == Tool.DRAW_SOLID:
			col = Color(SOLID_BROWN, 0.7)          # drawing a movable solid -> brown
		elif _tool == Tool.BUBBLE:
			col = Color(bubble_color.r, bubble_color.g, bubble_color.b, 0.4)  # bubble source
		elif _pressure_mode:
			col = PRESSURE_PREVIEW
		else:
			col = MAT_PREVIEW[_brush_material]
		for cell in _painted:
			_set_px(cell.x, cell.y, col)

	# chunk placement ghost: show the shape that a Q/W click will drop at the cursor
	if not _drag_mode and (_tool == Tool.LEMON_CHUNK or _tool == Tool.ICE_CHUNK):
		var ghost: MovableSolid = _preview_ice if _tool == Tool.ICE_CHUNK else _preview_lemon
		ghost.pos = _mouse_grid()
		var gcol := Color(ghost.color, 0.55)
		for cell in _cells(ghost):
			_set_px(int(cell.x), int(cell.y), gcol)

	# movable solids drawn opaque on top (they occlude the liquid behind them)
	for b in _solids:
		_draw_solid_overlay(b)

	# rising bubbles: light specks inside the liquid
	for b in _bubbles:
		_set_px(int(b[0] + sin(b[3]) * b[4]), int(b[1]), bubble_color)

	var cursor: Color = PRESSURE_PREVIEW if _pressure_mode else Color(1, 1, 1, 0.85)
	var r := _brush_radius
	var steps := maxi(16, int(TAU * r))
	for s in steps:
		var a := TAU * float(s) / float(steps)
		_set_px(int(round(_mouse_cell.x + cos(a) * r)), int(round(_mouse_cell.y + sin(a) * r)), cursor)
	_overlay_tex.update(_overlay_img)


func _set_px(x: int, y: int, col: Color) -> void:
	if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H:
		return
	_overlay_img.set_pixel(x, y, col)


func _debug_tick() -> void:
	_fcount += 1
	_step_us_acc += _last_step_us
	if _fcount == 40 or _fcount == 250 or _fcount == 550:
		var im := get_viewport().get_texture().get_image()
		im.save_png(SHOT_DIR + "shot_%03d.png" % _fcount)
		print("[F%d] fps=%d  step=%.2fms avg=%.2fms  active=%d/%d  probe=%s" % [
			_fcount, Engine.get_frames_per_second(), _last_step_us / 1000.0,
			(_step_us_acc / _fcount) / 1000.0, solver.active_particles(), solver.capacity,
			str(solver.read_probe())])


# ------------------------------------------------------------------ input ----
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_left_press()
			else:
				_on_left_release()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if _drag_mode and _grabbed != null:
				_grabbed.angle += ROT_STEP
			else:
				_brush_radius = clampf(_brush_radius + 1.0, 0.5, 40.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if _drag_mode and _grabbed != null:
				_grabbed.angle -= ROT_STEP
			else:
				_brush_radius = clampf(_brush_radius - 1.0, 0.5, 40.0)

	elif event is InputEventMouseMotion:
		if _drag_mode and _grabbed != null:
			_grabbed.pos = (_mouse_grid() + _grab_offset).clamp(
				Vector2(1, 1), Vector2(GRID_W - 1, GRID_H - 1))
		elif _dragging:
			_add_brush_cells()

	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: _paused = not _paused
			KEY_1: _set_material(FlipFluidGPU.T_VACUUM)
			KEY_2: _set_material(FlipFluidGPU.T_SOLID)
			KEY_3: _set_material(FlipFluidGPU.T_WATER)
			KEY_4: _set_material(FlipFluidGPU.T_AIR)
			KEY_5: _set_material(FlipFluidGPU.T_LEMON)
			KEY_6: _set_material(FlipFluidGPU.T_HONEY)
			KEY_0: _tool = Tool.MATERIAL; _pressure_mode = true
			KEY_Q: _tool = Tool.LEMON_CHUNK; _drag_mode = false
			KEY_W: _tool = Tool.ICE_CHUNK; _drag_mode = false
			KEY_9: _tool = Tool.DRAW_SOLID; _drag_mode = false
			KEY_E: _tool = Tool.BUBBLE; _drag_mode = false; _pressure_mode = false
			KEY_C: _drag_mode = not _drag_mode; _grabbed = null; _dragging = false
			KEY_P: solver.clear_velocity()
			KEY_V: solver.clear_pressure()


func _set_material(mat: int) -> void:
	_tool = Tool.MATERIAL
	_pressure_mode = false
	_brush_material = mat


func _mouse_grid() -> Vector2:
	var mp := get_local_mouse_position()
	return Vector2(mp.x / CELL_PX, mp.y / CELL_PX)


func _on_left_press() -> void:
	if _drag_mode:
		_grabbed = _body_at(_mouse_grid())
		if _grabbed != null:
			_grab_offset = _grabbed.pos - _mouse_grid()
			_grabbed.prev_pos = _grabbed.pos    # no velocity spike on grab
		return
	match _tool:
		Tool.LEMON_CHUNK:
			_add_solid(MovableSolid.make_halfdisk(_mouse_grid(), LEMON_R,
				LEMON_CHUNK_COLOR, LEMON_DENSITY, true))
		Tool.ICE_CHUNK:
			_add_solid(MovableSolid.make_square(_mouse_grid(), ICE_HALF,
				ICE_COLOR, ICE_DENSITY, true))
		_:
			# DRAW_SOLID and normal material brushes both paint cells first
			_dragging = true
			_painted.clear()
			_add_brush_cells()


func _on_left_release() -> void:
	if _drag_mode:
		_grabbed = null
		return
	if not _dragging:
		return
	if _tool == Tool.DRAW_SOLID:
		_dragging = false
		if _painted.size() >= 2:
			_create_or_merge_drawn(_painted.keys())
		_painted.clear()
	elif _tool == Tool.BUBBLE:
		# bubble sources were accumulated during the drag; nothing to commit to the solver
		_dragging = false
		_painted.clear()
	else:
		_commit_stroke()


# Create a drawn movable solid from the stroke, merging it with any existing
# drawn solid it touches (4-adjacent or overlapping) so a shape drawn in several
# strokes becomes one connected body. Chaining bridges multiple bodies into one.
func _create_or_merge_drawn(new_cells: Array) -> void:
	var cells := {}                       # union of all world cells -> true
	for c in new_cells:
		cells[c] = true
	var merged := []
	for b in _solids:
		if b.kind != MovableSolid.Kind.DRAW:
			continue
		for cell in _cells(b):
			if _cell_touches(Vector2i(int(cell.x), int(cell.y)), cells):
				merged.append(b)
				break
	for b in merged:
		for cell in _cells(b):
			cells[Vector2i(int(cell.x), int(cell.y))] = true
		if _grabbed == b:
			_grabbed = null
		_solids.erase(b)
	_add_solid(MovableSolid.make_drawn(cells.keys(), SOLID_BROWN))


func _cell_touches(ci: Vector2i, cells: Dictionary) -> bool:
	return (cells.has(ci)
		or cells.has(ci + Vector2i(1, 0)) or cells.has(ci + Vector2i(-1, 0))
		or cells.has(ci + Vector2i(0, 1)) or cells.has(ci + Vector2i(0, -1)))


func _body_at(gp: Vector2) -> MovableSolid:
	for i in range(_solids.size() - 1, -1, -1):
		var b := _solids[i]
		var w := gp - b.pos
		var ca := cos(b.angle)
		var sa := sin(b.angle)
		if b.contains_local(Vector2(w.x * ca + w.y * sa, -w.x * sa + w.y * ca)):
			return b
	return null


# --- movable solid rasterisation / dynamics ------------------------------------

# Cells a body occupies at its CURRENT pose, cached per (pos, angle). Every
# per-frame pass (buoyancy / separation / rasterise / overlay) shares this, so
# the AABB scan runs at most once per body per pose instead of ~5-7x/frame.
func _cells(b: MovableSolid) -> PackedVector2Array:
	if b.cache_valid and b.cache_pos == b.pos and b.cache_angle == b.angle:
		return b.cache_cells
	b.cache_cells = _scan_cells(b, b.pos, b.angle)
	b.cache_pos = b.pos
	b.cache_angle = b.angle
	b.cache_valid = true
	return b.cache_cells


# Cells covered by a body at the given pose (inverse mapping -> no holes),
# clamped to the domain. Returns Vector2(x, y) integer cell coords.
func _scan_cells(b: MovableSolid, at: Vector2, ang: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var R := b.bound_r
	var ca := cos(ang)
	var sa := sin(ang)
	var x0 := clampi(int(floor(at.x - R)), 0, GRID_W - 1)
	var x1 := clampi(int(ceil(at.x + R)), 0, GRID_W - 1)
	var y0 := clampi(int(floor(at.y - R)), 0, GRID_H - 1)
	var y1 := clampi(int(ceil(at.y + R)), 0, GRID_H - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var wx := x + 0.5 - at.x
			var wy := y + 0.5 - at.y
			if b.contains_local(Vector2(wx * ca + wy * sa, -wx * sa + wy * ca)):
				out.append(Vector2(x, y))
	return out


# Zero the upload buffers and stamp every body (mask + rigid velocity per cell).
# Kinematic bodies (bottle / grabbed) take their velocity from the pose delta.
func _rasterize_and_upload(delta: float) -> void:
	var dt := maxf(delta, 1e-4)
	for b in _solids:
		if (not b.dynamic) or (b == _grabbed):
			b.vel = (b.pos - b.prev_pos) / dt
			b.omega = wrapf(b.angle - b.prev_angle, -PI, PI) / dt
		b.prev_pos = b.pos
		b.prev_angle = b.angle
	_solid_mask.fill(0)
	_solid_vel.fill(0)
	for b in _solids:
		for cell in _cells(b):
			var x := int(cell.x)
			var y := int(cell.y)
			var c := x + y * GRID_W
			_solid_mask.encode_s32(c * 4, 1)
			var r := Vector2(x + 0.5 - b.pos.x, y + 0.5 - b.pos.y)
			var v := b.vel + b.omega * Vector2(-r.y, r.x)
			_solid_vel.encode_float(c * 8, v.x)
			_solid_vel.encode_float(c * 8 + 4, v.y)
	solver.upload_solids(_solid_mask, _solid_vel)


func _draw_solid_overlay(b: MovableSolid) -> void:
	for cell in _cells(b):
		_set_px(int(cell.x), int(cell.y), b.color)


# Integrate the dynamic (physics) bodies: gravity + buoyancy from the previous
# frame's fluid, light drag toward the local flow, plus a buoyant righting torque.
func _update_solid_dynamics(delta: float) -> void:
	if _last_display.is_empty():
		return
	var dt := clampf(delta, 1e-4, 0.05)
	# per-column topmost liquid cell (surface height); GRID_H = dry column.
	# Scan each column top-down and break at the first liquid cell.
	var surf := PackedInt32Array()
	surf.resize(GRID_W)
	for x in range(GRID_W):
		var sy := GRID_H
		for y in range(GRID_H):
			if _last_display[(x + y * GRID_W) * 4 + 3] >= 185:
				sy = y
				break
		surf[x] = sy
	for b in _solids:
		if b.dynamic and b != _grabbed:
			_integrate_body(b, dt, surf)
	_separate_bodies()


# Resolve solid-solid overlaps by pushing bodies apart (a couple of relaxation
# passes). Only movable (dynamic, not-grabbed) bodies get displaced; kinematic /
# grabbed bodies hold their pose, so a moving bottle shoves a floating chunk aside.
func _separate_bodies() -> void:
	var n := _solids.size()
	if n < 2:
		return
	for _iter in range(2):
		for i in range(n):
			var a: MovableSolid = _solids[i]
			var a_move := a.dynamic and a != _grabbed
			for j in range(i + 1, n):
				var bb: MovableSolid = _solids[j]
				var b_move := bb.dynamic and bb != _grabbed
				if not a_move and not b_move:
					continue
				# broad-phase: bounding-circle reject (cheap, avoids the O(N^2) cell work)
				var rr := a.bound_r + bb.bound_r
				if a.pos.distance_squared_to(bb.pos) > rr * rr:
					continue
				# narrow-phase: count a's cells that lie inside b (no set allocation)
				var ov := _overlap_direct(a, bb)
				if ov <= 0:
					continue
				var dir := bb.pos - a.pos
				dir = dir.normalized() if dir.length() > 0.01 else Vector2(0, -1)
				var push: float = minf(0.15 * float(ov), 3.0)
				if a_move and b_move:
					_push_body(a, -dir, push * 0.5)
					_push_body(bb, dir, push * 0.5)
				elif a_move:
					_push_body(a, -dir, push)
				else:
					_push_body(bb, dir, push)


# Number of body a's cells that fall inside body b (tests a's cached cells
# against b's shape directly -> no Dictionary allocation).
func _overlap_direct(a: MovableSolid, b: MovableSolid) -> int:
	var ca := cos(b.angle)
	var sa := sin(b.angle)
	var c := 0
	for cell in _cells(a):
		var wx := cell.x + 0.5 - b.pos.x
		var wy := cell.y + 0.5 - b.pos.y
		if b.contains_local(Vector2(wx * ca + wy * sa, -wx * sa + wy * ca)):
			c += 1
	return c


func _push_body(b: MovableSolid, dir: Vector2, dist: float) -> void:
	var newpos := (b.pos + dir * dist).clamp(Vector2(1, 1), Vector2(GRID_W - 1, GRID_H - 1))
	if not _body_blocked(b, newpos):
		b.pos = newpos
	var vn := b.vel.dot(dir)      # cancel velocity heading further into the overlap
	if vn < 0.0:
		b.vel -= dir * vn


func _integrate_body(b: MovableSolid, dt: float, surf: PackedInt32Array) -> void:
	var g := solver.gravity
	var cells := _cells(b)
	var total := cells.size()
	if total == 0:
		return
	# Ambient pool surface measured from the FREE columns beside the body, so water
	# trapped on a flat top does not fool the buoyancy (it can't fly out of water).
	var level := _ambient_level(cells, surf)   # -1 if no flanking pool found
	# Submersion is pure arithmetic (no per-cell fluid reads): count submerged cells
	# and their x-moment for the righting torque. Density/velocity are sampled ONCE
	# per body (at its centre depth) -- ample for a toy, and far cheaper per frame.
	var submerged := 0
	var sum_rx := 0.0
	for cell in cells:
		var s: float = level if level >= 0.0 else float(surf[int(cell.x)])
		if cell.y >= s:
			submerged += 1
			sum_rx += cell.x + 0.5 - b.pos.x
	var mass := maxf(b.density * total, 1e-3)
	var inertia := maxf(b.density * b.inertia_unit, 1e-2)
	var force := Vector2(0.0, g * b.density * total)     # weight (down)
	var torque := 0.0
	if submerged > 0:
		var cx := clampi(int(b.pos.x), 0, GRID_W - 1)
		var cy := clampi(int(b.pos.y), 0, GRID_H - 1)
		var rho_f := _rho_near(cx, cy)
		force.y -= g * rho_f * submerged                 # buoyancy (up)
		torque = -g * rho_f * sum_rx                      # righting moment
		force += BODY_DRAG * (_vel_at(cx, cy) - b.vel) * submerged   # drag / current
	b.vel += force / mass * dt
	b.omega += torque / inertia * dt
	b.vel *= exp(-BODY_LIN_DAMP * dt)
	b.omega *= exp(-BODY_ANG_DAMP * dt)
	_move_body_collide(b, b.pos + b.vel * dt)
	b.angle += b.omega * dt


# Ambient pool surface (cell y) sampled from the free columns just left/right of
# the body's span. Ignores any liquid trapped on the body itself. -1 = no pool
# beside the body (e.g. body spans the container) -> caller falls back per-column.
func _ambient_level(cells: PackedVector2Array, surf: PackedInt32Array) -> float:
	var x0 := GRID_W
	var x1 := -1
	for cell in cells:
		x0 = mini(x0, int(cell.x))
		x1 = maxi(x1, int(cell.x))
	var sum := 0.0
	var n := 0
	for d in range(1, 5):
		var lx := x0 - d
		if lx >= 0 and surf[lx] < GRID_H:
			sum += surf[lx]; n += 1
		var rx := x1 + d
		if rx < GRID_W and surf[rx] < GRID_H:
			sum += surf[rx]; n += 1
	return (sum / n) if n > 0 else -1.0


# Fluid density at the body cell's own depth (sample horizontally: the cell reads
# as air, so look left/right for the surrounding liquid). Phase code -> density.
func _rho_near(x: int, y: int) -> float:
	for dx: int in [0, -1, 1, -2, 2]:
		var nx: int = x + dx
		if nx >= 0 and nx < GRID_W:
			var a := int(_last_display[(nx + y * GRID_W) * 4 + 3])
			if a >= 185:
				return [1.0, 1.4, 2.0][clampi((a - 190) / 20, 0, 2)]
	return 1.0


func _vel_at(x: int, y: int) -> Vector2:
	var i := (x + y * GRID_W) * 4
	return Vector2(
		(float(_last_display[i + 1]) / 255.0 - 0.5) * 120.0,
		(float(_last_display[i + 2]) / 255.0 - 0.5) * 120.0)


# Axis-separated move that stops against static solids (display code 85) and the
# domain border. Body-body overlaps are resolved separately in _separate_bodies.
func _move_body_collide(b: MovableSolid, newpos: Vector2) -> void:
	if _body_blocked(b, Vector2(newpos.x, b.pos.y)):
		b.vel.x = 0.0
	else:
		b.pos.x = newpos.x
	if _body_blocked(b, Vector2(b.pos.x, newpos.y)):
		b.vel.y = 0.0
	else:
		b.pos.y = newpos.y


# Would the body (at candidate pose `at`, a pure translation of its current pose)
# hit a static solid or the border? Reuses the cached cells shifted by the
# translation instead of re-scanning the AABB (callers only ever translate).
func _body_blocked(b: MovableSolid, at: Vector2) -> bool:
	var off := at - b.pos
	for cell in _cells(b):
		var nx := int(floor(cell.x + 0.5 + off.x))
		var ny := int(floor(cell.y + 0.5 + off.y))
		if nx < 0 or nx >= GRID_W or ny < 0 or ny >= GRID_H:
			return true
		if int(_last_display[(nx + ny * GRID_W) * 4 + 3]) == 85:
			return true
	return false


func _add_brush_cells() -> void:
	var mp := get_local_mouse_position()
	var cx := mp.x / CELL_PX
	var cy := mp.y / CELL_PX
	var r := _brush_radius
	var r2 := (r + 0.5) * (r + 0.5)
	var min_x := clampi(int(floor(cx - r - 1)), 0, GRID_W - 1)
	var max_x := clampi(int(ceil(cx + r + 1)), 0, GRID_W - 1)
	var min_y := clampi(int(floor(cy - r - 1)), 0, GRID_H - 1)
	var max_y := clampi(int(ceil(cy + r + 1)), 0, GRID_H - 1)
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var dx := (x + 0.5) - cx
			var dy := (y + 0.5) - cy
			if dx * dx + dy * dy <= r2:
				_painted[Vector2i(x, y)] = true


func _commit_stroke() -> void:
	_dragging = false
	if _painted.is_empty():
		return
	var mask := PackedByteArray()
	mask.resize(GRID_W * GRID_H * 4)
	var sum := Vector2.ZERO
	for cell in _painted:
		mask.encode_s32((cell.x + cell.y * GRID_W) * 4, 1)
		sum += Vector2(cell.x + 0.5, cell.y + 0.5)
	var centroid := sum / _painted.size()

	if _pressure_mode:
		solver.commit_brush(mask, 0, 1, _pressure_strength, centroid, randi())
	else:
		solver.commit_brush(mask, _brush_material, 0, 0.0, centroid, randi())
		# the air/gas brush also acts as the eraser for movable solids and bubble sources
		if _brush_material == FlipFluidGPU.T_AIR:
			_erase_solids_overlapping(_painted)
			_erase_bubbles_overlapping(_painted)
	_painted.clear()


# Remove any movable solid the (air-brush) stroke touched.
func _erase_solids_overlapping(painted: Dictionary) -> void:
	for i in range(_solids.size() - 1, -1, -1):
		var b := _solids[i]
		for cell in _cells(b):
			if painted.has(Vector2i(int(cell.x), int(cell.y))):
				if _grabbed == b:
					_grabbed = null
				_solids.remove_at(i)
				break


# ------------------------------------------------------------- bubbles ----
# Is display cell (x, y) liquid? (fluid A code >= 185; solid/air/vacuum are below.)
func _is_fluid_cell(x: int, y: int) -> bool:
	if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H:
		return false
	return _last_display[(x + y * GRID_W) * 4 + 3] >= 185


# CPU overlay bubbles: the E-brush paints a per-cell source field (held strokes stack
# into more intensity); each frame we spawn bubbles from source cells that sit in liquid,
# rise + wobble them, and pop them the instant they leave the liquid (reach the surface).
func _update_bubbles(delta: float) -> void:
	var dt := clampf(delta, 1e-4, 0.05)
	# accumulate source strength while dragging the bubble brush (hold to intensify)
	if _dragging and _tool == Tool.BUBBLE:
		for cell in _painted:
			var c: int = cell.x + cell.y * GRID_W
			_bubble_src[c] = minf(_bubble_src[c] + bubble_paint_rate * dt, bubble_src_max)
			_bubble_src_cells[cell] = true
	if _paused or _last_display.is_empty():
		return
	# spawn from active source cells that are currently inside liquid
	var dead: Array = []
	for cell in _bubble_src_cells:
		var c: int = cell.x + cell.y * GRID_W
		var s: float = _bubble_src[c]
		if bubble_decay > 0.0:
			s = maxf(0.0, s - bubble_decay * dt)
			_bubble_src[c] = s
		if s <= 0.0:
			dead.append(cell)
			continue
		if _bubbles.size() < bubble_max and _is_fluid_cell(cell.x, cell.y):
			if randf() < s * bubble_spawn_rate * dt:
				_spawn_bubble(cell.x, cell.y)
	for cell in dead:
		_bubble_src_cells.erase(cell)
	# rise + wobble; pop when a bubble leaves the liquid (reaches the surface / an object)
	var survivors: Array = []
	for b in _bubbles:
		b[1] -= bubble_rise * b[2] * dt
		b[3] += bubble_wobble_freq * dt
		var cx: int = clampi(int(b[0] + sin(b[3]) * b[4]), 0, GRID_W - 1)
		var cy: int = int(b[1])
		if cy >= 0 and _is_fluid_cell(cx, cy):
			survivors.append(b)
	_bubbles = survivors


func _spawn_bubble(gx: int, gy: int) -> void:
	_bubbles.append(PackedFloat32Array([
		float(gx) + randf(),                            # 0: base x (wobble centre)
		float(gy) + randf(),                            # 1: y (rises = decreases)
		randf_range(0.7, 1.3),                          # 2: rise-speed multiplier
		randf() * TAU,                                  # 3: wobble phase
		randf_range(0.4, 1.0) * bubble_wobble_amp]))    # 4: wobble amplitude (cells)


# The air-brush eraser also clears bubble sources it touches.
func _erase_bubbles_overlapping(painted: Dictionary) -> void:
	for cell in painted:
		_bubble_src[cell.x + cell.y * GRID_W] = 0.0
		_bubble_src_cells.erase(cell)


# -------------------------------------------------------------------- hud ----
func _update_hud() -> void:
	var probe := solver.read_probe()   # [type, u, v, p, density, fluid]
	var active := solver.active_particles()
	var fps := Engine.get_frames_per_second()

	var cell_type: int = int(probe[0]) if probe.size() > 0 else 0
	var is_water := probe.size() > 5 and probe[5] > 0.5
	var rho: float = probe[6] if probe.size() > 6 else 0.0
	var cell_txt: String = _liquid_name(rho) if is_water else MAT_NAMES[clampi(cell_type, 0, 3)]

	var tool_txt := _tool_name()
	var mode_txt: String = "DRAG 拖拽" if _drag_mode else "PAINT 绘制"

	var lines := [
		"fps: %d    frame dt: %.2f ms    sim step: %.2f ms" % [fps, _frame_dt * 1000.0, _last_step_us / 1000.0],
		"phys substeps: %d/frame    phys_dt: %.4f s" % [SUBSTEPS, solver.phys_dt],
		"particles: %d active / %d capacity    solids: %d" % [active, solver.capacity, _solids.size()],
		"mode: %s    brush: %s    radius: %.0f cells" % [mode_txt, tool_txt, _brush_radius],
		"paused: %s" % ("YES" if _paused else "no"),
		"p_atm: %.2f    jacobi iters: %d    gravity: %.0f    flip: %.2f" % [
			solver.p_atm, solver.jacobi_iters, solver.gravity, solver.flip_ratio],
		"",
		"mouse cell (%d, %d):" % [_mouse_cell.x, _mouse_cell.y],
		"  type: %s%s" % [cell_txt, ("  (rho %.2f)" % rho) if is_water else ""],
		"  vel: (%.3f, %.3f)" % [probe[1] if probe.size() > 1 else 0.0, probe[2] if probe.size() > 2 else 0.0],
		"  pressure: %.3f    particles: %.1f" % [probe[3] if probe.size() > 3 else 0.0, probe[4] if probe.size() > 4 else 0.0],
		"",
		"[1]vac [2]solid [3]water [4]air [5]lemon-juice [6]honey [0]pressure",
		"[Q]lemon-chunk [W]ice-cube [E]bubbles [9]draw-solid  |  [C]drag mode (wheel=rotate)",
		"[space]pause  [P]clear vel  [V]clear pressure  |  wheel=radius",
	]
	_hud.text = "\n".join(lines)


func _tool_name() -> String:
	match _tool:
		Tool.LEMON_CHUNK: return "Lemon chunk 柠檬块"
		Tool.ICE_CHUNK:   return "Ice cube 冰块"
		Tool.DRAW_SOLID:  return "Movable solid 可移动固体"
		Tool.BUBBLE:      return "Bubbles 气泡"
		_: return "Pressure 压力" if _pressure_mode else MAT_NAMES[_brush_material]


# Name a liquid cell by its density (matches the RHO constants in p2g.glsl).
func _liquid_name(rho: float) -> String:
	if rho >= 1.7:
		return "Honey 蜂蜜"
	elif rho >= 1.2:
		return "Lemon 柠檬汁"
	return "Water 水"
