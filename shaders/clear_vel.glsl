#[compute]
#version 450

// Zero every particle's velocity (P key). Grid velocity buffers are cleared
// separately on the CPU side with buffer_clear. Dispatched over `capacity`.

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

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	vec4 p = particles[gid];
	if (p.x < 0.0) return;
	particles[gid] = vec4(p.xy, 0.0, 0.0);
}
