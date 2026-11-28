# Independent GSQ-RCO small-block products

Generated with the actual GGML Q8_0 quantizer and IQ4_NL/Q2_0 dot products
from llama.cpp revision `4c7344447cb1727f1e2f982febc99a8f88dcb77f`, using its
native x86 CPU library. The helper calls ggml_cpu_init before the first
product to initialize the CPU half-to-float table. No model_runner function generates expected output.
Apply generator.cpp.patch with patch -p0 in a temporary directory. Compile
with C++17, -O3 -march=native, the pinned checkout's include, ggml/include,
ggml/src and ggml/src/ggml-cpu paths, and link ggml-cpu, ggml-base and ggml.
Pass the output directory as the helper's only argument.

Each width has five random finite-scale weight rows in each format and nine
input vectors; the first input is zero. Expected activations, half-rounded
scales and output floats are stored separately. Native tests require exact
bits for packing and products, at widths64/128/1152/2304, including one and
two Q2_0 blocks and the published expert width. Tests also exercise shifted
array bounds, padded rows, strided vector selection, accumulation, output
guards, malformed requests, disabled ISA dispatch and -128 signed bytes.
Reference helpers are test-only; no runtime dependency is added.
