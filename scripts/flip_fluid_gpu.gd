class_name FlipFluidGPU
extends RefCounted

# GPU FLIP/PIC single-phase fluid solver on a local RenderingDevice.
# All simulation state (1M+ particles, MAC grid) lives in GPU storage buffers;
# only the 160x120 display buffer and a 1-cell probe are read back per frame.
# See docs/DESIGN.md for the data layout and algorithm.

# --- material codes ---
# 0..3 double as stored cell_type values; 2/4/5 are liquid "brush" materials
# (liquids are represented by particles + a per-particle phase, not a cell type).
const T_VACUUM := 0
const T_SOLID  := 1
const T_WATER  := 2   # phase 0 (rho 1.0)
const T_AIR    := 3
const T_LEMON  := 4   # phase 1 (rho 1.4, denser than water)
const T_HONEY  := 5   # phase 2 (rho 2.0, densest)

# --- grid dimensions ---
var nx: int
var ny: int
var u_count: int      # (nx+1)*ny  vertical faces (VelocityX)
var v_count: int      # nx*(ny+1)  horizontal faces (VelocityY)
var cell_count: int   # nx*ny

# --- tunable parameters (set before init, some live) ---
var capacity: int = 1048576      # particle pool size ("particle total")
var phys_dt: float = 1.0 / 240.0 # fixed substep length
var gravity: float = 40.0        # cells / s^2 (down = +y)
var flip_ratio: float = 0.90     # 1 = full FLIP, 0 = full PIC
var p_atm: float = 3.0           # free-surface reference pressure
var jacobi_iters: int = 60
var fixed_scale: float = 4096.0  # fixed-point atomic scale
var emit_ppc: int = 16           # particles seeded per cell on a water stroke

var rd: RenderingDevice

# buffers keyed by global binding index
var _buf := {}
# pipelines / shaders / uniform-sets keyed by name
var _shader := {}
var _pipeline := {}
var _uset := {}

var _shader_bindings := {
	"init_pool":       [0, 1, 20],
	"clear_grid":      [7, 8, 9, 10, 11, 13, 21],
	"p2g":             [0, 7, 8, 9, 10, 11, 20, 21],
	"normalize":       [3, 4, 5, 6, 7, 8, 9, 10],
	"enforce_solids":  [3, 4, 12, 23, 24],
	"cell_setup":      [3, 4, 11, 12, 13, 16, 21, 22, 23],
	"jacobi":          [12, 13, 14, 15, 16, 22, 23],
	"project":         [3, 4, 12, 13, 14, 22, 23],
	"g2p_advect":      [0, 3, 4, 5, 6, 12, 23, 24],
	"drain":           [0, 1, 2, 12],
	"emit":            [0, 1, 2, 12, 19, 20],
	"free_particles":  [0, 1, 2, 19],
	"brush_apply":     [12, 19],
	"pressure_impulse":[0, 19],
	"clear_vel":       [0],
	"render":          [3, 4, 11, 12, 13, 14, 17, 18, 21],
}

# transient push-constant fields updated per dispatch
var _jacobi_parity := 0
var _brush_material := 0
var _brush_cx := 0.0
var _brush_cy := 0.0
var _brush_radius := 0.0
var _brush_value := 0.0
var _brush_mode := 0
var _emit_count := 0
var _rng_seed := 0
var _mouse_cx := -1
var _mouse_cy := -1
var _clear_mode := 0


func init_solver(grid_w: int, grid_h: int) -> void:
	nx = grid_w
	ny = grid_h
	u_count = (nx + 1) * ny
	v_count = nx * (ny + 1)
	cell_count = nx * ny

	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("FlipFluidGPU: could not create a local RenderingDevice.")
		return

	_create_buffers()
	_load_shaders()
	_create_uniform_sets()
	_init_pool()


func _create_buffers() -> void:
	# floats/ints are 4 bytes each; vec4 particle = 16 bytes.
	_buf[0]  = _new_buf(capacity * 16)          # particles (vec4)
	_buf[1]  = _new_buf(capacity * 4)           # free_list (int)
	_buf[2]  = _new_buf_data(_ints([capacity, 0, 0, 0]))  # counters
	_buf[3]  = _new_buf(u_count * 4)            # grid_u
	_buf[4]  = _new_buf(v_count * 4)            # grid_v
	_buf[5]  = _new_buf(u_count * 4)            # grid_u_old
	_buf[6]  = _new_buf(v_count * 4)            # grid_v_old
	_buf[7]  = _new_buf(u_count * 4)            # mom_u
	_buf[8]  = _new_buf(v_count * 4)            # mom_v
	_buf[9]  = _new_buf(u_count * 4)            # wt_u
	_buf[10] = _new_buf(v_count * 4)            # wt_v
	_buf[11] = _new_buf(cell_count * 4)         # mass
	_buf[12] = _new_buf_data(_filled(cell_count, T_AIR))  # cell_type (default air)
	_buf[13] = _new_buf(cell_count * 4)         # fluid_mask
	_buf[14] = _new_buf(cell_count * 4)         # pressure_a
	_buf[15] = _new_buf(cell_count * 4)         # pressure_b
	_buf[16] = _new_buf(cell_count * 4)         # divergence
	_buf[17] = _new_buf(cell_count * 4)         # display (packed RGBA8)
	_buf[18] = _new_buf(8 * 4)                  # probe
	_buf[19] = _new_buf(cell_count * 4)         # brush_mask
	_buf[20] = _new_buf(capacity * 4)           # phase (per-particle liquid id)
	_buf[21] = _new_buf(cell_count * 3 * 4)     # phase_count (3 per-cell counts)
	_buf[22] = _new_buf(cell_count * 4)         # rho_cell (per-cell density, float)
	_buf[23] = _new_buf(cell_count * 4)         # solid_mask (movable solid this frame)
	_buf[24] = _new_buf(cell_count * 2 * 4)     # solid_vel (movable solid velocity, vec2)


func _new_buf(size_bytes: int) -> RID:
	var zero := PackedByteArray()
	zero.resize(size_bytes)   # zero-filled
	return rd.storage_buffer_create(size_bytes, zero)


func _new_buf_data(data: PackedByteArray) -> RID:
	return rd.storage_buffer_create(data.size(), data)


func _ints(values: Array) -> PackedByteArray:
	var pa := PackedByteArray()
	pa.resize(values.size() * 4)
	for i in values.size():
		pa.encode_s32(i * 4, int(values[i]))
	return pa


func _filled(count: int, value: int) -> PackedByteArray:
	var pa := PackedByteArray()
	pa.resize(count * 4)
	for i in count:
		pa.encode_s32(i * 4, value)
	return pa


func _load_shaders() -> void:
	for name in _shader_bindings.keys():
		var file: RDShaderFile = load("res://shaders/%s.glsl" % name)
		var spirv := file.get_spirv()
		var sh := rd.shader_create_from_spirv(spirv)
		_shader[name] = sh
		_pipeline[name] = rd.compute_pipeline_create(sh)


func _create_uniform_sets() -> void:
	for name in _shader_bindings.keys():
		var uniforms: Array[RDUniform] = []
		for b in _shader_bindings[name]:
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = b
			u.add_id(_buf[b])
			uniforms.append(u)
		_uset[name] = rd.uniform_set_create(uniforms, _shader[name], 0)


func _pack_params() -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(96)
	p.encode_s32(0, nx)
	p.encode_s32(4, ny)
	p.encode_s32(8, u_count)
	p.encode_s32(12, v_count)
	p.encode_s32(16, cell_count)
	p.encode_s32(20, capacity)
	p.encode_float(24, phys_dt)
	p.encode_float(28, gravity)
	p.encode_float(32, flip_ratio)
	p.encode_float(36, p_atm)
	p.encode_float(40, fixed_scale)
	p.encode_s32(44, _jacobi_parity)
	p.encode_s32(48, _brush_material)
	p.encode_float(52, _brush_cx)
	p.encode_float(56, _brush_cy)
	p.encode_float(60, _brush_radius)
	p.encode_float(64, _brush_value)
	p.encode_s32(68, _brush_mode)
	p.encode_s32(72, _emit_count)
	p.encode_s32(76, emit_ppc)
	p.encode_u32(80, _rng_seed)
	p.encode_s32(84, _mouse_cx)
	p.encode_s32(88, _mouse_cy)
	p.encode_s32(92, _clear_mode)
	return p


func _groups(count: int) -> int:
	return int(ceil(float(count) / 256.0))


# Record one dispatch into an open compute list, followed by a full barrier.
func _dispatch(cl: int, name: String, groups: int) -> void:
	rd.compute_list_bind_compute_pipeline(cl, _pipeline[name])
	rd.compute_list_bind_uniform_set(cl, _uset[name], 0)
	var pc := _pack_params()
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _init_pool() -> void:
	var cl := rd.compute_list_begin()
	_dispatch(cl, "init_pool", _groups(capacity))
	rd.compute_list_end()
	rd.submit()
	rd.sync()


# --- one rendered frame: `substeps` physics steps (if running) then render ---
func step(substeps: int, run_physics: bool, mouse_cx: int, mouse_cy: int) -> void:
	_mouse_cx = mouse_cx
	_mouse_cy = mouse_cy
	var pgroups := _groups(capacity)
	var fgroups := _groups(max(u_count, max(v_count, cell_count)))
	var cgroups := _groups(cell_count)

	var cl := rd.compute_list_begin()
	if run_physics:
		for s in substeps:
			_dispatch(cl, "clear_grid", fgroups)
			_dispatch(cl, "p2g", pgroups)
			_dispatch(cl, "normalize", fgroups)
			_dispatch(cl, "enforce_solids", fgroups)
			_dispatch(cl, "cell_setup", cgroups)
			for k in jacobi_iters:
				_jacobi_parity = k % 2
				_dispatch(cl, "jacobi", cgroups)
			_dispatch(cl, "project", fgroups)
			_dispatch(cl, "enforce_solids", fgroups)
			_dispatch(cl, "g2p_advect", pgroups)
			_dispatch(cl, "drain", pgroups)      # vacuum destroys water
	_dispatch(cl, "render", cgroups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func commit_brush(mask: PackedByteArray, material: int, mode: int, value: float,
		centroid: Vector2, seed_val: int) -> void:
	rd.buffer_update(_buf[19], 0, mask.size(), mask)
	_brush_material = material
	_brush_mode = mode
	_brush_value = value
	_brush_cx = centroid.x
	_brush_cy = centroid.y
	_rng_seed = seed_val
	var pgroups := _groups(capacity)
	var cgroups := _groups(cell_count)

	var cl := rd.compute_list_begin()
	if mode == 1:
		# pressure brush -> velocity impulse on the affected particles
		_dispatch(cl, "pressure_impulse", pgroups)
	elif material == T_WATER or material == T_LEMON or material == T_HONEY:
		# any liquid: emit particles carrying the material's phase (set in emit.glsl)
		_dispatch(cl, "emit", cgroups)
	else:
		# vacuum / solid / air: recycle covered particles, then stamp the type
		_dispatch(cl, "free_particles", pgroups)
		_dispatch(cl, "brush_apply", cgroups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


# Upload this frame's movable-solid rasterisation (mask + per-cell velocity).
# mask: int[cell_count] (1 = movable solid); vel: float[cell_count*2] (vx,vy).
func upload_solids(mask: PackedByteArray, vel: PackedByteArray) -> void:
	rd.buffer_update(_buf[23], 0, mask.size(), mask)
	rd.buffer_update(_buf[24], 0, vel.size(), vel)


func clear_velocity() -> void:
	rd.buffer_clear(_buf[3], 0, u_count * 4)
	rd.buffer_clear(_buf[4], 0, v_count * 4)
	rd.buffer_clear(_buf[5], 0, u_count * 4)
	rd.buffer_clear(_buf[6], 0, v_count * 4)
	var cl := rd.compute_list_begin()
	_dispatch(cl, "clear_vel", _groups(capacity))
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func clear_pressure() -> void:
	rd.buffer_clear(_buf[14], 0, cell_count * 4)
	rd.buffer_clear(_buf[15], 0, cell_count * 4)


func read_display() -> PackedByteArray:
	return rd.buffer_get_data(_buf[17])


func read_probe() -> PackedFloat32Array:
	return rd.buffer_get_data(_buf[18]).to_float32_array()


func active_particles() -> int:
	var c := rd.buffer_get_data(_buf[2]).to_int32_array()
	return capacity - c[0]   # capacity - free_count


func cleanup() -> void:
	if rd == null:
		return
	for k in _buf.keys():
		rd.free_rid(_buf[k])
	for k in _pipeline.keys():
		rd.free_rid(_pipeline[k])
	for k in _shader.keys():
		rd.free_rid(_shader[k])
	rd.free()
	rd = null
