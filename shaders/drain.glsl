#[compute]
#version 450

// Vacuum acts as a sink: any water particle whose cell is VACUUM is destroyed
// (recycled to the free-list). Dispatched over `capacity` threads.

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

layout(set = 0, binding = 0,  std430) restrict buffer Particles { vec4 particles[]; };
layout(set = 0, binding = 1,  std430) restrict buffer FreeList  { int free_list[]; };
layout(set = 0, binding = 2,  std430) restrict buffer Counters  { int counters[]; };
layout(set = 0, binding = 12, std430) restrict buffer CType     { int cell_type[]; };

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	vec4 p = particles[gid];
	if (p.x < 0.0) return;
	int ci = clamp(int(floor(p.x)), 0, pc.nx - 1);
	int cj = clamp(int(floor(p.y)), 0, pc.ny - 1);
	if (cell_type[ci + cj * pc.nx] != VACUUM) return;

	particles[gid] = vec4(-1.0, -1.0, 0.0, 0.0); // mark dead
	int fc = atomicAdd(counters[0], 1);
	if (fc < pc.capacity) free_list[fc] = int(gid);
}
