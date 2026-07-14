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



# material / mode
const MAT_NAMES := ["Vacuum 真空", "Solid 固体", "Water 水", "Air 气"]
const MAT_PREVIEW := [
	Color(0, 0, 0, 0.55),          # vacuum
	Color(0.25, 0.25, 0.25, 0.7),  # solid
	Color(0.15, 0.42, 0.9, 0.7),   # water
	Color(0.5, 0.5, 0.5, 0.7),     # air
]
const PRESSURE_PREVIEW := Color(0.95, 0.75, 0.1, 0.6)

var solver: FlipFluidGPU
var _tex: ImageTexture
var _sprite: Sprite2D

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
	solver.init_solver(GRID_W, GRID_H)

	var img := Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(img)

	# Retained-mode display: 160x120 texture scaled 10x with nearest filtering.
	# Placed in a CanvasLayer (layer 0, below the HUD) because the default
	# world-2D canvas does not present alongside the per-frame local-RD sync.
	var display_layer := CanvasLayer.new()
	display_layer.layer = 0
	add_child(display_layer)
	_sprite = Sprite2D.new()
	_sprite.texture = _tex
	_sprite.centered = false
	_sprite.scale = Vector2(CELL_PX, CELL_PX)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display_layer.add_child(_sprite)

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


const TEST_SCENE := false   # true = pre-built solid container + water + air showcase

func _seed_initial_water() -> void:
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
	var mp := get_local_mouse_position()
	_mouse_cell = Vector2i(
		clampi(int(mp.x / CELL_PX), 0, GRID_W - 1),
		clampi(int(mp.y / CELL_PX), 0, GRID_H - 1))

	var t0 := Time.get_ticks_usec()
	solver.step(SUBSTEPS, not _paused, _mouse_cell.x, _mouse_cell.y)
	_last_step_us = float(Time.get_ticks_usec() - t0)

	# pull the tiny display buffer back, composite the brush overlay, upload
	var bytes := solver.read_display()
	var img := Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, bytes)
	_composite_overlay(img)
	_tex.update(img)

	_update_hud()

	if DEBUG_CAPTURE:
		_debug_tick()


# Paint the brush preview cells and the radius cursor directly into the
# 160x120 image (cell-resolution, matching the blocky aesthetic).
func _composite_overlay(img: Image) -> void:
	if _dragging:
		var col: Color = PRESSURE_PREVIEW if _pressure_mode else MAT_PREVIEW[_brush_material]
		for cell in _painted:
			_blend_px(img, cell.x, cell.y, col)

	# radius cursor: ring of cells at distance ~= brush_radius from the mouse
	var cursor: Color = PRESSURE_PREVIEW if _pressure_mode else Color(1, 1, 1, 0.85)
	var r := _brush_radius
	var steps := maxi(16, int(TAU * r))
	for s in steps:
		var a := TAU * float(s) / float(steps)
		var cx := int(round(_mouse_cell.x + 0.5 + cos(a) * r - 0.5))
		var cy := int(round(_mouse_cell.y + 0.5 + sin(a) * r - 0.5))
		_blend_px(img, cx, cy, cursor)


func _blend_px(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H:
		return
	img.set_pixel(x, y, img.get_pixel(x, y).lerp(col, col.a))


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
	var cell_txt: String = "Water 水" if is_water else MAT_NAMES[clampi(cell_type, 0, 3)]

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
		"  type: %s" % cell_txt,
		"  vel: (%.3f, %.3f)" % [probe[1] if probe.size() > 1 else 0.0, probe[2] if probe.size() > 2 else 0.0],
		"  pressure: %.3f    density: %.2f" % [probe[3] if probe.size() > 3 else 0.0, probe[4] if probe.size() > 4 else 0.0],
		"",
		"[1]vac [2]solid [3]water [4]air [0]pressure  |  wheel=radius",
		"[space]pause  [P]clear vel  [V]clear pressure  |  L-drag=paint",
	]
	_hud.text = "\n".join(lines)
