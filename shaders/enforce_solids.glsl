#[compute]
#version 450

// No-flow boundary condition: zero any face velocity that touches a solid
// cell or the domain border. Dispatched over max(u_count, v_count) threads.
// Run once before the pressure solve and once after projection.

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

bool is_solid(int i, int j) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return true; // border walls
	return cell_type[i + j * pc.nx] == SOLID;
}

void main() {
	int g = int(gl_GlobalInvocationID.x);

	if (g < pc.u_count) {
		int i = g % (pc.nx + 1);
		int j = g / (pc.nx + 1);
		if (is_solid(i - 1, j) || is_solid(i, j)) grid_u[g] = 0.0;
	}
	if (g < pc.v_count) {
		int i = g % pc.nx;
		int j = g / pc.nx;
		if (is_solid(i, j - 1) || is_solid(i, j)) grid_v[g] = 0.0;
	}
}
