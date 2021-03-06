/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya
 * @date      2012-2015
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <stream_compaction/efficient.h>
#include "sceneStructs.h"
#include <util/checkCUDAError.h>
#include <vector>
#include <glm/gtx/transform.hpp>
#include "rasterize.h"
#include "rasterizeTools.h"

#define BINSIDE_LEN 4
#define TILESIDE_LEN 8
#define BIN_SIZE BINSIDE_LEN*BINSIDE_LEN	// this many tiles
#define TILE_SIZE TILESIDE_LEN*TILESIDE_LEN	// this many pixels

#define BINRASTER_BLOCK 256
#define VERTSHADER_BLOCK 128
#define FRAGSHADER_BLOCK 256

#define QSEG_SIZE 1024

// Data structure for rasterization filter
namespace Queue {
	struct Segment {
		int queueSize = 0;
		int queue[QSEG_SIZE];
	};

	__device__ void push(Segment &seg, int triId){
		int writeIdx = atomicAdd(&(seg.queueSize), 1);
		if (writeIdx < QSEG_SIZE){
			seg.queue[writeIdx] = triId;
		}
	}

	__device__ void clear(Segment &seg){
		atomicExch(&(seg.queueSize), 0);
	}
}

static int width = 0;
static int height = 0;
__constant__ static int *dev_bufIdx = NULL;
__constant__ static int *dev_depth = NULL;
__constant__ static VertexIn *dev_bufVertex = NULL;
__constant__ static VertexOut *dev_bufShadedVert = NULL;
__constant__ static Triangle *dev_primitives = NULL;
__constant__ static Fragment *dev_depthbuffer = NULL;
__constant__ static glm::vec3 *dev_framebuffer = NULL;

static int bufIdxSize = 0;
static int vertCount = 0;
static MVP *mvp = NULL;

// Geometry shader restriction
const int geomShaderLimit = 8;
static int triCount;

// Temp variables for stream compaction
__constant__ static int *dv_f_tmp = NULL;
__constant__ static int *dv_idx_tmp = NULL;
__constant__ static Triangle *dv_out_tmp = NULL;
__constant__ static int *dv_c_tmp = NULL;

// Fixed lighting
static glm::vec3 light1 = 10.0f*glm::vec3(100.0f, 100.0f, 100.0f);
static glm::vec3 lightCol1 = glm::vec3(0.95f, 0.95f, 1.0f);
static glm::vec3 light2 = light1 * glm::vec3(-1.0f, 1.0f, -1.0f);
static glm::vec3 lightCol2 = glm::vec3(1.0f, 0.725f, 0.494f);

// Rasterization filtering
int rowWidth;
int columnHeight;
int binGridWidth, binGridHeight;
__constant__ static Queue::Segment *binVsTriangle;
__constant__ static Queue::Segment *tileVsTriangle;

/****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
* Scanline pipeline below
****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
*****************************************************************************************************************************************/

__global__ void sendImageToPBO(uchar4 *pbo, int w, int h, Fragment *image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * w);

	if (x < w && y < h) {
		Fragment f = image[index];
		pbo[index].w = 0;
		glm::vec3 color = glm::vec3(255.0f);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].x = color.x*glm::clamp(f.col.x, 0.0f, 1.0f);
		pbo[index].y = color.y*glm::clamp(f.col.y, 0.0f, 1.0f);
		pbo[index].z = color.z*glm::clamp(f.col.z, 0.0f, 1.0f);
	}
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h, MVP *hst_mvp) {
    width = w;
	height = h;
	mvp = hst_mvp;
    //cudaFree(dev_depthbuffer);
	cudaMalloc(&dev_depthbuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_depthbuffer, 0, width * height * sizeof(Fragment));
    //cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
	cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

	cudaMalloc(&dev_depth, width * height * sizeof(int));
	cudaMemset(dev_depth, mvp->farPlane*10000, width * height * sizeof(int));
    checkCUDAError("rasterizeInit");
}

void flushDepthBuffer(){
	cudaMemset(dev_depth, mvp->farPlane * 10000, width * height * sizeof(int));
	cudaMemset(dev_depthbuffer, 0, width * height * sizeof(Fragment));
	cudaMemset(dev_primitives, 0, triCount * geomShaderLimit * sizeof(Triangle));
	cudaMemset(binVsTriangle, 0, binGridHeight*binGridWidth*sizeof(Queue::Segment));
	cudaMemset(tileVsTriangle, 0, binGridHeight*binGridWidth*BIN_SIZE*sizeof(Queue::Segment));
	checkCUDAError("rasterize flush");
}

/**
 * Set all of the buffers necessary for rasterization.
 */
void rasterizeSetBuffers(
        int _bufIdxSize, int *bufIdx,
        int _vertCount, float *bufPos, float *bufNor, float *bufCol) {
    bufIdxSize = _bufIdxSize;
    vertCount = _vertCount;

    //cudaFree(dev_bufIdx);
    cudaMalloc(&dev_bufIdx, bufIdxSize * sizeof(int));
    cudaMemcpy(dev_bufIdx, bufIdx, bufIdxSize * sizeof(int), cudaMemcpyHostToDevice);

    VertexIn *bufVertex = new VertexIn[_vertCount];
    for (int i = 0; i < vertCount; i++) {
        int j = i * 3;
        bufVertex[i].pos = glm::vec3(bufPos[j + 0], bufPos[j + 1], bufPos[j + 2]);
        bufVertex[i].nor = glm::vec3(bufNor[j + 0], bufNor[j + 1], bufNor[j + 2]);
        bufVertex[i].col = glm::vec3(bufCol[j + 0], bufCol[j + 1], bufCol[j + 2]);
    }
    //cudaFree(dev_bufVertex);
    cudaMalloc(&dev_bufVertex, vertCount * sizeof(VertexIn));
    cudaMemcpy(dev_bufVertex, bufVertex, vertCount * sizeof(VertexIn), cudaMemcpyHostToDevice);

	//cudaFree(dev_bufShadedVert);
	cudaMalloc(&dev_bufShadedVert, vertCount * sizeof(VertexOut));

	triCount = vertCount / 3;

    //cudaFree(dev_primitives);
    cudaMalloc(&dev_primitives, triCount * geomShaderLimit * sizeof(Triangle));
	cudaMemset(dev_primitives, 0, triCount * geomShaderLimit * sizeof(Triangle));

	// Allocate temp vars
	cudaMalloc((void**)&dv_f_tmp, triCount * geomShaderLimit *sizeof(int));
	cudaMalloc((void**)&dv_idx_tmp, triCount * geomShaderLimit *sizeof(int));
	cudaMalloc((void**)&dv_out_tmp, triCount * geomShaderLimit *sizeof(Triangle));
	cudaMalloc((void**)&dv_c_tmp, sizeof(int));

    checkCUDAError("rasterizeSetBuffers");
}

__global__ void shadeVertex(VertexOut *vOut, VertexIn *vIn, const int vertCount, const int width, const int height, const glm::mat4 mvp, const float near, const float far){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * width);

	if (index < vertCount) {
		// http://www.songho.ca/opengl/gl_transform.html
		VertexOut o;
		o.mpos = vIn[index].pos;
		o.nor = vIn[index].nor;
		o.col = vIn[index].col;
		glm::vec4 clip = mvp*glm::vec4(vIn[index].pos, 1.0f);
		glm::vec3 ndc = glm::vec3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w);
		o.pos = glm::vec3(
			width*0.5f*(ndc.x+1), 
			height*0.5f*(ndc.y+1), 
			((far-near)*ndc.z+(far+near))*0.5f
			);
		vOut[index] = o;
	}
}

__global__ void assemblePrimitive(Triangle *pOut, VertexOut *vIn, int *triIdx, const int triCount, const int width){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < triCount) {
		Triangle t;
		// Set rasterization property
		t.isPoint = false;
		t.isLine = false;
		t.isValidGeom = true;
		// Assemble vertices
		t.v[0] = vIn[triIdx[3 * index + 0]];
		t.v[1] = vIn[triIdx[3 * index + 1]];
		t.v[2] = vIn[triIdx[3 * index + 2]];
		// Find bounding box
		t.box = getAABBForTriangle(t);
		pOut[index] = t;
	}
}

__global__ void assemblePrimitivePoint(Triangle *pOut, VertexOut *vIn, int *triIdx, const int triCount, const int width){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < triCount) {
		Triangle t;
		t.v[0] = vIn[triIdx[3 * index + 0]];
		t.isPoint = true;
		t.isValidGeom = true;
		pOut[index] = t;
	}
}

__global__ void simpleShadeGeom(Triangle *pArr, const int triCount, const int width, const int limit, const int height, const glm::mat4 mvp, const float near, const float far){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * width);

	if (index < triCount) {
		Triangle t = pArr[index];
		Triangle tN = t;
		// Calculate a line that represents the vertex normal
		// Since normal is not MVP-transformed, need to do MVP here for the model-space normal line
		glm::vec4 clip = mvp*glm::vec4(t.v[0].mpos + t.v[0].nor*0.1f, 1.0f);
		glm::vec3 ndc = glm::vec3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w);
		tN.v[1].pos = glm::vec3(
			width / 2 * (ndc.x + 1),
			height / 2 * (ndc.y + 1),
			(far - near) / 2 * ndc.z + (far + near) / 2
			);
		tN.isLine = true;
		tN.isValidGeom = true;
		pArr[index + triCount] = tN;
	}
}

__global__ void simpleCulling(Triangle *pArr, const int triCount, const int width, const glm::vec3 camPos){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * width);

	if (index < triCount) {
		if (glm::dot(pArr[index].v[0].mpos - camPos, pArr[index].v[0].nor) >= 0){
			pArr[index].isValidGeom = false;
		}
	}
}

__global__ void testCover(Fragment *dBuf, int *depth, Triangle *pIn, const int triCount, const int width, const int height, const glm::vec3 camPos, const bool doScissor, const Scissor scissor, const glm::vec3 camLook){
	int xt = (blockIdx.x * blockDim.x) + threadIdx.x;
	int yt = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = xt + (yt * width);

	if (index < triCount) {
		if (pIn[index].isPoint){
			bool discard = false;
			int x = round(pIn[index].v[0].pos.x), y = round(pIn[index].v[0].pos.y);
			int flatIdx = width - x + (height - y)*width;
			// Scissor test
			if (doScissor){
				if (x > scissor.max.x || x < scissor.min.x || y > scissor.max.y || y < scissor.min.y){
					discard = true;
				}
			}
			// Window clipping test
			if (y < 0 || height < y || width < x || x < 0){
				discard = true;
			}
			if (!discard){
				int dp = -pIn[index].v[0].pos.z * 10000;
				// Try to win the depth test
				atomicMin(&depth[flatIdx], dp);
				// If won depth test
				if (depth[flatIdx] == dp) {
					// Shallowest
					Fragment f;
					f.col = pIn[index].v[0].col;
					f.nor = pIn[index].v[0].nor;
					f.pos = pIn[index].v[0].pos;
					dBuf[flatIdx] = f;
				}
			}
		}
		else if (pIn[index].isLine){
			glm::vec3 min = pIn[index].v[0].pos, max = pIn[index].v[1].pos;
			int minX = round(min.x), maxX = round(max.x);
			if (minX == maxX){
				// Straight vertical line
				int minY = round(min.y), maxY = round(max.y), minZ = min.z, maxZ = max.z;
				int x = minX;
				if (min.y > max.y){
					minY = round(max.y); maxY = round(min.y); minZ = max.z; maxZ = min.z;
				}
				int dp;
				bool discard;
				for (int y = maxY; y >= minY; y--){
					discard = false;
					// Scissor test
					if (doScissor){
						if (x > scissor.max.x || x < scissor.min.x || y > scissor.max.y || y < scissor.min.y){
							discard = true;
						}
					}
					int flatIdx = width - x + (height - y)*width;
					if (y < 0 || height < y || x > width || x < 0){
						discard = true;
					}
					if (!discard){
						float ratio = (y - minY) / (maxY - minY);
						dp = -(ratio*minZ + (1 - ratio)*maxZ) * 10000;

						atomicMin(&depth[flatIdx], dp);

						if (depth[flatIdx] == dp) {
							// Shallowest
							Fragment f;
							f.pos = glm::vec3(x, y, -dp* 0.0001);
							f.nor = glm::normalize(pIn[index].v[0].nor + pIn[index].v[1].nor);
							f.col = glm::vec3(1.0f);
							dBuf[flatIdx] = f;
						}
					}
				}
			}
			else {
				// Bresenham
				if (minX > maxX){
					min = pIn[index].v[1].pos; max = pIn[index].v[0].pos;
				}
				int minZ = min.z, maxZ = max.z;
				float slope = (max.y - min.y) / (max.x - min.x);
				int dp, y;
				bool discard;
				float ratio;
				for (int x = round(min.x); x <= round(max.x); x++){
					y = slope * (x - round(min.x)) + min.y;
					ratio = (x - round(min.x)) / (round(max.x) - round(min.x));
					discard = false;
					// Scissor test
					if (doScissor){
						if (x > scissor.max.x || x < scissor.min.x || y > scissor.max.y || y < scissor.min.y){
							discard = true;
						}
					}
					int flatIdx = width - x + (height - y)*width;
					if (y < 0 || y > height || x < 0 || x > width){
						discard = true;
					}
					if (!discard){
						dp = -(ratio*minZ + (1 - ratio)*maxZ) * 10000;

						atomicMin(&depth[flatIdx], dp);

						if (depth[flatIdx] == dp) {
							// Shallowest
							Fragment f;
							f.pos = glm::vec3(x, y, -dp*0.0001);
							f.nor = glm::normalize(pIn[index].v[0].nor + pIn[index].v[1].nor);
							f.col = glm::vec3(1.0f);
							dBuf[flatIdx] = f;
						}
					}
				}
			}
		}
		else {
			// General triangle
			// Early window clipping & scissor test
			int minX, maxX, minY, maxY;
			minX = fmaxf(round(pIn[index].box.min.x), 0.0f), maxX = fminf(round(pIn[index].box.max.x), (float)width);
			minY = fmaxf(round(pIn[index].box.min.y), 0.0f), maxY = fminf(round(pIn[index].box.max.y), (float)height);
			if (doScissor){
				minX = fmaxf(minX, scissor.min.x), maxX = fminf(maxX, scissor.max.x);
				minY = fmaxf(minY, scissor.min.y), maxY = fminf(maxY, scissor.max.y);
			}
			glm::vec3 coord[3] = { pIn[index].v[0].pos, pIn[index].v[1].pos, pIn[index].v[2].pos };
			int dp, flatIdx;
			glm::vec3 bcc;
			// For each scanline
			for (int y = maxY; y >= minY; y--){
				// Scan each pixel
				for (int x = minX; x <= maxX; x++){
					bcc = calculateBarycentricCoordinate(coord, glm::vec2(x, y));
					flatIdx = width - x + (height - y)*width;
					if (isBarycentricCoordInBounds(bcc)){
						dp = getZAtCoordinate(bcc, coord) * 10000;

						atomicMin(&depth[flatIdx], dp);

						if (depth[flatIdx] == dp) {
							// Shallowest
							Fragment f;
							f.pos = bcc.x * pIn[index].v[0].pos + bcc.y*pIn[index].v[1].pos + bcc.z*pIn[index].v[2].pos;
							f.nor = bcc.x * pIn[index].v[0].nor + bcc.y*pIn[index].v[1].nor + bcc.z*pIn[index].v[2].nor;
							f.col = bcc.x * pIn[index].v[0].col + bcc.y*pIn[index].v[1].col + bcc.z*pIn[index].v[2].col;
							dBuf[flatIdx] = f;
						}
					}
				}
			}
		}
	}
}

__global__ void shadeFragment(Fragment *fBuf, const int pxCount, const int width, const glm::vec3 light1, const glm::vec3 lightCol1, const glm::vec3 light2, const glm::vec3 lightCol2){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < pxCount) {
		// Add the two lights and do Lambert shading
		glm::vec3 L1 = glm::normalize(light1 - fBuf[index].pos);
		glm::vec3 L2 = glm::normalize(light2 - fBuf[index].pos);
		glm::vec3 C1 = glm::dot(L1, fBuf[index].nor)*fBuf[index].col*lightCol1;
		glm::vec3 C2 = glm::dot(L2, fBuf[index].nor)*fBuf[index].col*lightCol2;
		fBuf[index].col = C1+C2;
	}
}

__global__ void shadeFragmentNormal(Fragment *fBuf, const int pxCount, const int width){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < pxCount) {
		fBuf[index].col = fBuf[index].nor;
	}
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo) {
	int sideLength2d = 8;
	dim3 blockSize2d(sideLength2d, sideLength2d);

	dim3 blockCount2d((width + blockSize2d.x - 1) / blockSize2d.x,
		(height + blockSize2d.y - 1) / blockSize2d.y);

	int vertGridSize = (width*height + VERTSHADER_BLOCK - 1) / VERTSHADER_BLOCK;

	// Vertex shading
	shadeVertex << <vertGridSize, VERTSHADER_BLOCK>> >(dev_bufShadedVert, dev_bufVertex, vertCount, width, height, mvp->mvp, mvp->nearPlane, mvp->farPlane);
	checkCUDAError("Vert shader");

	// Primitive assembly
	if (mvp->pointShading){
		assemblePrimitivePoint << <vertGridSize, VERTSHADER_BLOCK >> >(dev_primitives, dev_bufShadedVert, dev_bufIdx, triCount, width);
		checkCUDAError("Prim assembly");
	}
	else {
		assemblePrimitive << <vertGridSize, VERTSHADER_BLOCK >> >(dev_primitives, dev_bufShadedVert, dev_bufIdx, triCount, width);
		checkCUDAError("Prim assembly");
	}
	
	int primCount = triCount;
	if (mvp->geomShading){
		simpleShadeGeom << <blockCount2d, blockSize2d >> >(dev_primitives, primCount, width, geomShaderLimit, height, mvp->mvp, mvp->nearPlane, mvp->farPlane);
		checkCUDAError("Geom shader");
		StreamCompaction::Efficient::compact(triCount*geomShaderLimit, dv_f_tmp, dv_idx_tmp, dv_out_tmp, dev_primitives, dv_c_tmp);
		checkCUDAError("Geom shader compact");
		cudaMemcpy(&primCount, dv_c_tmp, sizeof(int), cudaMemcpyDeviceToHost);
		cudaMemcpy(dev_primitives, dv_out_tmp, primCount * sizeof(Triangle), cudaMemcpyDeviceToDevice);
		checkCUDAError("Geom shader copy");
	}

	if (mvp->culling){
		simpleCulling << <blockCount2d, blockSize2d >> >(dev_primitives, primCount, width, mvp->camPosition);
		checkCUDAError("Culling");
		StreamCompaction::Efficient::compact(triCount*geomShaderLimit, dv_f_tmp, dv_idx_tmp, dv_out_tmp, dev_primitives, dv_c_tmp);
		checkCUDAError("Culling compact");
		cudaMemcpy(&primCount, dv_c_tmp, sizeof(int), cudaMemcpyDeviceToHost);
		cudaMemcpy(dev_primitives, dv_out_tmp, primCount * sizeof(Triangle), cudaMemcpyDeviceToDevice);
		checkCUDAError("Culling copy");
	}

	// Rasterization
	testCover << <blockCount2d, blockSize2d >> >(dev_depthbuffer, dev_depth, dev_primitives, primCount, width, height, mvp->camPosition, mvp->doScissor, mvp->scissor, mvp->camLookAt);
	checkCUDAError("Rasterization");

	int fragGridSize = (width*height + FRAGSHADER_BLOCK - 1) / FRAGSHADER_BLOCK;

	if (mvp->shadeMode == 0){
		// Fragment shading
		shadeFragment << <fragGridSize, FRAGSHADER_BLOCK >> >(dev_depthbuffer, height*width, width, light1, lightCol1, light2, lightCol2);
		checkCUDAError("Frag shader");
	}
	else if (mvp->shadeMode == 1){
		// Fragment shading
		shadeFragmentNormal << <fragGridSize, FRAGSHADER_BLOCK >> >(dev_depthbuffer, height*width, width);
		checkCUDAError("Frag shader");
	}

	dim3 blockSize2d2(16, 16);

	dim3 blockCount2d2((width + blockSize2d2.x - 1) / blockSize2d2.x,
		(height + blockSize2d2.y - 1) / blockSize2d2.y);

	sendImageToPBO << <blockCount2d2, blockSize2d2 >> >(pbo, width, height, dev_depthbuffer);
    checkCUDAError("rasterize");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {
    cudaFree(dev_bufIdx);
	cudaFree(dev_bufVertex);
	cudaFree(dev_bufShadedVert);
    cudaFree(dev_primitives);
    cudaFree(dev_depthbuffer);
    cudaFree(dev_framebuffer);
	cudaFree(dev_depth);

	cudaFree(dv_f_tmp);
	cudaFree(dv_idx_tmp);
	cudaFree(dv_out_tmp);
	cudaFree(dv_c_tmp);

	cudaFree(binVsTriangle);
	cudaFree(tileVsTriangle);

    checkCUDAError("rasterizeFree");
}


/****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
* Tile-based pipeline below
****************************************************************************************************************************************
****************************************************************************************************************************************
****************************************************************************************************************************************
*****************************************************************************************************************************************/

void rasterizeTileInit(){
	// Initialize tile arrays
	rowWidth = triCount * geomShaderLimit * sizeof(bool);
	binGridWidth = (width + BINSIDE_LEN*TILESIDE_LEN - 1) / (BINSIDE_LEN*TILESIDE_LEN);
	binGridHeight = (height + BINSIDE_LEN*TILESIDE_LEN - 1) / (BINSIDE_LEN*TILESIDE_LEN);
	cudaMalloc((void**)&binVsTriangle, binGridHeight*binGridWidth*sizeof(Queue::Segment));
	checkCUDAError("Bin array");
	cudaMalloc((void**)&tileVsTriangle, binGridHeight*binGridWidth*BIN_SIZE*sizeof(Queue::Segment));
	checkCUDAError("Tile array");
}

__global__ void assemblePrimitiveT(Triangle *pOut, VertexOut *vIn, int *triIdx, const int triCount, const int width, const int height, const glm::vec3 camPos, const bool doScissor, const Scissor scissor){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < triCount) {
		Triangle t;
		// Assemble vertices
		t.v[0] = vIn[triIdx[3 * index]];
		t.v[1] = vIn[triIdx[3 * index + 1]];
		t.v[2] = vIn[triIdx[3 * index + 2]];
		// Set rasterization property
		t.isPoint = false; t.isLine = false; t.isValidGeom = true;
		// Backface culling & degenerate (zero area)
		// Calculate signed area for later use also
		t.signedArea = calculateSignedArea(t.v);
		// Revert coordinates to fix OpenGL coord quirks
		t.v[0].pos = glm::vec3((float)width - t.v[0].pos.x, (float)height - t.v[0].pos.y, t.v[0].pos.z);
		t.v[1].pos = glm::vec3((float)width - t.v[1].pos.x, (float)height - t.v[1].pos.y, t.v[1].pos.z);
		t.v[2].pos = glm::vec3((float)width - t.v[2].pos.x, (float)height - t.v[2].pos.y, t.v[2].pos.z);
		// Find bounding box
		t.box = getAABBForTriangle(t);
		if (t.signedArea >= 0){
			t.isValidGeom = false;
		}
		// Coarse window & scissor clipping
		if (doScissor){
			if (t.box.min.x > scissor.max.x || t.box.max.x < scissor.min.x || t.box.min.y > scissor.max.y || t.box.max.y < scissor.min.y){
				t.isValidGeom = false;
			}
		}
		if (t.box.min.x > width || t.box.max.x < 0 || t.box.min.y > height || t.box.max.y < 0){
			t.isValidGeom = false;
		}
		// Minimum Z of all 3 vertices; for quick depth test
		t.minDepth = -t.box.max.z;
		pOut[index] = t;
	}
}

__global__ void assemblePrimitivePointT(Triangle *pOut, VertexOut *vIn, int *triIdx, const int triCount, const int width, const int height){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < triCount) {
		Triangle t;
		t.v[0] = vIn[triIdx[3 * index + 0]];
		t.v[0].pos = glm::vec3(width - ceil(t.v[0].pos.x), height - ceil(t.v[0].pos.y), t.v[0].pos.z);
		t.box = getAABB1D(t);
		t.isPoint = true;
		t.isValidGeom = true;
		pOut[index] = t;
	}
}

__global__ void simpleShadeGeomT(Triangle *pArr, const int triCount, const int width, const int limit, const int height, const glm::mat4 mvp, const float near, const float far){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * width);

	if (index < triCount && pArr[index].isValidGeom) {
		Triangle t = pArr[index];
		Triangle tN = t;
		// Calculate a line that represents the vertex normal
		// Since normal is not MVP-transformed, need to do MVP here for the model-space normal line
		glm::vec4 clip = mvp*glm::vec4(t.v[0].mpos + t.v[0].nor*0.1f, 1.0f);
		glm::vec3 ndc = glm::vec3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w);
		// Rounding
		tN.v[1].pos = glm::vec3(
			width / 2 * (ndc.x + 1),
			height / 2 * (ndc.y + 1),
			(far - near) / 2 * ndc.z + (far + near) / 2
			);
		tN.v[1].pos = glm::vec3(width - ceil(tN.v[1].pos.x), height - ceil(tN.v[1].pos.y), tN.v[1].pos.z);
		tN.box = getAABB2D(tN);
		tN.isLine = true;
		tN.isValidGeom = true;
		pArr[index + triCount] = tN;
	}
}

__global__ void binCover(Queue::Segment* binVsTriangle, Triangle *dev_primitives, const int primCount, const int width, const int height){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < primCount){
		Triangle t = dev_primitives[index];
		for (int b = 0; b < width*height; b++){
			int binX = b % width, binY = (b - binX) / width;
			AABB bin;
			bin.min.x = binX*BINSIDE_LEN*TILESIDE_LEN, bin.max.x = bin.min.x + BINSIDE_LEN*TILESIDE_LEN;
			bin.min.y = binY*BINSIDE_LEN*TILESIDE_LEN, bin.max.y = bin.min.y + BINSIDE_LEN*TILESIDE_LEN;
			if (boxOverlapTest(t.box, bin)){
				Queue::push(binVsTriangle[b], index);
			}
		}
	}
}

__global__ void tileCover(Queue::Segment *tileVsTriangle, Queue::Segment *binVsTriangle, Triangle *dev_primitives, const int width){
	int binId = blockIdx.x;
	int binX = binId % width, binY = (binId - binX) / width;
	int baseTileX = binX * BINSIDE_LEN, baseTileY = binY * BINSIDE_LEN;
	int tileId = baseTileX + threadIdx.x + (baseTileY + threadIdx.y)*width*BINSIDE_LEN;
	int tileMinX = (baseTileX + threadIdx.x)*TILESIDE_LEN, tileMaxX = tileMinX + TILESIDE_LEN;
	int tileMinY = (baseTileY + threadIdx.y)*TILESIDE_LEN, tileMaxY = tileMinY + TILESIDE_LEN;

	AABB tile;
	tile.min.x = tileMinX; tile.max.x = tileMaxX; tile.min.y = tileMinY; tile.max.y = tileMaxY;

	int bound = binVsTriangle[binId].queueSize > QSEG_SIZE ? QSEG_SIZE : binVsTriangle[binId].queueSize;

	for (int i = 0; i < bound; i++){
		Triangle t = dev_primitives[binVsTriangle[binId].queue[i]];
		if (boxOverlapTest(t.box, tile)){
			Queue::push(tileVsTriangle[tileId], binVsTriangle[binId].queue[i]);
		}
	}
	Queue::clear(binVsTriangle[binId]);
}

__global__ void pixCover(Fragment *dev_depthbuffer, Queue::Segment *tileVsTriangle, Triangle *dev_primitives, const int width, const int height, const int tileGridWidth, const bool doScissor, const Scissor scissor){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int tileIdx = x/TILESIDE_LEN + (y/TILESIDE_LEN)*tileGridWidth;
	int index = x + (y * width);

	if (x < width && y < height) {
		bool covered = true;
		if (doScissor){
			if (x < scissor.min.x || x > scissor.max.x || y < scissor.min.y || y > scissor.max.y){
				covered = false;
			}
		}
		if (tileVsTriangle[tileIdx].queueSize == 0){
			covered = false;
		}
		if (covered){
			float depth = 100;
			int bound = glm::min(tileVsTriangle[tileIdx].queueSize, QSEG_SIZE);
			int tIdx;
			for (int i = 0; i < bound; i++){
				tIdx = tileVsTriangle[tileIdx].queue[i];

				if (!dev_primitives[tIdx].isLine && !dev_primitives[tIdx].isPoint) {
					// General triangle
					if (dev_primitives[tIdx].minDepth <= depth){
						glm::vec3 bcc = calculateBarycentricCoordinate(dev_primitives[tIdx], glm::vec2((float)x, (float)y));
						if (isBarycentricCoordInBounds(bcc)){
							float dp = getZAtCoordinate(bcc, dev_primitives[tIdx]);
							if (dp <= depth) {
								// Shallowest
								dev_depthbuffer[index].pos = bcc.x * dev_primitives[tIdx].v[0].pos + bcc.y*dev_primitives[tIdx].v[1].pos + bcc.z*dev_primitives[tIdx].v[2].pos;
								dev_depthbuffer[index].nor = bcc.x * dev_primitives[tIdx].v[0].nor + bcc.y*dev_primitives[tIdx].v[1].nor + bcc.z*dev_primitives[tIdx].v[2].nor;
								dev_depthbuffer[index].col = bcc.x * dev_primitives[tIdx].v[0].col + bcc.y*dev_primitives[tIdx].v[1].col + bcc.z*dev_primitives[tIdx].v[2].col;
								depth = dp;
							}
						}
					}
				}
				else if (dev_primitives[tIdx].isPoint && dev_primitives[tIdx].v[0].pos.x == x && dev_primitives[tIdx].v[0].pos.y == y){
					if (-dev_primitives[tIdx].v[0].pos.z <= depth) {
						// Shallowest
						dev_depthbuffer[index].col = dev_primitives[tIdx].v[0].col;
						dev_depthbuffer[index].nor = dev_primitives[tIdx].v[0].nor;
						dev_depthbuffer[index].pos = dev_primitives[tIdx].v[0].pos;
						depth = -dev_primitives[tIdx].v[0].pos.z;
					}
				}
				else if (dev_primitives[tIdx].isLine){
					glm::vec3 min = dev_primitives[tIdx].v[0].pos, max = dev_primitives[tIdx].v[1].pos;
					if (min.x > max.x){
						min = dev_primitives[tIdx].v[1].pos; max = dev_primitives[tIdx].v[0].pos;
					}
					AABB pointBox = getAABB1D(glm::vec3(x, y, 1.0f));

					if (boxOverlapTest(pointBox, dev_primitives[tIdx].box)){
						float ratio, dp;
						if (min.x == max.x){
							// Straight vertical line
							ratio = __fdividef(y - min.y, max.y - min.y);
							//float ratio = (y - min.y) / (max.y - min.y);
							//float dp = -(ratio*min.z + (1 - ratio)*max.z);
							dp = -max.z - ratio*(min.z -max.z);
							if (dp <= depth) {
								// Shallowest
								dev_depthbuffer[index].pos = glm::vec3(x, y, dp);
								dev_depthbuffer[index].nor = dev_primitives[tIdx].v[0].nor;
								dev_depthbuffer[index].col = glm::vec3(1.0f);
								depth = dp;
							}
						}
						else {
							// Bresenham
							//float slope = (max.y - min.y) / (max.x - min.x);
							//float ratio = (x - min.x) / (max.x - min.x);
							float slope = __fdividef(max.y - min.y, max.x - min.x);
							int assumedY = slope * (x - min.x) + min.y;
							if (assumedY == y){
								ratio = __fdividef(x - min.x, max.x - min.x);
								//float dp = -(ratio*min.z + (1 - ratio)*max.z);
								dp = -max.z - ratio*(min.z - max.z);
								if (dp <= depth) {
									// Shallowest
									dev_depthbuffer[index].pos = glm::vec3(x, y, dp);
									dev_depthbuffer[index].nor = dev_primitives[tIdx].v[0].nor;
									dev_depthbuffer[index].col = glm::vec3(1.0f);
									depth = dp;
								}
							}
						}
					}
				}
			}
		}
		dev_depthbuffer[index].isCovered = covered;
		Queue::clear(tileVsTriangle[tileIdx]);
	}
}

__global__ void shadeFragmentT(Fragment *fBuf, const int pxCount, const int width, const glm::vec3 light1, const glm::vec3 lightCol1, const glm::vec3 light2, const glm::vec3 lightCol2){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < pxCount) {
		if (fBuf[index].isCovered){
			// Add the two lights and do Lambert shading
			glm::vec3 L1 = glm::normalize(light1 - fBuf[index].pos);
			glm::vec3 L2 = glm::normalize(light2 - fBuf[index].pos);
			glm::vec3 C1 = lightCol1*glm::dot(L1, fBuf[index].nor);
			glm::vec3 C2 = lightCol2*glm::dot(L2, fBuf[index].nor);
			fBuf[index].col = (C1 + C2)*fBuf[index].col;
		}
		else {
			fBuf[index].col = glm::vec3(0.0f);
		}
	}
}

__global__ void shadeFragmentNormalT(Fragment *fBuf, const int pxCount, const int width){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < pxCount) {
		fBuf[index].col = fBuf[index].nor;
	}
}

/**
* Perform rasterization.
*/
void rasterizeTile(uchar4 *pbo) {
	int sideLength2d = 8;
	dim3 blockSize2d(sideLength2d, sideLength2d);

	dim3 blockCount2d((width + blockSize2d.x - 1) / blockSize2d.x,
		(height + blockSize2d.y - 1) / blockSize2d.y);

	int vertGridSize = (width*height + VERTSHADER_BLOCK - 1) / VERTSHADER_BLOCK;

	// Vertex shading
	shadeVertex << <vertGridSize, VERTSHADER_BLOCK >> >(dev_bufShadedVert, dev_bufVertex, vertCount, width, height, mvp->mvp, mvp->nearPlane, mvp->farPlane);
	checkCUDAError("Vert shader");

	// Primitive assembly
	if (mvp->pointShading){
		assemblePrimitivePointT << <vertGridSize, VERTSHADER_BLOCK >> >(dev_primitives, dev_bufShadedVert, dev_bufIdx, triCount, width, height);
		checkCUDAError("Prim assembly");
	}
	else {
		assemblePrimitiveT << <vertGridSize, VERTSHADER_BLOCK >> >(dev_primitives, dev_bufShadedVert, dev_bufIdx, triCount, width, height, mvp->camPosition, mvp->doScissor, mvp->scissor);
		checkCUDAError("Prim assembly");
	}

	int primCount = triCount;

	// Primitive compaction
	StreamCompaction::Efficient::compact(triCount*geomShaderLimit, dv_f_tmp, dv_idx_tmp, dv_out_tmp, dev_primitives, dv_c_tmp);
	checkCUDAError("Primitive compact");
	cudaMemcpy(&primCount, dv_c_tmp, sizeof(int), cudaMemcpyDeviceToHost);
	cudaMemcpy(dev_primitives, dv_out_tmp, primCount * sizeof(Triangle), cudaMemcpyDeviceToDevice);
	checkCUDAError("Primitive copy");

	// Geometry shading
	if (mvp->geomShading){
		simpleShadeGeomT << <blockCount2d, blockSize2d >> >(dev_primitives, primCount, width, geomShaderLimit, height, mvp->mvp, mvp->nearPlane, mvp->farPlane);
		checkCUDAError("Geom shader");
		StreamCompaction::Efficient::compact(triCount*geomShaderLimit, dv_f_tmp, dv_idx_tmp, dv_out_tmp, dev_primitives, dv_c_tmp);
		checkCUDAError("Geom shader compact");
		cudaMemcpy(&primCount, dv_c_tmp, sizeof(int), cudaMemcpyDeviceToHost);
		cudaMemcpy(dev_primitives, dv_out_tmp, primCount * sizeof(Triangle), cudaMemcpyDeviceToDevice);
		checkCUDAError("Geom shader copy");
	}

	// Rasterization
	// Input to bin raster
	int binCoverGridSize = (primCount + BINRASTER_BLOCK - 1) / BINRASTER_BLOCK;
	binCover << <binCoverGridSize, BINRASTER_BLOCK>> >(binVsTriangle, dev_primitives, primCount, binGridWidth, binGridHeight);
	checkCUDAError("Bin cover test");

	// Bin to tile raster
	dim3 binSize2d(BINSIDE_LEN, BINSIDE_LEN);
	tileCover << <binGridHeight*binGridWidth, binSize2d >> >(tileVsTriangle, binVsTriangle, dev_primitives, binGridWidth);
	checkCUDAError("Tile cover test");

	// Tile to fragment raster

	dim3 blockSize2d3(8, 16);

	dim3 blockCount2d3((width + blockSize2d3.x - 1) / blockSize2d3.x,
		(height + blockSize2d3.y - 1) / blockSize2d3.y);
	pixCover << <blockCount2d3, blockSize2d3 >> >(dev_depthbuffer, tileVsTriangle, dev_primitives, width, height, binGridWidth*BINSIDE_LEN, mvp->doScissor, mvp->scissor);
	checkCUDAError("Pixel cover test");

	// Fragment shading
	int fragGridSize = (width*height + FRAGSHADER_BLOCK - 1) / FRAGSHADER_BLOCK;

	if (mvp->shadeMode == 0){
		shadeFragmentT << <fragGridSize, FRAGSHADER_BLOCK >> >(dev_depthbuffer, height*width, width, light1, lightCol1, light2, lightCol2);
		checkCUDAError("Frag shader");
	}
	else if (mvp->shadeMode == 1){
		shadeFragmentNormalT << <fragGridSize, FRAGSHADER_BLOCK >> >(dev_depthbuffer, height*width, width);
		checkCUDAError("Frag shader");
	}

	// Render to frame
	dim3 blockSize2d2(16, 16);

	dim3 blockCount2d2((width + blockSize2d2.x - 1) / blockSize2d2.x,
		(height + blockSize2d2.y - 1) / blockSize2d2.y);

	sendImageToPBO << <blockCount2d2, blockSize2d2 >> >(pbo, width, height, dev_depthbuffer);
	checkCUDAError("rasterize");
}