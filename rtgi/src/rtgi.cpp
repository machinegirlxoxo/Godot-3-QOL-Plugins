#include "rtgi.h"

#include <ArrayMesh.hpp>
#include <Engine.hpp>
#include <Image.hpp>
#include <Material.hpp>
#include <OmniLight.hpp>
#include <SceneTree.hpp>
#include <SpatialMaterial.hpp>
#include <SpotLight.hpp>
#include <DirectionalLight.hpp>
#include <Texture.hpp>
#include <ProceduralSky.hpp>
#include <Sky.hpp>
#include <PanoramaSky.hpp>
#include <ProjectSettings.hpp>

#include <chrono>
#include <unordered_map>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <thread>

#include "shader_src.h"

using namespace godot;
using rtgi::V3;

static const float PI_F = 3.14159265358979f;

// ---------------------------------------------------------------- helpers

static inline uint16_t float_to_half(float f) {
	uint32_t x;
	std::memcpy(&x, &f, 4);
	uint32_t sign = (x >> 16) & 0x8000;
	int32_t e = (int32_t)((x >> 23) & 0xFF) - 127 + 15;
	uint32_t m = x & 0x7FFFFF;
	if (e <= 0) return (uint16_t)sign; // flush denormals
	if (e >= 31) return (uint16_t)(sign | 0x7BFF); // clamp to max half
	return (uint16_t)(sign | (e << 10) | (m >> 13));
}

using Rng = rtgi::Rng32;

void RTGI::Scan::mix(const void *p, size_t n) {
	const uint8_t *b = (const uint8_t *)p;
	for (size_t i = 0; i < n; i++) {
		sig ^= b[i];
		sig *= 1099511628211ULL;
	}
}

void RTGI::Scan::mixl(const void *p, size_t n) {
	const uint8_t *b = (const uint8_t *)p;
	for (size_t i = 0; i < n; i++) {
		lsig ^= b[i];
		lsig *= 1099511628211ULL;
	}
}

// ---------------------------------------------------------------- registration

void RTGI::_register_methods() {
	register_method("_ready", &RTGI::_ready);
	register_method("_exit_tree", &RTGI::_exit_tree);
	register_method("_process", &RTGI::_process);
	register_method("rebuild", &RTGI::rebuild);
	register_method("reset", &RTGI::reset);
	register_method("get_trace_ms", &RTGI::get_trace_ms);
	register_method("get_ray_count", &RTGI::get_ray_count);
	register_method("is_settled", &RTGI::is_settled);
	register_method("get_invalid_probe_count", &RTGI::get_invalid_probe_count);
	register_method("sample_gi", &RTGI::sample_gi);
	register_method("get_quality_info", &RTGI::get_quality_info);

	const godot_method_rpc_mode RPC = GODOT_METHOD_RPC_MODE_DISABLED;
	const godot_property_usage_flags USE = GODOT_PROPERTY_USAGE_DEFAULT;
	const godot_property_hint NOH = GODOT_PROPERTY_HINT_NONE;
	const godot_property_hint RNG = GODOT_PROPERTY_HINT_RANGE;

	register_property<RTGI, bool>("enabled", &RTGI::enabled, true);
	// GI Quality: Low / High use tuned, fixed values (probe density, rays, bounces, denoiser, budget); Custom uses the properties below.
	// All three share the same instant-update pipeline, so lights react immediately in every mode.
	register_property<RTGI, int>("quality_preset", &RTGI::set_quality_preset, &RTGI::get_quality_preset, (int)QUALITY_CUSTOM, RPC, USE, GODOT_PROPERTY_HINT_ENUM, "Low Quality,High Quality,Custom");
	register_property<RTGI, int>("instant_rays", &RTGI::instant_rays, 8, RPC, USE, RNG, "1,64,1");
	register_property<RTGI, int>("instant_bounces", &RTGI::instant_bounces, 2, RPC, USE, RNG, "0,6,1");
	register_property<RTGI, bool>("run_in_editor", &RTGI::run_in_editor, true);
	register_property<RTGI, bool>("auto_apply_shader", &RTGI::auto_apply_shader, true);
	register_property<RTGI, bool>("update_only_on_change", &RTGI::update_only_on_change, true);
	register_property<RTGI, bool>("backface_black", &RTGI::backface_black, true);
	register_property<RTGI, bool>("texture_albedo", &RTGI::texture_albedo, true);
	register_property<RTGI, float>("env_ambient_strength", &RTGI::env_ambient_strength, 0.0f, RPC, USE, RNG, "0,1,0.01");
	register_property<RTGI, NodePath>("geometry_root", &RTGI::geometry_root, NodePath(".."));
	register_property<RTGI, Vector3>("bounds_size", &RTGI::bounds_size, Vector3(16, 8, 16));
	register_property<RTGI, int>("probes_x", &RTGI::probes_x, 16, RPC, USE, RNG, "1,64,1");
	register_property<RTGI, int>("probes_y", &RTGI::probes_y, 8, RPC, USE, RNG, "1,64,1");
	register_property<RTGI, int>("probes_z", &RTGI::probes_z, 16, RPC, USE, RNG, "1,64,1");
	register_property<RTGI, int>("rays_per_probe", &RTGI::rays_per_probe, 96, RPC, USE, RNG, "4,512,1");
	register_property<RTGI, int>("probes_per_frame", &RTGI::probes_per_frame, 256, RPC, USE, RNG, "1,8192,1");
	register_property<RTGI, int>("thread_count", &RTGI::thread_count, 0, RPC, USE, RNG, "0,32,1");
	register_property<RTGI, int>("settle_sweeps", &RTGI::settle_sweeps, 16, RPC, USE, RNG, "1,256,1");
	register_property<RTGI, int>("fast_sweeps", &RTGI::fast_sweeps, 8, RPC, USE, RNG, "1,128,1");
	register_property<RTGI, float>("fast_blend", &RTGI::fast_blend, 1.0f, RPC, USE, RNG, "0.1,1,0.01");
	register_property<RTGI, float>("trace_budget_ms", &RTGI::trace_budget_ms, 8.0f, RPC, USE, RNG, "0,50,0.5");
	register_property<RTGI, float>("display_smoothing", &RTGI::display_smoothing, 0.4f, RPC, USE, RNG, "0.02,1,0.01");
	register_property<RTGI, bool>("denoise", &RTGI::denoise, true);
	register_property<RTGI, float>("denoise_strength", &RTGI::denoise_strength, 0.6f, RPC, USE, RNG, "0,1,0.01");
	register_property<RTGI, float>("denoise_edge", &RTGI::denoise_edge, 0.5f, RPC, USE, RNG, "0.05,4,0.01");
	register_property<RTGI, int>("denoise_passes", &RTGI::denoise_passes, 2, RPC, USE, RNG, "1,4,1");
	register_property<RTGI, float>("blend", &RTGI::blend, 0.1f, RPC, USE, RNG, "0.005,1,0.005");
	register_property<RTGI, float>("intensity", &RTGI::intensity, 5.0f, RPC, USE, RNG, "0,8,0.01");
	register_property<RTGI, float>("bounce_strength", &RTGI::bounce_strength, 0.97f, RPC, USE, RNG, "0,1,0.01");
	register_property<RTGI, float>("normal_bias", &RTGI::normal_bias, 1.8f, RPC, USE, RNG, "0,4,0.01");
	register_property<RTGI, float>("radiance_clamp", &RTGI::radiance_clamp, 6.0f, RPC, USE, RNG, "1,1000,0.5");
	register_property<RTGI, float>("sky_energy", &RTGI::sky_energy, 1.1f, RPC, USE, RNG, "0,16,0.01");
	(void)NOH;
}

void RTGI::_init() {}

void RTGI::update_shader_code() {
	shader->set_code(RTGI_SHADER_SRC);
}

static inline Color to_linear(const Color &c) {
	return Color(std::pow(std::max(0.0f, c.r), 2.2f), std::pow(std::max(0.0f, c.g), 2.2f), std::pow(std::max(0.0f, c.b), 2.2f));
}

// Average an equirect panorama into top / horizon / ground colors (azimuth is averaged away, so no rotation needed).
static bool sample_panorama(const Ref<Texture> &tex, Color &top, Color &hor, Color &gnd) {
	if (tex.is_null()) return false;
	Ref<Image> img = tex->get_data();
	if (img.is_null() || img->is_empty()) return false;
	if (img->is_compressed()) img->decompress();
	if (img->is_compressed()) return false;
	int w = img->get_width(), h = img->get_height();
	if (w < 2 || h < 2) return false;
	int f = (int)img->get_format();
	bool linear = f == Image::FORMAT_RGBAH || f == Image::FORMAT_RGBH || f == Image::FORMAT_RH || f == Image::FORMAT_RGH ||
			f == Image::FORMAT_RGBAF || f == Image::FORMAT_RGBF || f == Image::FORMAT_RF || f == Image::FORMAT_RGF || f == Image::FORMAT_RGBE9995;
	img->lock();
	auto band = [&](float v0, float v1) {
		int y0 = std::max(0, (int)(v0 * h)), y1 = std::min(h - 1, (int)(v1 * h));
		int sy = std::max(1, (y1 - y0) / 16), sx = std::max(1, w / 64);
		double r = 0, g = 0, b = 0;
		int n = 0;
		for (int y = y0; y <= y1; y += sy)
			for (int x = 0; x < w; x += sx) {
				Color c = img->get_pixel(x, y);
				r += c.r; g += c.g; b += c.b;
				n++;
			}
		if (n == 0) n = 1;
		Color out((float)(r / n), (float)(g / n), (float)(b / n));
		return linear ? out : to_linear(out);
	};
	top = band(0.0f, 0.15f);
	hor = band(0.42f, 0.58f);
	gnd = band(0.85f, 1.0f);
	img->unlock();
	return true;
}

// Average colour (linear) of an albedo texture, cached per texture instance. Lets bounce light carry the real surface colour
// (sandstone, brick, ...) instead of the flat material colour. Cache is dropped whenever the node leaves the tree.
static std::unordered_map<uint64_t, V3> g_tex_avg;

static bool texture_average(const Ref<Texture> &tex, V3 &out) {
	if (tex.is_null()) return false;
	uint64_t id = tex->get_instance_id();
	auto it = g_tex_avg.find(id);
	if (it != g_tex_avg.end()) {
		out = it->second;
		return true;
	}
	Ref<Image> img = tex->get_data();
	if (img.is_null() || img->is_empty()) return false;
	if (img->is_compressed()) img->decompress();
	if (img->is_compressed()) return false;
	int w = img->get_width(), h = img->get_height();
	if (w < 1 || h < 1) return false;
	int f = (int)img->get_format();
	bool linear = f == Image::FORMAT_RGBAH || f == Image::FORMAT_RGBH || f == Image::FORMAT_RH || f == Image::FORMAT_RGH ||
			f == Image::FORMAT_RGBAF || f == Image::FORMAT_RGBF || f == Image::FORMAT_RF || f == Image::FORMAT_RGF || f == Image::FORMAT_RGBE9995;
	int sx = std::max(1, w / 32), sy = std::max(1, h / 32);
	double r = 0, g = 0, b = 0;
	int n = 0;
	img->lock();
	for (int y = 0; y < h; y += sy)
		for (int x = 0; x < w; x += sx) {
			Color c = img->get_pixel(x, y);
			if (!linear) c = to_linear(c);
			r += c.r; g += c.g; b += c.b;
			n++;
		}
	img->unlock();
	if (n == 0) return false;
	out = V3((float)(r / n), (float)(g / n), (float)(b / n));
	g_tex_avg[id] = out;
	return true;
}

// The sky light always comes from the Environment (WorldEnvironment): its Sky resource (ProceduralSky, or a PanoramaSky averaged into
// top/horizon/ground), else its background colour, else its ambient colour, else the project clear colour. No Environment = no sky light.
void RTGI::resolve_sky(const Ref<Environment> &env) {
	eff_top = eff_horizon = eff_ground = Color(0, 0, 0);
	eff_energy = 0.0f;
	if (env.is_null()) return;
	float benergy = env->get_bg_energy();
	// A Sky resource lights the scene whatever the background mode is, so use it whenever one is assigned.
	Ref<Sky> sk = env->get_sky();
	if (sk.is_valid()) {
		if (ProceduralSky *ps = Object::cast_to<ProceduralSky>(sk.ptr())) {
			eff_top = to_linear(ps->get_sky_top_color());
			eff_horizon = to_linear(ps->get_sky_horizon_color());
			Color g1 = to_linear(ps->get_ground_horizon_color()), g2 = to_linear(ps->get_ground_bottom_color());
			eff_ground = Color((g1.r + g2.r) * 0.5f, (g1.g + g2.g) * 0.5f, (g1.b + g2.b) * 0.5f);
			eff_energy = sky_energy * ps->get_sky_energy() * benergy;
			return;
		}
		if (PanoramaSky *pn = Object::cast_to<PanoramaSky>(sk.ptr())) {
			Ref<Texture> tex = pn->get_panorama();
			uint64_t id = tex.is_valid() ? tex->get_instance_id() : 0;
			if (id != pano_id) {
				pano_id = id;
				pano_ok = sample_panorama(tex, pano_top, pano_horizon, pano_ground);
			}
			if (pano_ok) {
				eff_top = pano_top; eff_horizon = pano_horizon; eff_ground = pano_ground;
				eff_energy = sky_energy * benergy;
				return;
			}
		}
	}
	int bg = (int)env->get_background();
	if (bg == Environment::BG_COLOR || bg == Environment::BG_CLEAR_COLOR) {
		Color c = bg == Environment::BG_COLOR ? env->get_bg_color() : (Color)ProjectSettings::get_singleton()->get_setting("rendering/environment/default_clear_color");
		c = to_linear(c);
		eff_top = eff_horizon = eff_ground = c;
		eff_energy = sky_energy * benergy;
		return;
	}
	// plain ambient colour set on the Environment (no sky): treat it as uniform sky light
	Color amb = env->get_ambient_light_color();
	float ae = env->get_ambient_light_energy();
	if (ae > 0.0f && (amb.r + amb.g + amb.b) > 0.001f) {
		eff_top = eff_horizon = eff_ground = to_linear(amb);
		eff_energy = sky_energy * ae;
	}
}

void RTGI::_ready() {
	shader.instance();
	update_shader_code();
	atlas.instance();
	set_process(true);
	set_process_priority(1000); // run after scripts that move lights this frame, so the update lands in the same frame
	set_process_priority(1000); // after gameplay scripts: light moves made this frame are traced and uploaded this frame
}

void RTGI::_exit_tree() {
	Node *root = get_node_or_null(geometry_root);
	if (root) restore_materials(root);
	gi_mats.clear();
	known_mats.clear();
	geo_cache.clear();
	g_tex_avg.clear();
	has_scene = false;
	last_sig = 0;
}

void RTGI::rebuild() {
	geo_cache.clear();
	last_sig = 0;
}

void RTGI::reset() {
	std::fill(cube.begin(), cube.end(), 0.0f);
	disp_dirty = true;
	std::fill(valid.begin(), valid.end(), 1.0f);
	std::fill(ages.begin(), ages.end(), (uint8_t)0);
	fast_left = fast_sweeps;
	sweeps_left = fast_sweeps + settle_sweeps;
	need_upload = true;
}

void RTGI::flush_history() {
	// Anything that changes the lighting is answered by instant_pass(), which overwrites EVERY probe in the same frame
	// (no stale light survives, nothing is swept in over several frames). This only restarts the refinement phase.
	std::fill(ages.begin(), ages.end(), (uint8_t)0);
	fast_left = 0;
	nobounce_left = 0;
	cursor = 0;
	sweeps_left = std::max(1, q.settle_sweeps);
}

// ---------------------------------------------------------------- scene gathering

void RTGI::surface_colors(GeometryInstance *gi, MeshInstance *mi, const Ref<Mesh> &mesh, int s, SurfCol &out, Scan &sc) {
	out.albedo = V3(0.8f, 0.8f, 0.8f);
	out.emission = V3(0, 0, 0);
	Ref<Material> m = gi->get_material_override();
	if (m.is_null() && mi) m = mi->get_surface_material(s);
	if (m.is_null()) m = mesh->surface_get_material(s);
	if (m.is_null()) return;

	if (SpatialMaterial *sm = Object::cast_to<SpatialMaterial>(m.ptr())) {
		Color c = sm->get_albedo();
		out.albedo = V3(c.r, c.g, c.b);
		if (texture_albedo) {
			// surface colour = linear(material colour) * average linear colour of the albedo texture
			Color lc = to_linear(c);
			out.albedo = V3(lc.r, lc.g, lc.b);
			V3 avg;
			if (texture_average(sm->get_texture(SpatialMaterial::TEXTURE_ALBEDO), avg)) out.albedo = V3(out.albedo.x * avg.x, out.albedo.y * avg.y, out.albedo.z * avg.z);
		}
		if (sm->get_feature(SpatialMaterial::FEATURE_EMISSION)) {
			Color e = sm->get_emission();
			float k = sm->get_emission_energy();
			out.emission = V3(e.r * k, e.g * k, e.b * k);
		}
		if (sm->get_metallic() > 0.5f) out.albedo = out.albedo * (1.0f - sm->get_metallic());
	} else if (ShaderMaterial *shm = Object::cast_to<ShaderMaterial>(m.ptr())) {
		Variant a = shm->get_shader_param("albedo");
		if (a.get_type() == Variant::COLOR) {
			Color c = a;
			out.albedo = V3(c.r, c.g, c.b);
			if (texture_albedo) {
				// converted SpatialMaterials land here (convert_materials runs first): linear colour * average linear albedo texture
				Color lc = to_linear(c);
				out.albedo = V3(lc.r, lc.g, lc.b);
				Variant tv = shm->get_shader_param("albedo_tex");
				if (tv.get_type() == Variant::OBJECT) {
					Ref<Texture> t = tv;
					V3 avg;
					if (texture_average(t, avg)) out.albedo = V3(out.albedo.x * avg.x, out.albedo.y * avg.y, out.albedo.z * avg.z);
				}
			}
		}
		Variant e = shm->get_shader_param("emission_color");
		Variant k = shm->get_shader_param("emission_energy");
		if (e.get_type() == Variant::COLOR) {
			Color c = e;
			float en = (k.get_type() == Variant::REAL || k.get_type() == Variant::INT) ? (float)k : 1.0f;
			out.emission = V3(c.r * en, c.g * en, c.b * en);
		}
		Variant mt = shm->get_shader_param("metallic");
		if (mt.get_type() == Variant::REAL) out.albedo = out.albedo * (1.0f - std::min(1.0f, std::max(0.0f, (float)mt)));
	}
	sc.mix(&out, sizeof(out));
}

void RTGI::convert_materials(GeometryInstance *gi, MeshInstance *mi, const Ref<Mesh> &mesh) {
	// MeshInstance: originals are remembered on the node. CSG roots: surfaces live on the generated mesh itself.
	Object *holder = mi ? (Object *)mi : (Object *)mesh.ptr();
	ArrayMesh *am = Object::cast_to<ArrayMesh>(mesh.ptr());
	if (!mi && !am) return;
	int n = (int)mesh->get_surface_count();
	for (int s = 0; s < n; s++) {
		String key = String("_rtgi_orig_") + String::num_int64(s);
		if (holder->has_meta(key)) continue;
		if (gi->get_material_override().is_valid()) break;
		Ref<Material> cur = mi ? mi->get_surface_material(s) : Ref<Material>();
		Ref<Material> eff = cur;
		if (eff.is_null()) eff = mesh->surface_get_material(s);
		// no material at all (e.g. primitive meshes) -> still receives GI using the default albedo
		SpatialMaterial *sm = nullptr;
		if (eff.is_valid()) {
			sm = Object::cast_to<SpatialMaterial>(eff.ptr());
			if (!sm) continue; // custom ShaderMaterial: user handles it (or uses rtgi_atlas in own shader)
			if (sm->get_feature(SpatialMaterial::FEATURE_TRANSPARENT)) continue;
		}

		Ref<ShaderMaterial> m;
		m.instance();
		m->set_shader(shader);
		if (sm) {
			m->set_shader_param("albedo", sm->get_albedo());
			Ref<Texture> t = sm->get_texture(SpatialMaterial::TEXTURE_ALBEDO);
			if (t.is_valid()) m->set_shader_param("albedo_tex", t);
			m->set_shader_param("metallic", sm->get_metallic());
			m->set_shader_param("roughness", sm->get_roughness());
			if (sm->get_feature(SpatialMaterial::FEATURE_EMISSION)) {
				m->set_shader_param("emission_color", sm->get_emission());
				m->set_shader_param("emission_energy", sm->get_emission_energy());
			}
			m->set_shader_param("uv1_scale", sm->get_uv1_scale());
			m->set_shader_param("uv1_offset", sm->get_uv1_offset());
		} else {
			m->set_shader_param("albedo", Color(0.8f, 0.8f, 0.8f));
		}

		// remembered so we can restore; a null original is stored as `false` (setting a Nil meta would erase the key)
		Ref<Material> store = mi ? cur : eff;
		holder->set_meta(key, store.is_valid() ? Variant((Object *)store.ptr()) : Variant(false));
		if (mi) mi->set_surface_material(s, m);
		else am->surface_set_material(s, m);
	}
}

void RTGI::gather(Node *n, Scan &s) {
	if (n->is_in_group("rtgi_ignore")) return;
	if (WorldEnvironment *we = Object::cast_to<WorldEnvironment>(n)) {
		if (s.env.is_null()) s.env = we->get_environment();
	}

	// Any geometry: MeshInstance, plus CSG root shapes (CSGBox, CSGCombiner, ... which bake into one generated mesh).
	GeometryInstance *gi = nullptr;
	MeshInstance *mi = Object::cast_to<MeshInstance>(n);
	Ref<Mesh> mesh;
	Transform local;
	if (mi) {
		gi = mi;
		mesh = mi->get_mesh();
	} else if (CSGShape *cs = Object::cast_to<CSGShape>(n)) {
		gi = cs;
		if (cs->is_root_shape()) {
			Array a = cs->get_meshes();
			if (a.size() == 2) {
				local = a[0];
				mesh = a[1];
			}
		}
	}

	if (gi) {
		if (mesh.is_valid() && gi->is_visible_in_tree()) {
			if (auto_apply_shader) convert_materials(gi, mi, mesh);
			Item it;
			it.mesh = mesh;
			it.mesh_id = mesh->get_instance_id();
			Transform xf = gi->get_global_transform() * local;
			for (int r = 0; r < 3; r++) {
				it.m[r * 4 + 0] = xf.basis.elements[r].x;
				it.m[r * 4 + 1] = xf.basis.elements[r].y;
				it.m[r * 4 + 2] = xf.basis.elements[r].z;
			}
			it.m[3] = xf.origin.x;
			it.m[7] = xf.origin.y;
			it.m[11] = xf.origin.z;
			s.mix(&it.mesh_id, sizeof(it.mesh_id));
			s.mix(it.m, sizeof(it.m));
			int sc = (int)mesh->get_surface_count();
			it.cols.resize(sc);
			for (int i = 0; i < sc; i++) {
				surface_colors(gi, mi, mesh, i, it.cols[i], s);
				Ref<Material> mat = mi ? mi->get_surface_material(i) : mesh->surface_get_material(i);
				if (mat.is_valid()) {
					if (ShaderMaterial *shm = Object::cast_to<ShaderMaterial>(mat.ptr())) {
						Ref<Shader> sh = shm->get_shader();
						if (sh.is_valid() && sh->get_code().find("rtgi_atlas") != -1) register_gi_material(Ref<ShaderMaterial>(shm));
					}
				}
			}
			s.items.push_back(std::move(it));
		}
	} else if (Light *l = Object::cast_to<Light>(n)) {
		if (l->is_visible_in_tree()) {
			LightData d;
			Transform xf = l->get_global_transform();
			Color c = l->get_color();
			float e = l->get_param(Light::PARAM_ENERGY) * l->get_param(Light::PARAM_INDIRECT_ENERGY);
			d.color = V3(c.r * e, c.g * e, c.b * e);
			d.pos = V3(xf.origin.x, xf.origin.y, xf.origin.z);
			// basis columns: -Z axis in world = -(column 2)
			d.dir = rtgi::norm(V3(-xf.basis.elements[0].z, -xf.basis.elements[1].z, -xf.basis.elements[2].z));
			d.range = l->get_param(Light::PARAM_RANGE);
			d.atten = l->get_param(Light::PARAM_ATTENUATION);
			d.spot_angle = 0;
			d.spot_atten = 1;
			d.type = -1;
			if (Object::cast_to<DirectionalLight>(l)) d.type = 0;
			else if (Object::cast_to<SpotLight>(l)) {
				d.type = 2;
				d.spot_angle = l->get_param(Light::PARAM_SPOT_ANGLE) * PI_F / 180.0f;
				d.spot_atten = l->get_param(Light::PARAM_SPOT_ATTENUATION);
			} else if (Object::cast_to<OmniLight>(l)) d.type = 1;
			if (d.type >= 0) {
				s.mixl(&d, sizeof(d));
				s.lights.push_back(d);
			}
		}
	}
	int cc = (int)n->get_child_count();
	for (int i = 0; i < cc; i++) gather(n->get_child(i), s);
}

std::shared_ptr<RTGI::MeshGeo> RTGI::get_geo(const Ref<Mesh> &mesh, uint64_t id) {
	auto it = geo_cache.find(id);
	if (it != geo_cache.end()) return it->second;
	if (geo_cache.size() > 4096) geo_cache.clear();
	auto geo = std::make_shared<MeshGeo>();
	int sc = (int)mesh->get_surface_count();
	geo->surfs.resize(sc);
	ArrayMesh *am = Object::cast_to<ArrayMesh>(mesh.ptr());
	for (int s = 0; s < sc; s++) {
		if (am && am->surface_get_primitive_type(s) != Mesh::PRIMITIVE_TRIANGLES) continue;
		Array arr = mesh->surface_get_arrays(s);
		PoolVector3Array verts = arr[Mesh::ARRAY_VERTEX];
		PoolIntArray idx = arr[Mesh::ARRAY_INDEX];
		PoolVector3Array norms = arr[Mesh::ARRAY_NORMAL];
		MeshGeo::Surf &sf = geo->surfs[s];
		int vn = verts.size();
		sf.v.resize(vn);
		for (int i = 0; i < vn; i++) {
			Vector3 v = verts[i];
			sf.v[i] = V3(v.x, v.y, v.z);
		}
		int in = idx.size();
		if (in > 0) {
			sf.idx.resize(in);
			for (int i = 0; i < in; i++) sf.idx[i] = idx[i];
		} else {
			sf.idx.resize(vn);
			for (int i = 0; i < vn; i++) sf.idx[i] = i;
		}
		// Winding differs between mesh sources (CSG, imported, negative scale...). Trust the vertex normals.
		sf.flip.assign(sf.idx.size() / 3, 0);
		if (norms.size() == vn) {
			for (size_t t = 0; t + 2 < sf.idx.size(); t += 3) {
				int a = sf.idx[t], b = sf.idx[t + 1], c2 = sf.idx[t + 2];
				if (a >= vn || b >= vn || c2 >= vn) continue;
				V3 n = rtgi::cross(sf.v[b] - sf.v[a], sf.v[c2] - sf.v[a]) * -1.0f;
				Vector3 nv = Vector3(norms[a]) + Vector3(norms[b]) + Vector3(norms[c2]);
				float d = n.x * nv.x + n.y * nv.y + n.z * nv.z;
				if (d < 0.0f) sf.flip[t / 3] = 1;
			}
		}
	}
	geo_cache[id] = geo;
	return geo;
}

void RTGI::rebuild_scene(const Scan &sc) {
	std::vector<rtgi::Tri> tris;
	double ma_r = 0, ma_g = 0, ma_b = 0, ma_w = 0;
	for (const Item &it : sc.items) {
		std::shared_ptr<MeshGeo> geo = get_geo(it.mesh, it.mesh_id);
		const float *m = it.m;
		float det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8]);
		float dsgn = det < 0.0f ? -1.0f : 1.0f;
		for (size_t s = 0; s < geo->surfs.size(); s++) {
			const MeshGeo::Surf &sf = geo->surfs[s];
			if (sf.idx.size() < 3) continue;
			std::vector<V3> w(sf.v.size());
			for (size_t i = 0; i < sf.v.size(); i++) {
				const V3 &v = sf.v[i];
				w[i] = V3(m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3],
						m[4] * v.x + m[5] * v.y + m[6] * v.z + m[7],
						m[8] * v.x + m[9] * v.y + m[10] * v.z + m[11]);
			}
			const SurfCol &col = s < it.cols.size() ? it.cols[s] : SurfCol();
			for (size_t i = 0; i + 2 < sf.idx.size(); i += 3) {
				int a = sf.idx[i], b = sf.idx[i + 1], c = sf.idx[i + 2];
				if (a >= (int)w.size() || b >= (int)w.size() || c >= (int)w.size()) continue;
				rtgi::Tri t;
				t.v0 = w[a];
				t.e1 = w[b] - w[a];
				t.e2 = w[c] - w[a];
				V3 n = rtgi::cross(t.e1, t.e2);
				if (rtgi::len(n) < 1e-12f) continue;
				t.n = rtgi::norm(n) * (-1.0f * dsgn * (sf.flip[i / 3] ? -1.0f : 1.0f)); // Godot front faces are clockwise, so outward normal = -cross(e1, e2)
				t.albedo = col.albedo;
				t.emission = col.emission;
				double area = 0.5 * rtgi::len(n);
				ma_r += area * col.albedo.x; ma_g += area * col.albedo.y; ma_b += area * col.albedo.z; ma_w += area;
				tris.push_back(t);
			}
		}
	}
	bvh.build(tris);
	lights = sc.lights;
	if (ma_w > 0.0) mean_albedo = V3((float)(ma_r / ma_w), (float)(ma_g / ma_w), (float)(ma_b / ma_w));
}

// ---------------------------------------------------------------- grid / materials

void RTGI::set_quality_preset(int p) {
	quality_preset = std::max(0, std::min(2, p));
}

void RTGI::effective_quality(Quality &o) const {
	Vector3 bs = bounds_size;
	bs.x = std::max(0.1f, bs.x); bs.y = std::max(0.1f, bs.y); bs.z = std::max(0.1f, bs.z);
	if (quality_preset == QUALITY_CUSTOM) {
		o.probes_x = std::max(1, std::min(64, probes_x));
		o.probes_y = std::max(1, std::min(64, probes_y));
		o.probes_z = std::max(1, std::min(64, probes_z));
		o.rays_refine = std::max(1, rays_per_probe);
		o.rays_instant = std::max(1, instant_rays);
		o.bounces = std::max(0, std::min(6, instant_bounces));
		o.probes_per_frame = std::max(1, probes_per_frame);
		o.trace_budget_ms = trace_budget_ms;
		o.settle_sweeps = std::max(1, settle_sweeps);
		o.bounce_strength = bounce_strength;
		o.display_smoothing = display_smoothing;
		o.denoise = denoise;
		o.denoise_strength = denoise_strength;
		o.denoise_edge = denoise_edge;
		o.denoise_passes = denoise_passes;
		o.blend = blend;
		return;
	}
	const bool high = quality_preset == QUALITY_HIGH;
	// probe density follows bounds_size (probes per metre), capped per axis (64) and in total
	const float density = high ? 1.6f : 0.7f;
	const int cap = high ? 6000 : 1200;
	float fx = std::ceil(bs.x * density), fy = std::ceil(bs.y * density), fz = std::ceil(bs.z * density);
	fx = std::max(2.0f, std::min(64.0f, fx)); fy = std::max(2.0f, std::min(64.0f, fy)); fz = std::max(2.0f, std::min(64.0f, fz));
	float tot = fx * fy * fz;
	if (tot > (float)cap) {
		float s = std::cbrt((float)cap / tot);
		fx = std::max(2.0f, std::floor(fx * s)); fy = std::max(2.0f, std::floor(fy * s)); fz = std::max(2.0f, std::floor(fz * s));
	}
	o.probes_x = (int)fx; o.probes_y = (int)fy; o.probes_z = (int)fz;
	if (high) {
		o.rays_refine = 192; o.rays_instant = 10; o.bounces = 3;
		o.probes_per_frame = 64; o.trace_budget_ms = 10.0f; o.settle_sweeps = 24;
		o.bounce_strength = 0.97f; o.display_smoothing = 0.35f;
		o.denoise = true; o.denoise_strength = 0.6f; o.denoise_edge = 0.5f; o.denoise_passes = 3;
		o.blend = 0.06f;
	} else {
		o.rays_refine = 32; o.rays_instant = 4; o.bounces = 2;
		o.probes_per_frame = 32; o.trace_budget_ms = 4.0f; o.settle_sweeps = 6;
		o.bounce_strength = 0.7f; o.display_smoothing = 0.5f;
		o.denoise = true; o.denoise_strength = 0.8f; o.denoise_edge = 0.8f; o.denoise_passes = 2;
		o.blend = 0.2f;
	}
}

String RTGI::get_quality_info() {
	Quality t;
	effective_quality(t);
	const char *name = quality_preset == QUALITY_LOW ? "Low Quality" : (quality_preset == QUALITY_HIGH ? "High Quality" : "Custom");
	char buf[256];
	snprintf(buf, sizeof(buf), "%s: %dx%dx%d = %d probes, %d instant / %d refine rays, %d bounces, denoise x%d",
			name, t.probes_x, t.probes_y, t.probes_z, t.probes_x * t.probes_y * t.probes_z, t.rays_instant, t.rays_refine, t.bounces, t.denoise ? t.denoise_passes : 0);
	return String(buf);
}

void RTGI::ensure_grid() {
	Transform xf = get_global_transform();
	Vector3 bs = bounds_size;
	bs.x = std::max(0.1f, bs.x); bs.y = std::max(0.1f, bs.y); bs.z = std::max(0.1f, bs.z);
	size = V3(bs.x, bs.y, bs.z);
	origin = V3(xf.origin.x - bs.x * 0.5f, xf.origin.y - bs.y * 0.5f, xf.origin.z - bs.z * 0.5f);
	effective_quality(q);
	int nx = q.probes_x, ny = q.probes_y, nz = q.probes_z;
	if (nx != gx || ny != gy || nz != gz || cube.empty()) {
		gx = nx; gy = ny; gz = nz;
		size_t total = (size_t)gx * gy * gz;
		cube.assign(total * 18, 0.0f);
		disp.assign(total * 18, 0.0f);
		den.clear();
		den_tmp.clear();
		ages.assign(total, 0);
		valid.assign(total, 1.0f);
		cursor = 0;
		need_upload = true;
		params_dirty = true;
	}
}

void RTGI::apply_params(Ref<ShaderMaterial> m) {
	m->set_shader_param("rtgi_atlas", atlas);
	m->set_shader_param("rtgi_origin", Vector3(origin.x, origin.y, origin.z));
	m->set_shader_param("rtgi_size", Vector3(size.x, size.y, size.z));
	m->set_shader_param("rtgi_counts", Vector3(gx, gy, gz));
	m->set_shader_param("rtgi_intensity", intensity);
	m->set_shader_param("rtgi_normal_bias", normal_bias);
	m->set_shader_param("rtgi_enabled", enabled ? 1.0f : 0.0f);
	m->set_shader_param("rtgi_env_ambient", env_ambient_strength);
}

void RTGI::register_gi_material(Ref<ShaderMaterial> m) {
	uint64_t id = m->get_instance_id();
	if (known_mats.insert(id).second) {
		gi_mats.push_back(m);
		if (gx > 0) apply_params(m);
	}
}

void RTGI::restore_materials(Node *n) {
	Object *holder = nullptr;
	Ref<Mesh> mesh;
	MeshInstance *mi = Object::cast_to<MeshInstance>(n);
	if (mi) {
		holder = mi;
		mesh = mi->get_mesh();
	} else if (CSGShape *cs = Object::cast_to<CSGShape>(n)) {
		Array a = cs->get_meshes();
		if (a.size() == 2) {
			mesh = a[1];
			holder = mesh.ptr();
		}
	}
	if (holder && mesh.is_valid()) {
		ArrayMesh *am = Object::cast_to<ArrayMesh>(mesh.ptr());
		int sc = (int)mesh->get_surface_count();
		for (int s = 0; s < sc; s++) {
			String key = String("_rtgi_orig_") + String::num_int64(s);
			if (holder->has_meta(key)) {
				Variant v = holder->get_meta(key);
				Ref<Material> orig;
				if (v.get_type() == Variant::OBJECT) orig = v;
				if (mi) mi->set_surface_material(s, orig);
				else if (am) am->surface_set_material(s, orig);
				holder->remove_meta(key);
			}
		}
	}
	int cc = (int)n->get_child_count();
	for (int i = 0; i < cc; i++) restore_materials(n->get_child(i));
}

// ---------------------------------------------------------------- shading

V3 RTGI::sky(const V3 &d) const {
	V3 top(eff_top.r, eff_top.g, eff_top.b), hor(eff_horizon.r, eff_horizon.g, eff_horizon.b), gnd(eff_ground.r, eff_ground.g, eff_ground.b);
	V3 c;
	if (d.y >= 0) {
		float t = std::pow(std::min(1.0f, d.y), 0.5f);
		c = hor * (1 - t) + top * t;
	} else {
		float t = std::pow(std::min(1.0f, -d.y), 0.5f);
		c = hor * (1 - t) + gnd * t;
	}
	return c * eff_energy;
}

// Light arriving at (p, n) from one light, with shadow ray.
V3 RTGI::light_at(const LightData &l, const V3 &p, const V3 &n) const {
	V3 L;
	float att = 1.0f, maxd = 1e30f;
	if (l.type == 0) {
		L = l.dir * -1.0f;
	} else {
		V3 to = l.pos - p;
		float d = rtgi::len(to);
		if (d < 1e-4f || d > l.range) return V3();
		L = to * (1.0f / d);
		att = std::pow(std::max(0.0f, 1.0f - d / l.range), l.atten);
		maxd = d - 0.01f;
		if (l.type == 2) {
			float cosang = rtgi::dot(l.dir, L * -1.0f);
			float ang = std::acos(std::min(1.0f, std::max(-1.0f, cosang)));
			if (ang > l.spot_angle) return V3();
			att *= std::pow(std::max(0.0f, 1.0f - ang / l.spot_angle), l.spot_atten);
		}
	}
	float ndl = rtgi::dot(n, L);
	if (ndl <= 0.0f || att <= 0.0f) return V3();
	if (bvh.occluded(p, L, maxd)) return V3();
	return l.color * (ndl * att);
}

// Directional + omni light. Spot lights are NOT sampled here: a narrow cone (a flashlight) is hit by only a handful of random probe
// rays, so its bounce light came out as nothing but noise. They are injected as virtual point lights (see build_vpls) instead.
V3 RTGI::direct_light(const V3 &p, const V3 &n) const {
	V3 sum;
	for (const LightData &l : lights) {
		if (l.type == 2) continue;
		sum += light_at(l, p, n);
	}
	return sum;
}

// Spot lights -> virtual point lights. A fixed Fibonacci pattern in the light's own cone is cast into the scene; every hit surface patch
// becomes a small diffuse emitter (reflected light + the patch area it stands for). The pattern is fixed relative to the light, so a moving
// flashlight slides smoothly instead of shimmering. Probes then gather these patches directly (gather_vpls), which finds the lit spot no
// matter how few rays the probe itself shoots.
void RTGI::build_vpls() {
	vpls.clear();
	if (bvh.empty()) return;
	const int K = 64;
	int spots = 0;
	for (const LightData &l : lights) {
		if (l.type != 2 || spots >= 4) continue;
		spots++;
		float ca = std::cos(std::min(l.spot_angle, 1.5707f));
		float omega = 2.0f * PI_F * (1.0f - ca); // solid angle of the cone
		V3 up = std::fabs(l.dir.y) < 0.99f ? V3(0, 1, 0) : V3(1, 0, 0);
		V3 tx = rtgi::norm(rtgi::cross(up, l.dir));
		V3 ty = rtgi::cross(l.dir, tx);
		for (int i = 0; i < K; i++) {
			float cz = 1.0f - (i + 0.5f) / K * (1.0f - ca);
			float r = std::sqrt(std::max(0.0f, 1.0f - cz * cz));
			float ph = 2.399963f * i;
			V3 d = rtgi::norm(l.dir * cz + tx * (r * std::cos(ph)) + ty * (r * std::sin(ph)));
			rtgi::Hit h;
			if (!bvh.intersect(l.pos, d, l.range, h)) continue;
			if (h.back) continue;
			const rtgi::Tri &t = bvh.tri(h.tri);
			V3 n = t.n;
			float cosh = std::max(0.15f, -rtgi::dot(n, d));
			V3 p = l.pos + d * h.t + n * 0.02f;
			V3 e = light_at(l, p, n);
			V3 Lv = t.albedo * e;
			if (Lv.x + Lv.y + Lv.z <= 1e-5f) continue;
			Vpl v;
			v.pos = p;
			v.n = n;
			v.rad = Lv;
			v.area = (omega / K) * h.t * h.t / cosh;
			vpls.push_back(v);
		}
	}
}

// Adds the light the probe at `pos` receives from the spot-light patches (visibility by shadow ray) to the six face values in `out`.
void RTGI::gather_vpls(const V3 &pos, float *out) const {
	const float inv_pi = 1.0f / PI_F;
	for (const Vpl &v : vpls) {
		V3 w = v.pos - pos;
		float d2 = rtgi::dot(w, w);
		if (d2 < 1e-6f) continue;
		float d = std::sqrt(d2);
		w = w * (1.0f / d);
		float cq = -rtgi::dot(v.n, w); // patch must face the probe
		if (cq <= 0.0f) continue;
		float dw = v.area * cq / std::max(d2, 0.36f); // solid angle the patch covers, seen from the probe
		float s = dw * inv_pi;
		if (s * std::max(v.rad.x, std::max(v.rad.y, v.rad.z)) < 2e-4f) continue;
		if (bvh.occluded(pos, w, d - 0.05f)) continue;
		float fw[6] = { std::max(w.x, 0.0f), std::max(-w.x, 0.0f), std::max(w.y, 0.0f), std::max(-w.y, 0.0f), std::max(w.z, 0.0f), std::max(-w.z, 0.0f) };
		for (int f = 0; f < 6; f++) {
			float k = fw[f] * s;
			out[f * 3 + 0] += v.rad.x * k;
			out[f * 3 + 1] += v.rad.y * k;
			out[f * 3 + 2] += v.rad.z * k;
		}
	}
}

V3 RTGI::lookup(const V3 &pos, const V3 &n, const std::vector<float> *buf) const {
	const std::vector<float> &src = buf ? *buf : cube;
	V3 p = V3((pos.x - origin.x) / size.x * gx - 0.5f, (pos.y - origin.y) / size.y * gy - 0.5f, (pos.z - origin.z) / size.z * gz - 0.5f);
	p.x = std::min(std::max(p.x, 0.0f), (float)(gx - 1));
	p.y = std::min(std::max(p.y, 0.0f), (float)(gy - 1));
	p.z = std::min(std::max(p.z, 0.0f), (float)(gz - 1));
	int x0 = (int)p.x, y0 = (int)p.y, z0 = (int)p.z;
	int x1 = std::min(x0 + 1, gx - 1), y1 = std::min(y0 + 1, gy - 1), z1 = std::min(z0 + 1, gz - 1);
	float fx = p.x - x0, fy = p.y - y0, fz = p.z - z0;
	int faces[3] = { n.x > 0 ? 0 : 1, n.y > 0 ? 2 : 3, n.z > 0 ? 4 : 5 };
	float w[3] = { n.x * n.x, n.y * n.y, n.z * n.z };
	// trilinear weights of the 8 neighbouring probes, scaled by validity so probes inside geometry are ignored
	float tw[8];
	int px[8] = { x0, x1, x0, x1, x0, x1, x0, x1 };
	int py[8] = { y0, y0, y1, y1, y0, y0, y1, y1 };
	int pz[8] = { z0, z0, z0, z0, z1, z1, z1, z1 };
	float wsum = 0.0f;
	for (int i = 0; i < 8; i++) {
		float wx = (i & 1) ? fx : 1 - fx, wy = (i & 2) ? fy : 1 - fy, wz = (i & 4) ? fz : 1 - fz;
		size_t pi = (size_t)(pz[i] * gy + py[i]) * gx + px[i];
		tw[i] = wx * wy * wz * valid[pi];
		wsum += tw[i];
	}
	if (wsum < 1e-4f) return V3(0, 0, 0);
	V3 out;
	for (int k = 0; k < 3; k++) {
		if (w[k] <= 1e-5f) continue;
		V3 acc;
		for (int i = 0; i < 8; i++) {
			if (tw[i] <= 0.0f) continue;
			size_t pi = (size_t)(pz[i] * gy + py[i]) * gx + px[i];
			const float *c = &src[(pi * 6 + faces[k]) * 3];
			acc += V3(c[0], c[1], c[2]) * tw[i];
		}
		out += acc * (w[k] / wsum);
	}
	return out;
}

// Radiance arriving along a ray. Iterative diffuse path: every hit gets direct light (with shadow rays) + emission, then the path
// continues with a cosine-weighted bounce for `bounces` more segments. That makes multi-bounce colour bleeding correct from the very
// first evaluation, with no dependence on previously computed probes. When `feedback` is set (refinement only), the path's last hit
// adds the already-updated probe grid, which supplies the remaining infinite-bounce tail.
V3 RTGI::radiance(const V3 &o0, const V3 &d0, int bounces, bool feedback, rtgi::Rng32 &rng, bool *back) const {
	V3 o = o0, d = d0;
	V3 tp(1, 1, 1);
	V3 L;
	const float bs = q.bounce_strength;
	for (int depth = 0;; depth++) {
		rtgi::Hit h;
		if (!bvh.intersect(o, d, 1e30f, h)) {
			L += tp * sky(d);
			break;
		}
		if (h.back && backface_black) {
			if (depth == 0 && back) *back = true;
			break;
		}
		const rtgi::Tri &t = bvh.tri(h.tri);
		V3 n = h.back ? t.n * -1.0f : t.n;
		V3 p = o + d * h.t + n * 0.01f;
		V3 e = direct_light(p, n);
		L += tp * t.emission;
		if (depth < bounces) {
			L += tp * t.albedo * e;
			// cosine-weighted hemisphere sample around n
			float u1 = rng.f(), u2 = rng.f();
			float r = std::sqrt(u1), ph = 2.0f * PI_F * u2;
			V3 up = std::fabs(n.y) < 0.99f ? V3(0, 1, 0) : V3(1, 0, 0);
			V3 tx = rtgi::norm(rtgi::cross(up, n));
			V3 ty = rtgi::cross(n, tx);
			d = rtgi::norm(tx * (r * std::cos(ph)) + ty * (r * std::sin(ph)) + n * std::sqrt(std::max(0.0f, 1.0f - u1)));
			o = p;
			tp = tp * t.albedo;
			if (std::max(tp.x, std::max(tp.y, tp.z)) < 1e-4f) break;
		} else {
			if (feedback) {
				// refinement: the already-updated probe grid supplies every remaining bounce
				if (bs > 0.0f) e += lookup(p, n) * bs;
				L += tp * t.albedo * e;
			} else {
				// instant pass (nothing to feed back from): one extra ray decides whether the path escapes to the sky or keeps bouncing
				// inside the scene; if it keeps bouncing, the geometric tail of further bounces is estimated from the scene reflectance.
				L += tp * t.albedo * e;
				float u1 = rng.f(), u2 = rng.f();
				float r = std::sqrt(u1), ph = 2.0f * PI_F * u2;
				V3 up = std::fabs(n.y) < 0.99f ? V3(0, 1, 0) : V3(1, 0, 0);
				V3 tx = rtgi::norm(rtgi::cross(up, n));
				V3 ty = rtgi::cross(n, tx);
				V3 d2 = rtgi::norm(tx * (r * std::cos(ph)) + ty * (r * std::sin(ph)) + n * std::sqrt(std::max(0.0f, 1.0f - u1)));
				rtgi::Hit h2;
				if (!bvh.intersect(p, d2, 1e30f, h2)) {
					L += tp * t.albedo * sky(d2);
				} else if (!(h2.back && backface_black)) {
					V3 w = t.albedo * e;
					L += tp * V3(w.x * tail_gain.x, w.y * tail_gain.y, w.z * tail_gain.z);
				}
			}
			break;
		}
	}
	float m = std::max(L.x, std::max(L.y, L.z));
	if (m > radiance_clamp) L = L * (radiance_clamp / m);
	return L;
}

void RTGI::trace_probe(int pi, uint32_t seed, int rays, int bounces, bool feedback, float *out) const {
	int x = pi % gx, y = (pi / gx) % gy, z = pi / (gx * gy);
	V3 pos(origin.x + (x + 0.5f) / gx * size.x, origin.y + (y + 0.5f) / gy * size.y, origin.z + (z + 0.5f) / gz * size.z);
	Rng rng(seed ^ (uint32_t)pi * 2654435761u);
	V3 acc[6];
	int N = std::max(1, rays);
	float phi0 = rng.f();
	int backs = 0;
	for (int i = 0; i < N; i++) {
		float u = (i + rng.f()) / N;
		float cz = 1.0f - 2.0f * u;
		float r = std::sqrt(std::max(0.0f, 1.0f - cz * cz));
		float ph = 2.0f * PI_F * (std::fmod(i * 0.61803398875f, 1.0f) + phi0);
		V3 d(r * std::cos(ph), cz, r * std::sin(ph));
		bool back = false;
		V3 L = radiance(pos, d, bounces, feedback, rng, &back);
		if (back) backs++;
		acc[0] += L * std::max(d.x, 0.0f);
		acc[1] += L * std::max(-d.x, 0.0f);
		acc[2] += L * std::max(d.y, 0.0f);
		acc[3] += L * std::max(-d.y, 0.0f);
		acc[4] += L * std::max(d.z, 0.0f);
		acc[5] += L * std::max(-d.z, 0.0f);
	}
	float k = 4.0f / N; // (1/pi) * integral over sphere with uniform sampling
	for (int f = 0; f < 6; f++) {
		out[f * 3 + 0] = acc[f].x * k;
		out[f * 3 + 1] = acc[f].y * k;
		out[f * 3 + 2] = acc[f].z * k;
	}
	if (!vpls.empty()) gather_vpls(pos, out);
	out[18] = (backs > N * 0.3f) ? 0.0f : 1.0f; // probe sits inside solid geometry
}

// ---------------------------------------------------------------- per-frame

static int worker_threads(int requested, int count) {
	int nt = requested > 0 ? requested : (int)std::thread::hardware_concurrency();
	nt = std::max(1, std::min(nt, 32));
	return std::max(1, std::min(nt, count));
}

// Instant pass: runs in the same frame a light / sky / geometry change is detected and overwrites EVERY probe (blend = 1) with a
// fresh, self-contained estimate (explicit multi-bounce paths, no feedback from old probes). Nothing waits for convergence and no
// stale light is left behind, so there are no trails. The fixed seed keeps the sampling noise identical from frame to frame, so a
// moving light slides smoothly instead of flickering. Refinement (trace_frame) then improves the result in the following frames.
void RTGI::instant_pass() {
	size_t total = (size_t)gx * gy * gz;
	if (total == 0) return;
	results.assign(total * 19, 0.0f);
	{
		float k = std::min(0.97f, std::max(0.0f, q.bounce_strength));
		auto g = [&](float a) { float r = std::min(0.9f, std::max(0.0f, a * k)); return r / (1.0f - r); };
		tail_gain = V3(g(mean_albedo.x), g(mean_albedo.y), g(mean_albedo.z));
	}
	int nt = worker_threads(thread_count, (int)total);
	// Responsiveness guard: every probe is always overwritten, but if a full pass would exceed the time budget (slow CPU, huge grid,
	// light being dragged) the instant pass uses fewer rays per probe (never fewer than 2). Refinement restores the quality afterwards.
	int rays = q.rays_instant;
	const double budget_ms = quality_preset == QUALITY_LOW ? 10.0 : 24.0;
	if (instant_ms_per_ray > 0.0) {
		int fit = (int)(budget_ms / (instant_ms_per_ray * (double)total));
		rays = std::max(std::min(2, q.rays_instant), std::min(q.rays_instant, fit));
	}
	const int bounces = q.bounces;
	auto tp0 = std::chrono::steady_clock::now();
	auto work = [&](int tid) {
		for (size_t k = tid; k < total; k += nt) trace_probe((int)k, 0x1234567u, rays, bounces, false, &results[k * 19]);
	};
	if (nt == 1) {
		work(0);
	} else {
		std::vector<std::thread> th;
		for (int t = 1; t < nt; t++) th.emplace_back(work, t);
		work(0);
		for (auto &t : th) t.join();
	}
	{
		double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tp0).count() / ((double)total * rays);
		instant_ms_per_ray = instant_ms_per_ray > 0.0 ? instant_ms_per_ray * 0.6 + ms * 0.4 : ms;
	}
	for (size_t pi = 0; pi < total; pi++) {
		const float *src = &results[pi * 19];
		float *dst = &cube[pi * 18];
		for (int i = 0; i < 18; i++) dst[i] = src[i];
		valid[pi] = src[18];
	}
	std::fill(ages.begin(), ages.end(), (uint8_t)0);
	last_ray_count = (int)std::min<size_t>(total * rays, (size_t)2000000000);
	cursor = 0;
	sweeps_left = std::max(1, q.settle_sweeps);
	fast_left = 0;
	nobounce_left = 0;
	need_upload = true;
}

void RTGI::trace_frame() {
	size_t total = (size_t)gx * gy * gz;
	int count = (int)std::min<size_t>(total, (size_t)std::max(1, q.probes_per_frame));
	// refinement: spend up to trace_budget_ms per frame (measured), never fewer than probes_per_frame
	if (q.trace_budget_ms > 0.0f && ms_per_probe > 0.0) {
		int want = (int)std::min<double>((double)total, (double)q.trace_budget_ms / ms_per_probe);
		count = std::max(count, want);
	}
	results.assign((size_t)count * 19, 0.0f);

	int nt = worker_threads(thread_count, count);

	uint32_t seed = ++frame_counter * 9781u + 17u;
	int start = cursor;
	auto tw0 = std::chrono::steady_clock::now();
	const int rays = q.rays_refine, bounces = q.bounces;
	auto work = [&](int tid) {
		for (int k = tid; k < count; k += nt) {
			int pi = (int)((start + k) % total);
			trace_probe(pi, seed, rays, bounces, true, &results[(size_t)k * 19]);
		}
	};
	if (nt == 1) {
		work(0);
	} else {
		std::vector<std::thread> th;
		for (int t = 1; t < nt; t++) th.emplace_back(work, t);
		work(0);
		for (auto &t : th) t.join();
	}

	{
		double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tw0).count() / std::max(1, count);
		ms_per_probe = ms_per_probe > 0.0 ? ms_per_probe * 0.7 + ms * 0.3 : ms;
	}
	for (int k = 0; k < count; k++) {
		int pi = (int)((start + k) % total);
		float age = ages[pi];
		float a = std::max(q.blend, 1.0f / (age + 1.0f));
		float *dst = &cube[(size_t)pi * 18];
		const float *src = &results[(size_t)k * 19];
		for (int i = 0; i < 18; i++) dst[i] += (src[i] - dst[i]) * a;
		valid[pi] += (src[18] - valid[pi]) * a;
		if (ages[pi] < 255) ages[pi]++;
	}
	last_ray_count = count * rays;
	cursor += count;
	if ((size_t)cursor >= total) {
		cursor -= (int)total;
		if (sweeps_left > 0) sweeps_left--;
	}
	need_upload = true;
}

void RTGI::upload_atlas() {
	int W = gx * gz, H = gy * 6;
	PoolByteArray bytes;
	bytes.resize((size_t)W * H * 8);
	{
		PoolByteArray::Write w = bytes.write();
		uint16_t *px = (uint16_t *)w.ptr();
		std::memset(px, 0, (size_t)W * H * 8);
		for (int z = 0; z < gz; z++)
			for (int y = 0; y < gy; y++)
				for (int x = 0; x < gx; x++) {
					size_t pi = (size_t)(z * gy + y) * gx + x;
					for (int f = 0; f < 6; f++) {
						const float *c = &disp[(pi * 6 + f) * 3];
						size_t o = ((size_t)(f * gy + y) * W + (z * gx + x)) * 4;
						float v = valid[pi];
						px[o + 0] = float_to_half(c[0] * v);
						px[o + 1] = float_to_half(c[1] * v);
						px[o + 2] = float_to_half(c[2] * v);
						px[o + 3] = float_to_half(v);
					}
				}
	}
	Ref<Image> img;
	img.instance();
	img->create_from_data(W, H, false, Image::FORMAT_RGBAH, bytes);
	if (W != atlas_w || H != atlas_h) {
		atlas->create_from_image(img, Texture::FLAG_FILTER);
		atlas_w = W;
		atlas_h = H;
	} else {
		atlas->set_data(img);
	}
}

Vector3 RTGI::sample_gi(Vector3 pos, Vector3 normal) const {
	if (gx == 0 || disp.size() != cube.size()) return Vector3();
	V3 n = rtgi::norm(V3(normal.x, normal.y, normal.z));
	V3 r = lookup(V3(pos.x, pos.y, pos.z), n, &disp);
	return Vector3(r.x, r.y, r.z);
}

void RTGI::_process(float delta) {
	if (enabled != last_enabled) {
		last_enabled = enabled;
		for (auto &m : gi_mats) apply_params(m);
	}
	if (!enabled) return;
	if (Engine::get_singleton()->is_editor_hint() && !run_in_editor) return;
	if (shader.is_null()) return;

	Node *root = get_node_or_null(geometry_root);
	if (!root) return;

	bool need_instant = false;
	// settings hash (anything that invalidates probes or shader params)
	{
		Quality nq;
		effective_quality(nq);
		Scan t;
		t.mix(&bounds_size, sizeof(bounds_size));
		int v[] = { quality_preset, nq.probes_x, nq.probes_y, nq.probes_z, nq.rays_instant, nq.rays_refine, nq.bounces, backface_black ? 1 : 0,
			auto_apply_shader ? 1 : 0, texture_albedo ? 1 : 0 };
		t.mix(v, sizeof(v));
		float f[] = { env_ambient_strength, intensity, nq.bounce_strength, normal_bias, radiance_clamp, sky_energy };
		t.mix(f, sizeof(f));
		Transform xf = get_global_transform();
		t.mix(&xf.origin, sizeof(xf.origin));
		if (t.sig != last_settings) {
			last_settings = t.sig;
			update_shader_code();
			params_dirty = true;
			ensure_grid();
			flush_history();
			need_instant = true;
		}
	}
	if (gx == 0) {
		ensure_grid();
		need_instant = true;
	}
	effective_quality(q); // refresh the non-hashed values (budget, smoothing, denoiser ...)

	Scan sc;
	gather(root, sc);
	resolve_sky(sc.env);
	{
		float e[] = { eff_top.r, eff_top.g, eff_top.b, eff_horizon.r, eff_horizon.g, eff_horizon.b, eff_ground.r, eff_ground.g, eff_ground.b, eff_energy };
		sc.mixl(e, sizeof(e));
	}
	if (sc.sig != last_sig || !has_scene) {
		last_sig = sc.sig;
		last_lsig = sc.lsig;
		rebuild_scene(sc); // geometry / material change: new BVH (also takes the new lights)
		has_scene = true;
		need_instant = true;
	} else if (sc.lsig != last_lsig) {
		last_lsig = sc.lsig;
		lights = sc.lights; // light moved / toggled / recoloured / sky changed: no BVH rebuild needed
		need_instant = true;
	}

	if (params_dirty) {
		for (auto &m : gi_mats) apply_params(m);
		params_dirty = false;
	}

	bool show_now = false; // present the new result without any smoothing lag
	if (need_instant) {
		auto t0 = std::chrono::steady_clock::now();
		flush_history();
		build_vpls();
		instant_pass();
		last_trace_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
		show_now = true;
	} else if (!(update_only_on_change && sweeps_left <= 0)) {
		auto t0 = std::chrono::steady_clock::now();
		trace_frame();
		last_trace_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	} else {
		last_ray_count = 0;
		last_trace_ms = 0.0;
	}
	if (need_upload) disp_dirty = true;
	if (disp_dirty && disp.size() == cube.size()) {
		// smoothing only hides refinement noise; a lighting change (show_now) is displayed at once
		float k = 1.0f - std::pow(1.0f - std::min(0.999f, std::max(0.02f, q.display_smoothing)), std::max(0.25f, std::min(4.0f, delta * 60.0f)));
		if (q.display_smoothing >= 0.999f || show_now) k = 1.0f;
		// spatial denoise: edge-aware blur across neighbouring probes (strongest on freshly re-traced, noisy probes)
		const std::vector<float> *target = &cube;
		if (q.denoise) {
			rtgi::DenoiseParams dp;
			dp.strength = std::min(1.0f, std::max(0.0f, q.denoise_strength));
			dp.edge = std::max(0.05f, q.denoise_edge);
			dp.passes = q.denoise_passes;
			int dnt = thread_count > 0 ? thread_count : (int)std::thread::hardware_concurrency();
			dnt = std::max(1, std::min(dnt, 32));
			rtgi::denoise_probes(cube, den, den_tmp, valid, ages, gx, gy, gz, dp, dnt);
			target = &den;
		}
		float maxd = 0.0f;
		for (size_t i = 0; i < cube.size(); i++) {
			float d = (*target)[i] - disp[i];
			disp[i] += d * k;
			maxd = std::max(maxd, std::fabs(d));
		}
		if (maxd <= 2e-4f || k >= 1.0f) {
			if (k >= 1.0f) disp = *target;
			if (maxd <= 2e-4f) {
				disp = *target;
				disp_dirty = false;
			}
		}
		need_upload = true;
	}
	if (need_upload) {
		upload_atlas();
		need_upload = false;
	}
}
