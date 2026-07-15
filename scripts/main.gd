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

# ---- inspector-tunable parameters (defaults match the in-code values) ----
@export_group("Simulation")
@export var particle_capacity: int = 524288   # pool size; applied at startup only 524288
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
const TEST_MULTIPHASE := true    # true = honey/lemon sinking through water (density layering)

func _seed_initial_water() -> void:
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

	var t0 := Time.get_ticks_usec()
	solver.step(SUBSTEPS, not _paused, _mouse_cell.x, _mouse_cell.y)
	_last_step_us = float(Time.get_ticks_usec() - t0)

	# upload the fluid DATA texture (shader composites it over the background)
	var bytes := solver.read_display()
	_fluid_tex.update(Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, bytes))
	_update_overlay()
	_apply_render_params()

	_update_hud()

	if DEBUG_CAPTURE:
		_debug_tick()


# Brush preview cells + radius cursor, drawn into the transparent overlay image.
func _update_overlay() -> void:
	_overlay_img.fill(Color(0, 0, 0, 0))
	if _dragging:
		var col: Color = PRESSURE_PREVIEW if _pressure_mode else MAT_PREVIEW[_brush_material]
		for cell in _painted:
			_set_px(cell.x, cell.y, col)

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
				_dragging = true
				_painted.clear()
				_add_brush_cells()
			else:
				_commit_stroke()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_brush_radius = clampf(_brush_radius + 1.0, 0.5, 40.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_brush_radius = clampf(_brush_radius - 1.0, 0.5, 40.0)

	elif event is InputEventMouseMotion and _dragging:
		_add_brush_cells()

	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: _paused = not _paused
			KEY_1: _pressure_mode = false; _brush_material = FlipFluidGPU.T_VACUUM
			KEY_2: _pressure_mode = false; _brush_material = FlipFluidGPU.T_SOLID
			KEY_3: _pressure_mode = false; _brush_material = FlipFluidGPU.T_WATER
			KEY_4: _pressure_mode = false; _brush_material = FlipFluidGPU.T_AIR
			KEY_5: _pressure_mode = false; _brush_material = FlipFluidGPU.T_LEMON
			KEY_6: _pressure_mode = false; _brush_material = FlipFluidGPU.T_HONEY
			KEY_0: _pressure_mode = true
			KEY_P: solver.clear_velocity()
			KEY_V: solver.clear_pressure()


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
	_painted.clear()


# -------------------------------------------------------------------- hud ----
func _update_hud() -> void:
	var probe := solver.read_probe()   # [type, u, v, p, density, fluid]
	var active := solver.active_particles()
	var fps := Engine.get_frames_per_second()

	var mat_txt: String = "Pressure 压力" if _pressure_mode else MAT_NAMES[_brush_material]
	var cell_type: int = int(probe[0]) if probe.size() > 0 else 0
	var is_water := probe.size() > 5 and probe[5] > 0.5
	var rho: float = probe[6] if probe.size() > 6 else 0.0
	var cell_txt: String = _liquid_name(rho) if is_water else MAT_NAMES[clampi(cell_type, 0, 3)]

	var lines := [
		"fps: %d    frame dt: %.2f ms    sim step: %.2f ms" % [fps, _frame_dt * 1000.0, _last_step_us / 1000.0],
		"phys substeps: %d/frame    phys_dt: %.4f s" % [SUBSTEPS, solver.phys_dt],
		"particles: %d active / %d capacity" % [active, solver.capacity],
		"brush: %s    radius: %.0f cells" % [mat_txt, _brush_radius],
		"paused: %s" % ("YES" if _paused else "no"),
		"p_atm: %.2f    jacobi iters: %d    gravity: %.0f    flip: %.2f" % [
			solver.p_atm, solver.jacobi_iters, solver.gravity, solver.flip_ratio],
		"",
		"mouse cell (%d, %d):" % [_mouse_cell.x, _mouse_cell.y],
		"  type: %s%s" % [cell_txt, ("  (rho %.2f)" % rho) if is_water else ""],
		"  vel: (%.3f, %.3f)" % [probe[1] if probe.size() > 1 else 0.0, probe[2] if probe.size() > 2 else 0.0],
		"  pressure: %.3f    particles: %.1f" % [probe[3] if probe.size() > 3 else 0.0, probe[4] if probe.size() > 4 else 0.0],
		"",
		"[1]vac [2]solid [3]water [4]air [5]lemon [6]honey [0]pressure  |  wheel=radius",
		"[space]pause  [P]clear vel  [V]clear pressure  |  L-drag=paint",
	]
	_hud.text = "\n".join(lines)


# Name a liquid cell by its density (matches the RHO constants in p2g.glsl).
func _liquid_name(rho: float) -> String:
	if rho >= 1.7:
		return "Honey 蜂蜜"
	elif rho >= 1.2:
		return "Lemon 柠檬汁"
	return "Water 水"
