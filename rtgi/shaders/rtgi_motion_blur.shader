shader_type spatial;
// Per-pixel motion blur for Godot 3.5 (GLES3): a port of the Godot 4 "JFA driven motion blur" CompositorEffect addon
// (Sphynx Motion Blur Toolkit, SphynxSimpleJumpFloodMotionBlur + PreBlurProcessor).
//
// The Godot 4 addon is a chain of compute passes (velocity prep -> tile max -> jump flood dilation -> neighbour max -> blur).
// Godot 3 has no compute shaders, no velocity buffer and cannot read the screen between two full-screen passes, so everything
// runs in ONE full-screen quad pass here:
//   1. velocity   : rebuilt per pixel from the depth buffer and last frame's camera (rotation / movement components with
//                   multipliers + thresholds, exactly like PreBlurProcessor; sky = rotation only).
//   2. dilation   : the jump flood "which neighbour's blur covers me" search (fitness function of jfp_simple.glsl), done as a
//                   gather: JFA step sizes (2 + step_exponent_modifier)^k * step_multiplier px in 8 directions, tile-jittered.
//   3. blur       : the jump_flood_simple_blur.glsl gather (trail samples + background reconstruction, depth aware).
// Rendered by rtgi_motion_blur.gd. Camera motion comes from the depth buffer; MOVING OBJECTS come from a helper viewport
// (obj_vel, see rtgi_velocity.shader) that holds the full per-pixel velocity of every mesh that moved this frame.
render_mode unshaded, blend_mix, depth_test_disable, depth_draw_never, cull_disabled;

uniform int samples = 16;                  // max blur samples per pixel
uniform float px_per_sample = 1.0;         // adaptive sample count: one sample per this many px of blur (capped by `samples`)
uniform int fast_trail = 0;                // 1 = trail test reads depth only (no per-sample velocity rebuild): much cheaper
uniform float intensity = 0.5;             // already framerate-independence scaled by the script
uniform float perpen_error_thresh = 0.5;   // side bleed allowed while dilating (fraction of speed)
uniform int step_multiplier = 16;          // px; size of one "tile" / first jump flood step
uniform float step_exponent_modifier = 1.0;
uniform int jfa_pass_count = 3;            // 1..5 jump levels
uniform float max_dilation_radius = 144.0; // px, pow(2 + step_exponent_modifier, passes - 1) * step_multiplier
uniform float depth_softness = 0.05;       // relative depth range over which foreground/background weights fade
uniform float frame = 0.0;                 // frame counter % 8 (noise)
uniform int debug_view = 0;                // 0 off, 1 own velocity, 2 dilated velocity
uniform vec2 comp_multiplier = vec2(1.0, 1.0);      // velocity components: x = camera rotation, y = camera movement
uniform vec2 comp_lower = vec2(0.0);                // lower blur threshold per component
uniform vec2 comp_upper = vec2(0.0);                // upper blur threshold per component
uniform mat4 rel_cam;                               // current view space -> previous frame's view space (computed once per frame on the CPU)
uniform int dilate = 1;                             // 0 = skip the dilation search (camera only rotates, no object moves: velocity is depth independent)
uniform int cross_only = 0;                         // 1 = dilation uses 4 taps per level instead of 8 (jitter covers the rest)
uniform vec2 prev_proj_ratio = vec2(1.0, 1.0);      // previous / current projection scale (fov changes)
uniform sampler2D obj_vel;         // per-object velocity (R,G = 0.5 + uv velocity * 4, B = depth / obj_far)
uniform float use_obj = 0.0;                        // 1 when the object velocity viewport is active
uniform float obj_far = 200.0;
uniform float obj_multiplier = 1.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

float sharp_step(float lo, float hi, float x) {
	if (hi <= lo) {
		return step(lo, x);
	}
	return clamp((x - lo) / (hi - lo), 0.0, 1.0);
}

// Interleaved gradient noise (Jimenez), animated over 8 frames.
float ign(vec2 p, float fr) {
	p += fr * (vec2(47.0, 17.0) * 0.695);
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Linear view distance (positive) from a depth buffer value.
float lin_depth(float d, mat4 ip) {
	float z = d * 2.0 - 1.0;
	float vz = ip[2][2] * z + ip[3][2];
	float vw = ip[2][3] * z + ip[3][3];
	return -vz / vw;
}

// Project a previous-frame view space position. Returns (uv.x, uv.y, sign of clip w).
vec3 reproject(vec3 v, vec4 pp, vec4 pq) {
	float w = pq.x * v.z + pq.y;
	float sgn = w < 0.0 ? -1.0 : 1.0;
	w = sgn * max(abs(w), 0.00001);
	vec2 c = vec2(pp.x * v.x + pp.z * v.z + pq.z, pp.y * v.y + pp.w * v.z + pq.w);
	return vec3(c / w * 0.5 + 0.5, sgn);
}

// Per pixel velocity, same recipe as pre_blur_processor.glsl (without the object velocity component).
// Returns (velocity uv = previous - current, depth change, linear depth); `sky` is 1 for background pixels.
vec4 get_velocity(sampler2D dt, vec2 uv, mat4 ip, mat4 rt, vec4 pp, vec4 pq, out float sky) {
	float d = textureLod(dt, uv, 0.0).x;
	sky = step(0.99999, d);
	vec4 vp = ip * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
	vec3 v = vp.xyz / vp.w;
	vec3 vr = mat3(rt) * v;
	vec3 vt = sky > 0.5 ? vr : (rt * vec4(v, 1.0)).xyz;
	vec3 rot = reproject(vr, pp, pq);
	vec3 tot = reproject(vt, pp, pq);
	vec2 rot_ch = rot.xy - uv;          // rotation only
	vec2 base = tot.xy - uv;            // full camera change
	vec2 mov_ch = base - rot_ch;        // movement only
	vec2 tv = rot_ch * comp_multiplier.x * sharp_step(comp_lower.x, comp_upper.x, length(rot_ch) * comp_multiplier.x * intensity)
			+ mov_ch * comp_multiplier.y * sharp_step(comp_lower.y, comp_upper.y, length(mov_ch) * comp_multiplier.y * intensity);
	// never exceed the real camera velocity
	if (dot(tv * 99.0, tv * 100.0) >= dot(base * 100.0, base * 100.0)) {
		tv = base;
	}
	float dd = (v.z - vt.z) * clamp(length(tv) / max(length(base), 0.0000001), 0.0, 1.0);
	float len = max(length(tv), 0.0000001);
	tv *= clamp(len, 0.0, 1.0) / len;
	vec4 outv = vec4(tv * tot.z, dd, -v.z);
	// moving object? (its proxy must be the surface actually visible here: depth has to match the scene depth)
	if (use_obj > 0.5 && sky < 0.5) {
		vec4 o = textureLod(obj_vel, uv, 0.0);
		float oz = o.b * obj_far;
		if (o.b > 0.0 && abs(oz + v.z) < max(0.05, 0.03 * oz)) {
			vec2 ov = (o.rg - 0.5) * 0.25 * obj_multiplier;
			float ol = max(length(ov), 0.0000001);
			ov *= clamp(ol, 0.0, 1.0) / ol;
			outv = vec4(ov, 0.0, -v.z);
		}
	}
	return outv;
}

// Jump flood fitness (jfp_simple.glsl): how well the neighbour at `off` (uv) with velocity `cv` blurs over this pixel.
// 0 = does not cover it; larger = nearer to the camera (the nearest covering neighbour wins).
float candidate_score(vec2 off, vec4 cv, float csky) {
	vec2 f = -cv.xy;
	float ff = dot(f, f);
	if (ff <= 0.000000000001 || csky > 0.5) {
		return 0.0;
	}
	float dist = dot(f, off) / ff;
	float mid = intensity * 0.5;
	float in_range = step(abs(dist - mid), mid);
	float side = abs(dot(vec2(off.y, -off.x), f)) / ff;
	float in_perp = step(side, perpen_error_thresh * intensity);
	float z = cv.w + cv.z * dist;
	return in_range * in_perp / max(z, 0.001);
}

vec2 safenorm(vec2 v) {
	float l = max(length(v), 0.000001);
	return l >= 0.5 ? v / l : vec2(0.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 size = VIEWPORT_SIZE;
	vec2 frag = floor(FRAGCOORD.xy);
	mat4 ip = INV_PROJECTION_MATRIX;
	mat4 pm = PROJECTION_MATRIX;
	mat4 rt = rel_cam;
	vec4 pp = vec4(pm[0][0] * prev_proj_ratio.x, pm[1][1] * prev_proj_ratio.y, pm[2][0], pm[2][1]);
	vec4 pq = vec4(pm[2][3], pm[3][3], pm[3][0], pm[3][1]);

	vec3 col_x = textureLod(SCREEN_TEXTURE, uv, 0.0).rgb;
	float sky_x;
	vec4 vxz = get_velocity(DEPTH_TEXTURE, uv, ip, rt, pp, pq, sky_x);

	// ---- jump flood style dilation: pick the neighbour whose motion blur covers this pixel ----
	vec4 best_v = vxz;
	float best_score = candidate_score(vec2(0.0), vxz, sky_x);
	if (dilate == 1) {
		vec2 texel = 1.0 / size;
		float step_px = float(step_multiplier);
		float grow = 2.0 + step_exponent_modifier;
		for (int lv = 0; lv < 5; lv++) {
			if (lv >= jfa_pass_count) {
				break;
			}
			// one jitter per level (shared by its taps) instead of two noise evaluations per tap
			vec2 jit = (vec2(ign(frag + vec2(float(lv) * 13.1, 3.7), frame),
					ign(frag.yx + vec2(float(lv) * 5.3, 9.1), frame)) - 0.5) * float(step_multiplier) * texel;
			vec2 sp = step_px * texel;
			for (int a = -1; a <= 1; a++) {
				for (int b = -1; b <= 1; b++) {
					if (a == 0 && b == 0) {
						continue;
					}
					if (cross_only == 1 && a != 0 && b != 0) {
						continue;
					}
					vec2 off = vec2(float(a), float(b)) * sp + jit;
					vec2 cuv = uv + off;
					if (cuv.x < 0.0 || cuv.x > 1.0 || cuv.y < 0.0 || cuv.y > 1.0) {
						continue;
					}
					float sky_c;
					vec4 cv = get_velocity(DEPTH_TEXTURE, cuv, ip, rt, pp, pq, sky_c);
					float s = candidate_score(off, cv, sky_c);
					if (s > best_score) {
						best_score = s;
						best_v = cv;
					}
				}
			}
			step_px *= grow;
		}
	}

	// ---- scale to pixels / intensity (dilated velocity vn, own velocity vx) ----
	vec2 vn = best_v.xy * size;
	float vn_len = max(0.5, length(vn));
	float m = min(max_dilation_radius, vn_len * intensity) / vn_len;
	vn *= m;
	vn_len *= m;
	float dd_n = best_v.z * m;

	vec2 vx = vxz.xy * size;
	float vx_len = max(0.5, length(vx));
	m = min(max_dilation_radius, vx_len * intensity) / vx_len;
	vx *= m;
	float dd_x = vxz.z * m;

	vec3 result = col_x;
	if (debug_view == 3) {
		// object velocity buffer: red/green = |velocity|, blue = depth where an object was drawn (black = no moving object here)
		vec4 o = textureLod(obj_vel, uv, 0.0);
		result = o.b > 0.0 ? vec3(abs(o.rg - 0.5) * 8.0, 0.25 + o.b) : vec3(0.0);
	} else if (debug_view == 1) {
		result = vec3(abs(vx / size * 10.0), 0.0);
	} else if (debug_view == 2) {
		result = vec3(abs(vn / size * 10.0), 0.0);
	} else if (vn_len > 0.5) {
		// ---- blur (jump_flood_simple_blur.glsl) ----
		float velocity_match = pow(clamp(dot(vx, vn) / dot(vn, vn), 0.0, 1.0), 0.5);
		vn = mix(vn, vx, velocity_match);
		dd_n = mix(dd_n, dd_x, velocity_match);
		vec2 wn = safenorm(vn);
		float zx = vxz.w;
		float soft = max(depth_softness * max(zx, 0.01), 0.0001);

		float weight = 0.0;
		vec3 sum = vec3(0.0);
		float total_back = 0.0000000001;
		vec3 back_sum = col_x * total_back;
		float j = ign(frag, frame) - 0.5;
		// adaptive sample count: short blurs need few samples, only long blurs use the full budget
		float n = clamp(ceil(vn_len / px_per_sample), min(4.0, float(samples)), float(samples));
		int n_i = int(n);

		for (int i = 0; i < samples; i++) {
			if (i >= n_i) {
				break;
			}
			float t = mix(0.0, -1.0, (float(i) + j + 1.0) / (n + 1.0));
			vec2 nai_y = uv + (vx / size) * t;
			vec2 y = uv + (vn / size) * t;
			if (nai_y.x < 0.0 || nai_y.x > 1.0 || nai_y.y < 0.0 || nai_y.y > 1.0 || y.x < 0.0 || y.x > 1.0 || y.y < 0.0 || y.y > 1.0) {
				continue;
			}
			float T = abs(t * vn_len);

			// background reconstruction along this pixel's own trajectory
			float z_nai = lin_depth(textureLod(DEPTH_TEXTURE, nai_y, 0.0).x, ip) + t * dd_x;
			float nai_b = clamp(1.0 - (zx - z_nai) / soft, 0.0, 1.0);
			total_back += nai_b;
			back_sum += textureLod(SCREEN_TEXTURE, nai_y, 0.0).rgb * nai_b;

			// trail of the dilated velocity: does the sample's own blur reach back to this pixel?
			float ay;
			if (fast_trail == 1) {
				// cheap path: assume the sample moves like the dilated velocity, only compare depths
				float zy_f = lin_depth(textureLod(DEPTH_TEXTURE, y, 0.0).x, ip) + t * dd_n;
				float f_f = clamp(1.0 - (zy_f - zx) / soft, 0.0, 1.0);
				ay = f_f * step(T, vn_len);
			} else {
				float sky_y;
				vec4 vyz = get_velocity(DEPTH_TEXTURE, y, ip, rt, pp, pq, sky_y);
				vec2 vy = vyz.xy * size;
				float vy_len = max(0.5, length(vy));
				float my = min(max_dilation_radius, vy_len * intensity) / vy_len;
				vy *= my;
				vy_len *= my;
				float zy = vyz.w + t * dd_n;
				float f = clamp(1.0 - (zy - zx) / soft, 0.0, 1.0);
				float wa = abs(max(0.0, dot(vy / vy_len, wn)));
				ay = f * step(T, vy_len * wa);
			}
			weight += ay;
			sum += textureLod(SCREEN_TEXTURE, y, 0.0).rgb * ay;
		}
		back_sum *= (n - weight) / total_back;
		result = (sum + back_sum) / n;
	}
	ALBEDO = result;
}
