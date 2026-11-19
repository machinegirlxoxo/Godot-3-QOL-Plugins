#pragma once
#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <vector>

namespace rtgi {

struct V3 {
	float x, y, z;
	V3() : x(0), y(0), z(0) {}
	V3(float a, float b, float c) : x(a), y(b), z(c) {}
	V3 operator+(const V3 &o) const { return V3(x + o.x, y + o.y, z + o.z); }
	V3 operator-(const V3 &o) const { return V3(x - o.x, y - o.y, z - o.z); }
	V3 operator*(float s) const { return V3(x * s, y * s, z * s); }
	V3 operator*(const V3 &o) const { return V3(x * o.x, y * o.y, z * o.z); }
	V3 &operator+=(const V3 &o) { x += o.x; y += o.y; z += o.z; return *this; }
	float operator[](int i) const { return i == 0 ? x : (i == 1 ? y : z); }
};
inline float dot(const V3 &a, const V3 &b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline V3 cross(const V3 &a, const V3 &b) { return V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
inline float len(const V3 &a) { return std::sqrt(dot(a, a)); }
inline V3 norm(const V3 &a) { float l = len(a); return l > 1e-20f ? a * (1.0f / l) : V3(0, 1, 0); }
inline V3 vmin(const V3 &a, const V3 &b) { return V3(std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)); }
inline V3 vmax(const V3 &a, const V3 &b) { return V3(std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)); }

struct Tri {
	V3 v0, e1, e2, n; // n = outward geometric normal (set by the caller)
	V3 albedo, emission;
};

struct Hit {
	float t;
	int tri;
	bool back;
};

class BVH {
	struct Node {
		V3 bmin, bmax;
		int left_or_first; // inner: left child index (right = left + 1); leaf: first tri
		int count; // >0 => leaf
	};
	std::vector<Node> nodes;
	std::vector<Tri> tris;

	void build_node(int node, int start, int end, std::vector<int> &order, const std::vector<V3> &cent, const std::vector<Tri> &src) {
		V3 bmin(FLT_MAX, FLT_MAX, FLT_MAX), bmax(-FLT_MAX, -FLT_MAX, -FLT_MAX);
		V3 cmin = bmin, cmax = bmax;
		for (int i = start; i < end; i++) {
			const Tri &t = src[order[i]];
			V3 a = t.v0, b = t.v0 + t.e1, c = t.v0 + t.e2;
			bmin = vmin(bmin, vmin(a, vmin(b, c)));
			bmax = vmax(bmax, vmax(a, vmax(b, c)));
			cmin = vmin(cmin, cent[order[i]]);
			cmax = vmax(cmax, cent[order[i]]);
		}
		nodes[node].bmin = bmin;
		nodes[node].bmax = bmax;
		int n = end - start;
		if (n <= 4) {
			nodes[node].left_or_first = start;
			nodes[node].count = n;
			return;
		}
		V3 ext = cmax - cmin;
		int axis = (ext.x > ext.y && ext.x > ext.z) ? 0 : (ext.y > ext.z ? 1 : 2);
		int mid = (start + end) / 2;
		std::nth_element(order.begin() + start, order.begin() + mid, order.begin() + end,
				[&](int a, int b) { return cent[a][axis] < cent[b][axis]; });
		int left = (int)nodes.size();
		nodes.resize(nodes.size() + 2);
		nodes[node].left_or_first = left;
		nodes[node].count = 0;
		build_node(left, start, mid, order, cent, src);
		build_node(left + 1, mid, end, order, cent, src);
	}

	static inline bool slab(const V3 &bmin, const V3 &bmax, const V3 &o, const V3 &inv, float tmax) {
		float t1 = (bmin.x - o.x) * inv.x, t2 = (bmax.x - o.x) * inv.x;
		float tn = std::min(t1, t2), tf = std::max(t1, t2);
		t1 = (bmin.y - o.y) * inv.y; t2 = (bmax.y - o.y) * inv.y;
		tn = std::max(tn, std::min(t1, t2)); tf = std::min(tf, std::max(t1, t2));
		t1 = (bmin.z - o.z) * inv.z; t2 = (bmax.z - o.z) * inv.z;
		tn = std::max(tn, std::min(t1, t2)); tf = std::min(tf, std::max(t1, t2));
		return tf >= std::max(tn, 0.0f) && tn < tmax;
	}

	static inline bool tri_hit(const Tri &t, const V3 &o, const V3 &d, float tmax, float &out_t) {
		V3 p = cross(d, t.e2);
		float det = dot(t.e1, p);
		if (std::fabs(det) < 1e-12f) return false;
		float inv = 1.0f / det;
		V3 s = o - t.v0;
		float u = dot(s, p) * inv;
		if (u < 0.0f || u > 1.0f) return false;
		V3 q = cross(s, t.e1);
		float v = dot(d, q) * inv;
		if (v < 0.0f || u + v > 1.0f) return false;
		float tt = dot(t.e2, q) * inv;
		if (tt < 1e-4f || tt >= tmax) return false;
		out_t = tt;
		return true;
	}

	static inline V3 safe_inv(const V3 &d) {
		return V3(1.0f / (std::fabs(d.x) > 1e-20f ? d.x : 1e-20f), 1.0f / (std::fabs(d.y) > 1e-20f ? d.y : 1e-20f), 1.0f / (std::fabs(d.z) > 1e-20f ? d.z : 1e-20f));
	}

public:
	bool empty() const { return tris.empty(); }
	size_t tri_count() const { return tris.size(); }
	const Tri &tri(int i) const { return tris[i]; }

	void build(std::vector<Tri> &src) {
		nodes.clear();
		tris.clear();
		if (src.empty()) return;
		int n = (int)src.size();
		std::vector<int> order(n);
		std::vector<V3> cent(n);
		for (int i = 0; i < n; i++) {
			order[i] = i;
			cent[i] = src[i].v0 + (src[i].e1 + src[i].e2) * (1.0f / 3.0f);
		}
		nodes.reserve(n + 8);
		nodes.resize(1);
		build_node(0, 0, n, order, cent, src);
		tris.resize(n);
		for (int i = 0; i < n; i++) tris[i] = src[order[i]];
	}

	bool intersect(const V3 &o, const V3 &d, float tmax, Hit &h) const {
		if (nodes.empty()) return false;
		V3 inv = safe_inv(d);
		int stack[64];
		int sp = 0;
		stack[sp++] = 0;
		bool found = false;
		float best = tmax;
		while (sp > 0) {
			const Node &nd = nodes[stack[--sp]];
			if (!slab(nd.bmin, nd.bmax, o, inv, best)) continue;
			if (nd.count > 0) {
				for (int i = 0; i < nd.count; i++) {
					float t;
					if (tri_hit(tris[nd.left_or_first + i], o, d, best, t)) {
						best = t;
						h.t = t;
						h.tri = nd.left_or_first + i;
						found = true;
					}
				}
			} else if (sp < 62) {
				stack[sp++] = nd.left_or_first;
				stack[sp++] = nd.left_or_first + 1;
			}
		}
		if (found) h.back = dot(d, tris[h.tri].n) > 0.0f;
		return found;
	}

	bool occluded(const V3 &o, const V3 &d, float tmax) const {
		if (nodes.empty()) return false;
		V3 inv = safe_inv(d);
		int stack[64];
		int sp = 0;
		stack[sp++] = 0;
		while (sp > 0) {
			const Node &nd = nodes[stack[--sp]];
			if (!slab(nd.bmin, nd.bmax, o, inv, tmax)) continue;
			if (nd.count > 0) {
				for (int i = 0; i < nd.count; i++) {
					float t;
					if (tri_hit(tris[nd.left_or_first + i], o, d, tmax, t)) return true;
				}
			} else if (sp < 62) {
				stack[sp++] = nd.left_or_first;
				stack[sp++] = nd.left_or_first + 1;
			}
		}
		return false;
	}
};

} // namespace rtgi
