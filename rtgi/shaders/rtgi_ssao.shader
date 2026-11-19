shader_type spatial;
// Screen-space ambient occlusion modelled on Godot 4's SSAO (same parameter set / look):
// XeGTAO-style horizon search (slices x steps, depth-derived normals), multiplied onto the lit frame.
// Rendered by a full-screen quad (see rtgi_ssao.gd). Godot 3.5, GLES3.
render_mode unshaded, blend_mul, depth_test_disable, depth_draw_never, cull_disabled;

uniform float radius = 1.0;        // world-space radius of the occlusion search
uniform float intensity = 2.0;     // occlusion multiplier
uniform float power = 1.5;         // contrast curve (higher = darker, tighter creases)
uniform float detail = 0.5;        // 0 = broad shading, 1 = favour small close-range occlusion
uniform float horizon = 0.06;      // occlusion below this amount is ignored (kills self-occlusion on slopes)
uniform float strength = 1.0;      // overall blend (0 = off)
uniform float fade_begin = 80.0;   // distance where AO starts fading out
uniform float fade_end = 120.0;    // distance where AO is gone
uniform int ssao_slices = 3;       // directions per pixel
uniform int ssao_steps = 8;        // samples per direction (each side)

const float PI = 3.14159265;
const float HALF_PI = 1.5707963;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

vec3 view_pos(sampler2D dt, vec2 uv, mat4 inv_proj) {
	float d = textureLod(dt, uv, 0.0).x;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
	return v.xyz / v.w;
}

// Interleaved gradient noise (Jimenez).
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 vp = VIEWPORT_SIZE;
	vec2 px = 1.0 / vp;
	mat4 ip = INV_PROJECTION_MATRIX;
	float depth = textureLod(DEPTH_TEXTURE, uv, 0.0).x;
	float ao = 1.0;
	float zlin = 0.0;
	vec2 par = mod(floor(FRAGCOORD.xy), 2.0);

	if (depth < 0.99999) {
		vec3 P = view_pos(DEPTH_TEXTURE, uv, ip);
		zlin = -P.z;

		// Normal from depth: per axis use the neighbour with the smaller depth step (avoids edge smearing).
		vec3 pl = view_pos(DEPTH_TEXTURE, uv - vec2(px.x, 0.0), ip);
		vec3 pr = view_pos(DEPTH_TEXTURE, uv + vec2(px.x, 0.0), ip);
		vec3 pd = view_pos(DEPTH_TEXTURE, uv - vec2(0.0, px.y), ip);
		vec3 pu = view_pos(DEPTH_TEXTURE, uv + vec2(0.0, px.y), ip);
		vec3 dx = abs(pr.z - P.z) < abs(P.z - pl.z) ? pr - P : P - pl;
		vec3 dy = abs(pu.z - P.z) < abs(P.z - pd.z) ? pu - P : P - pd;
		vec3 N = normalize(cross(dx, dy));

		bool persp = PROJECTION_MATRIX[2][3] != 0.0;
		vec3 V = persp ? normalize(-P) : vec3(0.0, 0.0, 1.0);
		if (dot(N, V) < 0.0) N = -N;

		// Search radius on screen (uv units), capped so huge radii stay cheap.
		float denom = persp ? max(-P.z, 0.001) : 1.0;
		vec2 rad_uv = radius * vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]) * 0.5 / denom;
		rad_uv *= min(1.0, 0.25 / max(max(rad_uv.x, rad_uv.y), 0.0001));
		float rad_px_max = max(rad_uv.x * vp.x, rad_uv.y * vp.y);

		float fall_range = 0.615;
		float fall_mul = -1.0 / (fall_range * radius);
		float fall_add = (1.0 - fall_range) / fall_range + 1.0;
		float dist_exp = mix(1.6, 3.2, detail);

		// Stratified per 2x2 quad: the 4 pixels of a quad take 4 different slice rotations / step offsets (jittered per quad),
		// so the quad average below behaves like 4x the samples instead of a visible hatch pattern.
		vec2 qc = floor(FRAGCOORD.xy * 0.5);
		float n1 = fract(ign(qc) + (par.x + 2.0 * par.y) * 0.25);
		float n2 = fract(ign(qc.yx + vec2(23.17, 41.31)) + (par.y + 2.0 * par.x) * 0.25);

		float vis = 0.0;
		for (int i = 0; i < ssao_slices; i++) {
			float phi = (float(i) + n1) / float(ssao_slices) * PI;
			vec2 omega = vec2(cos(phi), sin(phi));
			vec3 dir = vec3(omega, 0.0);
			vec3 ortho = dir - dot(dir, V) * V;
			vec3 axis = normalize(cross(ortho, V));
			vec3 pn = N - axis * dot(N, axis);
			float pn_len = length(pn);
			float sgn = sign(dot(ortho, pn));
			float cos_n = clamp(dot(pn, V) / max(pn_len, 0.0001), 0.0, 1.0);
			float nn = sgn * acos(cos_n);

			float low0 = cos(nn + HALF_PI);
			float low1 = cos(nn - HALF_PI);
			float hc0 = low0;
			float hc1 = low1;

			float rad_px = max(length(omega * rad_uv * vp), 0.0001);
			float min_s = 1.3 / rad_px;

			for (int j = 0; j < ssao_steps; j++) {
				float s = (float(j) + n2) / float(ssao_steps);
				s = max(pow(s, dist_exp), min_s);
				vec2 off = omega * rad_uv * s;

				vec3 d0 = view_pos(DEPTH_TEXTURE, uv + off, ip) - P;
				vec3 d1 = view_pos(DEPTH_TEXTURE, uv - off, ip) - P;
				float l0 = max(length(d0), 0.00001);
				float l1 = max(length(d1), 0.00001);
				float w0 = clamp(l0 * fall_mul + fall_add, 0.0, 1.0);
				float w1 = clamp(l1 * fall_mul + fall_add, 0.0, 1.0);
				hc0 = max(hc0, mix(low0, dot(d0 / l0, V), w0));
				hc1 = max(hc1, mix(low1, dot(d1 / l1, V), w1));
			}

			float h0 = -acos(clamp(hc1, -1.0, 1.0));
			float h1 = acos(clamp(hc0, -1.0, 1.0));
			h0 = nn + clamp(h0 - nn, -HALF_PI, HALF_PI);
			h1 = nn + clamp(h1 - nn, -HALF_PI, HALF_PI);
			float sn = sin(nn);
			float iarc0 = (cos_n + 2.0 * h0 * sn - cos(2.0 * h0 - nn)) * 0.25;
			float iarc1 = (cos_n + 2.0 * h1 * sn - cos(2.0 * h1 - nn)) * 0.25;
			vis += pn_len * (iarc0 + iarc1);
		}
		vis = clamp(vis / float(ssao_slices), 0.0, 1.0);

		float occ = clamp((1.0 - vis - horizon) / max(1.0 - horizon, 0.0001), 0.0, 1.0);
		ao = pow(clamp(1.0 - occ * intensity * 0.5, 0.0, 1.0), power);

		float dist = persp ? -P.z : length(P);
		float fade = 1.0 - smoothstep(fade_begin, max(fade_end, fade_begin + 0.01), dist);
		fade *= smoothstep(1.0, 4.0, rad_px_max); // radius shrank below a few pixels: nothing meaningful to sample
		ao = mix(1.0, ao, clamp(strength, 0.0, 1.0) * fade);
	}
	// Depth-aware 2x2 quad blur (derivatives): average AO with the quad neighbour unless a depth edge lies between.
	float dzx = dFdx(zlin);
	float dzy = dFdy(zlin);
	float rel = max(zlin, 0.001);
	float wx = 1.0 - smoothstep(0.004, 0.02, abs(dzx) / rel);
	float wy = 1.0 - smoothstep(0.004, 0.02, abs(dzy) / rel);
	if (zlin <= 0.0) { wx = 0.0; wy = 0.0; }
	ao = ao + (par.x < 0.5 ? 0.5 : -0.5) * dFdx(ao) * wx;
	float aoy = dFdy(ao);
	ao = ao + (par.y < 0.5 ? 0.5 : -0.5) * aoy * wy;
	ALBEDO = vec3(ao);
	ALPHA = 1.0;
}
