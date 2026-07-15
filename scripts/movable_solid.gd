class_name MovableSolid
extends RefCounted

# A movable solid body for the fluid sandbox (bottle / lemon chunk / ice cube).
# Geometry lives in grid-cell units. The fluid couples to it purely through a
# per-cell rasterisation (mask + velocity); see main.gd._rasterize_solids and
# the moving-solid boundary in the enforce_solids / project / g2p_advect shaders.
#
# A body is either KINEMATIC (bottle, or any body while grabbed -> pose driven by
# the user) or DYNAMIC (lemon / ice -> pose integrated from gravity + buoyancy).

enum Kind { DRAW, SQUARE, HALFDISK }

var kind: int = Kind.SQUARE
var pos: Vector2 = Vector2.ZERO   # centroid, grid coords (continuous)
var angle: float = 0.0            # radians
var vel: Vector2 = Vector2.ZERO  # cells / s
var omega: float = 0.0           # rad / s
var dynamic: bool = false        # true = physics (float/sink); false = kinematic
var color: Color = Color(0.5, 0.32, 0.15)
var density: float = 1.0         # for buoyancy (vs surrounding rho_cell)

# previous-frame pose (kinematic velocity = pose delta / dt)
var prev_pos: Vector2 = Vector2.ZERO
var prev_angle: float = 0.0

# shape params (in cells)
var half_ext: Vector2 = Vector2(4.0, 4.0)   # SQUARE
var radius: float = 6.0                      # HALFDISK

# DRAW shape: local occupancy bitmap (bw x bh), centroid at (origin) inside it
var bmp: PackedByteArray = PackedByteArray()
var bw: int = 0
var bh: int = 0
var origin: Vector2 = Vector2.ZERO

# cached (filled by finalize())
var bound_r: float = 1.0         # bounding radius for the AABB scan
var area_cells: int = 1          # number of occupied cells (~ mass / density)
var inertia_unit: float = 1.0    # Sum |r|^2 over cells (~ inertia / density)


# Is a point (local frame, relative to centroid, unrotated) inside the shape?
func contains_local(p: Vector2) -> bool:
	match kind:
		Kind.SQUARE:
			return absf(p.x) <= half_ext.x and absf(p.y) <= half_ext.y
		Kind.HALFDISK:
			return p.length() <= radius and p.y <= 0.0
		_:
			var ix := int(round(p.x + origin.x))
			var iy := int(round(p.y + origin.y))
			if ix < 0 or ix >= bw or iy < 0 or iy >= bh:
				return false
			return bmp[ix + iy * bw] != 0


# Precompute bounding radius, area and (unit) rotational inertia by scanning the
# local integer cell grid once. Call after the shape params are set.
func finalize() -> void:
	var R := 1
	match kind:
		Kind.SQUARE:
			R = int(ceil(maxf(half_ext.x, half_ext.y))) + 1
		Kind.HALFDISK:
			R = int(ceil(radius)) + 1
		_:
			R = int(ceil(maxf(float(bw), float(bh)))) + 1
	var n := 0
	var inertia := 0.0
	var maxd2 := 1.0
	for ly in range(-R, R + 1):
		for lx in range(-R, R + 1):
			var lp := Vector2(lx, ly)
			if contains_local(lp):
				n += 1
				var d2 := lp.length_squared()
				inertia += d2
				maxd2 = maxf(maxd2, d2)
	area_cells = maxi(1, n)
	inertia_unit = maxf(1.0, inertia)
	bound_r = sqrt(maxd2) + 1.0


# --- factory helpers ---------------------------------------------------------

static func make_square(p: Vector2, half: float, col: Color, dens: float, dyn: bool) -> MovableSolid:
	var b := MovableSolid.new()
	b.kind = Kind.SQUARE
	b.pos = p
	b.half_ext = Vector2(half, half)
	b.color = col
	b.density = dens
	b.dynamic = dyn
	b.finalize()
	return b


static func make_halfdisk(p: Vector2, r: float, col: Color, dens: float, dyn: bool) -> MovableSolid:
	var b := MovableSolid.new()
	b.kind = Kind.HALFDISK
	b.pos = p
	b.radius = r
	b.color = col
	b.density = dens
	b.dynamic = dyn
	b.finalize()
	return b


# Build a kinematic body from a set of painted cells (Vector2i). Used by the
# key-9 "draw a movable solid" brush (the bottle).
static func make_drawn(cells: Array, col: Color) -> MovableSolid:
	var b := MovableSolid.new()
	b.kind = Kind.DRAW
	b.color = col
	b.dynamic = false
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	var sum := Vector2.ZERO
	for c in cells:
		min_x = mini(min_x, c.x); max_x = maxi(max_x, c.x)
		min_y = mini(min_y, c.y); max_y = maxi(max_y, c.y)
		sum += Vector2(c.x + 0.5, c.y + 0.5)
	b.pos = sum / maxi(1, cells.size())
	b.bw = max_x - min_x + 1
	b.bh = max_y - min_y + 1
	b.bmp = PackedByteArray()
	b.bmp.resize(b.bw * b.bh)   # zero-filled
	# centroid within the bitmap (in local cell coords, so contains_local can map)
	b.origin = Vector2(b.pos.x - float(min_x) - 0.5, b.pos.y - float(min_y) - 0.5)
	for c in cells:
		b.bmp[(c.x - min_x) + (c.y - min_y) * b.bw] = 1
	b.finalize()
	return b
