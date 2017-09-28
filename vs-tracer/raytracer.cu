#include <iostream>
#include <float.h>
#include <fstream>
#include <ctime>
#include <SDL.h>

// For the CUDA runtime routines (prefixed with "cuda_")
#include <cuda_runtime.h>
#include <cuda_profiler_api.h>
#include <helper_cuda.h>

#include "sphere.h"
#include "camera.h"
#include "hitable_list.h"

//#define DBG_ID (150*600+300)
char buffer[100];

clock_t kernel = 0;
clock_t generate = 0;
clock_t compact = 0;

using namespace std;

struct cu_hit {
	int hit_idx;
	float hit_t;
};

struct pixel {
	//TODO pixel should know it's coordinates and it's id should be a computed field
	unsigned int id;
	unsigned int samples;

	pixel() { id = 0; samples = 0; }
};

class pixel_compare {
public:
	bool operator() (pixel p0, pixel p1)
	{
		return p0.samples < p1.samples;
	}
};

hitable_list *random_scene()
{
    int n = 500;
    hitable **list = new hitable*[n+1];
    list[0] =  new sphere(vec3(0,-1000,0), 1000, make_lambertian(vec3(0.5, 0.5, 0.5)));
    int i = 1;
    for (int a = -11; a < 11; a++) {
        for (int b = -11; b < 11; b++) {
            float choose_mat = drand48();
            vec3 center(a+0.9*drand48(),0.2,b+0.9*drand48());
            if ((center-vec3(4,0.2,0)).length() > 0.9) {
                if (choose_mat < 0.8) {  // diffuse
                    list[i++] = new sphere(center, 0.2, make_lambertian(vec3(drand48()*drand48(), drand48()*drand48(), drand48()*drand48())));
                }
                else if (choose_mat < 0.95) { // metal
                    list[i++] = new sphere(center, 0.2,
                            make_metal(vec3(0.5*(1 + drand48()), 0.5*(1 + drand48()), 0.5*(1 + drand48())),  0.5*drand48()));
                }
                else {  // glass
                    list[i++] = new sphere(center, 0.2, make_dielectric(1.5));
                }
            }
        }
    }

    list[i++] = new sphere(vec3(0, 1, 0), 1.0, make_dielectric(1.5));
    list[i++] = new sphere(vec3(-4, 1, 0), 1.0, make_lambertian(vec3(0.4, 0.2, 0.1)));
    list[i++] = new sphere(vec3(4, 1, 0), 1.0, make_metal(vec3(0.7, 0.6, 0.5), 0.0));

    return new hitable_list(list,i);
}

cu_sphere*
init_cu_scene(const hitable_list* world)
{
	const unsigned int size = world->list_size;
	cu_sphere* scene = (cu_sphere*) malloc(size*sizeof(cu_sphere));
	for (int i = 0; i < size; i++)
	{
		const sphere *s = (sphere*) world->list[i];
		scene[i].center = make_float3(s->center.x(), s->center.y(), s->center.z());
		scene[i].radius = s->radius;
	}

	return scene;
}

inline void generate_ray(const camera* cam, cu_ray& r, const unsigned int x, const unsigned int y, const unsigned int nx, const unsigned int ny)
{
	float u = float(x + drand48()) / float(nx);
	float v = float(y + drand48()) / float(ny);
	cam->get_ray(u, v, r);
	r.depth = 0;
	r.pixelId = (ny - y - 1)*nx + x;
}

cu_ray*
generate_rays(const camera* cam, cu_ray* rays, const unsigned int nx, const unsigned int ny)
{
	unsigned int ray_idx = 0;
    for (int j = ny-1; j >= 0; j--)
		for (int i = 0; i < nx; ++i, ++ray_idx)
			generate_ray(cam, rays[ray_idx], i, j, nx, ny);

    return rays;
}

camera*
init_camera(unsigned int nx, unsigned int ny)
{
    vec3 lookfrom(13,2,3);
    vec3 lookat(0,0,0);
    float dist_to_focus = 10.0;
    float aperture = 0.1;

    return new camera(lookfrom, lookat, vec3(0,1,0), 20, float(nx)/float(ny), aperture, dist_to_focus);
}

__global__ void
hit_scene(const cu_ray* rays, const unsigned int num_rays, const cu_sphere* scene, const unsigned int scene_size, float t_min, float t_max, cu_hit* hits)
{
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i >= num_rays)
    	return;

    const cu_ray *r = &(rays[i]);
    const float3 ro = r->origin;
    const float3 rd = r->direction;

    float closest_hit = t_max;
    int hit_idx = -1;

//    if (i == DBG_ID) printf("hit_scene: ro = (%.2f, %.2f, %.2f) rd = (%.2f, %.2f, %.2f) \n", ro.x, ro.y, ro.z, rd.x, rd.y, rd.z);

    for (int s = 0; s < scene_size; s++)
    {
    	const cu_sphere sphere = scene[s];
    	const float3 sc = sphere.center;
    	const float sr = sphere.radius;

    	float3 oc = make_float3(ro.x-sc.x, ro.y-sc.y, ro.z-sc.z);
    	float a = rd.x*rd.x + rd.y*rd.y + rd.z*rd.z;
    	float b = 2.0f * (oc.x*rd.x + oc.y*rd.y + oc.z*rd.z);
    	float c = oc.x*oc.x + oc.y*oc.y + oc.z*oc.z - sr*sr;
    	float discriminant = b*b - 4*a*c;
    	if (discriminant > 0)
    	{
    		float t = (-b - sqrtf(discriminant)) / (2.0f*a);
    		if (t < closest_hit && t > t_min) {
    			closest_hit = t;
    			hit_idx = s;
    		}
    	}
    }

    hits[i].hit_t = closest_hit;
    hits[i].hit_idx = hit_idx;

//    if (i == DBG_ID) printf("hit_scene: hit_idx = %d, hit_t = %.2f\n", hit_idx, closest_hit);
}

bool color(cu_ray& cu_r, const cu_hit& hit, const hitable_list *world, vec3& sample_clr, const unsigned int max_depth) {
	ray r = ray(vec3(cu_r.origin), vec3(cu_r.direction));

	if (hit.hit_idx == -1) {
		// no intersection with spheres, return sky color
		vec3 unit_direction = unit_vector(r.direction());
		float t = 0.5*(unit_direction.y() + 1.0);
		sample_clr *= (1 - t)*vec3(1.0, 1.0, 1.0) + t*vec3(0.5, 0.7, 1.0);
//		if (sample_id == DBG_ID) printf("no_hit: %s\n", sample_clr.to_string(buffer));
		return false;
	}

	hit_record rec;
	sphere *s = (sphere*) (world->list[hit.hit_idx]);
	rec.t = hit.hit_t;
	rec.p = r.point_at_parameter(hit.hit_t);
	rec.normal = (rec.p - s->center) / s->radius;
	rec.mat_ptr = s->mat_ptr;

	vec3 attenuation;
	if ((++cu_r.depth) <= max_depth && scatter(*rec.mat_ptr, r, rec, attenuation, r)) {
		cu_r.origin = r.origin().to_float3();
		cu_r.direction = r.direction().to_float3();

		sample_clr *= attenuation;
//		if (sample_id == DBG_ID) printf("scatter: %s\n", sample_clr.to_string(buffer));
		return true;
	}

	sample_clr = vec3(0, 0, 0);
//	if (sample_id == DBG_ID) printf("no_scatter: %s\n", sample_clr.to_string(buffer));
	return false;
}

void err(cudaError_t err, char *msg)
{
	if (err != cudaSuccess)
	{
		fprintf(stderr, "Failed to %s (error code %s)!\n", msg, cudaGetErrorString(err));
		exit(EXIT_FAILURE);
	}
}

void run_kernel(cu_ray* h_rays, cu_ray* d_rays, const unsigned int num_rays, cu_hit* h_hits, cu_hit* d_hits, cu_sphere* d_scene, unsigned int scene_size)
{
	// copying rays to device
	err(cudaMemcpy(d_rays, h_rays, num_rays * sizeof(cu_ray), cudaMemcpyHostToDevice), "copy rays from host to device");

	// Launch the CUDA Kernel
	int threadsPerBlock = 128;
	int blocksPerGrid = (num_rays + threadsPerBlock - 1) / threadsPerBlock;
	hit_scene << <blocksPerGrid, threadsPerBlock >> >(d_rays, num_rays, d_scene, scene_size, 0.001, FLT_MAX, d_hits);
	err(cudaGetLastError(), "launch kernel");

	// Copy the results to host
	err(cudaMemcpy(h_hits, d_hits, num_rays * sizeof(cu_hit), cudaMemcpyDeviceToHost), "copy results from device to host");
}

unsigned int compact_rays(cu_ray* h_rays, unsigned int num_rays, cu_hit* h_hits, const hitable_list* world, vec3* h_sample_colors, vec3* h_colors, 
	pixel* pixels, unsigned int num_pixels, const camera* cam, unsigned int nx, unsigned int ny, unsigned int ns)
{
	const int max_depth = 50;
	const float min_attenuation = 0.01;

	// first step only generate scattered rays and compact them
	clock_t start = clock();
	unsigned int ray_idx = 0;
	for (unsigned int i = 0; i < num_rays; ++i)
	{
		const unsigned int pixelId = h_rays[i].pixelId;
		if (color(h_rays[i], h_hits[i], world, h_sample_colors[i], max_depth) && h_sample_colors[i].squared_length() > min_attenuation)
		{
			// compact ray
			h_rays[ray_idx] = h_rays[i];
			h_sample_colors[ray_idx] = h_sample_colors[i];
			++ray_idx;
		}
		else
		{
			// ray is no longer active, cumulate its color
			h_colors[pixelId] += h_sample_colors[i];

		}
	}
	compact += clock() - start;
	// for each ray that's no longer active, sample a pixel that's not fully sampled yet
	start = clock();
	unsigned int sampled = 0;
	do
	{
		sampled = 0;
		for (unsigned int i = 0; i < num_pixels && ray_idx < num_pixels; ++i)
		{
			const unsigned int pixelId = pixels[i].id;
			if (pixels[i].samples < ns)
			{
				pixels[i].samples++;
				// then, generate a new sample
				const unsigned int x = pixelId % nx;
				const unsigned int y = ny - 1 - (pixelId / nx);
				generate_ray(cam, h_rays[ray_idx], x, y, nx, ny);
				h_sample_colors[ray_idx] = vec3(1, 1, 1);
				++ray_idx;
				++sampled;
			}
		}
	} while (ray_idx < num_pixels && sampled > 0);
	generate += clock() - start;
	return ray_idx;
}
/**
 * Host main routine
 */
int main(int argc, char** argv)
{
	bool quit = false;
	SDL_Event event;

	SDL_Init(SDL_INIT_VIDEO);

	const unsigned int scene_size = 500;

	printf("preparing renderer...\n");

	const int nx = 600;
	const int ny = 300;
	const int ns = 1000;
	const hitable_list *world = random_scene();

	cu_sphere *h_scene = init_cu_scene(world);
    const camera *cam = init_camera(nx, ny);
    const unsigned int num_pixels = nx*ny;
	pixel* pixels = new pixel[num_pixels];
	cu_ray *h_rays = new cu_ray[num_pixels];
	vec3 *h_colors = new vec3[num_pixels];
	vec3 *h_sample_colors = new vec3[num_pixels];

	cu_hit *h_hits = new cu_hit[num_pixels];

    // allocate device memory for input
    cu_sphere *d_scene = NULL;
	err(cudaMalloc((void **)&d_scene, scene_size * sizeof(cu_sphere)), "allocate device d_scene");

    cu_ray *d_rays = NULL;
	err(cudaMalloc((void **)&d_rays, num_pixels * sizeof(cu_ray)), "allocate device d_rays");

    cu_hit *d_hits = NULL;
	err(cudaMalloc((void **)&d_hits, num_pixels * sizeof(cu_hit)), "allocate device d_hits");

    // Copy the host input in host memory to the device input in device memory
	err(cudaMemcpy(d_scene, h_scene, world->list_size * sizeof(cu_sphere), cudaMemcpyHostToDevice), "copy scene from host to device");

	SDL_Window* screen = SDL_CreateWindow("Voxel Tracer", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, nx, ny, 0);
	SDL_Renderer* renderer = SDL_CreateRenderer(screen, -1, 0);
	SDL_Texture* texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, nx, ny);
	Uint32 * pix_array = new Uint32[nx * ny];

    clock_t begin = clock();

	// set temporary variables
	for (int i = 0; i < num_pixels; i++)
	{
		h_sample_colors[i] = vec3(1, 1, 1);
		pixels[i].id = i;
		pixels[i].samples = 1; // we initially generate one ray per pixel
	}

	// generate initial samples: one per pixel
	clock_t start = clock();
	generate_rays(cam, h_rays, nx, ny);
	generate += clock() - start;
	
	unsigned int num_rays = num_pixels;
	unsigned int iteration = 0;
	unsigned int total_rays = 0;
	while (num_rays > 0)
	{
		total_rays += num_rays;
		if (iteration % 100 == 0)
		{
			//cout << "iteration " << iteration << "(" << num_rays << " rays)\n";
			cout << "iteration " << iteration << "(" << num_rays << " rays)\r";
			cout.flush();
		}
		//if (num_rays < num_pixels)
		//{
		//	cout << "iteration " << iteration << "(" << num_rays << " rays)\n";
		//	cout.flush();
		//}

		// compute ray-world intersections
		cudaProfilerStart();
		clock_t start = clock();
		run_kernel(h_rays, d_rays, num_rays, h_hits, d_hits, d_scene, scene_size);
		kernel += clock() - start;
		cudaProfilerStop();

		// compact active rays
		num_rays = compact_rays(h_rays, num_rays, h_hits, world, h_sample_colors, h_colors, pixels, num_pixels, cam, nx, ny, ns);

		// update pixels
		{
			unsigned int sample_idx = 0;
			for (int j = ny - 1; j >= 0; j--)
			{
				for (int i = 0; i < nx; ++i, sample_idx++)
				{
					vec3 col = h_colors[sample_idx] / float(pixels[sample_idx].samples);
					col = vec3(sqrtf(col[0]), sqrtf(col[1]), sqrtf(col[2]));
					int ir = int(255.99*col.r());
					int ig = int(255.99*col.g());
					int ib = int(255.99*col.b());
					pix_array[(ny - 1 - j)*nx + i] = (ir << 16) + (ig << 8) + ib;
				}
			}
		}
		SDL_UpdateTexture(texture, NULL, pix_array, nx * sizeof(Uint32));
		SDL_RenderClear(renderer);
		SDL_RenderCopy(renderer, texture, NULL, NULL);
		SDL_RenderPresent(renderer);

		++iteration;
	}

    clock_t end = clock();
	printf("rendering %d rays, duration %.2f seconds\nkernel %.2f seconds\ngenerate %.2f seconds\ncompact %.2f seconds\n",
		total_rays,
		double(end - begin) / CLOCKS_PER_SEC,
		double(kernel) / CLOCKS_PER_SEC,
		double(generate) / CLOCKS_PER_SEC,
		double(compact) / CLOCKS_PER_SEC);

	while (!quit)
	{
		SDL_WaitEvent(&event);

		switch (event.type)
		{
		case SDL_QUIT:
			quit = true;
			break;
		}
	}

    // Free device global memory
	err(cudaFree(d_scene), "free device d_scene");
   	err(cudaFree(d_rays), "free device d_rays");
	err(cudaFree(d_hits), "free device d_hits");

    // Free host memory
    free(h_scene);
    free(h_hits);

	delete[] pix_array;
	SDL_DestroyTexture(texture);
	SDL_DestroyRenderer(renderer);
	SDL_DestroyWindow(screen);

    // generate final image
    ofstream image;
    image.open("picture.ppm");
	image << "P3\n" << nx << " " << ny << "\n255\n";
    unsigned int sample_idx = 0;
    for (int j = ny-1; j >= 0; j--)
    {
		for (int i = 0; i < nx; ++i, sample_idx++)
		{
			vec3 col = h_colors[sample_idx] / float(ns);
			col = vec3( sqrtf(col[0]), sqrtf(col[1]), sqrtf(col[2]) );
			int ir = int(255.99*col.r());
			int ig = int(255.99*col.g());
			int ib = int(255.99*col.b());

			image << ir << " " << ig << " " << ib << "\n";
		}
    }

	//cin.ignore();
    return 0;
}

