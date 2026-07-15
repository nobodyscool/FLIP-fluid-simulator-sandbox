#[compute]
#version 450

// No-flow / moving-solid boundary: set any face touching a wall to that wall's
// velocity -- 0 for static solids and the domain border, the movable solid's
// velocity for dynamic (rasterised) solids. Run before the pressure solve and
// after projection. Dispatched over max(u_count, v_count) threads.

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

layout(set = 0, binding = 3,  std430) restrict buffer GridU { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV { float grid_v[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 23, std430) restrict buffer SMask { int solid_mask[]; };
layout(set = 0, binding = 24, std430) restrict buffer SVel  { float solid_vel[]; };

bool static_solid(int i, int j) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return true; // border walls
	return cell_type[i + j * pc.nx] == SOLID;
}
bool movable(int i, int j) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return false;
	return solid_mask[i + j * pc.nx] == 1;
}

void main() {
	int g = int(gl_GlobalInvocationID.x);

	if (g < pc.u_count) {
		int i = g % (pc.nx + 1);
		int j = g / (pc.nx + 1);
		bool wl = static_solid(i - 1, j) || movable(i - 1, j);
		bool wr = static_solid(i, j)     || movable(i, j);
		if (wl || wr) {
			float vx = 0.0;
			if (movable(i - 1, j))    vx = solid_vel[2 * ((i - 1) + j * pc.nx)];
			else if (movable(i, j))   vx = solid_vel[2 * (i + j * pc.nx)];
			grid_u[g] = vx;
		}
	}
	if (g < pc.v_count) {
		int i = g % pc.nx;
		int j = g / pc.nx;
		bool wb = static_solid(i, j - 1) || movable(i, j - 1);
		bool wt = static_solid(i, j)     || movable(i, j);
		if (wb || wt) {
			float vy = 0.0;
			if (movable(i, j - 1))    vy = solid_vel[2 * (i + (j - 1) * pc.nx) + 1];
			else if (movable(i, j))   vy = solid_vel[2 * (i + j * pc.nx) + 1];
			grid_v[g] = vy;
		}
	}
}
