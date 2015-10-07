CUDA Rasterizer
===============

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 4**

* Tongbo Sui
* Tested on: Windows 10, i5-3320M @ 2.60GHz 8GB, NVS 5400M 2GB (Personal)

## Video demo

## Pipeline overview

* Vertex shading with perspective transformation
* Primitive assembly with support for triangles read from buffers of index and vertex data.
* Geometry shader, able to output a variable number of primitives per input primitive, optimized using stream compaction
  * `G` toggle geometry shader; shows vertex normals
* Rasterization
  * Barycentric color interpolation
  * Scissor test
    * `S`: toggle scissor test
  * Depth test (using atomics for race avoidance)
  * Support for rasterizing lines and points
      * Does **not** support vertex shading for such primitives; only rasterization
* Fragment shading
  * Lambert
* Mouse-based interactive camera support
  * `Left button` hold and drag: rotate
  * `Right button` hold and drag: pan
  * Scroll: zoom
  * `SPACE`: reset camera to default
* Misc support features
  * `N`: fragment shader will use normal vector as color vector; enable to see fragment normals
  * `R`: reset to color shading (use fragment color for shaded color, instead of fragment normal)
  * `P`: toggle point shader; only shows shaded vertices instead of all fragments

**IMPORTANT:**
For each extra feature, please provide the following brief analysis:

* Concise overview write-up of the feature.
* Performance impact of adding the feature (slower or faster).
* If you did something to accelerate the feature, what did you do and why?
* How might this feature be optimized beyond your current implementation?

### Performance Analysis

Provide summary of your optimizations (no more than one page), along with
tables and or graphs to visually explain any performance differences.

* Include a breakdown of time spent in each pipeline stage for a few different
  models. It is suggested that you use pie charts or 100% stacked bar charts.
* For optimization steps (like backface culling), include a performance
  comparison to show the effectiveness.

## References

* Line segment intersection test
  * http://paulbourke.net/geometry/pointlineplane/
* Vertex shader transformation
  * http://www.songho.ca/opengl/gl_transform.html