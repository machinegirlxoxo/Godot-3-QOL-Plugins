#pragma once

#include <Godot.hpp>
#include <Spatial.hpp>
#include <Mesh.hpp>
#include <MeshInstance.hpp>
#include <GeometryInstance.hpp>
#include <CSGShape.hpp>
#include <Environment.hpp>
#include <WorldEnvironment.hpp>
#include <Light.hpp>
#include <ImageTexture.hpp>
#include <Shader.hpp>
#include <ShaderMaterial.hpp>

#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "bvh.h"
#include "denoise.h"

namespace rtgi {
struct Rng32 {
	uint32_t s;
	explicit Rng32(uint32_t seed) : s(seed * 747796405u + 2891336453u) { if (!s) s = 1; next(); next(); }
	inline uint32_t next() {
		s ^= s << 13;
		s ^= s >> 17;
		s ^= s << 5;
		return s;
	}
	inline float f() { return (next() >> 8) * (1.0f / 16777216.0f); }
};
} // namespace rtgi

namespace godot {

class RTGI : public Spatial {
	GODOT_CLASS(RTGI, Spatial)

	struct LightData {
		int type; // 0 directional, 1 omni, 2 spot
		rtgi::V3 pos, dir, color;
		float range, atten, spot_angle, spot_atten;
	};
	struct MeshGeo {
		struct Surf {
			std::vector<rtgi::V3> v;
			std::vector<int> idx;
			std::vector<uint8_t> flip; // per triangle: winding disagrees with the mesh's vertex normals
		};
		std::vector<Surf> surfs;
	};
	struct SurfCol {
		rtgi::V3 albedo, emission;
	};
	struct Item {
		Ref<Mesh> mesh;
		uint64_t mesh_id;
		float m[12]; // row-major 3x4 world matrix
		std::vector<SurfCol> cols;
	};
	struct Scan {
		std::vector<Item> items;
		std::vector<LightData> lights;
		Ref<Environment> env;
		uint64_t sig = 1469598103934665603ULL; // geometry + materials (anything that needs a BVH rebuild)
		uint64_t lsig = 1469598103934665603ULL; // lights + sky (cheap: no BVH rebuild needed)
		void mix(const void *p, size_t n);
		void mixl(const void *p, size_t n);
	};

	// Quality preset: Low / High use the tuned values from effective_quality(); Custom uses the individual properties below.
	enum QualityPreset { QUALITY_LOW = 0, QUALITY_HIGH = 1, QUALITY_CUSTOM = 2 };
	// Values actually used by the tracer this frame (derived from the preset, or from the exported properties for Custom).
	struct Quality {
		int probes_x, probes_y, probes_z;
		int rays_refine; // rays per probe for progressive refinement sweeps
		int rays_instant; // rays per probe for the instant (same-frame, whole-grid) pass
		int bounces; // explicit diffuse bounces traced per path (the rest comes from probe feedback during refinement)
		int probes_per_frame; // minimum refinement probes per frame
		float trace_budget_ms; // refinement time budget per frame
		int settle_sweeps; // refinement sweeps after a change before going idle
		float bounce_strength; // probe feedback strength used by refinement
		float display_smoothing; // smoothing of refinement results only (changes are always shown instantly)
		bool denoise;
		float denoise_strength, denoise_edge;
		int denoise_passes;
		float blend;
	};

	// ---- exported properties ----
	bool enabled = true;
	int quality_preset = QUALITY_CUSTOM; // 0 Low, 1 High, 2 Custom (uses the properties below)
	int instant_rays = 8; // Custom: rays per probe in the instant pass
	int instant_bounces = 2; // Custom: explicit diffuse bounces traced per path
	bool run_in_editor = true;
	bool auto_apply_shader = true;
	bool update_only_on_change = true;
	bool backface_black = true;
	bool texture_albedo = true; // bounce light uses the albedo texture's average colour, not just the material colour
	float env_ambient_strength = 0.0f;
	NodePath geometry_root = NodePath("..");
	Vector3 bounds_size = Vector3(16, 8, 16);
	int probes_x = 16, probes_y = 8, probes_z = 16;
	int rays_per_probe = 96;
	int probes_per_frame = 256;
	int thread_count = 0;
	int settle_sweeps = 16;
	int fast_sweeps = 8;
	float fast_blend = 1.0f;
	float trace_budget_ms = 8.0f;
	float display_smoothing = 0.4f;
	bool denoise = true;
	float denoise_strength = 0.6f;
	float denoise_edge = 0.5f;
	int denoise_passes = 2;
	float blend = 0.1f;
	float intensity = 5.0f;
	float bounce_strength = 0.97f;
	float normal_bias = 1.8f;
	float radiance_clamp = 6.0f;
	float sky_energy = 1.1f;
	Color eff_top, eff_horizon, eff_ground; // sky taken from the Environment
	float eff_energy = 1.0f;
	uint64_t pano_id = 0;
	bool pano_ok = false;
	Color pano_top, pano_horizon, pano_ground;

	// ---- runtime state ----
	rtgi::BVH bvh;
	std::vector<LightData> lights;
	struct Vpl { rtgi::V3 pos, n, rad; float area; };
	std::vector<Vpl> vpls; // spot-light patches (virtual point lights)
	std::unordered_map<uint64_t, std::shared_ptr<MeshGeo>> geo_cache;
	std::vector<float> cube; // probes * 6 faces * RGB (accumulator, used for bounce feedback)
	std::vector<float> disp; // smoothed copy that is uploaded to the shader
	std::vector<float> den, den_tmp; // spatially denoised copy of cube (what disp chases when denoise is on)
	bool disp_dirty = true;
	int nobounce_left = 0;
	double ms_per_probe = 0.0;
	double instant_ms_per_ray = 0.0; // measured cost of the instant pass (per probe-ray), for the responsiveness guard
	std::vector<float> valid; // 1 = probe in free space, 0 = inside geometry
	std::vector<uint8_t> ages;
	std::vector<float> results;
	uint64_t last_sig = 0, last_lsig = 0, last_settings = 0;
	Quality q; // effective quality this frame
	int gen_bounces = 0; // explicit bounces of the path currently being traced
	rtgi::V3 mean_albedo = rtgi::V3(0.5f, 0.5f, 0.5f), tail_gain; // scene reflectance (area weighted) and per-channel infinite-bounce tail factor for the instant pass
	bool use_feedback = true; // false during the instant pass (probes are being overwritten, so they must not feed back)
	int cursor = 0, sweeps_left = 0, fast_left = 0;
	bool last_enabled = true;
	bool need_upload = true, params_dirty = true, has_scene = false;
	rtgi::V3 origin, size;
	int gx = 0, gy = 0, gz = 0;
	uint32_t frame_counter = 0;
	double last_trace_ms = 0.0;
	int last_ray_count = 0;
	Ref<ImageTexture> atlas;
	int atlas_w = 0, atlas_h = 0;
	Ref<Shader> shader;
	std::vector<Ref<ShaderMaterial>> gi_mats;
	std::unordered_set<uint64_t> known_mats;

	void gather(Node *n, Scan &s);
	void convert_materials(GeometryInstance *gi, MeshInstance *mi, const Ref<Mesh> &mesh);
	void surface_colors(GeometryInstance *gi, MeshInstance *mi, const Ref<Mesh> &mesh, int s, SurfCol &out, Scan &sc);
	void flush_history();
	void update_shader_code();
	void resolve_sky(const Ref<Environment> &env);
	void rebuild_scene(const Scan &s);
	void ensure_grid();
	void trace_frame();
	void instant_pass();
	void effective_quality(Quality &out) const;
	void upload_atlas();
	void apply_params(Ref<ShaderMaterial> m);
	void register_gi_material(Ref<ShaderMaterial> m);
	void restore_materials(Node *n);
	std::shared_ptr<MeshGeo> get_geo(const Ref<Mesh> &mesh, uint64_t id);

	rtgi::V3 sky(const rtgi::V3 &d) const;
	rtgi::V3 light_at(const LightData &l, const rtgi::V3 &p, const rtgi::V3 &n) const;
	rtgi::V3 direct_light(const rtgi::V3 &p, const rtgi::V3 &n) const;
	void build_vpls();
	void gather_vpls(const rtgi::V3 &pos, float *out) const;
	rtgi::V3 lookup(const rtgi::V3 &p, const rtgi::V3 &n, const std::vector<float> *buf = nullptr) const;
	rtgi::V3 radiance(const rtgi::V3 &o, const rtgi::V3 &d, int bounces, bool feedback, rtgi::Rng32 &rng, bool *back = nullptr) const;
	void trace_probe(int pi, uint32_t seed, int rays, int bounces, bool feedback, float *out) const;

public:
	static void _register_methods();
	void _init();
	void _ready();
	void _exit_tree();
	void _process(float delta);

	void set_quality_preset(int p);
	String get_quality_info();
	int get_quality_preset() const { return quality_preset; }
	Vector3 sample_gi(Vector3 pos, Vector3 normal) const; // CPU query of the probe grid (what the shaders see, before intensity)
	void rebuild();
	void reset();
	double get_trace_ms() const { return last_trace_ms; }
	int get_ray_count() const { return last_ray_count; }
	bool is_settled() const { return sweeps_left <= 0; }
	int get_invalid_probe_count() const {
		int n = 0;
		for (float v : valid) if (v < 0.5f) n++;
		return n;
	}
};

} // namespace godot
