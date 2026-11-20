shader_type spatial;
// Per-object velocity proxy: drawn by rtgi_motion_blur.gd into a small helper viewport (own world) for every mesh that moved
// this frame. Writes the FULL screen-space velocity (object motion + camera motion) of each pixel and its linear depth.
//   R,G = 0.5 + velocity_uv * 4      velocity_uv = (previous - current) screen position in uv units (same sign as the blur shader)
//   B   = linear view depth / far    (0 = nothing drawn here)
render_mode unshaded, cull_disabled;

uniform mat4 prev_model;
uniform mat4 prev_view;              // previous frame's inverse camera transform
uniform vec2 prev_proj_ratio = vec2(1.0, 1.0);
uniform float far_plane = 200.0;

varying vec4 cur_clip;
varying vec4 prev_clip;

void vertex() {
	vec4 wp = WORLD_MATRIX * vec4(VERTEX, 1.0);
	cur_clip = PROJECTION_MATRIX * (INV_CAMERA_MATRIX * wp);
	mat4 pp = PROJECTION_MATRIX;
	pp[0][0] *= prev_proj_ratio.x;
	pp[1][1] *= prev_proj_ratio.y;
	prev_clip = pp * (prev_view * (prev_model * vec4(VERTEX, 1.0)));
}

void fragment() {
	vec2 c = cur_clip.xy / cur_clip.w;
	vec2 v = vec2(0.0);
	if (prev_clip.w > 0.0001) {
		v = (prev_clip.xy / prev_clip.w - c) * 0.5;
	}
	ALBEDO = vec3(0.5 + v.x * 4.0, 0.5 + v.y * 4.0, max(-VERTEX.z, 0.001) / far_plane);
}
