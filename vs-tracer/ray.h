#ifndef RAY_H_
#define RAY_H_

#include "vec3.h"

class ray {
public:
	ray() {}
	ray(const vec3& a, const vec3& b) { A = a; B = b;}
	const vec3& origin() const { return A; }
	const vec3& direction() const { return B; }
	vec3 point_at_parameter(float t) const { return A + t*B; }

	vec3 A;
	vec3 B;
};

struct cu_ray {
	float3 origin;
	float3 direction;

	cu_ray() {}
	cu_ray(cu_ray& r) { origin = r.origin; direction = r.direction; }
};

struct sample {
	unsigned int pixelId;
	unsigned int depth;

	sample() {}
	sample(sample& s) { pixelId = s.pixelId; depth = s.depth; }
};

#endif /* RAY_H_ */
