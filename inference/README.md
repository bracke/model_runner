# model_runner inference project

`model_runner_inference.gpr` exposes the local GGUF inference engine without a
main unit or the CLI presentation layer. It imports the lightweight task
framework and excludes that project's explicit source closure, so an embedding
may import both projects without duplicate Ada units.

The project is a linkage boundary, not a second implementation. Its public
entry point is `Model_Runner.Inference`; loading, generation, cancellation,
progress, provenance, and limits remain owned by the normal model_runner
packages.
