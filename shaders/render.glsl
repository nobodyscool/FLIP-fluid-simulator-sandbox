#[compute]
#version 450

// Produce a per-cell DATA texture consumed by water_display.gdshader:
//   R = water fullness (density -> foam), 0 for non-fluid
//   G = encoded cell-centre velocity X   (0.5 == 0, scaled by V_MAX)
//   B = encoded cell-centre velocity Y
//   A = base type / liquid code:
//         air=0, solid=85, vacuum=170,
//         fluid = 190 + 20*dominant_phase  (190=water, 210=lemon, 230=honey),
//         which the display shader maps to that liquid's tint (one colour/cell).
// Colour uses the DOMINANT phase (not the average density) so mixed regions read
// as distinct liquids rather than a muddy blend.
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
// Per-phase rest density (must match cell_setup.glsl) for the HUD probe readout.
const float RHO[3] = float[](1.0, 1.4, 2.0);

layout(set = 0, binding = 3,  std430) restrict buffer GridU { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV { float grid_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass  { int mass[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 14, std430) restrict buffer PA    { float p_a[]; };
layout(set = 0, binding = 17, std430) restrict buffer Disp  { uint display[]; };
layout(set = 0, binding = 18, std430) restrict buffer Probe { float probe[]; };
layout(set = 0, binding = 21, std430) restrict buffer PhaseCnt { int phase_count[]; };

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

	// R = per-cell "fullness" (particle count): 0 = no water, small = thin/surface/
	// spray, 1 = deep packed. Drives the per-cell foam (thin -> whiter).
	float density = float(mass[c]) / pc.fixed_scale;
	float fullness = clamp(density / FOAM_REF, 0.0, 1.0);
	int r = (fluid_mask[c] == 1) ? max(1, int(fullness * 255.0 + 0.5)) : 0;

	// Dominant phase in the cell (argmax of the three counts) drives the colour.
	int c0 = phase_count[3 * c + 0];
	int c1 = phase_count[3 * c + 1];
	int c2 = phase_count[3 * c + 2];
	int dom = (c1 > c0) ? 1 : 0;
	if (c2 > ((dom == 1) ? c1 : c0)) dom = 2;

	// A = liquid code (190/210/230) for fluid cells, else the base type.
	int a;
	if (fluid_mask[c] == 1) {
		a = 190 + 20 * dom;
	} else {
		a = (t == SOLID) ? 85 : ((t == VACUUM) ? 170 : 0);
	}
	display[c] = pack(r, enc_vel(uc), enc_vel(vc), a);

	if (i == pc.mouse_cx && j == pc.mouse_cy) {
		int n = c0 + c1 + c2;
		float rho = (n > 0) ? (RHO[0] * float(c0) + RHO[1] * float(c1) + RHO[2] * float(c2)) / float(n) : 0.0;
		probe[0] = float(t);
		probe[1] = uc;
		probe[2] = vc;
		probe[3] = p_a[c];
		probe[4] = float(mass[c]) / pc.fixed_scale;
		probe[5] = float(fluid_mask[c]);
		probe[6] = rho;                     // physical cell density (liquid id)
	}
}
