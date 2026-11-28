# Shared-host Vulkan submission profile

The pre-batching one-token workload has an established five-sample shared-host
baseline of 27.740 seconds for prompt evaluation and 27.727 seconds for decode.
The model remains Q4_K_M; activations and KV are F32. See the
[baseline measurements](inkling2-benchmarks.md) and
[operation-count correction](inkling2-benchmark-interpretation.md).

On 2026-11-25, main-thread `strace -tt -T -e trace=ioctl,futex` recorded the
same workload with the existing device timeline. Across the complete process,
9,327 `DRM_IOCTL_AMDGPU_CS` calls consumed 189.927869 seconds: approximately
20.36 milliseconds per call, with a maximum of 29.914 milliseconds. The device
timeline reported 356.6 milliseconds of GPU work in 4,660 runs. Its measured
pass took 56.653 seconds. The timeline option also runs a second complete
campaign without recording its GPU timeline. Preparation, both campaigns and
cleanup belong to the process-level syscall totals; the 4,660 recorded runs
cover only the first campaign. These totals cannot establish a number of
submissions per GPU dispatch. These are diagnostic instrumented observations,
not replacement benchmark samples.

Submission dominates this shared-host configuration. Buffer import calls were
small in the same trace: 3,056 `DRM_IOCTL_AMDGPU_GEM_USERPTR` calls consumed
0.160458 seconds in total. The existing import implementation aligns and
imports the requested matrix-sized range. The trace does not support blaming
a whole-model import on every product.

An additional `strace -f -c` capture records all threads. Its large summed futex
time includes idle workers waiting in parallel and cannot be treated as
single-process elapsed inference time.

Raw traces, stdout/stderr and parsed syscall totals are preserved under
`artifacts/inkling2/obj/performance-round2/`. The detailed trace uses the
pre-batching benchmark executable with the corrected model-memory-limit driver,
SHA-256 `12207757e6846efec3d7c4e783899c203cc91b67713533a929352453d65584a6`.
Batched prefill reduces the number of small products and reuses the existing
backend; it does not establish a driver-level fix for shared-host submission
latency. Longer-context CPU/private-Vulkan measurements use a separate
[declared protocol](inkling2-batched-prefill-protocol.md).

The matching pre-batching private-4-GiB control recorded 8,168 AMD submission
calls consuming 0.198861 seconds in total (about 24.35 microseconds per call;
maximum 172 microseconds). It uses the preserved qualified executable
`4dd06281557d3cca50176dd8bbda0b99f2aba6d46862fa4d979eb221a3b610c7`;
the benchmark-only memory-limit driver differs, and the private arena fits
the earlier allocation limit. The process-wide comparison supports the
submission-cost diagnosis; it does not identify the driver's internal cause.
