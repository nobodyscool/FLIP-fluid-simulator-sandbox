#[compute]
#version 450

// One Jacobi iteration of the pressure Poisson equation on the MAC grid.
// Ping-pongs between pressure_a / pressure_b according to jacobi_parity.
//   fluid neighbour  -> uses its current pressure
//   empty  neighbour -> Ghost-Fluid free surface, pressure = p_atm (Dirichlet)
//   solid  neighbour -> Neumann, dropped from the stencil
// Dispatched over cell_count threads.

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

layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 14, std430) restrict buffer PA    { float p_a[]; };
layout(set = 0, binding = 15, std430) restrict buffer PB    { float p_b[]; };
layout(set = 0, binding = 16, std430) restrict buffer Div   { float divergence[]; };

// Accumulate one neighbour's contribution to the stencil.
void neighbour(int ni, int nj, inout float sum, inout float count) {
	if (ni < 0 || ni >= pc.nx || nj < 0 || nj >= pc.ny) return; // border = solid, drop
	int nc = ni + nj * pc.nx;
	if (cell_type[nc] == SOLID) return;                         // solid, drop
	count += 1.0;
	if (fluid_mask[nc] == 1) {
		sum += (pc.jacobi_parity == 0) ? p_a[nc] : p_b[nc];     // read current source
	} else {
		sum += pc.p_atm;                                        // free-surface ghost
	}
}

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	int i = c % pc.nx;
	int j = c / pc.nx;

	// parity 0: read A write B ; parity 1: read B write A
	float result;
	if (fluid_mask[c] != 1) {
		result = (cell_type[c] == SOLID) ? 0.0 : pc.p_atm;
	} else {
		float sum = 0.0;
		float count = 0.0;
		neighbour(i - 1, j, sum, count);
		neighbour(i + 1, j, sum, count);
		neighbour(i, j - 1, sum, count);
		neighbour(i, j + 1, sum, count);
		if (count < 0.5) {
			result = pc.p_atm;
		} else {
			result = (sum - divergence[c] / pc.phys_dt) / count;
		}
	}

	if (pc.jacobi_parity == 0) p_b[c] = result; else p_a[c] = result;
}
