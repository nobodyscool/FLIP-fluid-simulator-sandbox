#[compute]
#version 450

// One Jacobi iteration of the VARIABLE-DENSITY pressure Poisson equation on the
// MAC grid: solve  div( (1/rho) grad p ) = div(u*)/dt .  Each neighbour is
// weighted by 1/rho_face (rho_face = mean of the two cell densities), so the
// density difference between liquids produces buoyancy / layering. When all
// densities are equal this reduces exactly to the constant-density stencil.
// Ping-pongs between pressure_a / pressure_b according to jacobi_parity.
//   fluid neighbour  -> uses its current pressure, weight 1/rho_face
//   empty  neighbour -> Ghost-Fluid free surface, p = p_atm, rho_face = rho_c
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
layout(set = 0, binding = 22, std430) restrict buffer RhoCell { float rho_cell[]; };
layout(set = 0, binding = 23, std430) restrict buffer SMask   { int solid_mask[]; };

// Accumulate one neighbour's contribution, weighted by 1/rho_face.
//   sum   += w * p_neighbour   (w = 1/rho_face)
//   denom += w
void neighbour(int ni, int nj, float rho_c, inout float sum, inout float denom) {
	if (ni < 0 || ni >= pc.nx || nj < 0 || nj >= pc.ny) return; // border = solid, drop
	int nc = ni + nj * pc.nx;
	if (cell_type[nc] == SOLID || solid_mask[nc] == 1) return;  // solid (static or movable), drop
	bool nf = fluid_mask[nc] == 1;
	float rho_face = nf ? (0.5 * (rho_c + rho_cell[nc])) : rho_c; // empty -> liquid's own rho
	float w = 1.0 / rho_face;
	denom += w;
	if (nf) {
		sum += w * ((pc.jacobi_parity == 0) ? p_a[nc] : p_b[nc]); // read current source
	} else {
		sum += w * pc.p_atm;                                      // free-surface ghost
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
		float rho_c = rho_cell[c];       // > 0 for a fluid cell
		float sum = 0.0;
		float denom = 0.0;
		neighbour(i - 1, j, rho_c, sum, denom);
		neighbour(i + 1, j, rho_c, sum, denom);
		neighbour(i, j - 1, rho_c, sum, denom);
		neighbour(i, j + 1, rho_c, sum, denom);
		if (denom < 1e-6) {
			result = pc.p_atm;
		} else {
			result = (sum - divergence[c] / pc.phys_dt) / denom;
		}
	}

	if (pc.jacobi_parity == 0) p_b[c] = result; else p_a[c] = result;
}
