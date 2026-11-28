# Inkling 2 native V3 task backlog

Status: 57 candidate tasks and 12 candidate requirements persisted locally through the existing V3 APIs.
No candidate has been marked complete through the V3 lifecycle. Native fixed-loop
checkpoint comparisons now pass; implementation evidence and remaining release
gates are recorded in [verification](inkling2-verification.md).

The authoritative task definitions and lifecycle state live in this workspace's `.model_runner/` store.
That local directory includes derived repository indexes and host-specific runtime data and is ignored by Git.
This checked-in document preserves the full task definitions and the mapping to native identifiers for review
and reconstruction. It is a plan, not an alternative task schema or lifecycle engine.

Initialization used the installed `generic` template, component `model_runner`, project isolation, and the
existing `alr test` verification command. Requirements and tasks were created with `/req new` and `/task new`;
dependencies are native `depends_on` references, validated transactionally by `Framework.Tasks`.
Each candidate retains normal acceptance, readiness and verification rules. A separate isolated
real-model Ada repair task completed normal V3 execution and required verification; it is not evidence
that these candidate tasks have completed their lifecycle. Task permissions,
completion gates and agent semantics remain the existing framework rules.

Inspect through the ordinary session commands:

```text
/task list
/task show TASK-010
/task audit TASK-010
/req list
```

Native IDs belong to this store. INK identifiers are stable plan labels in task titles; V3 allocates its own
IDs and must not be forced to use the illustrative `INK-XXX` format. In another project create requirements
first, then tasks in the order below, using the IDs returned by V3 for requirements and dependencies.
Supply `kind`, `component`, `requirements`, `depends_on`, `acceptance` and `notes`, not unsupported YAML fields.
`acceptance` holds behavioral requirements; `notes` names scope, tests, the INK plan label and completion evidence.

All tasks require existing Alire builds, appropriate AUnit/reference/regression checks, documentation updates
and recorded evidence before completion. Runtime inference stays native Ada 2022, uses existing tensor,
backend, expert-cache, memory, session and harness infrastructure, and introduces no external executor.
Required numerical fixtures are independent; tolerances are measured, never widened to force a pass.

## Requirement traceability

| Plan requirement | Local native ID | Subject |
| --- | --- | --- |
| INK-R01 | REQ-006 | Fixed-loop architecture contract |
| INK-R02 | REQ-008 | GGUF structural validation |
| INK-R03 | REQ-011 | Logical execution ownership |
| INK-R04 | REQ-013 | Residual and message mathematics |
| INK-R05 | REQ-014 | Hybrid attention and context lifecycle |
| INK-R06 | REQ-015 | MoE routing and quantized execution |
| INK-R07 | REQ-016 | CPU Vulkan memory and performance |
| INK-R08 | REQ-017 | Tokenizer and generation API |
| INK-R09 | REQ-018 | V3 autonomous workflow |
| INK-R10 | REQ-019 | Variable-loop checkpoint |
| INK-R11 | REQ-021 | Vision input |
| INK-R12 | REQ-022 | Release and adoption evidence |

INK-R01: The fixed-loop text decoder SHALL follow pinned official configuration and independent source contracts, with
checkpoint-specific fixtures and measured reference baselines before dependent execution work.

INK-R02: Inkling GGUF inspection and preparation SHALL validate required metadata, tensors, dimensions, scales, variants
and limits before allocation-intensive preparation, using structured errors.

INK-R03: Repeated execution SHALL share physical weights while keeping deterministic logical visit identities and
independently addressable session state; ordinary decoder semantics SHALL remain unchanged.

INK-R04: Block attention residuals and Q/K/V/FFN cross-pass message controllers SHALL match independent fixtures,
preserve prelude restarts, precision conversions and producer lifetimes.

INK-R05: Relative attention, clipping, sinks and short convolutions SHALL match references; per-visit KV and history
SHALL remain correct through prefill, decode, eviction, reset, rewind, cancellation and close.

INK-R06: Each visit SHALL route independently with reference sigmoid selection and aggregation; physical expert weights
and all quantization scales SHALL be shared through the existing cache.

INK-R07: CPU, Vulkan and hybrid paths SHALL preserve validated numerical behavior, respect shared host/device budgets,
release resources and record repeatable target-hardware measurements.

INK-R08: Official tokenization, conversation rendering, sampling, reasoning controls, streaming and structured output
SHALL use existing inference interfaces; fixed-loop visits SHALL remain three.

INK-R09: Native Inkling tool calls and child agents SHALL use existing schemas, permissions, session exclusivity,
durable
tasks, remediation and verification gates, with auditable recovery.

INK-R10: Variable-loop support SHALL validate a separate checkpoint contract and allowed counts, reject fixed-checkpoint
overrides and pass independent fixtures at each tested count.

INK-R11: Native image input SHALL validate preprocessing, encoder, projection, context accounting, provenance,
bounds and
cancellation against independent image/text reference fixtures.

INK-R12: Support declarations SHALL require production execution, structural validation, structured failures, AUnit and
independent conformance, existing release gates and repeatable inference and 30-task coding comparisons.

## Milestones and dependencies

- A: source audit, selected-file fixtures and reference baseline (INK-001/009). Evidence is recorded; native task lifecycle remains open.
- B: native CPU text inference (INK-010/030 and INK-036/040). Full-checkpoint F32 comparisons, exact tokenization and greedy generation pass.
- C: Vulkan/hybrid execution and budgets (INK-031/035). Differential coverage passes; repeatable native performance qualification remains open.
- D: normal capabilities, tools, V3 verification and child isolation (INK-041/047). Protocol tests and real native task completion/recovery pass. The comparative coding corpus is unevaluated.
- E: separate variable-loop checkpoint (INK-048/050) and vision input (INK-051/054).
- F: fixed-text release (INK-055/056); extensions qualified separately (INK-057).

Ranges above include every intervening ID. Source-only scheduler work can be tested independently, while
decoder integration waits for the Phase 0 gate in INK-006. The reusable builder accepts general schedules;
the fixed adapter must enforce three visits. INK-056 has no variable-loop or vision dependency.

## Task definitions

### INK-001: Audit fixed-loop execution and independent sources

Native ID: TASK-001. Phase: 0. Kind: analysis. Requirement: INK-R01 (REQ-006).

Dependencies: none.

Goal and requirements: Pin source identities and document every nonstandard operation, precision conversion and
unresolved discrepancy.

Scope: Llama preparation/evaluation, official configuration, llama.cpp and Transformers.

Tests: Compare both independent implementations; record gaps without invented defaults.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-002: Pin checkpoint and GGUF conversion variant

Native ID: TASK-002. Phase: 0. Kind: analysis. Requirement: INK-R01 (REQ-006).

Dependencies: INK-001 (TASK-001).

Goal and requirements: Record checkpoint revision, GGUF hash, converter commit and parameters; distinguish
fixed, variable and incompatible layouts.

Scope: GGUF containers, reference-runtime fixtures and upstream converters.

Tests: Inspect metadata without loading weights; demonstrate reproducible conversion and file identity.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-003: Inventory tensor names shapes and all precision scales

Native ID: TASK-003. Phase: 0. Kind: analysis. Requirement: INK-R01 (REQ-006).

Dependencies: INK-002 (TASK-002).

Goal and requirements: Map each required tensor exactly once, including external per-expert scales, fused
layouts and optional fields.

Scope: Llama tensor mapping, Tensors, Quantization, upstream loader and converter.

Tests: Compare descriptor inventory to official checkpoint and selected GGUF; document unsupported encodings.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-004: Capture independent mathematical activation fixtures

Native ID: TASK-004. Phase: 0. Kind: test. Requirement: INK-R01 (REQ-006).

Dependencies: INK-003 (TASK-003).

Goal and requirements: Capture all visits, block mixing, four message controllers, relative attention,
convolutions, routing and logits with hashes.

Scope: tests/fixtures/inkling2 and external reference tooling used for tests only.

Tests: Run independent implementation; record exact inputs, dtype, accumulation order and measured backend
tolerances.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-005: Capture tokenizer prefill decode and tool fixtures

Native ID: TASK-005. Phase: 0. Kind: test. Requirement: INK-R01 (REQ-006).

Dependencies: INK-002 (TASK-002).

Goal and requirements: Pin vocabulary, merges, special tokens and template; capture golden token IDs and
checkpoint prefill/decode outputs.

Scope: Tokenizer, Templates, reference-runtime fixture format and official chat template.

Tests: Compare rendered conversation, UTF-8, greedy continuation, tool declarations and malformed tool
responses.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-006: Measure reference baseline and close architecture audit

Native ID: TASK-006. Phase: 0. Kind: analysis. Requirement: INK-R01 (REQ-006).

Dependencies: INK-004 (TASK-004), INK-005 (TASK-005).

Goal and requirements: Measure target Ryzen 7840U/780M memory, prefill and decode; resolve unknown contracts
before decoder implementation.

Scope: Existing benchmark, speed and device timeline tools.

Tests: At least five runs, medians and variation, hashes, compiler/runtime settings and an explicit audit exit
decision.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-007: Recognize and validate fixed-loop GGUF metadata

Native ID: TASK-007. Phase: 1. Kind: implementation. Requirement: INK-R02 (REQ-008).

Dependencies: INK-003 (TASK-003), INK-006 (TASK-006).

Goal and requirements: Recognize confirmed inkling2_loop identifier; validate required fields, fixed variant,
loop region, heads, attention and limits.

Scope: Llama architecture dispatch and metadata validation; GGUF inspection.

Tests: AUnit valid, missing, malformed and unsupported metadata; inspect without loading all tensors.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-008: Validate physical tensors layouts and precision compatibility

Native ID: TASK-008. Phase: 1. Kind: implementation. Requirement: INK-R02 (REQ-008).

Dependencies: INK-007 (TASK-007).

Goal and requirements: Map required tensors once, validate shape/quantization/scale dependencies and fail before
expensive preparation.

Scope: Existing tensor mapping, Tensors and preparation cleanup.

Tests: AUnit missing, duplicate, mismatched and incompatible tensors; partial preparation cleanup.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-009: Verify inspection failures and architecture regression

Native ID: TASK-009. Phase: 1. Kind: test. Requirement: INK-R02 (REQ-008).

Dependencies: INK-008 (TASK-008).

Goal and requirements: Ensure malformed inputs and unsupported variants fail explicitly with stable categories.

Scope: Existing GGUF fixtures, inspect CLI and structured diagnostics.

Tests: AUnit adversarial metadata and tensor fixtures; unchanged existing architecture inspection.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-010: Build bounded reusable logical execution schedules

Native ID: TASK-010. Phase: 2. Kind: implementation. Requirement: INK-R03 (REQ-011).

Dependencies: INK-001 (TASK-001).

Goal and requirements: Represent physical, visit, logical and state identities without weight copies; validate
bounds before arithmetic.

Scope: Llama.Execution_Schedules and AUnit schedule fixtures.

Tests: 48-step independent source trace, 24 physical identities, unique state slots, deterministic single-pass
identity and invalid bounds.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-011: Integrate schedule traversal with the native decoder

Native ID: TASK-011. Phase: 2. Kind: implementation. Requirement: INK-R03 (REQ-011).

Dependencies: INK-009 (TASK-009), INK-010 (TASK-010).

Goal and requirements: Let the architecture adapter resolve visits, inputs, messages and state IDs; keep
physical ownership separate.

Scope: Existing CPU evaluation, batch evaluation, profiling and session geometry.

Tests: AUnit execution order and logical/physical profiling identities; unchanged ordinary decoder path.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-012: Implement normalized block attention residual mixing

Native ID: TASK-012. Phase: 3. Kind: implementation. Requirement: INK-R04 (REQ-013).

Dependencies: INK-004 (TASK-004), INK-011 (TASK-011).

Goal and requirements: Normalize candidates before depth attention; apply learned queries and correct
block-boundary residual ordering.

Scope: Existing normalization and tensor kernels; architecture adapter.

Tests: Independent first-block, zero/nonzero query and output-mix fixtures; CPU precision and non-finite checks.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-013: Manage prelude restarts and previous-pass message banks

Native ID: TASK-013. Phase: 3. Kind: implementation. Requirement: INK-R04 (REQ-013).

Dependencies: INK-012 (TASK-012).

Goal and requirements: Preserve prelude state; build the bank from previous-pass blocks and output with explicit
producer lifetimes.

Scope: Session workspace ownership and architecture execution adapter.

Tests: AUnit first pass has no message, second/third pass bank identities, lifetime reuse and deterministic
results.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-014: Implement Q K V and FFN low-rank message controllers

Native ID: TASK-014. Phase: 3. Kind: implementation. Requirement: INK-R04 (REQ-013).

Dependencies: INK-013 (TASK-013).

Goal and requirements: Apply independent four-channel normalized concatenation, rank-64 projection and tanh
gain/forget controls.

Scope: Architecture adapter and existing matrix/normalization kernels.

Tests: Independent zero/nonzero gate fixtures, all visits and both middle blocks; no uninitialized reads.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-015: Verify residual precision and workspace reuse

Native ID: TASK-015. Phase: 3. Kind: test. Requirement: INK-R04 (REQ-013).

Dependencies: INK-014 (TASK-014).

Goal and requirements: Preserve reference rounding and accumulation order; detect non-finite results and stale
dependencies.

Scope: CPU evaluator, mixed-precision conversion and workspaces.

Tests: Independent quantized/float activations, repeatability, prefill/decode equivalence and workspace-reuse
comparisons.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-016: Implement local relative attention clipping and sinks

Native ID: TASK-016. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-004 (TASK-004), INK-011 (TASK-011).

Goal and requirements: Use learned relative bias without RoPE, query/key clipping, value norm, query sink and
output gate.

Scope: Existing attention kernels, window masks and architecture adapter.

Tests: Independent relative distances, 1024-window boundary, clipping, normalization, sink and masked-position
fixtures.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-017: Implement global relative attention and position scaling

Native ID: TASK-017. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-016 (TASK-016).

Goal and requirements: Use separate Q/K/V input norms, zero relative bias beyond extent and logarithmic Q/R
scaling.

Scope: Attention kernels and model adapter.

Tests: Independent positions around 8192 floor and 1024 extent; global retention and score comparisons.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-018: Implement per-visit static short-convolution history

Native ID: TASK-018. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-004 (TASK-004), INK-011 (TASK-011).

Goal and requirements: Maintain four causal histories per visit for K, V, attention output and FFN output, with
residual scaling.

Scope: Existing recurrent cache and convolution/tensor kernels.

Tests: Independent impulse, kernel order, warm/cold history and batched/token fixtures.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-019: Implement input-dependent global K V convolution taps

Native ID: TASK-019. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-017 (TASK-017), INK-018 (TASK-018).

Goal and requirements: Apply per-head dynamic taps to correct lags and preserve static-plus-dynamic residual
scaling.

Scope: Global projection adapter and existing convolution infrastructure.

Tests: Independent dynamic-tap fixtures including all-zero taps, lag orientation and head/channel layout.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-020: Allocate logical KV and convolution state within budgets

Native ID: TASK-020. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-011 (TASK-011), INK-018 (TASK-018).

Goal and requirements: Separate all 48 visits while sharing 24 weight sets; allocate bounded local/global KV and
recurrent state.

Scope: Session opening, cache geometry, device budgets and memory accounting.

Tests: AUnit slot isolation, memory calculations, failure cleanup and no physical-weight duplication.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-021: Verify cached prefill and incremental decode

Native ID: TASK-021. Phase: 4. Kind: test. Requirement: INK-R05 (REQ-014).

Dependencies: INK-015 (TASK-015), INK-019 (TASK-019), INK-020 (TASK-020).

Goal and requirements: Cached logits and intermediate state must match full recomputation for identical
prefixes.

Scope: Native attention evaluator, prefill batches and reference fixtures.

Tests: Independent multi-token and single-token comparisons across all visits and attention types.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-022: Reset and reuse all logical cache state

Native ID: TASK-022. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-021 (TASK-021).

Goal and requirements: Clear every invalid KV and convolution state; preserve only prefixes allowed by the
contract.

Scope: Existing reset and prefix-reuse lifecycle.

Tests: AUnit fresh versus reset, repeated prefix reuse and cross-session isolation.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-023: Rewind KV and convolution histories atomically

Native ID: TASK-023. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-022 (TASK-022).

Goal and requirements: Restore every required visit history and valid token boundary before an alternative
continuation.

Scope: Existing truncation, rollback and cache snapshots.

Tests: Rewind then branch versus fresh run, including short-window and multi-token prefill boundaries.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-024: Recover cache state after cancellation and failed generation

Native ID: TASK-024. Phase: 4. Kind: implementation. Requirement: INK-R05 (REQ-014).

Dependencies: INK-023 (TASK-023).

Goal and requirements: Never expose partly committed logical visits; restore a coherent state or explicitly
require reset.

Scope: Cancellation, deadlines and cache commit boundary.

Tests: AUnit cancellation/failure during each visit, prompt/decode timeout and successful subsequent generation.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-025: Validate long-context eviction and memory limits

Native ID: TASK-025. Phase: 4. Kind: test. Requirement: INK-R05 (REQ-014).

Dependencies: INK-024 (TASK-024).

Goal and requirements: Local reads exclude evicted positions; global retention, history and allocation remain
bounded.

Scope: Existing cache eviction and session limits.

Tests: Long-context reference comparisons, configured limits, low-memory structured failures and session-close
cleanup.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-026: Adapt sigmoid routing correction bias and top-k weights

Native ID: TASK-026. Phase: 5. Kind: implementation. Requirement: INK-R06 (REQ-015).

Dependencies: INK-004 (TASK-004), INK-011 (TASK-011).

Goal and requirements: Route per token per visit in F32; select using correction bias but weight unbiased
sigmoid scores, normalize and scale.

Scope: Existing MoE router and deterministic top-k infrastructure.

Tests: Independent logits, selected IDs, weights, tie behavior and unchanged existing MoE routing.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-027: Implement softcapped expert activation and aggregation

Native ID: TASK-027. Phase: 5. Kind: implementation. Requirement: INK-R06 (REQ-015).

Dependencies: INK-026 (TASK-026).

Goal and requirements: Use softcap(gate,4)*sigmoid(raw gate)*softcap(up,25), down projection and reference
accumulation.

Scope: Existing MoE expert products, fused gate/up layout and kernels.

Tests: Independent expert outputs and weighted sums, fused tensor strides and quantized/float fixtures.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-028: Share physical expert cache entries and all scales

Native ID: TASK-028. Phase: 5. Kind: implementation. Requirement: INK-R06 (REQ-015).

Dependencies: INK-027 (TASK-027), INK-003 (TASK-003).

Goal and requirements: Key by model/physical layer/expert/tensor; later visits retain every external scale and
route independently.

Scope: Expert_Cache, device allocations, Quantization and scale mapping.

Tests: AUnit repeated hits, eviction invariance, per-visit selection counts and later-pass NVFP4 scale
regression.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-029: Conform complete CPU decoder logits to reference

Native ID: TASK-029. Phase: 5. Kind: test. Requirement: INK-R06 (REQ-015).

Dependencies: INK-015 (TASK-015), INK-025 (TASK-025), INK-028 (TASK-028).

Goal and requirements: Complete fixed-loop decoder must pass intermediate and final logit conformance without
another runtime.

Scope: Native CPU evaluator and external-model reference fixtures.

Tests: Independent tokenizer-prefill-decode fixture suite, greedy tokens and repeated deterministic runs.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-030: Qualify selected GGUF quantizations

Native ID: TASK-030. Phase: 5. Kind: test. Requirement: INK-R06 (REQ-015).

Dependencies: INK-029 (TASK-029).

Goal and requirements: Validate Q4_K_M first, then IQ4_XS and Q5_K_M where fixtures and memory permit; original
mixed precision separately.

Scope: Existing quantization execution and reference tooling.

Tests: Same GGUF differential logits and expert outputs; precision-specific measured tolerances.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-031: Run residual relative attention and convolution kernels on Vulkan

Native ID: TASK-031. Phase: 6. Kind: implementation. Requirement: INK-R07 (REQ-016).

Dependencies: INK-030 (TASK-030).

Goal and requirements: Implement required device operations with measured precision behavior and explicit
supported host fallbacks.

Scope: Existing Vulkan kernels and backend dispatch.

Tests: CPU/device differential mathematical fixtures, transfer accounting and existing architecture regression.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-032: Integrate logical state with Vulkan and hybrid scheduling

Native ID: TASK-032. Phase: 6. Kind: implementation. Requirement: INK-R07 (REQ-016).

Dependencies: INK-031 (TASK-031), INK-025 (TASK-025).

Goal and requirements: Keep logical visit state coherent across host/device boundaries and honor exclusive
device sessions.

Scope: Existing device session ownership, hybrid policy and state transfer.

Tests: Native CPU/Vulkan/hybrid equivalence, fallback diagnostics and cancellation at transfers.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-033: Validate Vulkan and hybrid full decoder conformance

Native ID: TASK-033. Phase: 6. Kind: test. Requirement: INK-R07 (REQ-016).

Dependencies: INK-032 (TASK-032).

Goal and requirements: Every supported backend must pass complete logits, cache lifecycle and generation
reference fixtures.

Scope: Existing backend differential and integration suites.

Tests: CPU/device reference suite including prefill, decode, rewind, expert eviction and repeatability.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-034: Enforce shared host device memory and lifecycle budgets

Native ID: TASK-034. Phase: 6. Kind: implementation. Requirement: INK-R07 (REQ-016).

Dependencies: INK-033 (TASK-033).

Goal and requirements: Account weights, local/global KV, messages, history and shared RAM; release allocations
on all exits.

Scope: Memory accounting, session open/close, expert residency and device budget.

Tests: Peak accounting, exhaustion failure/fallback, session-close leaks, timeouts and existing MoE regression.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-035: Profile and optimize measured bottlenecks

Native ID: TASK-035. Phase: 6. Kind: implementation. Requirement: INK-R07 (REQ-016).

Dependencies: INK-034 (TASK-034), INK-006 (TASK-006).

Goal and requirements: Measure routing/expert time, cache hits/transfers, visit timings and allocations before
optimizing.

Scope: Existing tests speed, benchmark and device timeline instrumentation.

Tests: Five-run repeatable before/after comparisons on target host; unchanged conformance after each
optimization.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-036: Validate official tokenizer encoding decoding and stops

Native ID: TASK-036. Phase: 7. Kind: implementation. Requirement: INK-R08 (REQ-017).

Dependencies: INK-005 (TASK-005), INK-009 (TASK-009).

Goal and requirements: Reuse actual tokenizer format; validate vocabulary padding, BOS/EOS, UTF-8 and stopping.

Scope: Existing Tokenizer, vocabulary loading and special token handling.

Tests: Golden token IDs and decoding, round trips over supported text and invalid-token/byte cases.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-037: Render official conversations tools and reasoning effort

Native ID: TASK-037. Phase: 7. Kind: implementation. Requirement: INK-R08 (REQ-017).

Dependencies: INK-036 (TASK-036).

Goal and requirements: Match official role/content/tool framing; map effort independently of sampling and fixed
three visits.

Scope: Existing Templates and inference-profile mechanism.

Tests: Golden chat/tool/reasoning templates, invalid effort values, reasoning markers and no loop override.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-038: Integrate sampling streaming cancellation and limits

Native ID: TASK-038. Phase: 7. Kind: implementation. Requirement: INK-R08 (REQ-017).

Dependencies: INK-029 (TASK-029), INK-037 (TASK-037).

Goal and requirements: Use existing sampling, streaming, seeded determinism, token/context limits and deadline
behavior.

Scope: Inference public API, Sampling, generation sessions and stops.

Tests: Greedy reference continuation, seeded sampling contracts, prefill/decode cancellation and API consumer
regression.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-039: Preserve structured output constraints

Native ID: TASK-039. Phase: 7. Kind: test. Requirement: INK-R08 (REQ-017).

Dependencies: INK-038 (TASK-038).

Goal and requirements: Inkling generation must respect normal constraints and reject unsupported output modes
explicitly.

Scope: Existing Grammar and structured output validation.

Tests: Schema-valid generation, impossible constraints, malformed output and cancellation tests.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-040: Verify native text milestone through public API

Native ID: TASK-040. Phase: 7. Kind: test. Requirement: INK-R08 (REQ-017).

Dependencies: INK-039 (TASK-039), INK-030 (TASK-030).

Goal and requirements: Fixed-loop CPU text inference is usable through normal model/session interfaces with
independent conformance.

Scope: Inference API, model management and session lifecycle.

Tests: End-to-end tokenizer to greedy generation, reset/rewind, limits and unchanged existing model API.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-041: Register honest capabilities and model selection

Native ID: TASK-041. Phase: 8. Kind: implementation. Requirement: INK-R09 (REQ-018).

Dependencies: INK-040 (TASK-040).

Goal and requirements: Report only validated text/tool/structured/effort/loop/vision capabilities and
memory-limited context.

Scope: Existing capability registry, selection CLI and runtime context reporting.

Tests: Unsupported capability requests fail explicitly; existing Qwen selection and task profiles unchanged.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-042: Parse official tool calls and validate schemas

Native ID: TASK-042. Phase: 8. Kind: implementation. Requirement: INK-R09 (REQ-018).

Dependencies: INK-037 (TASK-037), INK-041 (TASK-041).

Goal and requirements: Parse declared name/args and framing; reject unknown tools, invalid JSON and
schema-invalid arguments.

Scope: Existing tool-call parser, schemas and official protocol.

Tests: Golden calls, malformed/repeated framing, truncated streams and invalid argument fixtures.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-043: Dispatch tools with permissions provenance and conversation recovery

Native ID: TASK-043. Phase: 8. Kind: implementation. Requirement: INK-R09 (REQ-018).

Dependencies: INK-042 (TASK-042).

Goal and requirements: Execute only through normal harness, persist results and resume generation with
deterministic tool messages.

Scope: Existing tool dispatch, permissions, conversation and audit records.

Tests: Permission escalation rejection, tool failure/remediation, cancellation and no generated-text bypass.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-044: Complete and resume an audited V3 Ada development task

Native ID: TASK-044. Phase: 8. Kind: test. Requirement: INK-R09 (REQ-018).

Dependencies: INK-043 (TASK-043).

Goal and requirements: Native Inkling must edit Ada, consume diagnostics and satisfy existing gates; failed
checks prevent completion.

Scope: Framework.Work, durable tasks, quality, build/test gates and remediation.

Tests: Real existing task success, failed-test prevention, interrupted-task resume and complete evidence chain.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-045: Validate child-agent isolation and device serialization

Native ID: TASK-045. Phase: 8. Kind: test. Requirement: INK-R09 (REQ-018).

Dependencies: INK-044 (TASK-044).

Goal and requirements: Preserve parent/child semantics, narrowed permissions, bounded contexts, result
collection and exclusive Vulkan use.

Scope: Existing recursive-agent contexts, permissions and device ownership.

Tests: Child model selection, cancellation/failure recovery, deterministic integration and unchanged Qwen
workflow.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-046: Prepare thirty identical Ada coding benchmark tasks

Native ID: TASK-046. Phase: 8. Kind: analysis. Requirement: INK-R12 (REQ-022).

Dependencies: INK-045 (TASK-045).

Goal and requirements: Provide 6 bugfix, 6 feature, 4 tests, 4 refactor, 4 static-analysis, 4 integration and 2
recovery tasks.

Scope: Existing benchmark harness, task snapshots and accepted specifications.

Tests: Same repositories, permissions, contexts, budgets, attempts and gates for Inkling and current Qwen.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-047: Measure verified coding completion and inference cost

Native ID: TASK-047. Phase: 8. Kind: analysis. Requirement: INK-R12 (REQ-022).

Dependencies: INK-046 (TASK-046), INK-035 (TASK-035).

Goal and requirements: Report verified rate, elapsed/inference time, calls/tokens, remediation, unauthorized
changes, memory and recovery.

Scope: Existing task/evidence and benchmark reporting.

Tests: Run all 30 tasks for both models; distinguish model, engine and harness failures; evidence-based adoption
decision.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-048: Audit separate variable-loop checkpoint controls

Native ID: TASK-048. Phase: 9. Kind: analysis. Requirement: INK-R10 (REQ-019).

Dependencies: INK-001 (TASK-001).

Goal and requirements: Pin actual allowed counts/control mechanism; never infer support by editing
fixed-checkpoint count.

Scope: Official research checkpoint, converter, model capabilities and independent runtimes.

Tests: Independent checkpoint metadata and per-count reference fixtures; document unsupported variants.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-049: Validate and expose variable-loop configuration

Native ID: TASK-049. Phase: 9. Kind: implementation. Requirement: INK-R10 (REQ-019).

Dependencies: INK-048 (TASK-048), INK-040 (TASK-040).

Goal and requirements: Reject fixed-checkpoint count overrides; accept only research-checkpoint permitted counts
with provenance.

Scope: Existing inference configuration, adapter validation and schedule builder.

Tests: AUnit count boundaries, default/explicit settings and independence from reasoning effort.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-050: Conform variable-loop cache and message execution

Native ID: TASK-050. Phase: 9. Kind: test. Requirement: INK-R10 (REQ-019).

Dependencies: INK-049 (TASK-049), INK-024 (TASK-024).

Goal and requirements: Resize state for validated counts while preserving lifecycle and deterministic behavior.

Scope: Logical state allocation, message lifetimes and reference fixtures.

Tests: Independent per-count logits, reset/rewind/cancel, context budgets and actual-count diagnostics.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-051: Map and execute native vision encoder tensors

Native ID: TASK-051. Phase: 10. Kind: implementation. Requirement: INK-R11 (REQ-021).

Dependencies: INK-040 (TASK-040), INK-003 (TASK-003).

Goal and requirements: Validate model-specific encoder and projection mapping within existing multimodal
execution.

Scope: Existing Vision, tensor loader and backend kernels.

Tests: Independent encoder-stage fixtures, invalid shapes/precision, allocation failure and cleanup.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-052: Match image preprocessing patching and projection

Native ID: TASK-052. Phase: 10. Kind: implementation. Requirement: INK-R11 (REQ-021).

Dependencies: INK-051 (TASK-051), INK-004 (TASK-004).

Goal and requirements: Implement exact resolution/tiling/patch ordering and projection into text hidden width.

Scope: Existing Ada image codecs, resize/preprocess and projection kernels.

Tests: Independent decoded pixel, patch, embedding and projection fixtures; invalid and oversized input cases.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-053: Integrate image embeddings with text context and provenance

Native ID: TASK-053. Phase: 10. Kind: implementation. Requirement: INK-R11 (REQ-021).

Dependencies: INK-052 (TASK-052).

Goal and requirements: Combine image/text with correct token accounting and preserved provenance without
normalizing raw image embeddings.

Scope: Existing multimodal prompt sequence, conversation state and context accounting.

Tests: Single/multiple image prompts where supported, context reuse, limits and cancellation.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-054: Conform mixed image text input and lifecycle

Native ID: TASK-054. Phase: 10. Kind: test. Requirement: INK-R11 (REQ-021).

Dependencies: INK-053 (TASK-053), INK-034 (TASK-034).

Goal and requirements: Validate image understanding separately from text support and reject unsupported image
modes.

Scope: Existing multimodal inference and independent image references.

Tests: Mixed image/text reference answers and embeddings, invalid input, memory cleanup and text-only
regression.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-055: Validate regressions documentation and public Ada contracts

Native ID: TASK-055. Phase: 11. Kind: implementation. Requirement: INK-R12 (REQ-022).

Dependencies: INK-040 (TASK-040), INK-045 (TASK-045), INK-035 (TASK-035).

Goal and requirements: Describe actual validated capabilities; document unsupported extensions and all new
public contracts.

Scope: support-matrix, inference-api, reference-runtime, coverage roadmap, CLI, changelog and GNATdoc.

Tests: Existing architecture/backend regression suite, documentation checks and project_tools quality gates.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-056: Run production release conformance and lifecycle gates

Native ID: TASK-056. Phase: 11. Kind: test. Requirement: INK-R12 (REQ-022).

Dependencies: INK-055 (TASK-055), INK-047 (TASK-047).

Goal and requirements: Require native CPU/Vulkan conformance, cancellation/cleanup, harness evidence and
measured benchmarks.

Scope: Existing AUnit, reference, release, dependency and packaging gates.

Tests: Full existing release verification, no external runtime dependencies and all 14 fixed-text acceptance
gates.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

### INK-057: Qualify variable-loop and vision release independently

Native ID: TASK-057. Phase: 11. Kind: test. Requirement: INK-R12 (REQ-022).

Dependencies: INK-050 (TASK-050), INK-054 (TASK-054), INK-056 (TASK-056).

Goal and requirements: Advertise each extension only after its own execution, structural validation, errors,
AUnit and conformance.

Scope: Existing release capability declarations and extended reference suites.

Tests: Variable-loop and vision acceptance suites; fixed-loop text completion does not depend on these
extensions.

Acceptance and completion: the stated behavior executes, required checks pass, unsupported behavior fails
explicitly, documentation is current, and build/test/reference evidence is recorded through normal V3 gates.

## Current implementation evidence

`Llama.Execution_Schedules` and four registered AUnit routines cover the 48-step independent source trace,
physical ownership and distinct runtime slots, deterministic reconstruction, single-pass identity for all
supported physical counts, half-open region boundaries, caller limits, overflow rejection and stale-result
clearing. These tests require no checkpoint. This is evidence toward INK-010; it does not complete Milestone B
or satisfy the unresolved checkpoint-level dependencies. See [verification](inkling2-verification.md).
