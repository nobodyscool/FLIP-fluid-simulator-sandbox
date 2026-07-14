#[compute]
#version 450

// Per-cell pre-solve setup: classify fluid cells (non-solid cells that contain
// particle mass) and compute the velocity divergence used as the pressure RHS.
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

layout(set = 0, binding = 3,  std430) restrict buffer GridU { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV { float grid_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass  { int mass[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 16, std430) restrict buffer Div   { float divergence[]; };
layout(set = 0, binding = 21, std430) restrict buffer PhaseCnt { int phase_count[]; };
layout(set = 0, binding = 22, std430) restrict buffer RhoCell  { float rho_cell[]; };

// Per-phase rest density (must match render.glsl): 0=water 1=lemon-juice 2=honey.
const float RHO[3] = float[](1.0, 1.4, 2.0);

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	int i = c % pc.nx;
	int j = c / pc.nx;

	bool fluid = (cell_type[c] != SOLID) && (mass[c] > 0);
	fluid_mask[c] = fluid ? 1 : 0;

	// Per-cell density = count-weighted average of the phase densities. Non-fluid
	// cells get 0. Drives the variable-density pressure solve (buoyancy/layering).
	int c0 = phase_count[3 * c + 0];
	int c1 = phase_count[3 * c + 1];
	int c2 = phase_count[3 * c + 2];
	int n = c0 + c1 + c2;
	rho_cell[c] = (fluid && n > 0)
		? (RHO[0] * float(c0) + RHO[1] * float(c1) + RHO[2] * float(c2)) / float(n)
		: 0.0;

	if (fluid) {
		float uL = grid_u[i + j * (pc.nx + 1)];
		float uR = grid_u[(i + 1) + j * (pc.nx + 1)];
		float vB = grid_v[i + j * pc.nx];
		float vT = grid_v[i + (j + 1) * pc.nx];
		divergence[c] = (uR - uL) + (vT - vB);
	} else {
		divergence[c] = 0.0;
	}
}
