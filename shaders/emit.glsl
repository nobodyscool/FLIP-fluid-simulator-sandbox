#[compute]
#version 450

// Emit water particles into the painted (brush_mask) cells on commit.
// One thread per cell; each masked non-solid cell pops `ppc` slots from the
// free-list stack and seeds jittered particles. Dispatched over cell_count.

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
layout(set = 0, binding = 1,  std430) restrict buffer FreeList  { int free_list[]; };
layout(set = 0, binding = 2,  std430) restrict buffer Counters  { int counters[]; }; // [0]=free_count
layout(set = 0, binding = 12, std430) restrict buffer CType     { int cell_type[]; };
layout(set = 0, binding = 19, std430) restrict buffer BrushMask { int brush_mask[]; };
layout(set = 0, binding = 20, std430) restrict buffer Phase     { int phase[]; };

// Map the brush material code to a liquid phase id (see main.gd / FlipFluidGPU):
//   2 = water -> 0,  4 = lemon juice -> 1,  5 = honey -> 2.
int material_phase(int m) { return (m == 2) ? 0 : ((m == 4) ? 1 : 2); }

uint hash(uint x) { x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16; return x; }
float rnd(inout uint s) { s = hash(s); return float(s) * (1.0 / 4294967296.0); }

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	if (brush_mask[c] != 1) return;
	if (cell_type[c] == SOLID) return;

	int i = c % pc.nx;
	int j = c / pc.nx;
	uint seed = hash(pc.rng_seed ^ uint(c) * 2654435761U);
	int ph = material_phase(pc.brush_material);

	for (int k = 0; k < pc.ppc; ++k) {
		int fc = atomicAdd(counters[0], -1);
		int top = fc - 1;
		if (top < 0) { atomicAdd(counters[0], 1); return; } // pool exhausted
		int slot = free_list[top];
		float rx = rnd(seed);
		float ry = rnd(seed);
		particles[slot] = vec4(float(i) + rx, float(j) + ry, 0.0, 0.0);
		phase[slot] = ph;
	}
}
