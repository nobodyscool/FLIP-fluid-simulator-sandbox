#[compute]
#version 450

// Grid-to-Particle transfer + advection. Interpolates the new (projected) grid
// velocity and the saved pre-force velocity, blends FLIP/PIC, then advects the
// particle with RK2 and resolves solid collisions separably.
// Dispatched over `capacity` threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

const int SOLID = 1;

layout(set = 0, binding = 0,  std430) restrict buffer Particles { vec4 particles[]; };
layout(set = 0, binding = 3,  std430) restrict buffer GridU  { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV  { float grid_v[]; };
layout(set = 0, binding = 5,  std430) restrict buffer GridUO { float grid_u_old[]; };
layout(set = 0, binding = 6,  std430) restrict buffer GridVO { float grid_v_old[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType  { int cell_type[]; };
layout(set = 0, binding = 23, std430) restrict buffer SMask  { int solid_mask[]; };
layout(set = 0, binding = 24, std430) restrict buffer SVel   { float solid_vel[]; };

bool is_solid(int i, int j) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return true;
	int c = i + j * pc.nx;
	return cell_type[c] == SOLID || solid_mask[c] == 1;
}
// Wall velocity component at cell (i,j): the movable solid's velocity if any,
// else 0 (static solid / border). axis 0 = x, 1 = y.
float wall_vel(int i, int j, int axis) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return 0.0;
	int c = i + j * pc.nx;
	return (solid_mask[c] == 1) ? solid_vel[2 * c + axis] : 0.0;
}

// Returns vec2(new_velocity, old_velocity) for the U component at pos.
vec2 sample_u_pair(vec2 pos) {
	float gx = pos.x;
	float gy = pos.y - 0.5;
	int i0 = clamp(int(floor(gx)), 0, pc.nx - 1);
	int j0 = clamp(int(floor(gy)), 0, pc.ny - 2);
	float fx = clamp(gx - float(i0), 0.0, 1.0);
	float fy = clamp(gy - float(j0), 0.0, 1.0);
	int s = pc.nx + 1;
	int a = i0 + j0 * s, b = (i0 + 1) + j0 * s, c = i0 + (j0 + 1) * s, d = (i0 + 1) + (j0 + 1) * s;
	float w00 = (1.0 - fx) * (1.0 - fy), w10 = fx * (1.0 - fy);
	float w01 = (1.0 - fx) * fy,         w11 = fx * fy;
	float nu = grid_u[a] * w00 + grid_u[b] * w10 + grid_u[c] * w01 + grid_u[d] * w11;
	float ou = grid_u_old[a] * w00 + grid_u_old[b] * w10 + grid_u_old[c] * w01 + grid_u_old[d] * w11;
	return vec2(nu, ou);
}

// Returns vec2(new_velocity, old_velocity) for the V component at pos.
vec2 sample_v_pair(vec2 pos) {
	float gx = pos.x - 0.5;
	float gy = pos.y;
	int i0 = clamp(int(floor(gx)), 0, pc.nx - 2);
	int j0 = clamp(int(floor(gy)), 0, pc.ny - 1);
	float fx = clamp(gx - float(i0), 0.0, 1.0);
	float fy = clamp(gy - float(j0), 0.0, 1.0);
	int s = pc.nx;
	int a = i0 + j0 * s, b = (i0 + 1) + j0 * s, c = i0 + (j0 + 1) * s, d = (i0 + 1) + (j0 + 1) * s;
	float w00 = (1.0 - fx) * (1.0 - fy), w10 = fx * (1.0 - fy);
	float w01 = (1.0 - fx) * fy,         w11 = fx * fy;
	float nv = grid_v[a] * w00 + grid_v[b] * w10 + grid_v[c] * w01 + grid_v[d] * w11;
	float ov = grid_v_old[a] * w00 + grid_v_old[b] * w10 + grid_v_old[c] * w01 + grid_v_old[d] * w11;
	return vec2(nv, ov);
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	vec4 p = particles[gid];
	if (p.x < 0.0) return;
	vec2 pos = p.xy;
	vec2 vel = p.zw;

	vec2 up = sample_u_pair(pos);
	vec2 vp = sample_v_pair(pos);
	vec2 v_pic = vec2(up.x, vp.x);
	vec2 v_old = vec2(up.y, vp.y);
	vec2 v_flip = vel + (v_pic - v_old);
	vec2 v_new = mix(v_pic, v_flip, pc.flip_ratio);

	vec2 lo = vec2(0.501, 0.501);
	vec2 hi = vec2(float(pc.nx) - 0.501, float(pc.ny) - 0.501);

	// RK2 advection through the projected velocity field.
	vec2 mid = clamp(pos + 0.5 * pc.phys_dt * v_new, lo, hi);
	vec2 v_mid = vec2(sample_u_pair(mid).x, sample_v_pair(mid).x);
	vec2 npos = clamp(pos + pc.phys_dt * v_mid, lo, hi);

	// Separable solid collision: cancel the component that enters a solid cell and
	// adopt the wall's velocity there (so a moving solid carries / pushes liquid).
	float nxp = npos.x;
	int sx = int(floor(nxp)), sy = int(floor(pos.y));
	if (is_solid(sx, sy)) { nxp = pos.x; v_new.x = wall_vel(sx, sy, 0); }
	float nyp = npos.y;
	int tx = int(floor(nxp)), ty = int(floor(nyp));
	if (is_solid(tx, ty)) { nyp = pos.y; v_new.y = wall_vel(tx, ty, 1); }

	particles[gid] = vec4(nxp, nyp, v_new.x, v_new.y);
}
