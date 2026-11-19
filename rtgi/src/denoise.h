#pragma once
// Edge-aware spatial denoiser for the RTGI probe grid.
// Pure C++ (no Godot types) so it can be unit tested on its own.
//
// Layout (same as RTGI::cube): probe index pi = (z * gy + y) * gx + x, 6 faces * RGB per probe -> 18 floats.
//
// Each pass is a 3x3x3 cross-bilateral filter run per probe face:
//   weight = gaussian(distance) * probe validity * luminance edge-stop
// Young probes (just re-traced after a light/geometry change, so they hold one noisy sample)
// get a stronger filter and a looser edge-stop than converged ones. That is what removes the
// blotchy "blob" noise while a light is being dragged, and it relaxes by itself once probes settle.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

namespace rtgi {

struct DenoiseParams {
	float strength = 0.75f; // 0..1, how much of the filtered result is used for converged probes
	float edge = 0.5f; // luminance edge-stop width (relative); smaller keeps more contrast between probes
	int passes = 2; // 3x3x3 passes (2 ~ 5x5x5, 3 ~ 7x7x7)
	float young_boost = 1.0f; // extra smoothing for probes with few samples (1 = default, 0 = none)
};

inline float luma(const float *c) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }

// src/dst: probes * 18 floats. valid: probes. ages: probes (number of samples folded into the probe).
// tmp is scratch with the same size as src. Result ends up in dst. src is left untouched.
inline void denoise_probes(const std::vector<float> &src, std::vector<float> &dst, std::vector<float> &tmp,
		const std::vector<float> &valid, const std::vector<uint8_t> &ages,
		int gx, int gy, int gz, const DenoiseParams &prm, int threads = 1) {
	const size_t total = (size_t)gx * gy * gz;
	dst = src;
	if (prm.strength <= 0.0f || prm.passes <= 0 || total == 0) return;
	tmp.resize(src.size());

	const int passes = std::max(1, std::min(4, prm.passes));
	// gaussian-ish spatial weights for offsets of 0 / 1 / sqrt2 / sqrt3 cells
	const float gw[4] = { 1.0f, 0.55f, 0.30f, 0.17f };

	for (int pass = 0; pass < passes; pass++) {
		const std::vector<float> &in = (pass == 0) ? src : (pass & 1 ? dst : tmp);
		std::vector<float> &out = (pass & 1) ? tmp : dst;
		// ping-pong: pass 0 src->dst, pass 1 dst->tmp, pass 2 tmp->dst, ...
		const float *I = in.data();
		float *O = out.data();

		auto run_range = [&](int z0, int z1) {
			for (int z = z0; z < z1; z++)
				for (int y = 0; y < gy; y++)
					for (int x = 0; x < gx; x++) {
						size_t pi = (size_t)(z * gy + y) * gx + x;
						float *o = O + pi * 18;
						const float *c0p = I + pi * 18;
						if (valid[pi] < 0.5f) { // probe inside geometry: leave alone
							for (int i = 0; i < 18; i++) o[i] = c0p[i];
							continue;
						}
						float youth = 1.0f / (1.0f + (float)ages[pi]); // 1 for fresh probes, ~0 for converged ones
						float k = prm.strength + (1.0f - prm.strength) * std::min(1.0f, youth * prm.young_boost);
						float sig_scale = prm.edge * (1.0f + 2.0f * youth * prm.young_boost);
						for (int f = 0; f < 6; f++) {
							const float *c0 = c0p + f * 3;
							float l0 = luma(c0);
							float acc[3] = { 0, 0, 0 };
							float wsum = 0.0f;
							for (int dz = -1; dz <= 1; dz++) {
								int zz = z + dz;
								if (zz < 0 || zz >= gz) continue;
								for (int dy = -1; dy <= 1; dy++) {
									int yy = y + dy;
									if (yy < 0 || yy >= gy) continue;
									for (int dx = -1; dx <= 1; dx++) {
										int xx = x + dx;
										if (xx < 0 || xx >= gx) continue;
										size_t qi = (size_t)(zz * gy + yy) * gx + xx;
										float v = valid[qi];
										if (v < 0.5f) continue;
										const float *cn = I + qi * 18 + f * 3;
										float ln = luma(cn);
										float dl = ln - l0;
										float sigma = sig_scale * (0.05f + 0.5f * (l0 + ln));
										float we = std::exp(-(dl * dl) / (2.0f * sigma * sigma));
										float ws = gw[std::abs(dx) + std::abs(dy) + std::abs(dz)];
										float w = ws * we * v;
										acc[0] += cn[0] * w;
										acc[1] += cn[1] * w;
										acc[2] += cn[2] * w;
										wsum += w;
									}
								}
							}
							if (wsum > 1e-6f) {
								float inv = 1.0f / wsum;
								for (int ch = 0; ch < 3; ch++) o[f * 3 + ch] = c0[ch] + (acc[ch] * inv - c0[ch]) * k;
							} else {
								for (int ch = 0; ch < 3; ch++) o[f * 3 + ch] = c0[ch];
							}
						}
					}
		};

		int nt = std::max(1, std::min(threads, gz));
		if (nt == 1 || total < 4096) {
			run_range(0, gz);
		} else {
			std::vector<std::thread> th;
			for (int t = 1; t < nt; t++) th.emplace_back(run_range, gz * t / nt, gz * (t + 1) / nt);
			run_range(0, gz / nt); // thread 0 takes [0, gz/nt), thread t takes [gz*t/nt, gz*(t+1)/nt)
			for (auto &t : th) t.join();
		}
	}
	// after the loop the last written buffer must be dst
	if (((passes - 1) & 1) != 0) dst = tmp;
}

} // namespace rtgi
