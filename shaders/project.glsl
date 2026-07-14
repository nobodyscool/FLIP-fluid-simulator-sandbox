#[compute]
#version 450

// Pressure projection: subtract the pressure gradient from the face velocities
// to make the fluid divergence-free. Empty (air/vacuum) neighbours contribute
// the ghost pressure p_atm; solid faces stay closed (velocity 0).
// The converged pressure lives in pressure_a. Dispatched over max(u,v) faces.

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
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 14, std430) restrict buffer PA    { float p_a[]; };
layout(set = 0, binding = 22, std430) restrict buffer RhoCell { float rho_cell[]; };

bool solid(int i, int j) {
	if (i < 0 || i >= pc.nx || j < 0 || j >= pc.ny) return true;
	return cell_type[i + j * pc.nx] == SOLID;
}
float pressure_of(int i, int j) {
	int c = i + j * pc.nx;
	return (fluid_mask[c] == 1) ? p_a[c] : pc.p_atm; // ghost = p_atm in empty cells
}
// Face density = mean of the adjacent fluid cell densities (variable-density
// projection). At a liquid/empty face use the liquid's own density. The caller
// guarantees at least one side is fluid.
float rho_face(int ia, int ja, int ib, int jb) {
	int ca = ia + ja * pc.nx;
	int cb = ib + jb * pc.nx;
	bool fa = fluid_mask[ca] == 1;
	bool fb = fluid_mask[cb] == 1;
	if (fa && fb) return 0.5 * (rho_cell[ca] + rho_cell[cb]);
	return fa ? rho_cell[ca] : rho_cell[cb];
}

void main() {
	int g = int(gl_GlobalInvocationID.x);

	if (g < pc.u_count) {
		int i = g % (pc.nx + 1);
		int j = g / (pc.nx + 1);
		if (i == 0 || i == pc.nx || solid(i - 1, j) || solid(i, j)) {
			grid_u[g] = 0.0;
		} else {
			bool lf = fluid_mask[(i - 1) + j * pc.nx] == 1;
			bool rf = fluid_mask[i + j * pc.nx] == 1;
			if (lf || rf) {
				float pL = pressure_of(i - 1, j);
				float pR = pressure_of(i, j);
				grid_u[g] -= pc.phys_dt * (pR - pL) / rho_face(i - 1, j, i, j);
			}
		}
	}
	if (g < pc.v_count) {
		int i = g % pc.nx;
		int j = g / pc.nx;
		if (j == 0 || j == pc.ny || solid(i, j - 1) || solid(i, j)) {
			grid_v[g] = 0.0;
		} else {
			bool bf = fluid_mask[i + (j - 1) * pc.nx] == 1;
			bool tf = fluid_mask[i + j * pc.nx] == 1;
			if (bf || tf) {
				float pB = pressure_of(i, j - 1);
				float pT = pressure_of(i, j);
				grid_v[g] -= pc.phys_dt * (pT - pB) / rho_face(i, j - 1, i, j);
			}
		}
	}
}
