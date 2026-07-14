#[compute]
#version 450

// Colourise each cell into a packed RGBA8 value for display (nearest-filtered
// upscale gives the crisp 10x10 blocks). Also writes the probed cell's physical
// fields into `probe` for the HUD. Dispatched over cell_count threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

const int VACUUM = 0;
const int SOLID  = 1;
const int AIR    = 3;

layout(set = 0, binding = 3,  std430) restrict buffer GridU { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV { float grid_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass  { int mass[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType { int cell_type[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };
layout(set = 0, binding = 14, std430) restrict buffer PA    { float p_a[]; };
layout(set = 0, binding = 17, std430) restrict buffer Disp  { uint display[]; };
layout(set = 0, binding = 18, std430) restrict buffer Probe { float probe[]; };

uint pack(int r, int g, int b) { return uint(r) | (uint(g) << 8) | (uint(b) << 16) | (255u << 24); }

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	int i = c % pc.nx;
	int j = c / pc.nx;
	int t = cell_type[c];

	uint col;
	if (t == SOLID) {
		col = pack(64, 64, 64);            // dark gray
	} else if (fluid_mask[c] == 1) {
		col = pack(38, 108, 230);          // water blue
	} else if (t == AIR) {
		col = pack(128, 128, 128);         // gray
	} else {
		col = pack(0, 0, 0);               // vacuum black
	}
	display[c] = col;

	// HUD probe for the cell under the mouse.
	if (i == pc.mouse_cx && j == pc.mouse_cy) {
		float uc = 0.5 * (grid_u[i + j * (pc.nx + 1)] + grid_u[(i + 1) + j * (pc.nx + 1)]);
		float vc = 0.5 * (grid_v[i + j * pc.nx] + grid_v[i + (j + 1) * pc.nx]);
		probe[0] = float(t);
		probe[1] = uc;
		probe[2] = vc;
		probe[3] = p_a[c];
		probe[4] = float(mass[c]) / pc.fixed_scale;
		probe[5] = float(fluid_mask[c]);
	}
}
