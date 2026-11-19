shader_type spatial;
// Surface shader that receives ray-traced GI from an RTGI node.
// Copy/modify freely: keep the rtgi_* uniforms and the EMISSION line.

uniform vec4 albedo : hint_color = vec4(1.0);
uniform sampler2D albedo_tex : hint_albedo;
uniform float metallic : hint_range(0, 1) = 0.0;
uniform float roughness : hint_range(0, 1) = 0.8;
uniform vec4 emission_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);

uniform sampler2D rtgi_atlas : hint_black;
uniform vec3 rtgi_origin = vec3(0.0);
uniform vec3 rtgi_size = vec3(16.0, 8.0, 16.0);
uniform vec3 rtgi_counts = vec3(16.0, 8.0, 16.0);
uniform float rtgi_intensity = 1.0;
uniform float rtgi_normal_bias = 0.5;
uniform float rtgi_enabled = 1.0;
uniform float rtgi_env_ambient = 0.0; // share of the Environment ambient kept (SSAO only acts on this part)

vec4 rtgi_fetch(int face, float z, vec2 xy) {
	vec2 atlas = vec2(rtgi_counts.x * rtgi_counts.z, rtgi_counts.y * 6.0);
	vec2 uv = vec2(z * rtgi_counts.x + xy.x + 0.5, float(face) * rtgi_counts.y + xy.y + 0.5) / atlas;
	return textureLod(rtgi_atlas, uv, 0.0); // rgb premultiplied by probe validity (a); probes inside geometry have a = 0
}

vec4 rtgi_face(int face, vec3 p) {
	float z0 = floor(p.z);
	float z1 = min(z0 + 1.0, rtgi_counts.z - 1.0);
	return mix(rtgi_fetch(face, z0, p.xy), rtgi_fetch(face, z1, p.xy), p.z - z0);
}

vec3 rtgi_unpack(vec4 c) {
	return c.rgb / max(c.a, 0.001);
}

vec3 rtgi_gi(vec3 wpos, vec3 wn) {
	vec3 p = (wpos + wn * rtgi_normal_bias - rtgi_origin) / rtgi_size * rtgi_counts - 0.5;
	p = clamp(p, vec3(0.0), rtgi_counts - 1.0);
	vec3 w = wn * wn;
	int fx = wn.x > 0.0 ? 0 : 1;
	int fy = wn.y > 0.0 ? 2 : 3;
	int fz = wn.z > 0.0 ? 4 : 5;
	return rtgi_unpack(rtgi_face(fx, p)) * w.x + rtgi_unpack(rtgi_face(fy, p)) * w.y + rtgi_unpack(rtgi_face(fz, p)) * w.z;
}

void fragment() {
	vec2 uv = UV * uv1_scale.xy + uv1_offset.xy;
	vec4 a = albedo * texture(albedo_tex, uv);
	ALBEDO = a.rgb;
	AO = rtgi_env_ambient;
	AO_LIGHT_AFFECT = 0.0;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	vec3 wpos = (CAMERA_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wn = normalize((CAMERA_MATRIX * vec4(NORMAL, 0.0)).xyz);
	EMISSION = emission_color.rgb * emission_energy
			+ a.rgb * rtgi_gi(wpos, wn) * rtgi_intensity * (1.0 - metallic) * rtgi_enabled;
}
