#[compute]
#version 450

// One-time particle pool initialisation: mark every slot dead and fill the
// free-list stack with all slot indices. counters[0] (free_count) is uploaded
// separately from the CPU. Dispatched over `capacity` threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

layout(set = 0, binding = 0, std430) restrict buffer Particles { vec4 particles[]; };
layout(set = 0, binding = 1, std430) restrict buffer FreeList  { int free_list[]; };

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	particles[gid] = vec4(-1.0, -1.0, 0.0, 0.0);
	free_list[gid] = int(gid);
}
