# model_runner inference project

`model_runner_inference.gpr` exposes the local GGUF inference engine without a
main unit, CLI presentation layer, agent runtime, Code Health engine, or task
framework. It imports the neutral core project and owns an explicit inference
source closure, so an embedding may import the inference and framework projects
together without duplicate Ada units.

The project is a linkage boundary, not a second implementation. Its public
entry point is `Model_Runner.Inference`; loading, generation, cancellation,
progress, provenance, and limits remain owned by the normal model_runner
packages.
