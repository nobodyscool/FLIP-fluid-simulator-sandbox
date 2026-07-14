#[compute]
#version 450

// Normalize accumulated momentum by weight to obtain grid face velocities.
// Saves the pre-force velocity (for the FLIP delta) and then applies gravity
// to the V (vertical) faces. Dispatched over max(u_count, v_count) threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

layout(set = 0, binding = 3,  std430) restrict buffer GridU  { float grid_u[]; };
layout(set = 0, binding = 4,  std430) restrict buffer GridV  { float grid_v[]; };
layout(set = 0, binding = 5,  std430) restrict buffer GridUO { float grid_u_old[]; };
layout(set = 0, binding = 6,  std430) restrict buffer GridVO { float grid_v_old[]; };
layout(set = 0, binding = 7,  std430) restrict buffer MomU { int mom_u[]; };
layout(set = 0, binding = 8,  std430) restrict buffer MomV { int mom_v[]; };
layout(set = 0, binding = 9,  std430) restrict buffer WtU  { int wt_u[]; };
layout(set = 0, binding = 10, std430) restrict buffer WtV  { int wt_v[]; };

void main() {
	uint gid = gl_GlobalInvocationID.x;
	int g = int(gid);

	if (g < pc.u_count) {
		float w = float(wt_u[g]) / pc.fixed_scale;
		float vel = (w > 1e-6) ? (float(mom_u[g]) / pc.fixed_scale) / w : 0.0;
		grid_u[g] = vel;
		grid_u_old[g] = vel;
	}
	if (g < pc.v_count) {
		float w = float(wt_v[g]) / pc.fixed_scale;
		float vel = (w > 1e-6) ? (float(mom_v[g]) / pc.fixed_scale) / w : 0.0;
		grid_v_old[g] = vel;              // saved before external forces
		grid_v[g] = vel + pc.gravity * pc.phys_dt;
	}
}
