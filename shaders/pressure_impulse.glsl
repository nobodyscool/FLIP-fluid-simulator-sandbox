#[compute]
#version 450

// Pressure brush (material 0 / brush_mode 1). A raw pressure assignment is
// immediately overwritten by the Jacobi solve, so the pressure disturbance is
// realised as a radial velocity impulse from the painted region's centroid
// (brush_value = magnitude, may be negative for suction). This produces the
// observable "pressure source drives flow" behaviour required by F4.
// Dispatched over `capacity` threads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	int nx; int ny; int u_count; int v_count;
	int cell_count; int capacity; float phys_dt; float gravity;
	float flip_ratio; float p_atm; float fixed_scale; int jacobi_parity;
	int brush_material; float brush_cx; float brush_cy; float brush_radius;
	float brush_value; int brush_mode; int emit_count; int ppc;
	uint rng_seed; int mouse_cx; int mouse_cy; int clear_mode;
} pc;

layout(set = 0, binding = 0,  std430) restrict buffer Particles { vec4 particles[]; };
layout(set = 0, binding = 19, std430) restrict buffer BrushMask { int brush_mask[]; };

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (int(gid) >= pc.capacity) return;
	vec4 p = particles[gid];
	if (p.x < 0.0) return;
	int ci = clamp(int(floor(p.x)), 0, pc.nx - 1);
	int cj = clamp(int(floor(p.y)), 0, pc.ny - 1);
	if (brush_mask[ci + cj * pc.nx] != 1) return;

	vec2 dir = p.xy - vec2(pc.brush_cx, pc.brush_cy);
	float len = length(dir);
	dir = (len > 1e-4) ? dir / len : vec2(0.0, -1.0);
	particles[gid] = vec4(p.xy, p.zw + dir * pc.brush_value);
}
