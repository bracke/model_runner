# Model coverage roadmap

A plan to close every model-related gap the survey found — the live refusal
paths and host fallbacks that block or slow real models. Ordered by dependency
and cost, not by tier, so the sequence is buildable start-to-finish.

## Progress (as of 2026-09-21)

Done, each crossed against the independent reference over every format and path
(conformance outside tolerance nought) and committed to main:

- **Phase 0:** #1 rope longrope, #2 unnormalized expert weights, #3 samplers
  (top-a, Mirostat v1, dynamic temperature), #5 jina alibi bias read from the
  file. **#4 (Q8_1/Q8_K) is closed as a non-goal** — both are ggml activation
  intermediates, not weight-storage formats; no published GGUF stores weights
  in them, so there is nothing to decode. Phase 0 is complete but for #6, which
  is ongoing onboarding rather than a task.
- **Phase 1:** #7 shared experts, #8 sigmoid gating, #9 wide-mixture gather spill — Phase 1 is complete.
- **Phase 2:** #10 IQ3_S (the first sub-4-bit grid quant; the rest of the IQ
  family remains, on demand).
- **Phase 3:** #12 reranker head; #11 Granite, OLMo2, GLM4, Starcoder2,
  GraniteMoE, StableLM, GPT-NeoX, InternLM2, Baichuan (7B and 13B), MPT,
  ChatGLM and Command-R/Command-R+ — the config-mostly batch is **complete**.

Phase 0 is closed (bar #6, ongoing onboarding). Still open: #10 (other
quants), and Phases 4–6 (#11, the config-mostly arch batch, is complete).

## Guiding constraints

- **The engine refuses rather than defers.** Each gap is an explicit refusal
  (`Reject_Feature`, `Arch_Unsupported*`, `Type_Unknown`) or a
  "…on the host" fallback. The work is turning a refusal into a real path,
  never loosening a check without a path behind it.
- **The gate must stay green.** Every new architecture, quant, or projector
  needs (a) a fixture in `tests/src/tiny_model.adb`, (b) a `conformance` entry,
  and (c) CPU↔device parity — the device shader packs every format the CPU
  decodes, so adding a quant means adding *both* sides. This is the dominant
  hidden cost and is folded into each item's estimate.
- **Solo repo, one workstream at a time**, commit straight to main, gate before
  each commit, re-stamp `docs/measured-figures.txt` when a fingerprinted source
  changes.

## Cross-cutting foundations (build once, reuse everywhere)

- **F0 — a fixture+conformance recipe per new kind.** Adding an arch/quant today
  means hand-writing a tiny model and a conformance row. Factor the shared
  scaffolding so each later addition is one small entry, not a copy-paste. Do
  this the first time Phase 2 or Phase 3 needs it. *Small, pays back across all
  later phases.*
- **F1 — a refusal audit map.** One place listing every `Reject_Feature` /
  `Arch_Unsupported*` call site and the metadata key it guards, so a reviewer
  sees coverage as a table. *Small.*

---

## Phase 0 — Quick wins (independent, small, high ratio)

Each is isolated, needs no new infrastructure, and can ship same-day.

1. ✅ **Done. Rope scaling allow-list** (`llama.adb:678`, refusal `:681`). Accept
   `longrope`/`su`/`dynamic` and route to the LongRoPE factor-table path that
   already exists (`:686`, `:3610`); add dynamic-NTK where the table doesn't
   apply. *Verify first whether Phi-3.5 long files set this key.* **Small.**
2. ✅ **Done. Unnormalized expert weights** (`llama.adb:976`). Replace the refusal with a
   branch that skips the top-k renormalization when
   `expert_weights_norm = false`. **Small–Medium.**
3. ✅ **Done. Extra samplers** (`sampling.adb:239`). Mirostat v1 (count from the
   estimated tail shape), top-a, and a dynamic/entropy temperature
   (`dynatemp_range`/`dynatemp_exponent`) now sit beside the existing
   v2/min-p/typical/DRY/XTC set, each held to its behaviour by a unit test.
   **Small each.**
4. 🚫 **Won't do (non-goal). Q8_1 / Q8_K decode** (`gguf.adb:32`, `:38`). Both
   are ggml *activation intermediates*, not weight-storage formats — no
   published GGUF stores weights in them, so flipping `Supported` would add a
   decoder+encoder+fixture+shader for a format nothing downloads. Kept refused,
   with the reason recorded in the support matrix. **Not a gap.**
5. ✅ **Done. jina-bert-v2 alibi `max_bias ≠ 8`** (`llama.adb:1168`). The stated
   bias is read from `attention.max_alibi_bias` and used (eight kept only as
   the default); `Head_Slope` already built the ladder from whatever it holds.
   **Small.**
6. **Tokenizer pre-tokenizer rules** (`tokenizer.adb:490`). Not a one-time task:
   each new model may need one rule mapping added to the ~40 already present.
   Treat as ongoing onboarding, not a phase. **Small each.**

**Exit:** long-context Phi/others load (#1); a class of MoE loads (#2);
sampling is complete.

---

## Phase 1 — MoE completeness

The three MoE refusals share one forward path; do them together.

7. ✅ **Done. Shared (always-on) experts** (`llama.adb:988`). Add a shared-expert arm to
   the mixture forward that runs for every token beside the routed top-k, on
   both CPU and device. Unblocks Qwen2-MoE, Hunyuan-MoE, and is a prerequisite
   for DeepSeek (Phase 4). **Large** (new forward path + device dispatch).
8. ✅ **Done. Sigmoid gating** (`llama.adb:963`). Add `expert_gating_func = sigmoid`
   beside softmax in the router. **Medium.**
9. ✅ **Done. `[device]` spill a wide mixture's gather** (the real limit was
   `Products.Max_Gather = 16`, the experts one gather reads at once — the
   push block holds sixteen member indices — not `Block_Limit`, which bounds
   a multi-session round). A token routing to more than sixteen experts used
   to drop its mixture to the host; now the router chooses up to
   `Max_Route = 64` in one pass (the route buffer and `route.comp` hold the
   whole chosen set) and the gather reads them sixteen at a time, each chunk
   summed by its pre-renormalized shares — exactly additive, so the chunks
   land where one gather of them all would. The token road sums the chunks on
   the host (its existing design); the batch road already iterated per expert
   with no cap. Crossed CPU-vs-device at twenty experts, seventeen chosen, a
   token, a batch and in chunks. **Medium.**

**Exit:** modern routed+shared MoE loads and runs on-device, a wide mixture
spilling its gather rather than dropping to the host. (#2 from Phase 0 is the
third leg.) **Phase 1 is complete.**

---

## Phase 2 — Quantization expansion

Per format: `gguf.ads` enum entry → CPU decoder + interleave → device shader
pack (`backend-device.adb:706`) → fixture. Keep CPU and device in lockstep.
Order by what actually gets downloaded.

10. ⏳ **Partial (IQ3_S done). IQ4-family gaps, then IQ3_S/XXS, IQ2_*, IQ1_*, TQ1_0/TQ2_0**
    (`gguf.ads:122`, refusal via `Type_Unknown`). Each format is a self-
    contained decoder+shader+fixture. These are what fits 70B+/big-MoE into
    consumer memory, so prioritize the specific quant of a model you want.
    IQ3_S landed (grid decoder + encoder + reference + fixture; host-only, the
    device falls back). **Large in aggregate; Medium per format.**

**Exit:** sub-4-bit downloads stop bouncing at load. Do formats on demand rather
than all at once.

---

## Phase 3 — Conventional architecture variants

Arches that are transformer-shaped and differ mostly in config/norm placement.
Each: enum entry (`llama.ads:187`), metadata loader, block-shape handling,
fixture, conformance row. Batch the cheap ones.

11. ✅ **Done. Config-mostly arches:**
    ✅ Granite, ✅ OLMo2, ✅ GLM4, ✅ Starcoder2, ✅ GraniteMoE, ✅ StableLM (the
    1.6B config; the 12B's per-head QK-norm and parallel residual are refused),
    ✅ GPT-NeoX (both the parallel-residual and sequential forms), ✅ InternLM2
    (llama's block; the converter splits its fused GQA-interleaved wqkv
    upstream, so nothing new at load), ✅ Baichuan-7B (llama's block again;
    the converter splits its fused W_pack upstream — the 13B's runtime-selected
    alibi, keyed on forty-layer depth, is a separate follow-up a fixture
    cannot reach), ✅ MPT (the departure from the family — a pre-normalized
    decoder with causal alibi in place of rotation, a centred normalization
    without a bias, a non-gated Gaussian feed-forward and an optional
    queries/keys/values clamp; host fallback for that untried device
    combination), ✅ ChatGLM (ChatGLM3 / GLM-4-9B — glm4's partial interleaved
    rotation and fused gate/up, but with fused queries/keys/values and an
    optional fused bias, and a plain RMS pre-norm in place of glm4's sandwich;
    host fallback like glm4), ✅ Command-R/Command-R+ (MPT's centred-no-bias
    normalization worn as Falcon's one-norm parallel block, a logit scale that
    multiplies where Granite's divides, and — for Command-R+ — a centred
    per-head query/key normalization read where present; host fallback for the
    combination), ✅ Baichuan-13B (the ALiBi size — forty layers alone tells it
    from the 7B, no key in the file, so the depth turns rotation off and sets
    the bias of eight; MPT's causal ALiBi, host fallback gated by the bias it
    carries so the 7B stays on device; crossed by a forty-layer fixture like
    the deep gemma3, not the sweep). **The config-mostly batch (#11) is
    complete.** Refusal was at `llama.adb:524`; each arch was largely wiring
    against the existing norm/gate/bias/rotary/mixture paths + a device
    host-fallback guard for any untried kernel combination.
12. ✅ **Done. Reranker (ranked pooling) head** (`llama.adb:642`). Add a scoring head
    beside mean/cls/last pooling so GGUF rerankers load. **Small–Medium.**

**Exit:** the long tail of standard-shaped models loads.

---

## Phase 4 — DeepSeek (MLA + MoE)

Depends on Phase 1. DeepSeek needs three things at once:

13. **Multi-head latent attention (MLA)** — a new attention shape (compressed
    KV latent + decoupled rope). New enum arch (`llama.ads:187`), a distinct
    attention path on CPU and device, plus shared experts (#7) and sigmoid
    gating (#8) from Phase 1. **Large** — the single biggest conventional-family
    unblock, and the reason to finish Phase 1 first.

**Exit:** DeepSeek-V2/V3-class models load and run.

---

## Phase 5 — Non-attention sequence layers

The largest infra investment; also the largest device win for models already
"supported."

14. **`[device]` delta-rule / linear-attention shader** (`llama.adb:13165`,
    `:14044`). Today a hybrid's linear layers (delta rule + short conv + gated
    norm) run entirely on the host — for Qwen3.5/3.6 that's ~75% of the network
    off-device. Write the device shaders and a device state path. **Large.**
15. **State-space architectures** (Mamba/Mamba2/RWKV/Jamba). Build on the
    host-then-device pattern #14 establishes: a new sequence-layer kind with its
    own recurrence, on host first, then the device shader. **Large per family.**

**Exit:** hybrid models run mostly on-device; pure state-space models load.

---

## Phase 6 — Vision projectors

16. **Beyond gemma3 / qwen3vl_merger** (`vision.adb:416`, `:540`). Per projector:
    pixtral, llama4/mtmd, MiniCPM-V, InternVL, SmolVLM, LLaVA, Qwen2-VL. Each is
    a distinct patch-embed + merge shape. **Large in aggregate; Medium each.**
17. **`[device]` `Sink_Room` depth cap** (`backend-device.ads:72`). A model
    deeper/wider than GPT-OSS spills its sink layers to the host. Raise the room
    or make the sink slot region grow with the model. **Small–Medium.** Fold in
    whenever a deeper sink model becomes relevant.

**Exit:** the common multimodal families load.

---

## Sequencing at a glance

```
Phase 0  (quick wins)            ── independent, do first
Phase 1  (MoE completeness)      ── before Phase 4
Phase 2  (quants)                ── anytime after Phase 0, on demand
Phase 3  (conventional arches)   ── independent batch
Phase 4  (DeepSeek MLA)          ── needs Phase 1
Phase 5a (delta-rule device)     ── before 5b
Phase 5b (state-space)           ── needs 5a's infra
Phase 6  (vision)                ── independent
```

## Effort summary

| Phase | Unblocks | Size |
|-------|----------|------|
| 0 | long-context rope, some MoE, samplers, small quants | S (days) |
| 1 | Qwen2-MoE, Hunyuan, DeepSeek prep | L |
| 2 | sub-4-bit downloads | L (M per format) |
| 3 | standard-shaped long tail | M (many small) |
| 4 | DeepSeek-V2/V3 | L |
| 5 | on-device hybrids, state-space | XL |
| 6 | multimodal families | L (M per projector) |

## Recommendation

Do **Phase 0** in full (cheap, unblocks real loads immediately), then pick the
one Phase-2 quant or Phase-3/4 arch of a model you actually want to run — the
big phases only pay off against a concrete download, so drive them by need
rather than completeness.
