#[compute]
#version 450

// Produce a per-cell DATA texture consumed by water_display.gdshader:
//   R = water coverage (255 if the cell holds fluid, else 0)
//   G = encoded cell-centre velocity X   (0.5 == 0, scaled by V_MAX)
//   B = encoded cell-centre velocity Y
//   A = base type code: air=0, solid=85, vacuum=170
// Also writes the probed cell's physical fields for the HUD.
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

const int SOLID  = 1;
const int VACUUM = 0;
const float V_MAX = 60.0;      // velocity scale used for the refraction encoding
const float FOAM_REF = 18.0;   // particle count treated as a "full/deep" cell

layout(set = 0, binding = 3,  std430) restrict buffer GridU { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV { float grid_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass  { int mass[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 14, std430) restrict buffer PA    { float p_a[]; };
layout(set = 0, binding = 17, std430) restrict buffer Disp  { uint display[]; };
layout(set = 0, binding = 18, std430) restrict buffer Probe { float probe[]; };

uint pack(int r, int g, int b, int a) {
	return uint(r) | (uint(g) << 8) | (uint(b) << 16) | (uint(a) << 24);
}
int enc_vel(float v) {
	return int(clamp(clamp(v / V_MAX, -1.0, 1.0) * 0.5 + 0.5, 0.0, 1.0) * 255.0 + 0.5);
}

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	int i = c % pc.nx;
	int j = c / pc.nx;
	int t = cell_type[c];

	float uc = 0.5 * (grid_u[i + j * (pc.nx + 1)] + grid_u[(i + 1) + j * (pc.nx + 1)]);
	float vc = 0.5 * (grid_v[i + j * pc.nx] + grid_v[i + (j + 1) * pc.nx]);

	// R = per-cell "fullness" (density): 0 = no water, small = thin/surface/spray,
	// 1 = deep packed water. Drives the per-cell foam (thin -> whiter).
	float density = float(mass[c]) / pc.fixed_scale;
	float fullness = clamp(density / FOAM_REF, 0.0, 1.0);
	int r = (fluid_mask[c] == 1) ? max(1, int(fullness * 255.0 + 0.5)) : 0;
	int a = (t == SOLID) ? 85 : ((t == VACUUM) ? 170 : 0);
	display[c] = pack(r, enc_vel(uc), enc_vel(vc), a);

	if (i == pc.mouse_cx && j == pc.mouse_cy) {
		probe[0] = float(t);
		probe[1] = uc;
		probe[2] = vc;
		probe[3] = p_a[c];
		probe[4] = float(mass[c]) / pc.fixed_scale;
		probe[5] = float(fluid_mask[c]);
	}
}
