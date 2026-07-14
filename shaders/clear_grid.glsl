#[compute]
#version 450

// Zeros the P2G accumulation buffers at the start of every substep.
// Dispatched over max(u_count, v_count, cell_count) threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

layout(set = 0, binding = 7,  std430) restrict buffer MomU  { int mom_u[]; };
layout(set = 0, binding = 8,  std430) restrict buffer MomV  { int mom_v[]; };
layout(set = 0, binding = 9,  std430) restrict buffer WtU   { int wt_u[]; };
layout(set = 0, binding = 10, std430) restrict buffer WtV   { int wt_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass  { int mass[]; };
layout(set = 0, binding = 13, std430) restrict buffer Fluid { int fluid_mask[]; };

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) < pc.u_count) { mom_u[gid] = 0; wt_u[gid] = 0; }
	if (int(gid) < pc.v_count) { mom_v[gid] = 0; wt_v[gid] = 0; }
	if (int(gid) < pc.cell_count) { mass[gid] = 0; fluid_mask[gid] = 0; }
}
