#[compute]
#version 450

// Write the painted material into the cell type field for masked cells
// (vacuum / solid / air). Water is not a stored type -- it is represented by
// particles -- so this is only dispatched for non-water materials.
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

layout(set = 0, binding = 12, std430) restrict buffer CType     { int cell_type[]; };
layout(set = 0, binding = 19, std430) restrict buffer BrushMask { int brush_mask[]; };

void main() {
	int c = int(gl_GlobalInvocationID.x);
	if (c >= pc.cell_count) return;
	if (brush_mask[c] == 1) cell_type[c] = pc.brush_material;
}
