#[compute]
#version 450

// Particle-to-Grid transfer (scatter). Each active particle deposits its
// velocity onto the four surrounding MAC faces with bilinear weights, using
// fixed-point integer atomics for order-independent accumulation.
// Dispatched over `capacity` threads (one per particle slot).

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

layout(set = 0, binding = 0,  std430) restrict buffer Particles { vec4 particles[]; }; // xy=pos, zw=vel
layout(set = 0, binding = 7,  std430) restrict buffer MomU { int mom_u[]; };
layout(set = 0, binding = 8,  std430) restrict buffer MomV { int mom_v[]; };
layout(set = 0, binding = 9,  std430) restrict buffer WtU  { int wt_u[]; };
layout(set = 0, binding = 10, std430) restrict buffer WtV  { int wt_v[]; };
layout(set = 0, binding = 11, std430) restrict buffer Mass { int mass[]; };
layout(set = 0, binding = 20, std430) restrict buffer Phase    { int phase[]; };        // per-particle liquid id
layout(set = 0, binding = 21, std430) restrict buffer PhaseCnt { int phase_count[]; };  // 3 counts per cell

int fixp(float v) { return int(round(v * pc.fixed_scale)); }

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	vec4 p = particles[gid];
	if (p.x < 0.0) return; // dead slot sentinel
	vec2 pos = p.xy;
	vec2 vel = p.zw;

	// --- scatter vel.x onto U faces (located at integer x, y+0.5) ---
	{
		float gx = pos.x;
		float gy = pos.y - 0.5;
		int i0 = int(floor(gx));
		int j0 = int(floor(gy));
		float fx = gx - float(i0);
		float fy = gy - float(j0);
		for (int dj = 0; dj < 2; ++dj) {
			for (int di = 0; di < 2; ++di) {
				int i = i0 + di;
				int j = j0 + dj;
				if (i < 0 || i > pc.nx || j < 0 || j >= pc.ny) continue;
				float wx = (di == 0) ? (1.0 - fx) : fx;
				float wy = (dj == 0) ? (1.0 - fy) : fy;
				float w = wx * wy;
				int idx = i + j * (pc.nx + 1);
				atomicAdd(mom_u[idx], fixp(w * vel.x));
				atomicAdd(wt_u[idx], fixp(w));
			}
		}
	}

	// --- scatter vel.y onto V faces (located at x+0.5, integer y) ---
	{
		float gx = pos.x - 0.5;
		float gy = pos.y;
		int i0 = int(floor(gx));
		int j0 = int(floor(gy));
		float fx = gx - float(i0);
		float fy = gy - float(j0);
		for (int dj = 0; dj < 2; ++dj) {
			for (int di = 0; di < 2; ++di) {
				int i = i0 + di;
				int j = j0 + dj;
				if (i < 0 || i >= pc.nx || j < 0 || j > pc.ny) continue;
				float wx = (di == 0) ? (1.0 - fx) : fx;
				float wy = (dj == 0) ? (1.0 - fy) : fy;
				float w = wx * wy;
				int idx = i + j * pc.nx;
				atomicAdd(mom_v[idx], fixp(w * vel.y));
				atomicAdd(wt_v[idx], fixp(w));
			}
		}
	}

	// --- deposit unit mass + per-phase count at the containing cell ---
	int ci = clamp(int(floor(pos.x)), 0, pc.nx - 1);
	int cj = clamp(int(floor(pos.y)), 0, pc.ny - 1);
	int cell = ci + cj * pc.nx;
	atomicAdd(mass[cell], fixp(1.0));
	atomicAdd(phase_count[3 * cell + clamp(phase[gid], 0, 2)], 1);
}
