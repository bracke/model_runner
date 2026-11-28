# model_runner

Local GGUF language-model execution in Ada 2022.

The current native runtime requires an x86-64 host. Non-x86 execution is
refused explicitly until the remaining machine-code kernels have portable
bodies.

`model_runner` loads a local GGUF model file, validates its container strictly,
prepares a bounded Llama-compatible decoder-only execution plan, tokenizes
prompts, evaluates the model on the processor or on a compute device, maintains
an explicit KV cache, samples output tokens, decodes them incrementally and
streams the generated text.

Inference is local only: no network access, no daemon, no Ollama, no llama.cpp,
no delegation to an external model runtime.

## Status

The engine and the command-line program work end to end. Current qualified timing evidence is linked
under Speed. Older performance observations are preserved in [PERFORMANCE_HISTORY.md](PERFORMANCE_HISTORY.md)
and are not current-source claims.

A list of what is
**not** implemented is at the bottom of this file; nothing here claims a
capability it does not have.

```
$ model_runner inspect tiny-model.gguf --threads 4
Container
  path                            tiny-model.gguf
  file size                       7.5 KiB (7648 bytes)
  GGUF version                    3
  data alignment                  32
  metadata entries                21
  tensors                         21
  parameters                      1256
  tensor formats                  F32
  memory mapped                   yes

Architecture
  name                            tiny
  architecture                    llama
  context length                  16
  embedding width                 8
  ...

Tokenizer
  tokenizer model                 llama
  vocabulary                      16
  byte fallback                   no
  beginning token                 1
  end token                       2
  chat template                   present and supported

Memory
  model weights                   4.9 KiB (5024 bytes)
  session at this context         5.2 KiB (5338 bytes)
  ...

Execution
  backend                         cpu
  worker tasks                    4

$ model_runner run tiny-model.gguf --raw --prompt "ab" --seed 42 --temperature 0 --max-tokens 6
 bcaaaa
```

## Commands

```
model_runner [MODEL]         a session on a terminal: the model named, the
                             settings file's `model`, or one chosen from the
                             models directory
model_runner run MODEL       generate text from a model file
model_runner embed MODEL     reduce a text to one vector
model_runner image [MODEL]   draw a picture from a prompt (Qwen-Image 2.1)
model_runner transcribe FILE.wav
                             write out what a recording says (Whisper)
model_runner inspect MODEL   report what a model file contains
model_runner models          list the models on hand, or remove one
model_runner help [COMMAND]  show help for a command
model_runner version         show version information
```

The project's commands -- /init, /task, /work, /req, /check, /tree and the
rest -- are a session's: `model_runner MODEL`, then
`/help project` lists them.

A model is a path, a file in the models directory, an alias from the
settings file, or a Hugging Face reference offered for download. The models
directory is `~/models` where that folder is, else
`~/.local/share/model_runner/models` (`$XDG_DATA_HOME` where set); `models-dir`
in the settings file or `MODEL_RUNNER_MODELS` names another. Downloads go
there and `models remove` takes from it. A bare name it does not hold is
looked for in the other of the two folders too -- the data home's when
`~/models` is the store, so what was downloaded before still runs by name
-- and `models`, the chooser and completion show its files by their path.

Run `model_runner help run` for the full option list. Options are validated
with the same typed path as environment variables, repeated options are a usage
error, and `--` ends option processing.

### What `run` decides on its own

Each of these is what a run does when the option is not given; giving the
option always wins.

- **Where it runs.** On the device when one opens and the model fits what the
  device may hold -- its own memory and the share of system memory it can map,
  leaving room for the rest of the machine -- and on the processor otherwise.
  A mixture whose experts do not fit but whose other layers do runs those
  layers on the device and its experts on the processor for a prompt, and a
  generated token -- or a drafted round's few -- in the first 1,536 positions
  of a context on the processor whole, its attention over the host's copy of
  the cache: two hand-overs a layer cost a token more than the processor
  takes for the layers itself (Qwen3-30B-A3B Q4_K_M 17.4 tokens a second
  split, 19.0 so, its prompt 299 a second either way). Deeper, the device's
  attention is the faster: 13.3 split against 7.2 at 8,315 positions. Not a hybrid, whose linear layers the device runs faster, and not a mixture
  whose other layers are in any format but Q4_K, Q5_K, Q6_K, Q8_0 and the
  floating-point ones: the rest the processor reads four to eight times
  slower as the file lays them out than in the panels the device's half is
  not rewritten into (Qwen3-Coder-30B-A3B Q2_K: 9.9 on the processor whole,
  23.7 split). The experts the processor runs are rewritten into its panels,
  kept in the panel cache, as a processor run's are. A dense model that
  does not fit keeps the gate, up and down of enough of its top layers on the
  processor, in panels, for the rest to fit. The room such a model takes on
  the device is counted -- the device's memory less its context, a hybrid's
  states and a margin -- rather than a fixed three quarters: the context the
  run names, or where it names none the longest one, halving down from the
  model's own, at which the whole model fits, and 16,384 positions where
  none does. A session that named none is held to that context, because a
  context left to grow on the device grows into the weights' room; the
  statistics say the context size. `--backend` names one.

  A mixture session records every routed expert in a bounded, per-layer
  recency/frequency policy. `Model_Runner.Llama.Expert_Cache_Stats` reports
  observations, candidate hits, misses, promotions and evictions, plus
  physical admissions, device runs and resident bytes. `--expert-cache SIZE`,
  or `Prepare`'s `Expert_Cache` parameter, reserves an explicit byte budget
  from a partially held mixture. The default is zero. Admission uses only
  that reserve and never evicts another matrix; all three slices must fit or
  none is kept. Individually resident experts run on the device while the
  rest remain in the processor's pool.
  Where the processor rewrites experts into interleaved panels, admission
  and device execution use source-layout slices retained from their stacks;
  the device never reads the panel representation as ordinary rows.
- **How the processor holds the weights.** Repacked once into eight-row
  panels (`--repack rows`) where the processor has the kernels, the model fits
  in free memory and in one allocation; the panels are kept under
  `~/.cache/model_runner/panels` so the next load maps them. `--repack none`
  keeps the file's layout.
- **How the context is stored.** Transformed four-bit keys and four-bit values
  (`--kv-cache q4t`), with automatic `f16` fallback for a model whose head
  width is not divisible by the transform's 32-element group.
- **How long a reply may be.** In a conversation, no limit: a reply runs
  until the model ends it, Ctrl-C stops it, or the context is full, which is
  said. With a prompt, at most 4,096 tokens, or less where the context fills
  first, as nobody may be watching to stop one that never ends. An agent's
  reply has 1,024, or more with a reasoning model. `--max-tokens` names one.
- **Whether and how it drafts.** In this order: from the model's own
  next-token block where it carries one and that block is cheap beside the
  model; from a draft named beside the model in a `.draft` file; from the
  largest file in the store or the model's folder that numbers its tokens as
  the model does and is at most a sixth of its size, for a dense model of two
  gigabytes a token or more; from the context (`--draft-lookup`) for such a
  model on the device otherwise; and not at all for anything else. Three
  proposals a round, and a draft model's rounds grow or shrink with what the
  rounds keep. A draft model searches the context first each round and
  proposes only where that finds nothing, resting the search for eight
  rounds after one of its rounds kept nothing. `--draft-tokens 0` turns it
  off; so does a grammar where the run samples.

### Spec-driven development

A session's project commands keep a project's development state in
`.model_runner/` beside its code, as specified in
`docs/spec_driven_development_framework_v3_revised.md`: what the project is
meant to be (specifications, requirements and decisions, each revised
rather than rewritten), the work toward it (tasks moved only by their
lifecycle's legal transitions), what happened (events, evidence, model
invocations and their context manifests), and what is derived from them
(indexes, traceability, readiness). Every change is a journaled
transaction that an interrupted session finishes or undoes on the next
open; nothing is kept in a conversation.

The commands are typed in the conversation, between turns, in the project
directory. One pass through the workflow, with illustrative identifiers:

```text
$ cd ~/src/hello
$ model_runner qwen2.5-coder-0.5b-instruct-q8_0.gguf      # a session opens; no --interactive needed

> /init ada-cli project_name=hello                        # start the project's state from a template
  ▸ Initialize                                            # confirm the plan; Tab shows it whole
initialized hello in ./.model_runner
next: /bootstrap FILE reads a document's requirements in, /req new TITLE text=... says one,
      and /task new TITLE kind=KIND makes a task

> /bootstrap docs/requirements.md                         # REQ-… lines are imported, SHALL lines proposed
> /req new "Greets by name" text="The program SHALL print Hello, NAME."
created REQ-001: Greets by name
> /accept                                                 # the one candidate waiting; several → it lists each
REQ-001 is accepted
derived TASK-001, in the component hello                  # a task that serves it, made at once
> /task accept 1                                          # 1 is TASK-001
> /task list                                              # ready tasks shown first
TASK-001  [ready]  REQ-001: Greets by name

> /work 1                                                 # this session's model does it:
                                                          # context → call → changed files → verify
> /check                                                  # the project's checks, recorded as a verification
> /task integrate 1                                       # where work runs in a workspace: take it in
> /state                                                  # where the project stands
> /tree   /sym Greet   /refs Greet   /impact src/hello.adb   # ask about the code; no model involved
> /search greet by name --verbose                         # ranked: symbols, files, records, lines; why each
> /exit
```

1. **Existing code:** `/init` in its directory, `/bootstrap` its documents,
   then `/req accept` the candidates worth keeping.
2. **A task done by hand:** `/task complete ID` runs its checks and closes
   it.
3. **Stuck:** `/help project` lists every project command, and most
   commands end with a `next:` line naming the likely step.

Out of scope: an outside program -- a script, another coding agent -- as
the agent. The harness can only compare files after such a program ran, not
confine it, so `/work` runs a model: the session's own, or one `model=PATH`
names.

`/work` gives the session's own model the task in a conversation of its
own, built from the project state, with the file tools and nothing else;
the conversation on the screen is left as it was. That work conversation
has a KV session of its own, retained between `/work` calls; project-stable
rules, configuration and specifications lead each context, then task facts,
repository excerpts and run-specific results, so exact prefix matching can
keep only what still agrees. One lazily opened helper session is retained as
a serial, bounded pool: model weights remain shared, while at most two extra
KV contexts (work and helper) are resident. It may hand a part of the work -- a review, an
investigation -- to a helper with `delegate`: the harness makes that child
agent within what its parent was given (by default at most two, one level
down), gives it a context and KV session of its own so it cannot evict its
parent's prefix, keeps its result and tells the parent only that. Each
invocation records its total prompt tokens, those read and reused, and its
prompt milliseconds, cache-hit percentage, and why its first and last prompt
did or did not reuse a prefix (`cache_empty`, `prefix_extended`,
`token_changed`, `picture_changed`, or a rewind outcome). `/task audit` shows
those figures. The measured production check and regression thresholds are in
[`docs/cache-session-baseline.md`](docs/cache-session-baseline.md). A required child that fails is run once more; if it
still fails the task is blocked (`scalar agents.on_child_failure = fail`
fails it instead), and cancelling a task cancels its agent's children.

What an agent may do is checked as it does it. Its file tools stay inside
the project and within its `read_source`/`read_specs` and
`write_source`/`write_specs` grants; `run_checks` builds and tests the
project as the task will be verified, where `run_build`, `run_tests` or
`run_static_analysis` covers the profile; and a workspace is taken in for
it only with `request_integration`. A task can narrow its agent further
with a `permissions` field -- `/task new "..." "permissions=read_source;
write_source: roots=src/parser/; run_tests"` -- and what that does not
name, the agent may not do, reading included; `/work` refuses a task whose
agent would be left unable to do it. Work an agent proposes becomes candidate tasks where it may
`propose_tasks` (by default it may), and an issue where it may not.
Ctrl-C stops a reply or a `/work` as it runs: the invocation and its
agents are recorded cancelled and the task is set aside, blocked, until
it is accepted again.

Settings change with `/reconfigure NAME=VALUE ...` -- `scalar.`, `set.`,
`list.`, `map.`, `profile.`, `fact.`, `adapter.` and `task_kind.` fields,
`NAME=` to remove one -- for a permission's capability too, which is then
not granted at that level; `on` grants it with no constraints, `off` takes
it away, and `inherit` follows the level above. It shows each change and what it reaches, asks, and
makes a new revision of the configuration, kept in its history; evidence
taken under the old one no longer applies, and requirements and readiness
are worked out again. No template is read on the way.

A session that starts in a project looks at its state first and says what it
put right: a task whose session died holding it (a lease names its process,
so a dead one lets go at once) is blocked -- or failed, or accepted again,
as `scalar recovery.running` says -- and agents, invocations and workspaces
no one is running are recorded abandoned. Every call is on record: a child
has an invocation and a context manifest of its own, each tool call is
noted on the invocation that made it, with what it used, and `/work`
budgets for the loaded model's own context size.

What a task's agent is shown of the code is chosen by the harness, not
found by the model. A symbol the task names -- `Parser.Parse_Number`,
`Units_Of_File` -- is given as its declarations, cut from their files as
they are now (an Ada declaration from its comments and generic part to its
`;` or `end NAME;`, C-like code by braces, Python by indentation), and as
the bodies it is used in, before the component's files, which follow
ranked by the task's words: in a small room the model gets the lines it
needs where a whole file would not fit. Each excerpt says its file, lines,
how it was bounded and a reference with its file's print; an excerpt of a
file given whole is left out, and the manifest records how the source was
chosen and why each item went in. During the work the agent asks for more
with the `find` tool -- kind `search` ranks the symbols, files, records and
lines that best match words or names, saying why and how far each is to be
taken as said (accepted, proposed, historical, not authoritative); kind
`declaration` shows a name's declarations, the one holding `PATH:LINE`, or
a reference's lines while its file is unchanged -- each held to what the
agent may read. `/search WORDS` asks the same at the terminal. Measured by
`tests retrieval-bench` on twelve frozen framework sources, five tasks at
rooms of 4,096, 8,192 and 32,768 tokens: the lines each task needs went in
36 times of 36, against 14 before; at 8,192 the lookup task's context is
4,003 tokens where it was 7,168 and held neither line. On a task naming one
subprogram of a 2,400-line package (`tests agent-trial --task large
[--retrieval whole]`, three runs each), qwen3-8b with excerpts edited on
its first call every time: eight runs of eight complete with 2 calls each,
117-194 s (151 s on average), against eight of eight with the files whole
at 3-4 calls, 122-305 s (191 s on average); an earlier set of three had one
run with excerpts loop and fail. Mellum2.1-12B read the file either way and
took the same time both ways. The ranking's
rules are written in `Model_Runner.Framework.Retrieval`; the index of the
files' words is kept in the process and read again on the first search
after a start.

For a complete Ada function or procedure body, agents can give `edit_file` a revision-bound `ref` from
`find` instead of copying `old_text`. The tool checks structural boundaries and returns a fresh reference
after a successful replacement. See [reference editing](docs/reference-editing.md) for its scope and examples.

Work is verified as widely as what it changed reaches. The traceability graph
says which tests the change reaches and how sure that is; where the policy
allows testing less than everything and names a profile for it --
`scalar verification.scope.certain` or `.component`, or per task kind
`verification.scope.KIND.certain` -- that profile runs in the task's
profile's place, its checks given `{tests}`, `{scope}` and `{component}`;
anything uncertain is verified in full. The evidence says what was chosen
and why. `/check consistency` lists what does not hold together in the
project's state -- the spec's list, including a task whose component the
project does not have and one held ready while what it depends on is open --
and opening a project says how much there is.

The graph, what a change reaches and the tests chosen for it are worked out
once and kept (`.model_runner/derivations`), each named by everything it was
made from -- the files at their fingerprints, the project's records, the
policy, and its algorithm's own version -- so the same change chooses its
tests without working them out again, and anything changed is worked out
anew. The evidence names the selection, and `/result VER-...` follows it back
through what the change reached to the files that changed.

What an agent finds while it works -- a tool's quirk, an approach that
failed -- it keeps with `record_observation`; the harness keeps it at once,
with the task, generation, agent and invocation it came from, and keeps one
of its own when a task's checks fail again as they failed before. Later work
on the same task, its files, its requirements or its component is told it,
after what governs the work and labelled stale where its files have changed
since, and never as authoritative: `/obs` lists and shows what was learned,
and `/obs promote ID task|fact|decision` is the only way one becomes part of
what the project means. `scalar knowledge.observations = off` stops it being
told -- what agents and the harness find is still recorded, so turning it back
on loses nothing -- and `knowledge.max_hot` and `knowledge.max_warm` bound it
(five each).

Both are there to read, too: `.model_runner/views/observations.md` and
`.model_runner/views/derivations.md` are made again from the state whenever
it changes, say at their top that they are generated, and are read by
nothing -- an edit to one is gone the next time it is made, and
`scalar views.markdown = off` leaves them out.

A task is revised with `/task edit TASK NAME=VALUE ...` -- a new revision of
its definition, its kind among them (`kind=test`), and `/task link TASK
REQ-001 ...` adds requirements it serves; its parent and dependencies have
their own commands -- made to wait with `/task depend TASK ON`, and split with `/task split TASK
First part; Second part`: the parts are its children, and the parent waits
on them, blocked, unless the project's `scalar task.coordination` (or
`task.coordination.KIND`) is `parent_runs`. An ended task comes back only by
`/task reopen`, a rejected one by `/task reconsider`. A task's kind may set
its own policies -- `scalar task.isolation.KIND`, `task.token_budget.KIND`,
`task.max_steps.KIND`, `set task.gates.KIND`, and its permission level for
children and proposals -- and its Effective Task (`/task show`) says what
governs it, with every override and conflict, what it may do, where it
writes, what bounds it and which gates it must pass; what governs it is put
in front of the model too.

How each model call `/work` makes is set -- its temperature and probability
filters, whether and how much it reasons, how long its reply may be -- is the
project's inference policy. `scalar inference.mode` is `fixed` unless said
otherwise: every call is set as the session is, its command line first,
then the model file's own settings -- but for an implementation task on a
model of the qwen3, qwen35, mellum or Qwen mixture (qwen3moe, qwen35moe)
architecture, which is adaptive unless
a mode is named (below). `profile` sets every call by one
profile, `scalar inference.default`; `adaptive` sets a task's calls by its
kind (`scalar inference.task.KIND`, which `standard-development` maps:
implementation to coding, bugfix to debugging, test to testing, analysis to
analysis), a helper's by its role (`inference.role.ROLE`), and each call by
what the harness saw lead to it: one after checks failed is
`failure_recovery` (the debugging profile), one asked only for the report
`result_reporting` (reporting), a helper's whose role may write neither
source nor specifications `verification_analysis` (verification) -- by what
it is granted, not what it is called -- each mappable with
`inference.activity.ACTIVITY` -- `task` keeps the task's own. A task no
mapping reaches is set as in fixed mode. The built-in profiles are analysis,
architecture, coding, testing, debugging, exploration, reporting and
verification -- temperatures from 0 to 0.5 and reasoning low to high, first
values for a model's benchmark to confirm -- and documents. In every mode,
fixed too, a helper whose delegate outputs are documents alone (`.md`,
`.txt`, `.rst`, `.adoc`) is set by `inference.helpers`, `documents` unless
named: thinking off and nothing else, measured below; `none` sets it as its
parent, as a helper that writes code is and one run again after a failure.
A model names its helpers' roles as it likes, but says what each must
write. `scalar inference.profile.NAME.FIELD` changes one (`temperature`, `top_k`, `top_p`,
`min_p`, `reasoning`, `thinking`, `max_tokens`) or makes one of its own, and
`scalar inference.adapts` takes `both` halves of a profile, only its
`reasoning`, or only its `temperature` and filters -- what tells apart which
half a task's outcome owes (`tests agent-trial --inference
fixed|adaptive|reasoning|temperature|thinking-off|helpers-off`). A
task's own `inference=profile=NAME temperature=0.1 ...` stands in any mode.
Each setting comes from the first that says it -- the session's command
line, the task, the project's profile fields, the profile, the defaults --
and then from what the model's template reads: a reasoning level goes to a
template that takes one (`reasoning_effort`, as gpt-oss's) and to one that
only takes whether to think as on for high and off for low, its default for
medium, said as a fallback; a level the task or project named that the model
cannot take stops the task before it moves, while one a profile chose is
dropped and said. A reply never gets more room than the session keeps for
it, and nothing here reaches the task's budgets, permissions or checks. Each
round's settings, with where each came from, are kept on its
invocation as it is made -- `/task audit` lists them -- and a model run as a
process of its own is handed the policy beside its prompt (`run
--policy-file`) to fit to its own template. `run --reasoning-effort
low|medium|high` names a level for a run outside `/work`.

**What was measured, and where fixed stays the default.** On 2026-11-01,
`tests agent-trial` ran the edit, find and delegate tasks under each arm on
Mellum2.1-12B-A2.5B-Thinking (three rounds) and qwen3-8b (two); both
templates take only whether to think, so a reasoning level was measured as
thinking on or off. In seconds over the three tasks and three rounds, on
Mellum:

| arm | total | completed |
|---|---|---|
| fixed | 803 | 9/9 |
| adaptive | 913 | 9/9 |
| reasoning only | 909 | 9/9 |
| temperature only | 882 | 9/9 |
| thinking off for every call | -- | 6/9: edit and find loop |
| adaptive, helpers not thinking | 667 | 9/9 |

No arm beat fixed by more than a run's own spread, so the profiles' values
stay unproven and fixed the default. Thinking pays for itself: without it
the edit loops. A helper without it is a third faster where it fetches and
writes prose (delegate 54 s a run against adaptive's 88), and no faster
where it edits code (`delegate-edit`, three rounds: 525 s against 457, its
calls doubled) -- so `inference.helpers` sets only a helper whose outputs
are documents, and one that writes code thinks as its parent does. So split,
three alternated rounds took delegate from 272 s to 178 and left
delegate-edit's helper thinking, all twelve runs complete. The
sampling filters measured alike: top-k 40, top-p 0.95, min-p 0.05 took
611 s over two rounds; min-p alone 1,101, top-p alone 867,
none 1,078.

gpt-oss-20b, whose template takes levels -- low, medium, high reach it as
asked -- ran fixed, adaptive and reasoning only three alternated rounds on
2026-11-02. Medians a run, edit / find / delegate: fixed 86 / 32 / 64 s,
adaptive 202 / 128 / 55, reasoning only 341 / 71 / 56; fixed completed 9/9,
adaptive 9/9, reasoning only 7/9 (a find without its summary line, an edit
that gave up after 1,018 s). Levels make gpt-oss slower and no surer, so
fixed stays the default there too.

That edit gave up after going round one line -- "We can use
Ada.Numerics.Long_Long_Integer? Not." -- for nineteen thousand tokens. A
thought that comes back to a line an eighth time, once it has run past
8 KB, is now closed for gpt-oss at high effort, the line named in it and in
the note that asks it to go on; other models' thoughts are left alone. The
rule is the model family's own (`Agent.Round_Rule_For`): closed at the
fourth time and at any length, gpt-oss's fixed and adaptive edits failed
where left alone they were done, and four trials of three rounds could not
tell the remaining rules apart -- the loop is an Ada idiom gpt-oss lacks,
which closing seldom mends. With it, and a `summary:` written ahead of the
report giving way to the report's own (gpt-oss's finds were refused on
it), the last trial completed 23 of 27; Mellum after it 18 of 18, its
medians at or below its earlier runs.

Across the 2026-11-01/02 trials, paired by alternated round, adaptive's
edit was the faster in 10 pairs of 14 on qwen3-8b, Mellum and
Swift-1.5-Qwen3.8-27B (medians on 2026-11-02: Mellum 188 -> 127 s, Swift
379 -> 317 s), and level on finding (6 of 11) and handing work on (6 of
11); gpt-oss's edits were slower adaptive, its levels reaching its
template. So an implementation task on those three families' models is
adaptive where no mode is named, and so are the two Qwen mixture families
(qwen3moe, qwen35moe), unmeasured -- coding's temperature 0.2 and medium
effort, debugging for a mending, reporting for the report
(`Inference_Policy.Measured_For`); naming `scalar inference.mode = fixed`
keeps it fixed, and every other family and kind of task is fixed as
before. A run apart (`--policy-file`) is set the same way: the session's
model's family goes into the file written for it.

A project that lists its components (`set components = parser, lexer`) has
tasks name one of them or none. A profile's check may carry options after
its label -- `tests[timeout=120, retry=1, severity=warning, keep=summary]?:
alr build` -- and each check is an event: `Build_Completed`,
`Test_Completed` or `Test_Failed`. Evidence records each program's
`--version`, the adapters, the template version and every check's
parameters, and no longer applies once the environment its checks were
given has changed -- or, with `scalar verification.toolchain = strict`, once
a tool answers with another version.

`/task list` narrows with
`state=`, `kind=`, `component=`, `requirement=`, `origin=` and `parent=`;
`/work` takes text as well as an identifier, running the one accepted task
it names and offering, or listing, the ones when it names several;
`/check full` runs the profiles `list verification.full` names; and
`/state` says how many agents are active and how the last full test went.

An agent that finds its task too large may name its parts under `parts:`;
where it may propose tasks they become candidate children of it. A record
of an older schema version is carried forward by the migration steps
registered for it. Raw check logs and kept contexts go after `scalar
retention.raw_log_days` and `retention.context_days`; evidence stays. An
agent's tool calls can be bounded (`scalar agents.max_tool_calls`, or
`task.max_tool_calls.KIND`) and the workspaces active at once
(`work.max_workspaces`); the standard-development template asks where work
is written, `project` or `workspace`. The Ada adapter also records
instantiations, derivations, the interfaces a type takes on, overriding
and calls.

What the project is meant to be is managed in the session too. `/req`,
`/decision` and `/spec` list their register, show an entry by its
identifier, and take `new TITLE "text=..." "criteria=..." scope=...`,
`accept`, `reject`, `reconsider`, `obsolete`, `revise ID "text=..."
scope=...`, `link ID RELATION TARGET`, `supersede OLD NEW` and, for
requirements, `block` and `unblock`, and for decisions and
specifications, `govern ID SETTING RULING`. One superseded is listed as
superseded by the one that replaced it, in every register. Nothing
proposed -- by a person, or found by `/bootstrap` -- governs until it is
accepted, and each change moves the project along at once: an accepted
requirement derives its task, for the project's own component when the
requirement is the whole project's. Bare `/accept` and `/reject` decide the
one candidate waiting, whatever it is, and name the commands when there are
several. An agent writing a component in the project itself holds it:
another task of that component is not ready until it is done.

An agent's answer can say more than done or not. `proposed_tasks:` lines may
name their own `kind=` and `component=` (`Write the manual; kind=
documentation`); `decisions:` and `specifications:` become proposed entries
of those registers; `waits_for:` says which task this one should wait for,
kept as said until `/task depend` makes it so; and `verify: yes` has the
work checked whatever the status. All of it is proposal until a person
accepts it. A project names the gates a task must pass (`set task.gates`,
or `task.gates.KIND`): beside verification, children, no blocking issue and
integration, `implementation_present`, `traceability_sufficient`,
`documentation_current`, and any gate of its own that `scalar gate.NAME`
ties to a profile.

Ada project templates also enable native [Code Health](docs/code-health.md):
successful source-changing calls are reconciled against the actual workspace
and checked immediately, blocking findings return to the model for bounded
repair, and the `code_health` task gate accepts only current immutable evidence
linked to the task's full verification. Ordinary conversations can opt in with
`code-health.enabled = true` in the [settings file](docs/settings-file.md).

What `/work` puts in front of the model follows the specification's list:
besides the rules, the task, its requirements, decisions, authorities,
configuration, specifications and files, it now says what the task's files
declare, which tests bear on it, and what the last attempt left -- the
previous answer and what its verification found wrong -- so a retry knows
why it is one. And work is bounded in time: `scalar agents.max_seconds`, or
`task.max_seconds.KIND`, else the task's lease, for the agent and its
children together; past it the task is set aside, blocked, not failed. Set
to `model`, the time is the model's pace instead: what 24,000 tokens take
at the speed it generates at, measured as it works, so a slow model is
given longer for the same work -- the lease at most.

A task answers for itself: `/task audit TASK` says, from the records alone,
which requirement and definition revisions applied, why it could start (kept
when it did -- its state, what it waited for, that nothing held it or its
component), which decisions applied, what context the model got and which
model it was, what changed and where, what verified it and with which tool
versions, what completed it, and where its requirements stand now. What of
the project's state goes into Git is `scalar repository.state_policy`:
`portable`, the default, commits what travels with the project and leaves
out what belongs to one machine or can be built again; `local` leaves out all
of it; `all` commits all of it -- kept as the state's own `.gitignore`. And
`/git` asks Git how the project stands: the branch, and each changed path
with the tasks whose work changed it.

A tool's output becomes diagnostics that say, where the tool does, the
file, line and column, the severity, the tool's own code (`-gnatwu`,
`E0308`), the name it is about, the other places it points at, and where
in the kept raw output it was said. `/impact` takes a symbol as well as a
file -- `/impact Parser.Next`, or just `Next` -- and says what refers to it,
depends on it and tests it. A task that is proposed starts as a candidate
unless `set task.auto_accept` names its class -- its kind, or where it came
from: `user`, `requirement_derivation`, `agent`, `verification_engine` --
and every acceptance, rejection and other move records who made it: the
person at the terminal, the policy, or the agent. An agent's file tools never read or write the project's state, whatever
its grants -- it changes only through the harness's transactions -- nor
write `.git`; links are followed before that is judged. The same guard
holds an agent the harness starts as a process of its own (`/work ID
model=PATH`): its tree and permissions go with it, and its file tools refuse
the rest. Git and that agent process run through the execution layer like a
project's checks -- no standard input, only PATH, HOME and what is passed,
a deadline -- and each run is a line in `.model_runner/runtime/harness.log`.
`/instruct scope = change only src/parser/ overriding DEC-003` puts a
person's word above every decision, specification and baseline rule on that
subject, as what agents are told, until `/instruct withdraw INSTR-001`; it
changes no setting -- `/reconfigure` does that. What `/bootstrap` reads and
may make is the project's bootstrap policy (`set bootstrap.sources`,
`set bootstrap.propose`, `scalar bootstrap.import`). A template can ask
for confirmation before `/init` writes anything (`scalar init.confirm =
yes`; the generic template does). `/reconfigure` checks the whole new
configuration, says which derived state it invalidates, and commits the
new revision together with the requirements it takes verification from.
`/init` builds the derived indexes -- requirements, decisions, tasks,
components, symbols, tests, traceability, dependencies and a search index
of names -- and opening a session builds them again when what they were
built from has moved on. `/sandbox RESTRICTION` confines every agent the
session starts, below every other permission level, written as a task's
`permissions` field is (`MODEL_RUNNER_SANDBOX` does the same from the
shell; `/sandbox off` frees it). Integration refuses a semantic conflict as
it refuses a textual one: no file changed on both sides, but a unit changed
on both, or one side's changed unit depending on the other's;
`/task integrate ID anyway` takes the work in once someone has looked. The repository graph reads Ada, C and C++, Rust and Python: each file's
unit, what it brings in (`with`, `#include "..."`, `use`, `import`), what it
declares at its outer level, what it extends or implements, and where the
names it can see are used and called -- each relation saying whether it is
explicit, a naming convention or a heuristic. None of the adapters compiles:
macros, conditional compilation and re-exports are not seen through, and a
Rust `use` of a lower-case name, which may be a module or a function, is
marked uncertain. Templates state baselines -- `baseline project.SUBJECT = ...` and
`baseline language.SUBJECT = ...` -- the two lowest standings of authority,
which govern what nothing higher speaks to and reach the task's context.
Where the files are is configuration too: `set repository.skip`,
`repository.tests` and `repository.documentation` name directories, paths
or `*` name parts, and the standard templates set them. The repository graph is brought up to date
rather than made again: only a file whose size or time changed is read,
and only the references that could see it are found again. A file tool's
path stays inside the project with its links resolved, so a link out of
it is no way out. These commands are a session's alone: the command line
has none of them.

Kinds of project, task kinds, verification profiles, execution policy,
permissions and automation rules are all the project's configuration,
resolved from templates at `/init` and never looked up again. A model is
asked only for the work itself: selection, readiness, verification,
completion, traceability and scheduling are the harness's.

### Saving a context

Reading a prompt costs what it costs: on this machine prefill runs at about
27 tokens a second, so a thousand-token document is more than half a minute
before the model says anything. Its cache is tens of megabytes. Saving that
and handing it back is the difference between waiting for the model to
re-read a document every time and not.

```
model_runner run MODEL --raw --prompt-file document.txt --max-tokens 0 \
  --save-session document.ctx
model_runner run MODEL --raw --prompt-file question.txt \
  --load-session document.ctx
```

Only the committed positions are written, not the capacity. What is loaded
fills the cache before the prompt is looked at, and the generation keeps
whatever of it the new prompt agrees with and re-reads only the rest -- so a
saved context is worth having when the next prompt extends it, and costs
nothing but a refusal to read the file when it does not.

The file names the model it belongs to, the shape of the cache, the context
capacity and the precision it is held in, and any mismatch is refused rather
than read: one model's attention is not another's. The identifier is the
model's validated shape together with the size of its tensor data, a sample
of its bytes, and a digest of any adapter merged into it -- that identifies a
model file and is not meant to verify one.

The adapter belongs in that identifier because merging one replaces the
weights: a context computed before a merge describes attention the merged
model never had, and nothing about the text that came back would look
wrong. The two were indistinguishable until a test asked, and the test only
asked usefully once it was written against a quantized model -- with
binary32 weights the merge writes into the file's own bytes, which the
identifier already samples, so it appeared to be handled when it was not.

A saved context is untrusted input, and every field of it is range checked.
What cannot be checked is whether the contents mean anything: bytes that
match are read, and what they say the model was thinking is what the model
will think. Loading a file is trusting whoever wrote it with the
conversation.

### Auxiliary GGUF shards

`--shard PATH` loads tensors from an explicitly named GGUF beside the main
model. It is repeatable, and paths may also be comma-separated. `--ple PATH`
is the same option under the name used for separately distributed
per-layer-embedding or engram weights:

```
model_runner run MODEL --ple model-ple.gguf --prompt "..."
```

These are exact auxiliary files, not numbered backbone pieces: their split
numbers are ignored and no neighbouring files are inferred from their names.
Tensor names must be unique across the combined model. The one intentional
exception matches llama.cpp's external-PLE contract: an auxiliary containing
only `per_layer_token_embd.weight` replaces that tensor in the backbone.
Other duplicate names are rejected. All files remain open for the model's
lifetime, their offsets are rebound into one logical source, and their sizes
are included in memory admission while their resolved paths are included in
session-cache identity. Panel-cache identity binds the backbone and every
auxiliary in precedence order, each by resolved path, size, nanosecond
modification time and filesystem change stamp. A missing identity disables
reuse; changing or reordering any auxiliary cannot serve the old panels.

### Adapters

Complete trajectory capture is opt-in through `MODEL_RUNNER_CAPTURE_DIR`, with bounded private local
storage and separate helper episodes. `tests trajectories --episode PATH` validates a selected capture;
`--mode export --out NEW.json --include-content` explicitly exports its full content. Without content
selection the export contains metadata only and is ineligible for training. Independent verification,
token masks, limits and the dataset contract are described in [trajectory capture](docs/trajectory-capture.md).

`tests agent-campaign` compares original and adapted models through the native
`/work` workflow, in four arms with thinking enabled and disabled. It records
content hashes, independently graded outcomes and resumable JSON attempts.
Separate runtime adapters can be selected per model slot with `--base-adapter`
and `--adapted-adapter`, at independent scales and an explicit CPU backend.
Embeddings select CPU attachments through `Inference.Open_Options.Runtime_Adapters`;
see [the inference API](docs/inference-api.md) for ownership and provenance semantics.
An identical-source [before/after CPU check](docs/harness-adapter-no-adapter-check.md)
records the no-adapter timing cost separately from active-adapter overhead.
Its inspection mode compares bounded GGUF headers without claiming that missing
tensor payload has been verified. See [the campaign guide](docs/harness-adapter-campaign.md).

`--lora` is repeatable and the adapters stack, in the order given: a merge
adds a difference to the weights, so a second one lands on top of the first
rather than replacing it. `--lora-scale` pairs with them positionally -- the
Nth scale belongs to the Nth adapter, and an adapter named without one is the
adapter as it was trained.

A scale of minus one subtracts, which is how an adapter comes off again:
naming the same file twice at plus one and minus one leaves the weights where
they started, to within what binary32 rounding does to a number added and
taken away. Both claims are held by a test that measures how far the logits
move -- a second merge moves them about as far again as the first, and plus
one followed by minus one puts them back within a hundredth of that
distance.

`--lora PATH` merges a low-rank adapter into the weights before anything is
generated. An adapter says what a fine-tune changed, as a pair of small
matrices per weight it touches whose product is the difference; merging adds
that difference, so evaluation afterwards costs exactly what it cost before
and the adapter's own storage goes when its file is closed.

```
model_runner run MODEL --lora adapter.gguf --lora-scale 0.8 --prompt "..."
```

Only binary32 weights can be added to, so naming an adapter selects
`--repack f32` where none was named -- four bytes a weight, the same bargain
that flag already publishes. `--repack bf16` beside an adapter is a usage
error rather than a quiet rounding of every merged weight.

The merger validates recognized pairs and numerical results before writing
weights, so a bad later pair leaves the model unchanged. Saved contexts bind
the full adapter content and tensor descriptors. This adds merge-time work.

Use `--lora-mode runtime` to keep base weights quantized and apply the low-rank
difference during CPU execution:

```
model_runner run MODEL --lora adapter.gguf --lora-mode runtime --prompt "..."
```

This mode selects CPU and disables drafting unless those choices were already
explicit. It supports dense Llama, Qwen2, Qwen3, Qwen35 and Granite main-layer projections,
including hybrid feed-forward layers. CPU token and prompt-batch execution are
supported; the reference backend supports tokens. Device execution, experts,
drafting and mixing runtime attachments with merged adapters are refused.
The default remains `--lora-mode merge`, with its existing F32 repacking rule.

Runtime adapters accept finite F16/F32 matrices and own decoded F32 copies, so
their source files can close after loading. Limits are eight files, 4096 pairs,
rank 64 and one GiB of decoded matrices plus descriptors; API callers can tighten
them. Session scratch holds eight rank vectors and eight output vectors, sized
to the largest attached rank and output width, at four bytes per element.
CPU batches process tiles of up to eight positions on the
existing worker pool; each completed tile reuses the scratch. Failed loading preserves the model, memory
account and identity. Saved contexts bind decoded content, shapes, order, scales,
alpha and execution mode. See the [execution contract](docs/adapter-execution-contract.md).
The tiled implementation versions runtime identity; saved runtime contexts from
the first scalar implementation must be regenerated.

`tests adapter-fixture` takes `--model MODEL --out ADAPTER [--tensor NAME]` and
writes a bounded synthetic rank-two F16 pair shaped from the named matrix (default
`blk.0.ffn_gate.weight`). Its coefficients are artificial, for execution and
memory checks; it carries no trained behavior or evidence of a quality gain.
The output must be a new path; existing files are refused.
`--rank N` selects ranks one through 64; `--all-targets` includes every present
supported main-layer projection and excludes next-layer drafting weights.
The generator caps encoded matrix data at 128 MiB.

`tests adapter-bench` measures paired CPU base, zero-scale and runtime arms,
optionally including same-base F32 merging. It reuses the speed runner's full
warm-up and prompt/decode clocks, reverses arm order on alternate repeats, and
records raw samples, paired ratios, content hashes, accounting and host conditions
as JSON. Zero scale must preserve the base digest and every arm generates the
same requested token count. These are timing controls, with no model-quality claim.

**What merging costs.** It is rank times every weight it touches, once at
load. Measured on this machine: **0.27 ns** an update at rank sixteen, and
4.4 ns at rank one -- the difference is that a rank-one merge reads and
writes each weight for a single update where a rank-sixteen merge amortizes
that over sixteen. TinyLlama-1.1B has about 968 million adaptable weights,
so a rank-sixteen adapter is 15.5 billion updates: **about four seconds**.
`tests benchmark` reports both ranks, because reporting only rank one would
have made a four-second merge look like a minute.

The scale multiplies the difference over and above the adapter's own alpha,
so `1.0` is the fine-tune as trained and `0` is the model without it.
Adapters for `attn_q`, `attn_k`, `attn_v`, `attn_output`, `ffn_gate`,
`ffn_up` and `ffn_down` are merged; a pair naming anything else is refused,
as is half a pair, because half a difference is not a smaller difference.

### Constrained output


`--json-schema TEXT` and `--json-schema-file PATH` take a JSON schema and
turn it into a grammar before anything is generated, so a caller with a
schema does not have to hand-write GBNF and then keep the two in step. It
reads `type`, `properties` with `required`, `items`, `enum`, `const`, exact
`allOf` intersections, supported `anyOf` unions, provably disjoint `oneOf`
unions, and document-local `$ref` pointers through `$defs` or `definitions`.
Nested intersections are reduced exactly;
`integer` intersected with `number` remains `integer`, while incompatible
types are refused. Object intersections merge distinct properties and
identical declarations of the same property; conflicting declarations are
refused rather than approximated. Every other keyword is refused by name
rather than ignored -- a keyword
ignored produces a grammar that allows more than the schema does, which is a
constraint that quietly is not one.

A property the schema does not require may be absent; one it requires may
not. A schema that names no `required` list requires everything it names,
which is not what JSON Schema says -- there, absent means optional -- and is
the narrow direction this errs in throughout. The first property named must
be one the schema requires: a first property that may be absent makes the
comma before the second conditional on it, and expressing that needs an
alternative for every place the object might start.

Objects come out closed and ordered: exactly the properties named, in the
order named. JSON leaves member order free and a grammar that allowed every
order would grow as the factorial of the property count, so what this
produces is narrower than the schema. Everything it accepts the schema
accepts, and not the reverse; that is the honest direction for a constraint
to err in and it is written where a reader will meet it.

`tests schema SCHEMA` prints the grammar a schema becomes, which is how the
output gets read without running a model.

```
$ model_runner run MODEL --raw --prompt "Describe Paris: " --max-tokens 24 \
    --temperature 0 --json-schema '{"type":"object","properties":{
      "city":{"type":"string"},"population":{"type":"integer"},
      "capital":{"type":"boolean"}}}'
{"city":"Paris","population":100000,"capital":true}
```

`--grammar` holds the generated text to a grammar. At each step every token
whose text cannot continue the grammar is removed from the distribution
before anything is sampled, so what comes out is text the grammar accepts --
not text the model was asked nicely to produce.

```
model_runner run MODEL --raw --prompt "list three colours" \
  --grammar 'root ::= "[" item ("," item){0,4} "]"
             item ::= "\"" [a-z]+ "\""'
```

`--grammar-file` reads it from a file instead; naming both is a usage error.
The notation is GBNF: rules with `::=`, alternatives with `|`, sequences,
`"literals"` with the usual escapes, `[a-z]` and `[^a-z]` sets, `( )`
grouping, `?` `*` `+` and `{n}` `{n,}` `{n,m}` repetition, and `#` comments.
One rule must be called `root`. Sets and literals match code points, not
bytes, so `[a-ø]` means what it says whatever the tokenizer does underneath.

Anything outside that notation is refused where it is met, with the position
in the grammar: there is no construct the parser recognizes and then
declines, so there is no separate diagnostic for one. Every bound -- rules,
elements, ranges, nesting, and how many ways the grammar may be in the middle
of at once -- is a refusal rather than an allocation, because a grammar comes
from a command line or a file and is therefore untrusted.

The end-of-sequence token is masked until the grammar may end, so a run
cannot stop half way through what it was told to produce. A token that
contributes no text at all is masked throughout: it cannot advance a grammar,
and allowing it would let a run produce it forever while the grammar stayed
where it was. If a step leaves nothing at all -- a grammar this model's
vocabulary cannot spell -- the run stops and says so, rather than leaving the
sampler with an empty distribution and reporting that instead.

In a conversation the grammar applies to each reply, and starts again for
each: what a grammar describes is an answer, not a whole conversation.

**Tools.** `--tools` offers the model tools, as the JSON a caller already
holds; `--tools-file` reads them from a file. They reach the model through
its own chat template, so a model whose template says nothing about tools is
refused rather than told nothing and asked anyway. What comes back is a
reply, and what the reply asks for is read out of it and reported on standard
error, by name, so standard output stays what the model wrote.

Reading a tool definition or a tool call runs nothing: the tool packages
start no process, open no socket and load no library, so a tool call is text
the model wrote and a tool result is text you hand back. Offered this way and
left open, the loop closes outside the program -- you run the tool and pass
its answer back on the next turn:

```
$ model_runner run MODEL --tools-file tools.json \
    --prompt "What is the weather in Paris?" > reply.txt
tool call: get_weather {"city": "Paris"}

$ model_runner run MODEL --tools-file tools.json \
    --prompt "What is the weather in Paris?" \
    --assistant-file reply.txt \
    --tool-result '{"temperature_c": 18, "sky": "clear"}'
The current weather in Paris is clear with a temperature of 18°C.
```

The turns follow the prompt in the order they are written -- `--assistant`,
`--tool-result`, another reply, another answer -- because which reply an
answer follows is the shape of the loop. The reply is handed back as it was
printed and the calls are read out of it here, so what reaches the model is
the call as that model's template writes one rather than as the model
happened to spell it. Interactively the same loop is `/tools` to see what is
on offer and `/tool TEXT` to hand an answer back.

**Closing the loop.** `--agent` runs the loop rather than leaving it open: the
model's calls are run and the answers fed back until it answers, a step
budget (`--max-steps N`, eight by default) or a token budget
(`--max-total-tokens N`, off by default) runs out, or a call repeats one
already made. A repeat is answered from the first only while nothing has
changed what it read: each tool says whether it reads, changes state or
varies (a clock), and a call that changes state -- a write, a shell, a
sub-agent -- makes every call before it run again, so a file read after it
was written is read anew. Each call also ends answered, failed or refused
-- and refused by what: a path outside the project, the harness's own state,
a permission, the execution policy -- which is what the harness acts on,
never the words of the answer; `--trace-file` writes it beside each result.
A conversation compacted to fit carries the harness's record of the work in
its task -- what was changed, what still fails, what was refused -- written
from the calls it saw rather than by asking the model. It runs a broad built-in set -- arithmetic and string work, a
scratchpad it can write and read, base64, the clock, files, a ranked search
over a folder of text files, PDFs, Office documents (modern and legacy),
OpenDocument, EPUB, RTF and HTML, a shell, Python, an HTTP fetch, a web
search, SQLite, a `delegate` that hands a subtask to a sub-agent, and an
`ask_user` that puts a question to the user mid-loop
-- so unlike the rest of the program
the agent's built-ins *do* start processes and open files. `http_get` and
`web_search` fetch through an in-process HTTP/HTTPS client (the `httpclient`
crate, the body streamed to a file rather than held in memory -- `web_search`
percent-encodes its query into a GET to the DuckDuckGo lite endpoint);
`run_python`, `sql` and `shell` run `python3`, `sqlite3` or `sh`, and say so
plainly when that program is not installed. Each spawned command runs
under a watchdog that stops it after thirty seconds, so one that hangs
answers the model with a timeout rather than stalling the loop. An answer too
big for the call buffer -- a long file, a chatty command -- keeps its head
and its tail with the middle dropped and its size noted (`...[N bytes
elided]...`), rather than losing everything past the head, so the start of a
file and the summary or error a run ends with both reach the model, and it
can ask again for a narrower slice if it needs the rest; a file is read head
and tail directly, never through its middle, so an enormous one costs no more
than a small one. Because those
built-ins reach the world, `--confirm-tools` puts a hand on the gate: each
call is
printed and the loop waits on standard input -- y runs it, q stops the run, and
anything else declines the one call and tells the model, which may then take
another way to the answer. For an unattended run there are guardrails that
need no one at the keyboard: `--deny-tool NAME` (repeatable) refuses every
call to a named tool, and `--deny-arg TEXT` (repeatable) refuses any call
whose arguments contain the text -- a shell command with `rm`, a path outside
a root, a host you will not reach. A refused call is not fatal: the model is
told, as with a declined confirmation, and may take another way, so the run
goes on inside the fence. The rules are checked before a call runs and before
any confirmation prompt. `--max-retries N` gives a generation that errors a
second try instead of ending the run on the first stumble.
`--max-total-tokens N` caps the tokens generated over the whole loop, not just
one reply: it is checked between steps, so the reply in flight finishes and
then the loop stops rather than running the next round of calls -- a turn that
answers is never cut off. The `delegate` tool splits a large job into pieces:
it hands one self-contained subtask to a sub-agent that runs a loop of its
own -- same tools, its own step and token budget, a session and conversation
apart from the caller's -- and only the sub-agent's final answer comes back,
so the detail of the piece never fills the caller's context. A sub-agent is
given no delegator of its own, so delegation goes one level deep and no
further; when no sub-agent session will open (most often for want of memory)
`delegate` declines and the run goes on with the other tools. With
`--max-parallel` above one, on a processor backend, the delegator opens a
small pool of sub-agent sessions rather than one, and several `delegate`
calls in a turn fan out -- each subtask on a session of its own, running at
the same time -- which is the map half of a map-reduce: split a job across
sub-agents, then combine what they return. (The device backend evaluates one
session at a time, so there delegation stays one subtask at a time whatever
`--max-parallel` says.) `--memory-file PATH` backs the
`memory_put`/`memory_get` scratchpad with a file: the notes in it are read in
at the start and each `memory_put` writes the whole set back, so what one run
remembers a later run recalls. Without it, memory lasts only for the run. The
file is the run's own -- a fanned-out sub-agent keeps its memory to itself
rather than sharing it -- and its format is length-prefixed, so a value with
any byte in it, a newline included, reads back whole. `--trace-file PATH`
writes a machine-readable record of the run as JSON: the model, the final
tally (why it stopped, steps, calls, retries, tokens, elapsed milliseconds),
and every call and result in order, each with the time since the run began.
It is best effort -- a trace that will not write does not fail the run -- and
arguments and results are escaped, so a tool's own JSON sits in the trace as
a string.
`--max-parallel N` lets a turn's calls overlap: when the model makes several
calls at once, the ones that are safe to run beside each other -- a read, a
network fetch, a search that ranks by words -- run together on up to N worker
tasks, while the rest, and every dedup and approval decision, stay in order
on the main task, and results are handed back to the model in call order
whatever order they finished in. The tools that must not overlap stay serial:
the memory notes (one scratchpad), `write_file`, the tools that run a process
this program waits on (`shell`, `run_python`, `sql` -- one wait would reap
another's child), `delegate` and `ask_user` (a single session, the one
console), and `retrieve` when it embeds (one embedding session). One, the
default, keeps every run one after another. The `ask_user`
tool lets the model pause to ask for what only the user knows -- a missing
detail, a choice, a go-ahead: the question goes to the console and the
answer is read from standard input as one line, so a run is a conversation
where it needs to be, not only a one-shot task. With no one to ask -- an
eval, a library embedding, a closed input -- `ask_user` gets no answer
rather than blocking, and the loop goes on. `--compact` keeps a
long tool-using run going when the conversation outgrows what will render:
the oldest turns are dropped, the system message, the task and the recent
turns kept, and a short digest of what was dropped -- the calls made and what
they returned, in a line each -- is folded into the task, so the run keeps
the thread of what it has already done rather than losing it outright. The
digest is bounded and carried forward, so it never grows the task without
limit. `--checkpoint-file PATH` lets a run be taken up again: it writes the
whole conversation to the file at the close of every step and once more at the
end, and at the start, when the file already holds one, it loads that
conversation and continues it rather than starting from the prompt -- the
prompt becomes the next turn, a follow-up on the resumed run. So a run stopped
at a step or token budget can be continued with a higher one, a task carried
across sessions, and a run cut off partway -- killed, a crash -- resumed from
the last step it finished rather than lost. The format is length-prefixed, so
any content round-trips whole. `--embed-model PATH` gives
the `retrieve` tool a model trained to
embed, so it ranks a folder's passages by meaning rather than by the words
they share (without it, the model being run embeds, or the ranking stays
lexical). `--json-schema` (or `--json-schema-file`), which constrains a
plain run's whole output, here constrains the agent's final answer: the
reply becomes a tool call or an object in that shape, so the answer the loop
ends on is valid against the schema rather than prose to be parsed. It holds
whenever the offered tools build the tight call grammar, which the whole
built-in set does. `--tool-command CMD`
instead runs the tools `--tools`/`--tools-file` describe by handing each call
to that program, which is a caller's own runner reached from the command
line. Either way the reply is grammar-constrained, so a call the model writes
always parses and always names a tool on offer. A caller embedding the library
passes its own `Approver` for the gate and its own runner for the tools. The
library is where this is assembled --
`Model_Runner.Agent` drives the render/generate/parse/run circle over
`Model_Runner.Tools`, `Model_Runner.Conversation`, `Model_Runner.Templates`
and `Model_Runner.Generation`, against a `Model_Runner.Tools.Runner` a caller
supplies -- and `tests agent-eval --model MODEL --anyway` scores it on a table
of tool-use tasks against a real model, the way `tests speed` and `tests
perplexity` measure behind the same gate.

**What the campaign scores, on published models.** Ten tasks: four that
need one tool, three that chain two, one that must answer to a schema, and
two that must not call anything. Greedy, seeded, so a score is the same
run to run; each model at the arithmetic `run` gives it unasked -- int8,
and for Gemma 2 mixed -- rendered with the carried format its own template
is written in, since none of these five templates compiles; eight threads,
an 8,192-token context, 2026-09-15.

| Model | Passed | Steps | Calls | Tokens | Wall | Peak RSS |
|---|---|---|---|---|---|---|
| Qwen3.5-4B Q8_0 | **10** / 10 | 20 | 12 | 735 | 3:46 | 5.3 GB |
| Qwen3.5-0.8B Q8_0 | **9** / 10 | 19 | 10 | 501 | 0:38 | 1.3 GB |
| MiniCPM5-1B Q4_K_M | **9** / 10 | 19 | 10 | 1238 | 0:51 | 1.1 GB |
| Gemma2-2B | **8** / 10 | 19 | 12 | 612 | 2:28 | 3.2 GB |
| Gemma3-4B Q4_K_M | **10** / 10 | 21 | 12 | 689 | 2:18 | 3.3 GB |
| Gemma3-1B Q4_K_M | **3** / 10 | 17 | 11 | 947 | 3:12 | 1.1 GB |

Gemma 2 is the one whose score the arithmetic decides: 7 at f32, 3 at int8,
8 with its attention projections left in f32 and the rest rounded, which is
what `--arith mixed` is and why it is that family's default. Gemma3-1B scores
3 at every arithmetic; a one-billion-parameter model pastes a parameter
schema where the arguments go, and no format fixes that -- the 4B, on the
same format, scores ten. The table is
what `tests agent-eval` printed, not a claim about the models beyond these
ten tasks.

**What sampling costs.** It runs once per token and over as many candidates
as the model has tokens, which every fixture here has sixteen of. Measured
over 32,000: **0.062 ms** greedy, and **0.18 ms** with top-k 40, top-p 0.95,
min-p 0.05 and a repetition penalty. Against about 85 ms for a token of
TinyLlama-1.1B that is a fifth of a per cent.

It was 2.86 ms -- fifteen times that -- because a top-k of forty was reached
by sorting all thirty-two thousand candidates. A small top-k is now selected
rather than sorted: the order candidates are ranked by is total, the logit
and then the token, so any correct way of taking the first k of it takes the
same k in the same places. A large top-k is still sorted, because keeping k
in order as you go costs more per candidate than sorting does once k is big
enough; where the two cross is a judgement and it is written where it is
made. Both figures come from `tests benchmark`.

**What it costs.** The filter runs over the whole vocabulary at every step,
so it is worth a figure rather than an assurance. Measured on a stand-in
vocabulary of 32,000 short pieces, one token filtered takes **10 ns** where
the grammar allows one character next and **116 ns** inside a run of letters,
where most tokens survive their first character and are matched to the end.
Over 32,000 tokens that is 0.3 ms and 3.7 ms a step, against about 85 ms for
a token of TinyLlama-1.1B: four per cent at worst.

The first version cost 7.4 microseconds a token -- 0.24 s a step, several
times the forward pass -- and the whole difference was copying. A matcher
holds 256 stacks of 64 positions, and both stepping and testing a token were
clearing or copying all of it whether or not it was in use. Now the count
bounds what is copied, nothing is cleared that will not be read, and a token
whose first character no live stack accepts is refused before anything is
copied at all. `tests benchmark` reports both figures.

### Speech input

A session can be spoken to. Name a Whisper model -- `--speech-model PATH`,
or `speech-model = PATH` in the settings file -- and in the session Ctrl-G
records, Ctrl-G again stops, and what was said is put into the line being
typed, at the cursor, to be edited and sent as any typed line is. Escape
drops the recording, or stops hearing it; Ctrl-_ takes the transcript out
again. Nothing is sent, and no command
run, by speaking: a transcript beginning with a slash goes in with a space
before it.

```
model_runner qwen3-8b --speech-model ~/models/whisper-small-f16.gguf --speech-language da
model_runner transcribe meeting.wav --speech-model ~/models/whisper-small-f16.gguf --speech-timestamps
```

The speech model is its own: read on first use, beside the conversation's
model and never in its place, with its own workers and memory; refused
where the two do not fit, never the conversation's shrunk. The microphone
is the sound server's on Linux (PipeWire or PulseAudio, through
libpulse-simple; a host without it refuses by name), winmm's on Windows and
AudioToolbox's on macOS; `--speech-device` names another source,
or `file:PATH.wav` to play a recording in its place, at its own pace.
Recordings stop at `--speech-max-seconds` (120), are kept in memory only,
and are forgotten once heard.

The Whisper file is a GGUF written from OpenAI's checkpoint as Hugging Face
publishes it: `cd tests && ./bin/tests whisper-convert --from DIR --out
whisper-small-f16.gguf`. Transcription is the reference's, greedy: on
Whisper tiny and small the tokens, times and text of English and Danish
recordings are the reference's own (docs/plan-speech.md).

Whisper runs on the device when one is open, its encoder and every token
of its decoder: `transcribe` opens it unless `--backend cpu` is given or,
`--backend` not given, the model is tiny's size (128 MB or less) and the
recording one window of thirty seconds, which the processor hears sooner
than the device can be opened; in a session it is borrowed while the conversation's model, there
already, waits for the line -- never while that model runs, and not at
all where the device has no room beside it.
Current transcription speed is not qualified. Earlier speech timings are preserved in
[the historical snapshot](PERFORMANCE_HISTORY.md#speech-input).
`--speech-detect-from-window` detects language from the decoding window rather than a separate encode.

### Embedding

`image` draws a picture from a prompt with Qwen-Image 2.1: its denoiser,
Qwen3-VL-8B as its text encoder, and its VAE, each found in the models
directory by its published name -- `qwen-image-2.1-Q8_0.gguf`,
`Qwen3-VL-8B-Instruct-Q8_0.gguf`, `qwen_image_2.1_vae_bf16.safetensors` --
unless named with MODEL, `--text-encoder` and `--vae`.

```
model_runner image --prompt "a red apple on a wooden table" --out apple.png --size 512x512
```

The picture is an RGBA PNG; the same `--seed` (42 unless said) draws the
same picture. Each part is held to stable-diffusion.cpp on the published
files: the prompt's rows, a step's velocity (cosine 0.99999), the latent
after forty steps (0.99997) and the decoded picture (76-78 dB); the whole
command's 512 picture is the reference's at 48 dB from the same seed.

`--count N` draws N pictures in one run, from the seed given and the
ones after it, as FILE-1.png and on; the models are read once for all of
them.

What the text encoder makes of a prompt is kept in the cache home's
`prompts` directory, so a picture drawn again from the same prompt does
not read the encoder (`--no-cache` passes the cache by).

`--turbo` draws with Qwen-Image 2.1 Turbo (`qwen-image-2.1-turbo-Q8_0.gguf`)
through its own eight levels instead of forty. `--negative TEXT --cfg
SCALE` leans each step away from what the picture is not to be -- two
evaluations a step; at the default scale of one, none.

`--ref-image FILE` edits beside a picture -- up to four, in order -- as
stable-diffusion.cpp's Qwen-Image 2.1 edit does: the text encoder sees
each through Qwen3-VL's vision tower (`--mmproj`, by its published name
unless said) and the denoiser reads its latent beside the prompt. The
first sets the size unless `--size` does. For example:

```
model_runner image --prompt "make the apple green" --ref-image apple.png --out green.png
```

Where a device opens, the text encoder, the denoiser's products,
attention and feed-forward, and the VAE's convolutions run there.
Current image-generation speed is not qualified. Earlier image timings are preserved in
[the historical snapshot](PERFORMANCE_HISTORY.md#embedding).

`embed` prints what the model made of a text rather than what it would say
next: the hidden state after the final normalization, before the projection
that turns a state into a distribution over tokens. That projection is where
the resemblance between two texts is thrown away -- it keeps only how much
each token is favoured -- which is why the state is what an embedding is
pooled from.

```
model_runner embed MODEL --prompt "the text" --pooling mean
```

One component a line, so the usual tools can read it. `--pooling mean`
averages every position and `--pooling last` takes the final one; neither is
chosen on a model's behalf, because which is right depends on how the model
was trained. The vector is scaled to unit length unless `--no-normalize`,
since the usual thing to do with two of them is compare their directions and
that is a dot product only when both have length one.

A text longer than the model's context is refused, saying both counts;
`--truncate` cuts it to the context instead.

The prompt is read as written and no chat template is applied. A template
turns a text into a turn of a conversation, and an embedding is of the text.

The text is evaluated in batches, as a prompt is: a matrix product over
thirty-two vectors moves 1.87 times the elements a second that one at a time
does on this machine, and a text to be embedded is exactly that shape.
Pooling needs every position's state, so the batched path is asked for them
-- it is the only one that has them all in hand at once. `--batch-size` sets
how many go through the weights together and does not change the answer.

### Streams

| Content | Destination |
| --- | --- |
| generated model text | standard output, byte for byte |
| help, version | standard output |
| the `inspect` report, including `--metadata` and `--tensors` | standard output |
| diagnostics, warnings, progress, statistics | standard error |
| interactive prompts and command responses | standard error |

So `model_runner run m.gguf --prompt-file p.txt > answer.txt` puts only
generated text in `answer.txt` — no trailing newline, no styling, no prefix.

### Environment

| Variable | Meaning |
| --- | --- |
| `MODEL_RUNNER_LOCALE` | locale for program messages (`en`, `da`, `qps`) |
| `MODEL_RUNNER_COLOR` | `always` or `never` |
| `NO_COLOR` | suppresses automatic styling |
| `LC_ALL` | locale, when `MODEL_RUNNER_LOCALE` is unset |
| `LANG` | locale, when neither of the above is set |
| `MODEL_RUNNER_CONFIG` | path to the settings file, overriding its default location |
| `MODEL_RUNNER_INSTRUCTIONS` | `off` disables standing `AGENTS.md` instructions |
| `MODEL_RUNNER_REPORT_SETTINGS` | `1` emits native fitted settings frames for campaign capture |
| `HF_TOKEN` | Hugging Face token, sent when downloading a gated model |
| `HTTPS_PROXY`, `https_proxy`, `ALL_PROXY` | proxy a hub download goes through, the first set of the three |
| `NO_PROXY`, `no_proxy` | hosts a hub download reaches directly, not through the proxy |
| `XDG_CONFIG_HOME` | base for the settings file when `MODEL_RUNNER_CONFIG` is unset |
| `XDG_DATA_HOME` | base for the models and sessions directories |
| `XDG_CACHE_HOME` | base for the prompt cache |
| `HOME` | fallback base for the above when the `XDG_*` variables are unset; passed to a project's verification checks |
| `USERPROFILE` | Windows fallback for `HOME` when choosing configuration, data and cache directories |
| `PATH` | passed to a project's verification checks, with the variables its configuration's `execution.environment` names |

Prompts are never taken from the environment. This table is the whole of what
the program reads: the release checklist fails on a variable read but not
listed here, and on a read from anywhere but the two files that are allowed
one. Both locale variables were read and unlisted until that check was written.

### Exit statuses

`0` success · `2` usage error · `3` model format error · `4` unsupported model
feature · `5` resource failure · `6` input or output failure · `7` cancelled ·
`8` internal failure.

Every diagnostic carries a stable public code such as `MR-GGUF-0023`, derived
mechanically from the error enumeration so a code and its message cannot drift.
`docs/error-codes.md` marks each code raised or reserved: a published ordinal is
never reused, so codes that nothing raises stay listed, and saying which is which
keeps the reference from promising diagnostics the program cannot emit.

## Implemented

| Area | What exists |
| --- | --- |
| GGUF container | Full structural parse and validation of versions 2 and 3; typed metadata accessors separating missing / mistyped / out-of-range keys |
| Untrusted-input defence | Checked arithmetic on every offset, count and size; explicit limits on every count a file controls; UTF-8 validation; tensor range, alignment and non-overlap checks; trailing-data policy |
| Byte sources | Random-access interface; in-memory, file-backed, and POSIX read-only `mmap` with automatic / required / disabled policy and safe fallback |
| Tensors | Read-only views with one documented dimension convention, block-boundary checks, row dot product, row dequantization, row-range matrix-vector |
| Quantization | Reference decoders for F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q2_K, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ4_XS, IQ3_S, IQ2_XXS, IQ2_XS, IQ2_S, IQ3_XXS, IQ1_S, IQ1_M, TQ1_0, TQ2_0, Q1_0, Q2_0, MXFP4, NVFP4 — decoded one block at a time, never a second full copy of the model. IQ3_S reads a nine-bit index into a grid of 512 four-value entries with a sign byte and a four-bit sub-block scale, and IQ2_XXS -- about two bits an element -- reads an eight-bit index into a grid of 256 eight-value entries, a seven-bit index into a shared sign table, and a four-bit scale, all four of each packed into the second of a sub-block's two words. IQ2_XS and IQ2_S carry two sub-scales a byte and index grids of 512 and 1024 magnitude entries; IQ3_XXS reads two indices a lane into a 256-entry grid with packed scale and sign indices; IQ1_S and IQ1_M -- about a bit and a half -- index a grid of 2048 signed entries lifted an eighth-step, IQ1_M spreading its block scale four bits at a time across four scale words. These five decode on the processor, the reference backend and the device. TQ1_0 and TQ2_0 are the ternary pair TriLM and BitNet b1.58 conversions use -- every weight minus one, nought or one times the block's scale, five to a byte as a base-three number or four to a byte in two bits -- Q1_0 is one sign bit an element over blocks of 128, Q2_0 two bits over blocks of 64, and NVFP4 is MXFP4's values over runs of sixteen, each with an unsigned E4M3 scale of its own. Each is checked against ggml's own dequantizer on fixed blocks, and the four `llama-quantize` writes against a TinyLlama it quantized. On the device all twelve low-bit formats -- IQ3_S, IQ2_XXS and the IQ five, the ternary pair, Q1_0, Q2_0 and NVFP4 -- are decoded by a second compilation of the row product, `row_product.comp` built with `LOW_BITS`: a branch costs every format beside it registers whether it is taken or not, so the sixteen formats of the first compilation keep their words byte for byte and these twelve share their own pipelines. A generated token in one goes to a subgroup kernel of its own, `row_product_wave_low.comp` compiled once a format with its decode and codebook alone, the shape of the k-quant kernels at the device's native wave of sixty-four, eight rows a workgroup. Historical speed comparisons are archived in PERFORMANCE_HISTORY.md. A prompt in one goes through the matrix instruction like every other format: the tile's third compilation, `matrix_product.comp` built with `LOW_BITS`, decodes sixteen weights a lane into the half-precision tile by the format's own arithmetic. The two non-linear formats read a nibble as an index into a table of sixteen levels that belongs to the format rather than to any file, and MXFP4 reads one into eight magnitudes and their negatives with a scale that is a power of two: one byte of exponent where every other format here keeps a half. It is the one format the device shader has no branch for, so a model carrying it is refused on that backend while it loads, by name — what the program reads and what the shader reads are two lists, and the backend publishes the second. Q8_1 and Q8_K are refused: they are intermediates a reference implementation quantizes activations into, not formats weights are stored in |
| Kernels | Scalar reference add, multiply, scale, dot, RMS normalization, softmax, SiLU, rotary encoding, with `Wide_Real` accumulation for length-dependent reductions |
| Tokenizer | SentencePiece (`llama`) vocabulary: scores, token types, special tokens, byte fallback, greedy highest-score merge encoding. Byte-pair (`gpt2`) vocabulary: merge tables by rank, byte-level stand-in alphabet, and twenty-six cutting rules named by `tokenizer.ggml.pre` -- a hundred values of that key select between them, each rule the other runtime's list of expressions written out by hand as one scanner per expression and held to a reader in the suite that interprets the expressions themselves -- a vocabulary naming any other being refused by name rather than cut by the wrong one, and the four names that ask for another road refused on purpose. WordPiece (`bert`) vocabulary: the text folded before anything is looked up -- lower-cased, accents off, punctuation and ideographs cut loose -- and each word then spelled from the front with the longest piece the vocabulary carries, a piece that starts a word carrying a leading U+2581 and one that continues it written bare, and a word no run of pieces spells given back as one unknown rather than as the pieces that did match. All three with UTF-8-boundary-safe incremental decoding. A special-token identifier that is absent leaves the token unset; one that names no token refuses the model rather than being ignored |
| Chat templates | Bounded allowlisted engine: `for`, `if`/`elif`/`else`, `set`, comments, `+`-joined output, `==`/`!=`/`and`/`or`/`not` with parentheses, chained comparisons such as `a < b <= c`, and the standard Jinja `is` predicates for definition, value type, parity, divisibility, case, identity and comparison aliases -- as conditions and as values, so `(a == b) != (c == d)` compares two truths and `{{ x is defined }}` prints one -- `trim`, `length` and `tojson`, message indexing, front slicing such as `messages[1:]`, cuts at a position such as `content[:n]` and `content[n:]`, brackets round part of a sum, a choice written on one line -- `A if C else B`, inside an expression too -- `loop.first`/`last`/`index`/`index0`/`previtem`/`nextitem`, whitespace control -- `{%- -%}`, `{{- -}}`, `{%+`, `+%}`, and the line a block tag stands on, whose indentation and closing line break are the template's own shape rather than text the model was trained to see -- counting loops, namespaces, the string methods a reasoning model's template takes its own reply apart with -- `.strip`, `.split`, `.startswith`, `.endswith`, `.replace`, with names or expressions for their arguments -- together with the `first`, `last` and `min` filters, the list filters -- `join`, `map`, `select`/`reject`, `selectattr`/`rejectattr`, `sort`, `dictsort`, `indent`, `unique`, `list` -- on lists written out, on a schema's members and on the conversation itself, mapping literals with `.keys()`/`.values()`/`.get()`, `break` and `continue`, `loop.length`/`revindex`, `{% filter %}` blocks, `{% call %}` blocks with `caller()`, and the tool-calling branches: the tools a caller offered and the calls a turn asked for, each a value walked under any name, read member by member along a dotted path or by a quoted name, indexed by an expression, positions and members chained in any order, walked as a mapping with `\| items` or `.items()`, written with `tojson`. List literals, `[::-1]`, a loop over any value with loops nesting, a list passed to a macro, and macro arguments expanded from lists with `*` and mappings with `**`. A name assigned inside a loop's body or a macro's is the body's own and is put back when it ends, as the language scopes it; a namespace's field is what a loop or a macro assigns for after. A number is a number and not the text of one -- written, counted, measured, read out of a schema or assigned -- so `+` adds numbers and runs text together, `1 == '1'` is false, and a sum answers as a number whether it is assigned, compared or printed. `tools` is `none` where none were offered, as the reference passes it; a developer message, `--developer TEXT`, is the fifth role a turn may carry, written as gpt-oss and Qwen3.6 write one and refused where a template insists on roles it names; a user turn given as parts, `--prompt-parts JSON`, a picture and words, reaches the template as the list it is, which Gemma 3's and Qwen3.6's walk and a template that adds words to it refuses as jinja2 does. Enough that the templates current Llama-3, Gemma 3, Qwen3, Qwen3-MoE, Qwen3.5, Qwen3.6, Qwen3-Coder, MiniCPM and gpt-oss files ship with render, every one checked against Python's jinja2 conversation for conversation on tools, calls, answers and reasoning, byte for byte, by `tests cross`, which carries the jinja2 side as text so a checkout runs it. This build also carries formats of its own -- `--chat-template llama3`, `chatml`, `gemma`, `phi3`, `qwen3-coder` or `minicpm` -- `gemma` and the last two the models' own templates said in the subset, each the same bytes as its model for every conversation, tools, calls, answers and reasoning included, which the suite checks by rendering each beside the model's own file; a model whose template will not compile or will not render is stood in for by the carried format its template is written in. Arithmetic -- `*`, `//`, `%` and `/` binding before `+` and `-`, brackets binding tightest, in whole numbers where every term is one and in binary64 where any is not, written as Python writes it -- `~`, the text filters `lower`, `upper`, `capitalize`, `title`, `int`, `string`, `safe`, `default` and `replace` chained up to four deep, `strftime_now` with the directives a date in a system prompt is written with, `raise_exception` as the template's own refusal in its author's words, block sets that gather what is written into a name, and macros with defaults that may call themselves. Compiled and validated at load time; `include`, `import` and `extends` are rejected there, having nothing to name, while a value the engine cannot compute -- a function it does not carry, a message printed whole -- is refused if the render reaches it |
| Architecture profile | Native CPU `dflash` DSpark greedy drafting is opt-in, borrowing the Q4 target head and retaining Q4T target cache storage; see [the adapter](docs/inkling2-dspark-native.md). Experimental fixed-loop `inkling2_loop` executes natively with shared physical weights and independent logical cache state; CPU/Vulkan checkpoint comparisons pass for the documented F32 activation profile, a real native V3 task also passes normal verification, with the qualified profile and remaining extended measurements tracked in [Inkling verification](docs/inkling2-verification.md). Other profiles: `llama`, `granite`, `granitemoe`, `olmo2`, `qwen2`, `qwen3`, `qwen3moe`, `qwen3vl`, `qwen2vl`, `mellum`, `qwen35`, `qwen35moe`, `gpt-oss`, `gemma`, `gemma2`, `gemma3`, `gemma4`, `glm4`, `phi3`, `falcon`, `phi2`, `gpt2`, `starcoder2`, `stablelm`, `gptneox`, `internlm2`, `baichuan`, `mpt`, `chatglm`, `command-r`, `mamba`, `mamba2`, `rwkv6`, `jamba`, `lfm3`, `deepseek2`, `bert`, `nomic-bert` and `jina-bert-v2`, each read under its own metadata keys and refused by name otherwise, with the refusal naming every one this build reads. All are the same shape with a difference: granite llama's shape and rotation with four scalar multipliers the file carries -- the embedding lifted before the first layer, each sublayer's output damped before it joins the residual, the attention scores scaled in place of one over the root of the head width, and the final logits divided down -- each optional and the identity when absent, so a granite that states none is a plain llama, and each a plausible wrong answer rather than a refusal when missed, which is why all four are crossed against the independent implementation; the residual damping is the one the device sequence has no step for, so a granite layer runs on the host under the device backend as a hybrid's linear layers do; granitemoe that same granite with the feed-forward behind a router -- a softmax over the experts, the highest few renormalized over that few and multiplied by an `expert_weights_scale` the file carries, the one mechanism the mixture family here had not got -- read through the granite fixture built in its mixture shape; olmo2 the same shape rearranged -- no normalization on the way into a sublayer, and a normalization of what the sublayer produced instead, `post_attention_norm` over the attention output and `post_ffw_norm` over the feed-forward's, each added to the residual, which is gemma2's arrangement without the normalization on the way in, together with a root-mean-square normalization of the whole of the query projection and the whole of the key projection in place of the per-head one qwen3 does under the same names -- biasless, split rotary, and its whole-projection normalization the one the device sequence has no step for, so an olmo2 layer too runs on the host under the device backend; glm4 a composition of pieces already here -- gemma2's sandwich normalization, phi3's fused gate and up projection, a bias on each attention projection taken where the file holds it rather than required, a rotation over part of each head, and llama's interleaved pairing, with no softcap and no window -- the first to want a post-normalization with an interleaved partial rotation and a projection bias together on the device, so it too runs on the host under the device backend until those kernels are tried together; starcoder2 gpt2's block -- a centred normalization with a bias on the way into each sublayer, a bias on every projection, and a feed-forward with no gate, one projection up, a Gaussian unit, one down -- but rotating where gpt2 learns a row for the position and writing its queries, keys and values apart where gpt2 fuses them, its layer-norm epsilon read from the key the model states rather than the root-mean-square one, and the first to want a centred normalization with an active rotation and a projection bias together on the device, so it too runs on the host under the device backend; stablelm starcoder2's block but gated, a sigmoid-weighted feed-forward rather than a Gaussian one, its queries, keys and values biased where the file holds them, and turning only part of each head -- the leading `rope.dimension_count` -- where starcoder2 turns the whole, so the split pairing over the leading elements and the tail left alone are crossed for the first time; its larger sizes' centred normalization of each query and key head, a gain a head, is read and applied as command-r+'s is, and on the device it decodes through the row product's and the tile's low-bit compilations; gptneox gpt2's block -- centred normalization with a bias, queries, keys and values in one tensor with a bias, a bias out of attention, a feed-forward with no gate -- but rotating over the leading part of each head where gpt2 learns a row for the position, and running its two halves side by side where `use_parallel_residual` says so, each reading the layer's input under its own centred normalization and both adding to it, the two-norm parallel arrangement Pythia and GPT-NeoX-20B use that no other architecture here has; it too runs on the host under the device backend; internlm2 llama's block exactly, distinctive only in where its checkpoint keeps the attention projections -- fused in one `wqkv` laid out by grouped-query group, so many query heads then a key head then a value head per group -- which the converter splits into three permuted tensors as it writes the file, so what this reads already carries them apart and in the interleaved-rotation layout, nothing new to do at load, and being llama's kernel combination it runs on the device backend with no host fallback; baichuan that same llama block again, its 7B size fusing the three attention projections in one `W_pack` that the converter splits and permutes into the interleaved-rotation layout before this reads them, so it too carries them apart with nothing new at load and runs on the device backend without fallback -- its 13B size drops rotation for an alibi fall-off -- MPT's causal one -- that the runtime selects by its forty-layer depth alone, no key in the file saying which, so forty layers turns the rotation off and sets the bias of eight; the 13B runs on the host under the device backend as an alibi decoder, gated by the bias it carries so the rotating 7B beside it stays on the device, and is crossed against the independent implementation by a forty-layer fixture as the deep gemma3 is; mpt the departure from the family -- a pre-normalized decoder that does not rotate but is told where a token is by an alibi fall-off in the scores, one slope a head off the ladder jina-bert-v2 uses but under a causal mask, the first decoder here to attend that way; whose normalization centres but carries no shift, a centred normalization without a bias that nothing else here has; whose feed-forward has no gate and which carries no bias anywhere; and which may clamp its queries, keys and values to a magnitude the file states before it attends, which nothing else here does -- so it runs on the host under the device backend for that untried causal-alibi, centred, clamping combination; chatglm -- ChatGLM3 and GLM-4-9B, the older architecture of that name rather than the newer glm4 -- a composition of pieces already here: glm4's partial interleaved rotation and its fused gate-and-up feed-forward, with the queries, keys and values fused in one tensor and a bias on them carried where the file holds it, the fused twin of glm4's three separate biases, but parting from glm4 in its normalization -- a plain root-mean-square before each sublayer where glm4 sandwiches -- and multi-query with two key-and-value heads a layer; it too runs on the host under the device backend; command-r a composition no single architecture here had put together -- one normalization a block, centred and carrying no shift as mpt's does, with attention and the feed-forward both reading it and both adding to the residual as falcon's parallel block does, its final logits multiplied by a scale under the same key granite divides by, interleaved rotation over the whole of each head, a gated feed-forward with no biases, and its output tied to the token table; command-r+ adds a centred normalization of each query and key head before the rotation, a gain a head, read where the file holds it so both sizes load; it too runs on the host under the device backend; qwen2 a bias on each attention projection -- required, not optional -- and the split rotary pairing, element *i* against element *i + rotary/2* rather than against its neighbour; qwen3 no biases and a root-mean-square normalization of every query and key head before the rotation, equally required; qwen3moe that again with the feed-forward block behind a router; qwen3vl Qwen3-VL's language model, qwen3 dense under its own prefix -- what Qwen-Image 2.1 encodes a prompt with -- its multi-part rotation read as qwen35's is and the same as the plain one for text, its pictures read through Qwen3-VL's projector, the deepstack's rows added to the picture's positions after the first layers; qwen2vl Qwen2-VL's language model, qwen2's biased attention with the multi-part rotation dealt in runs -- time, row, column -- where qwen3vl interleaves them, its pictures read through `qwen2vl_merger`; mellum qwen3moe's block with a sliding window on three layers in four, read layer by layer as its file lists them, the windowed layers turned on a base of their own and left unstretched by the YaRN the full layers take, as gemma3's and OLMo-3's are; gpt-oss a mixture too, and the only architecture here with an attention sink -- one learned score a head that joins the softmax's denominator and takes none of the weight, which lets a head attend to nothing -- and with a gate that is not the sigmoid-weighted one: both projections held at a limit, the logistic at a steeper slope, and one added to the up projection, so it reaches the second vector and is not an activation followed by a multiply. It alternates a window as gemma2 does and turns the windowed layers on a base of their own as gemma3 does, and carries biases on its router, on each of an expert's three projections and on the way out of attention; gemma three differences of its own -- the normalization gain is the stored weight as it stands, which is already one plus what the architecture trained, because the converter adds the one as it writes the file, and a runtime that adds it again answers in fluent nonsense; the embedding row is multiplied by the square root of the embedding width before the first layer; and the feed-forward gate is a Gaussian error unit rather than a logistic one. Each of the three produces a plausible wrong answer rather than a refusal when it is missed, which is why each is crossed against the independent implementation rather than checked once; gemma2 those three and four more -- a normalization after each sublayer as well as before it, a bound on the attention scores and another on the logits, both applied as a scaled hyperbolic tangent, and a sliding window on every other layer rather than on all of them; gemma3 keeps the two normalizations, drops the two bounds, normalizes query and key heads as qwen3 does, windows five layers in six, and turns those five on a rotation base of their own; gemma4 is gemma3's block with its layers of two widths -- the windowed ones' heads half as wide as the global ones', each layer turning its own width, the global ones over a part of each head through the file's `rope_freqs` -- attention scores left unscaled, the values normalized a head as the queries and keys are, the residual multiplied at a layer's end by a scale the layer carries, and in its small sizes the last layers reading an earlier layer's cache and an embedding a layer of its own gated into each layer's output; it runs on the processor, its device paths not yet written; phi3 nothing at all in its arithmetic and everything in where its weights are -- the queries, keys and values in one tensor and the gate and up projection in another, taken out as views at a row offset rather than copied; falcon a different block rather than a different detail -- one normalization a block instead of two, with attention and the feed-forward both reading it and both adding to the same residual, a normalization that subtracts the mean and carries a bias rather than the root-mean-square form every other architecture here uses, and a feed-forward with no gate at all: one projection up, a Gaussian error unit, one projection down; and phi2 that arrangement with a bias on every projection instead of on none. Bert is the one that is not a decoder at all: it reads a whole text and produces a state for every position of it, attending both ways, normalizing after each residual add rather than before each sublayer, and learning a row for the token, a row for its position and a row for its segment where every other architecture here learns one. It carries no projection from a state to a token, so `run` is refused by name and `embed` is what it is for. nomic-bert is that arrangement with three parts swapped -- it rotates rather than learning a row for the position, writes its queries, keys and values fused, and gates its feed-forward -- and carries no bias on any projection at all -- the three attention biases in one vector as their matrices are in one tensor, one on the way out of attention, one on each side of the feed-forward, and one on the output projection itself, which is added to every logit. jina-bert-v2 is that arrangement again with the positions taken away entirely: it neither rotates nor learns a row for where a token is, and is told instead by a fall-off in the attention scores, one slope a head, taken off after the scale and before the softmax and unsigned -- a position is as far from what follows it as from what came before. Its ladder of slopes has two branches and the second is only reached where the head count is not a power of two, which twelve heads is. Its code variant carries six tensors a block the text one does not -- a centred normalization over the whole of the queries and another over the whole of the keys, each with its shift, and a second normalization of the attention sublayer over the joined residual with the layer's input added once more -- read where the file has them, all six or none; it gates its feed-forward by the Gaussian unit where nomic-bert gates by the sigmoid-weighted one, and shifts what it projects down and nothing else. Metadata validation in which an absent optional key takes a default and a present-but-unusable one refuses the model, derived-width divisibility, separate key and value head widths read from the file when it states them, rejection of rotary scaling this does not compute, tensor resolution and shape validation, tied-output aliasing. Sliding-window attention is read and applied: each position attends to the window's worth of positions ending at itself, and the layers that slide one hold the window and a batch rather than the whole context -- a gemma3 session at its own 32,768 costs 0.33 GB where it cost 1.83, on the processor and, since the session geometry stopped excluding it, on the device A mixture of experts is read and applied: a router a layer, the highest few experts run for each position and summed in proportion to their shares. Rotary scaling is read and applied for `none`, `linear` and `yarn`, together with a `rope_freqs.weight` table of per-dimension divisors when the file carries one. mamba is the pure state-space model, no attention and no feed-forward anywhere: every layer projects its input to an inner activation and a gate, runs a causal convolution over the activation, and drives a selective scan -- a recurrent state a channel decayed by a per-channel step and driven by the input, read back through a per-position matrix -- the whole block a linear layer that keeps a state a session as a hybrid's linear layers do, one Mamba's own selective recurrence rather than the gated delta rule, and every layer rather than three in four; its scan runs on the host under the device backend, and it is crossed against the independent implementation over every format and path, outside tolerance nought. mamba2 is Mamba's structured successor, the same pure state-space shape restructured: one projection in lays out the gate, the inner activation, B and C and a time step a head all at once; the causal convolution runs over the activation with B and C beside it, through the same sigmoid-weighted unit; the selective scan is a head rather than a channel, its decay one scalar a head where Mamba's is a channel by a state, its B and C shared across the heads of a group as grouped-query attention shares a key head; and the answer is gated by the front of the projection in and normalized in groups -- a root-mean-square over each group's channels, scaled by a stored gain -- before the projection out, where Mamba only gates. Its projected matrices repack like any other and its scan runs on the host under the device backend; crossed against the independent implementation over every format and path, outside tolerance nought. rwkv6 is a recurrent model of a different family again -- not a state-space scan but RWKV's own token-shift and linear attention. Each block is two sublayers, each with its own residual and no attention or feed-forward: a time mix and a channel mix, each shifting the position against the one before through an interpolation that is itself data-dependent -- computed from the position through a low-rank projection and a tanh, five streams at once. The time mix keeps a linear-attention state a head, a matrix the head's width square, decayed a channel by a data-dependent factor and driven by an outer product of key and value, read at the receptance with the position's own key-value lifted out of the decay by a learned bonus, then normalized a head and gated; the channel mix is a squared-ReLU gate. Every normalization centres and carries a shift, and the block's output is halved every so many layers to keep the residual bounded over the depth. Its wide matrices repack like any other and its recurrence runs on the host under the device backend; crossed against the independent implementation over every format and path, outside tolerance nought. jamba is the other hybrid, and a hybrid of a different kind: it interleaves Mamba mixer layers with attention ones -- a layer is a Mamba layer where the file states it nought key-value heads and an attention layer where it states the count they share -- and puts a mixture of experts on some layers and a dense feed-forward on others, a router where the file carries one and a plain gated block where it does not. Its Mamba layers are Mamba's scan with three normalizations plain Mamba has not -- of the time step and of the B and C the scan reads -- and then, unlike a pure state-space model, a feed-forward after; its attention does not rotate and carries no bias; its mixture softmaxes over every expert and keeps the highest few's shares without renormalizing them; and all its normalizations are root-mean-square with a gain and no shift. Reusing Mamba's scan, ordinary attention and the mixture path, it runs on the host under the device backend and is crossed against the independent implementation over every format and path, outside tolerance nought. lfm3 is LiquidAI's hybrid of short convolutions and attention: a layer stating nought key-value heads projects its input to B, C and x, convolves B times x causally over a few positions with a memory a session keeps, multiplies by C and projects out; the others attend with qwen3's head normalizations and a gate a head -- the logistic of a row of `attn_gate` against the layer's normalized input -- on each head's blend, every fourth of them windowed and turned on a base of its own over the whole head, left unstretched by the YaRN a file may state, while the full ones take the file's `rope_freqs` divisors, and every sublayer normalized after as gemma2's is; under the device backend every layer goes whole, the convolution and the gate a head included. qwen35 and qwen35moe are the hybrids: every fourth layer attends as qwen3 does with a gate beside each head, and the other three run a gated delta rule over a state a value head, after a short convolution -- a state rather than a cache, which a session keeps, snapshots, and holds a ring of for a draft's rewind, and which no context shift can take the middle out of. Their block past the stack drafts the next token, and `--draft-tokens` with no draft model drafts from it. deepseek2 is DeepSeek-V2/V3's multi-head latent attention: a position's query goes through a low-rank latent -- or straight where the file states none -- and its keys and values through one that carries a rotated slice shared across the heads, each latent normalized by root mean square; the up projection reconstructs a key and a value a head into the same cache a plain attention keeps, the rotation turning the trailing slice a head, and the first few layers run dense before the mixture ones begin. Crossed against the independent implementation over every format and path outside tolerance nought. On the device the latent is read absorbed by default -- the cache keeps the latent and its rotated slice rather than a key and a value a head, the values in the keys' rows -- and every layer runs whole there; YaRN's score scale is applied as the reference squares it, V3's routing in groups (`expert_group_count`, `expert_group_used_count`) keeps the best groups before choosing experts among them, and the shared experts run beside the routed ones |
| Execution | Embedding lookup, per-layer RMS norm, Q/K/V projection, rotary encoding, grouped-query causal attention without duplicating key or value heads, output projection, SiLU-gated feed-forward, residuals, raw logits |
| KV cache and session | Explicit cache sized with checked arithmetic, transactional commit, state machine, reset preserving allocations, committed-prefix reuse. Any number of sessions may be open on one prepared model at once: a model carries no per-evaluation state -- the activations, the normalized copies and the query and key rows all belong to the session -- so a second sequence costs its own cache and nothing else. Held by a test that interleaves two sessions a token at a time and checks each gets what it would have got alone; interleaved rather than sequential, because sequential sessions pass even on a model that does hold such state. Anything that would write to the model is refused while a session is open. `--prompt` asks for several: the model is read once and answers each in turn, which is what the sessions buy |
| Sampling | Documented pipeline: vocabulary check, non-finite rejection, masks, per-token biases, sequence penalty, repetition penalty, frequency and presence penalties, temperature, top-k, tail-free, locally typical, top-p, min-p, exclude-top-choices, renormalize, select. Everything that acts on a token acts on the greedy path too, which is where a caller can check by hand what a penalty did -- they did not, for as long as they have existed. Mirostat v2 replaces the truncation filters rather than joining them and is refused alongside any of them, because two answers to one question is not a configuration. Greedy is tie-broken to the lowest token and consumes no random state, and
both walks over the vocabulary -- the one looking for a logit that is not a
number and the one looking for the highest -- divide across whatever workers
the caller has, into blocks that do not move when the team does, so the token
is the same at every worker count and with none; xoshiro256++ seeded per session. `--logit-bias TOKEN=X` nudges a token; `--logprobs N` reports what the model made of each position, from a plain softmax over the raw logits with none of the sampling applied |
| Stops | End-of-sequence, stop tokens, stop strings matched across token boundaries with earliest-then-longest resolution and no leaked bytes |
| Generation | Prefill, decode loop, streaming to an output sink, eight completion reasons, statistics against a monotonic clock, bounded text retention |
| Pictures | PNG, JPEG and PPM inputs through `--mmproj` and `--prompt-parts`, interactive `/image`, pan-and-scan, Gemma 3 and Qwen vision projectors, and supported MiniCPM-V resamplers. Qwen3.5 video input accepts files through host FFmpeg libraries or ordered frame directories. Vision paths have independent numerical checks; performance comparisons are historical and archived |
| Conversation | Structured roles, bounded history, system-message replacement, turn rollback, and the tool calls a turn asked for held beside its text rather than inside it -- so the next prompt carries the call as that model's own template writes one, not as the model happened to spell it |
| CLI | `run`, `embed`, `inspect`, `help`, `version`; typed command parsing separated from execution; end-of-options; repeated, conflicting and out-of-range option detection. `--prompt` is repeatable: several prompts are several sequences from one loaded model, each with its own context and its own statistics, and standard error says which is which so that standard output stays nothing but generated text. It is refused together with a saved or restored context, which names one conversation. `--tools` offers the model tools and the calls it writes back are read out of the reply and reported; `--assistant` and `--tool-result` put the earlier turns back, in the order they are written, which is how one run closes the loop another opened |
| Interactive | Committed structured history, template rendering per turn, prefix verification against the cache, `/exit` `/reset` `/help` `/settings` `/stats` `/context` `/system [TEXT]` `/tools` `/tool TEXT` `/save PATH` `/load PATH` `/model [PATH]` `!COMMAND` `/tools [on|off]` `/undo` `/compact` `/plan [on|off]` `/jobs` `/paste` `/mcp` `!&COMMAND` `@FILE` and the user's own `/NAME` commands (`docs/settings-file.md`), `/system` removing the system message when no text follows it, `/tool` handing back what a tool answered as a turn of its own, `/save`/`/load` writing the conversation to a file and replacing it with one, and `/model` going on with another model -- the one named, or one chosen from the models on hand in the selector -- the old one let go, the new one's backend, context and drafting decided as a run's are, and the conversation carried into it, or back to the model before where the new one will not load. A conversation's model has the built-in tools -- reading, listing and searching files, writing and editing them, a shell, Python, SQL and the rest `run --agent` has -- where the context holds at least 4,096 tokens and no `--tools` of the caller's were named: each turn is the agent loop's, every call shown as it is made, one that only reads run unasked and any other asked in the selector first (this once, the tool for the session, no, or stop the turn); `/tools off` and `/tools on` take them away and give them back. `/plan` is plan mode: a call that would change something is refused unasked, and the model is asked to read and answer with a plan. `tools.allow` and `tools.deny` in the settings file name calls that run unasked and calls refused unasked (`shell(alr build*)`, `write_file(src/*)`). `mcp.NAME = COMMAND` in the settings file names a Model Context Protocol server whose tools the conversation offers as `mcp__NAME__TOOL`, each call asked about as a shell's is, and `/mcp` lists them. The model may hand a part of the work to a helper with `delegate`: a fresh context on a session of its own, opened for the turn, whose calls are shown and asked about as the conversation's are, and which reports back only its result. The model keeps a to-do list with the `todo` tool, shown after a turn that changed it. `hook.after-edit` and `hook.after-turn` in the settings file run a command of the user's after an edit or a turn, and `lsp` names a language server whose problems with a written or edited file are put after the tool's answer. Before a tool call writes or edits a file its old content is kept, a turn at a time, and `/undo` puts back what the last such turn changed -- again, the turn before it; what a shell command changed is not kept. `/compact` makes the oldest turns a summary when asked, the last two kept whole. `@PATH` in a message, with Tab completing the path, sends the file's text with it, up to 64 KiB, a binary file or a folder left as the words they are. A conversation follows the user's standing instructions: `AGENTS.md` in the settings folder and in the session's folder and every folder above it, the outermost first, up to 32 KiB, stand before its system message (and before `--system` or `/system`), and the session names the files it follows. Every conversation is kept as it goes -- a file of its own under the data home's `conversations` folder (`conversations-dir`, `MODEL_RUNNER_CONVERSATIONS`), the model it is spoken with noted beside it -- and `model_runner --continue` takes up the latest, `model_runner --resume` one chosen in the selector by when it was, its model and its first message; with no model named, the conversation's own runs. `!COMMAND` runs a command in the host's shell -- what it writes shown as it comes, a failing status said -- and the command with what it wrote, the first 16 KiB of it, goes before the next message, so the model can be asked about it. Enter sends; Shift-Enter, Alt-Enter or Ctrl-J breaks the line. Needs a terminal on both standard input and standard output, whether it is chosen because no prompt was given or asked for with `--interactive` |
| Localization | Every application-authored string through `messages`; 229 diagnostic codes each with a catalog entry; every catalog key has a reader and every key the code names has an entry, checked both ways; English, a complete Danish translation, and a generated pseudo-locale, with per-key inheritance for a locale that is not yet whole; locale precedence with an emergency path that cannot recurse |
| Cancellation | An interrupt requests a clean cancellation rather than killing the process; observed between parser sections, tensors, layers and tokens, so a cancelled run releases everything and commits no cache position. The parser, preparation, the single-token pass and the batched pass are each held by a test; generation's own two checks stop the work a batch or a token earlier than the pass below would, which no test of the outcome can distinguish |
| Presentation | `terminal_styles` in the presentation layer only; styling asks whether the stream a line is going to is a terminal, so redirecting one stream and not the other never puts escape sequences in the file — which it did, once the inspection report moved to standard output and the colour decision stayed on standard error; severity always carried by a word as well as a colour; `--color always` colours whatever the destination is, `auto` colours only a stream that is a terminal and honours `NO_COLOR`, and `never` colours nothing; generated text never styled |
| Backends | `cpu`: reusable Ada workers with bounded coordination, deterministic partitioning, failure propagation and cleanup; `--threads` selects the count. `reference`: serial independent evaluation for numerical checks. `device`: native Vulkan products and supported cooperative matrix kernels, with explicit capability and memory checks. Missing or unsupported devices are reported rather than silently selected. Current CPU timing evidence and historical GPU observations are linked under Speed |
| Tooling | `tests test`, `tests check`, `tests conformance`, `tests fuzz`, `tests speed`, `tests perplexity`, `tests dump-states`, `tests tokenizer-cross`, `tests probe`, `tests approve-probe`, `tests fake-mcp`, `tests fake-lsp`, `tests agent-eval`, `tests agent-trial`, `tests trajectories`, `tests knowledge-bench`, `tests quantize`, `tests imatrix`, `tests benchmark`, `tests external-model`, `tests fixture-likeness`, `tests slow`, `tests device-bench`, `tests device-tune`, `tests tokenize`, `tests cut`, `tests render`, `tests cross`, `tests records`, `tests see`, `tests image`, `tests whisper-convert`, `tests hear`, `tests speech-corpus`, `tests docs`, `tests shader`, `tests restamp`, `tests schema`, `tests session-command`, `tests fixtures`, `tests fixture-check`, `tests package`, `tests pristine` — all Ada, all in the tests crate, and the set is a registry the checklist holds the dispatch and this row against, because two hand-kept copies of it had already drifted apart. The approve and fake-server commands are deterministic helpers for terminal, MCP and LSP integration tests. `tests <command>` with no command lists them with what each takes. `tests restamp WHY GROUP...` records the fingerprints of the named groups in `docs/measured-figures.txt` that a change moved without moving what they measure, with WHY written above each; a moved group not named is left stale for the check to fail on, unless `--all` says the reason holds for every one. `tests check` is the gate: it runs the suite, the repository checks, the conformance comparison, the fixture check and a short fuzzing campaign, and fails when a test is written and registered by nothing or when the suite has shrunk. The fixture check moves every tensor of every architecture's fixture in turn and requires an answer to move with it -- a logit, or for the architecture that has no distribution to give, what the model made of every position: a tensor nothing reads makes every comparison over that fixture weaker than its count suggests, and one that was written twice made two correct readers disagree about every logit before anything here asked. Each architecture is built in every shape it can hold and five formats and read by four combinations of backend and evaluation path, which is what makes the question specific: a tensor only the batched path reads, or only the shader, is a different tensor from the one every path reads. A shape an architecture cannot hold is built anyway and required to refuse, because a skip nothing needs any more is a skip costing comparisons; and a reading an architecture has not got -- a model that attends both ways has no token at a time, and so no run on the backend that declines batching -- is counted rather than asked, because asking produced a refusal that read as a fault. It also reports what it moved quietly: a tensor whose logits answer by less than a comparison would call a disagreement is read, but a mistake of that size in it would pass the sweep unremarked, and that is the measure the sweep cannot take of itself. The public operations the program itself never calls are listed in `Library_Surface` with the reason for each, and the list is held in both directions: this is a library as well as a command, so the interface is wider than the command uses, and how much wider is a thing somebody chose rather than a thing that happened. The separate commands are for looking closer |
| Conformance | An independent reference transformer in the tests crate recomputes the forward pass in a different arithmetic, with its own float decoding, its own full key/value history and expanded rather than mapped attention heads. It implements both architectures, each with its own rotary pairing and its own attention bias, so the two agree by arriving at the same numbers rather than by sharing the code that produces them. The engine agrees to within 1.3e-6 absolute on the fixtures, against tolerances of 1e-4 absolute and 1e-3 relative, and `tests check` runs the comparison rather than leaving it to be remembered |

## Building and testing

Needs [Alire](https://alire.ada.dev) and a GNAT toolchain.

`model_runner` depends on sibling crates that are not in the Alire community
index. As the rest of this family does, `alire.toml` pins them **by path**, so
they have to sit beside this one:

```
Ada/
├── model_runner/       <- this crate
├── terminal_styles/    pinned here
├── messages/           pinned here
└── project_tools/      pinned by the tests crate
```

Those pins are transitive, and the closure is deeper than it looks: `messages`
pins `i18n`, and sub-crates inside `i18n` and `awklib` pin further crates
again. A bare clone of this repository alone will not build -- `alr` reports
that a pin path is not a valid directory and names the crate it wanted, one at
a time.

The reliable way to materialise the closure is the composite action this family
uses in CI, which walks the pins for you:

```yaml
- uses: bracke/project_tools/.github/actions/checkout-ada-siblings@main
  with:
    root: model_runner
```

By hand, clone each crate `alr` asks for into the same parent directory until
it stops asking, then:

```
cd model_runner
alr update                                 # regenerates config/ with the
                                           # dependency withs; a fresh clone
                                           # needs this before it will compile
alr build --release
cd tests && alr build && ./bin/tests test
```

I have not reduced that to a single verified command line for a reader
starting from nothing, and would rather say so than print one that does not
work. From a tree that already has the siblings, `tests pristine` is that
command: it clones what git carries beside them -- so every path pin resolves
without copying or linking -- resolves the pins, builds, and runs the suite
and the repository checks in the clone, in about twenty seconds. It removes
the clone when it passes and leaves it where it says when it does not.

That is the only arrangement in which the repository is what a reader gets,
and it is the arrangement in which the suite failed for forty consecutive
pushes while passing here. Run it before a release. It is not part of the
release checklist, because it clones from git and therefore sees only what is
committed -- a checklist run before the commit would be answering about the
previous one.

Two things are generated rather than committed, so a clone does not have them
until something makes them:

- **`config/`** holds the configuration project that Alire writes, and both
  project files import it. `alr build` creates it. Calling `gprbuild` directly
  in a fresh clone fails with `imported project file "config/..." not found`,
  which is what that means.
- **`tests/fixtures/tiny-model.gguf`** is written by `tests fixtures`, and by
  the suite itself: three tests read a model from that path and write it
  first, through one operation that also names it. This paragraph used to say
  the suite did not need it -- that it built the same model in memory -- and
  that was the belief behind forty consecutive red CI runs. The file is
  ignored by git, because a model file is not committed unless its licence
  plainly allows it; it was present on the machine where the suite was run
  and on no clean checkout, so the suite passed here and failed there with
  `inspect does not print the published line "Container"`.

Development is the default profile here and in every sibling crate, on
purpose: `-Og` with the full validity checks, one profile across every root so
they share object files. Release is for a release -- and for anything you
intend to measure, because the difference is not small: twelve tokens on a 1.1B
model take 2.2 seconds at `--release` and around 14 at the default.

```
alr build --release                        # optimized, what to ship and measure
alr build                                  # debug: -Og, all validity checks
cd tests && ./bin/tests test               # the whole suite
cd tests && ./bin/tests check              # the gate: the suite, repository
                                           # checks, conformance, a fuzz run
cd tests && ./bin/tests conformance        # engine vs independent reference
cd tests && ./bin/tests benchmark          # row kernels and parsing, synthetic
cd tests && ./bin/tests benchmark --wait 30 # the same, once the machine is quiet
cd tests && ./bin/tests docs               # regenerate docs/error-codes.md
cd tests && ./bin/tests shader ../src/shaders/row_product.comp out.spv \
                             [SOURCE.comp OUT.spv ...] [ROOT]
                                           # after recompiling a shader, and
                                           # naming every one of the thirty-two
                                           # compilations: the package is
                                           # written whole. route.comp and
                                           # mix.comp compile with -V as
                                           # norm, rotate and place do.
                                           # Five compile with
                                           # `glslangValidator -V`; the
                                           # matrix product needs
                                           # `--target-env vulkan1.3`,
                                           # because it is SPIR-V 1.6.
                                           # The matrix product is compiled
                                           # again with `-DMORE_FORMATS`,
                                           # the row product with
                                           # `-DSINGLE`, and attention twice
                                           # more with `--target-env
                                           # vulkan1.1 -DSUBGROUPS -DWIDE`
                                           # and with `--target-env
                                           # vulkan1.1 -DSUBGROUPS
                                           # -DQUERY_TILE`; the packed
                                           # attention and the packing
                                           # each once plain and once
                                           # with `--target-env vulkan1.1
                                           # -DSUBGROUPS`. The checks name
                                           # every compilation's flags.
                                           # `attention_matrix.comp` needs
                                           # `--target-env vulkan1.3` as
                                           # the matrix product does. A
                                           # constant is named for the
                                           # compiled file, so they arrive
                                           # as Matrix_Product and
                                           # Matrix_Extra, Row_Product and
                                           # Row_Single, Attention,
                                           # Attention_Subgroups,
                                           # Attention_Tiled and
                                           # Attention_Matrix.
cd tests && ./bin/tests fuzz --seed 1 --cases 2000
cd tests && ./bin/tests fixtures           # write tests/fixtures/tiny-model.gguf
cd tests && ./bin/tests package .. .       # write model_runner-<version>.tar
cd tests && ./bin/tests external-model --model /path/to/your.gguf [--expect FILE]
cd tests && ./bin/tests fixture-likeness --model /path/to/your.gguf [--names]
cd tests && ./bin/tests render --model /path/to/your.gguf --system S --prompt P
                                           # the model's own chat template
cd tests && ./bin/tests cut --pre tekken --texts hex-lines.txt
                                           # where a cutting rule cuts each
                                           # line, a piece length each; a
                                           # harness around llama.cpp's own
                                           # splitter prints the same
cd tests && ./bin/tests slow                # where the suite's time goes
cd tests && ./bin/tests device-bench        # what an attention call costs,
                                           # and what one vector costs a
                                           # row product in each format
cd tests && ./bin/tests device-tune --write # correctness-gated launch tuning;
                                           # replay with --check PROFILE
```

`fixture-likeness` asks the question the rest of the suite cannot. Everything
else compares two implementations that were written together, against a
fixture written to suit them; where the fixture and the engine share a wrong
idea about what a model carries, both agree and nothing is said. This folds
layer indices together and compares a published file's tensor list against the
fixture this repository builds for its architecture, reporting what each side
has that the other does not. Pointed at a published `gpt2` the first time it
ran, it named `blk.*.ffn_norm.bias` -- a tensor every gpt2 carries, that the
fixture did not write and the engine did not read.

The suite takes eight seconds, and took twenty-eight minutes until one test
was moved out of it. That test ran the whole conformance sweep -- the same
`Conformance.Run` the gate runs as a stage of its own -- so the gate did it
twice, 948 s inside the suite and 650 s again beside it. Ninety-nine and a
half per cent of the suite was one routine.

It read "a second and a half" here for a long time after that had stopped
being true, and the wrong figure cost a day: the gate timed every stage except
the suite, AUnit prints nothing until it has finished, and a timeout set from
a stale number looks exactly like a hang. The gate says `took: suite` now, and
`tests slow` says where a suite's time goes.

Compiling a template took half a minute until it stopped allocating
twenty-six megabytes: an instruction carried its operand and its condition
inline, and the program is four thousand of them.

Every test is deterministic, offline, and needs no downloaded model. The
checklist holds the second of those: nothing in the repository may exceed a
megabyte, which is what a committed model would. What the suite covers:

- **GGUF** — truncation at *every* byte offset of a valid file, corrupt
  magic, unsupported versions, excessive counts, duplicate metadata keys,
  duplicate tensor names, invalid UTF-8, quantization block misalignment,
  out-of-bounds tensor ranges, trailing-data policy, typed accessors, a
  450-case mutation corpus that must produce only controlled outcomes, the
  fused dot product agreeing with the reference decoder for every format, the
  number of vectors in one kernel call changing none of them, and nothing a
  model file says -- metadata value, metadata key or tensor name -- reaching
  the terminal unescaped, five hundred generated containers read back through
  the accessors the engine uses and compared with what was written -- strings,
  signed and unsigned integers of two widths, booleans, array elements and the
  tensor descriptors -- so a disagreement between the writer and the reader
  cannot look like agreement, the UTF-8 validator refusing overlong encodings,
  surrogates and code points past U+10FFFF while accepting each length at its
  boundaries, a hostile vocabulary, whose special-token
  identifiers name tokens that do not exist, being unable to make the
  tokenizer reach outside itself, and the structural refusals -- an unnamed
  metadata key or tensor, an alignment that is not a power of two, a string
  past the length limit -- each reporting the code that names it, and the
  tokenizer's own refusals doing the same: no tokenizer model, a model this
  engine does not implement, no token list, input that is not UTF-8, and a
  buffer too small for the tokens. The architecture profile likewise: a file
  naming no architecture or another one, widths that do not divide, an odd
  rotary width, a rotary scaling this does not compute, an expert count with
  no used count and one asking for more experts than the model has, a shared
  expert, a sliding window of no positions, and an embedding tensor of the
  wrong shape. A prompt
  file that is absent, a directory, past the size limit or not UTF-8 likewise,
  with a sound one read. A file that ends inside a field is truncated, a rank
  past the limit is an invalid rank, and an extent of zero is an invalid
  dimension -- three answers a reader could give as one. What a caller can be
  wrong about is checked the same way: a request for no tokens or no batch, a
  prompt longer than the context, a message with no content, and generating
  from a model that was never prepared, a conversation past its bound, a model
  released while a session still holds it, and a sampler with every token
  forbidden. Refusals that cannot be built into a
  container are edited into one: an undefined value, array-element or tensor
  type, an array of arrays, a tensor off its alignment, and two tensors over
  the same bytes. The builder records where it wrote each field and the test
  asks by name, so no test carries a table of byte offsets. A tensor view
  refuses each impossible shape by name too: no rows or columns, a quantized
  row that is not whole blocks, a format this build cannot decode, a shape
  past its buffer, and an operand that does not match.
- **Inference** — every piece the streaming decoder hands out being whole
  UTF-8, checked over a vocabulary built so that a character spans three
  tokens, which the fixture model's all-ASCII vocabulary cannot express;
  preparation, finite logits, run-to-run determinism,
  cancellation leaving the cache uncommitted, a batch refused at the same
  context boundary a single token is -- filling it exactly accepted, one past
  refused, and a refused batch leaving the cache where it was; a cancellation
  asked for while
  the model is still loading stopping the load, context exhaustion and reset,
  out-of-range token rejection, tokenizer round trip, an interrupt reaching the
  cancellation token through a real signal, agreement with the independent
  reference implementation, and a batch producing the same bits as the same
  tokens evaluated one at a time, down to the cache it leaves behind.
- **Sampling, stops, kernels and templates** — a fixed seed producing a token
  sequence written down rather than only compared with itself, so the claim
  that the generator produces the same stream on every host is checked on
  every host the suite runs on; the stop-string matcher
  compared against the rule written out the slow way, over two thousand
  generated sets and buffers, so a disagreement is a fault in one of them
  rather than a restatement of the other; two thousand generated
  configurations, every setting varied together over logits that include what
  a broken model produces, each returning a token inside the vocabulary or
  saying it cannot; the kernels answering
  degenerate input rather than trapping on it: a layer of zeros normalized
  without dividing by its own scale, a length mismatch leaving the target
  zeroed, and softmax refusing to turn values that are not finite into a
  distribution; greedy maximum and tie-breaking, greedy
  entropy independence, fixed-seed reproducibility, top-k, min-p, repetition
  penalty, NaN and infinity rejection, stop-string earliest-then-longest
  matching, stop bounds, exact template rendering, branches and whitespace
  control, rejection of unsupported constructs, and automatic seeding varying
  between runs without falling back to the fixed seed.
- **CLI and generation** — four thousand generated command lines, built from
  options in impossible orders, values where flags go, empty arguments, text
  that is not UTF-8 and numbers too long to be numbers, each answered with a
  definite outcome rather than raised on; interactive mode, which needs a
  terminal at both ends and so was driven by nothing at all until its loop was
  made to read redirected input -- the loop running a conversation to its end,
  a turn accumulating across lines and submitting on a blank one, a turn past
  its bound refused whole rather than truncated, a slash on a later line being
  the text it looks like, every command word read as itself, and the
  conversation keeping its shape under the edits the loop makes: a system
  message landing first, replacing rather than accumulating, clearing without
  disturbing the rest, and a cancelled turn dropped from the end without going
  past the beginning; every backend this build has named on the command line
  and one it does not have refused; command parsing, fifteen distinct usage
  errors,
  end-of-options, pre-parse scans, reproducible generation, stop strings across
  token boundaries with no leak, stop tokens producing no text, closed output
  as a normal end, context budget checked before evaluation, retained text
  matching what was streamed, the end token ending a run without any of it
  reaching the output, the reference comparison accepting a match while
  rejecting a mismatch and a recording with no stated origin, a prompt read
  from standard input bounded and refused plainly rather than truncated, the
  diagnostics never quoting the prompt or the system message, and a seed
  covering the whole unsigned range in parsing, storage and display.
- **Catalog** — every diagnostic code resolves, every enumeration-derived
  key resolves, every interface key exists, protocol tokens untranslated,
  emergency path, locale fallback, escaped parameters, the pseudo-locale
  differing everywhere while keeping every placeholder, a partial locale
  translating and inheriting per key, the shipped Danish held to being whole,
  and POSIX host-locale normalization.
- **Chat template** — two thousand generated templates, mostly balanced so
  that rendering rather than compiling is what is examined, one in four broken
  on purpose, rendered into buffers small enough to overrun: none raises, and
  every render that fails reports writing nothing, which is what stops a
  caller emitting the previous turn's bytes; an ordinary template compiling
  and rendering, every
  documented compile-time refusal reported by its own code rather than merely
  as an error, and all five bounds driven to their edge and one past it: size,
  instruction count, nesting depth, output size and iterations.
- **Arithmetic, memory, clocks, text and packaging** — numbers rendering the
  way a reader sees them, with fractions keeping their leading zeros and a
  value too large for a fixed-point image saying so rather than raising inside
  a diagnostic; the release archive carrying
  every file a distribution needs under its versioned prefix, with the program
  executable and the documents not, and refusing to write anything at all when
  one input is missing; the byte readers decoding little-endian
  from any offset and refusing a field that runs past the end, returning zero
  when they do; checked arithmetic carrying overflow
  rather than raising or wrapping, invalidity absorbing through further
  operations, alignment refusing a non-power of two, narrowing to Natural
  reporting range loss and zeroing its result; an allocation past the budget
  refused
  before it is attempted, mapped bytes not counted as allocated, a plan that
  cannot be represented refused rather than wrapped, a clock that goes
  backwards yielding no elapsed time, and a file mapping reading back what is
  in it while refusing a read past the end.
- **CPU backend** — the partition covers every row exactly once for every
  worker count, a parallel product equals the serial one **exactly**, more
  workers than rows still produces a complete result, a closed pool rejects
  work, one pool serves many jobs, a pool that is never used still terminates,
  capabilities advertise only what is implemented.

### Locales

`en` is complete, and so is `da`, every key of it; a locale that is not yet
whole falls back to English per key, so nothing reaches the emergency form.
`qps` is a pseudo-locale
generated from the English entries: every letter outside a `{placeholder}` or a
protocol token is accented and the message is bracketed, so an untranslated
string, a lost placeholder or a truncated line is visible at a glance.

```
$ model_runner --locale da run x.gguf --bogus
model_runner: fejl: MR-CLI-0003: ukendt tilvalg: --bogus
kør 'model_runner help' for at se brugen

$ model_runner --locale qps run x.gguf --bogus
⟦model_runner: ⟦éŕŕóŕ⟧: MR-CLI-0003: ⟦úñkñówñ ópŧíóñ: --bogus⟧⟧
⟦⟦ŕúñ 'model_runner héĺp' fóŕ úßágé⟧⟧
```

Two lines, not one: the diagnostic and the hint that follows it. Both are
translated, and the second is the one that shows a locale is complete enough
to be useful rather than merely present -- a run that told a Danish reader
what went wrong and then advised them in English would be the interesting
failure, and would not have been visible here while the example showed only
the first line.

### Fuzzing

`tests fuzz` runs two campaigns: one over model files, one over the text a
caller supplies. Both are seeded, so a failure replays exactly.

#### Text

The second is `Text_Fuzzing`, and it exists because everything fuzzed before
it was a container. A prompt file, standard input and a command-line value are
untrusted too, and they reach `Model_Runner.Tokenizer.Encode` whole. A case
fails when the call raises, when it reports a code the interface does not
document, when it says it succeeded and hands back a token the vocabulary does
not hold, or when it takes longer than the limit for text of its size — which
is 50 ms plus 20 µs a character, roughly a hundred times what encoding
actually costs.

The clock is there because the defect that prompted this could not have been
found any other way. `Encode` looks for a control token at every position
whose byte some piece of the vocabulary begins with, and the scan reached the
longest token the format allows — 1024 bytes — at every one of them. Sixty thousand brackets, well inside the
documented input limit, took **25.5 seconds** where the same length of
ordinary text took a fortieth of a second. Nothing was wrong with the answer.
The scan is now bounded by the longest marker the vocabulary actually holds,
which for the fixture is four bytes and for a real vocabulary about
seventeen; a position whose byte begins no piece costs one array read and no
lookup at all.

`tests benchmark` times both cases now: **0.0026 s** for sixty thousand
ordinary characters and **0.0086 s** for sixty thousand brackets (the
afternoon of 2026-10-30, at a load of 5.29 falling to 2.17), so the hostile
text costs about three times more rather than six hundred times more. The
vocabulary's pieces are a flat table now, a pool of text and one array of
slots, where they were a hashed map with an allocation a key, and the
ordinary text, a lookup a piece, is where that shows. The pair before this
one read 0.0071 and 0.0123, at the end of a run that had taken the load
from 0.69 to 3.91 and the part to 91 degrees; the one before that 0.0139 and 0.0156 at
a load of 1.11, on a byte-pair cutter that has since been rewritten as
passes over code points and a marker scan that has not changed; the
ordinary text is the SentencePiece road and half the time it was, which
a hot part and a second-of-three-rounds median do not explain, so the
figure is taken again at the next sitting before anything is concluded
from it. Those are lower than the 0.039 and 0.045 this used to
quote, and the reason is what they measure: the older pair came from timing
a whole `model_runner run` in the shell -- parsing the model, loading the
vocabulary, encoding, and refusing the prompt for length -- while these are
the encode. Taken that way again on 2026-10-07, once the length bound on a
whole text was gone, they read 0.123 and 0.131 s: the prompt is encoded
whole now and refused for the context, and the process around it has grown
(the same sitting read 0.118 and 0.122 before the change). On the
afternoon of 2026-10-30 they read 0.087 s both, with `--backend cpu` named
-- `run` takes the device unasked now, and opening it put them at 0.144 and
0.186 -- the parse and the vocabulary's tables a fraction of what they
were. The 25.5 s is history and needs the commit before the bound; it
is quoted as the reason the bound exists rather than as something to
reproduce.

The longest cases are drawn from an alphabet where one character in two is a
bracket, because a cost paid per bracket is invisible in text where one
character in twenty is one, and drawing that shape by chance would need a
campaign far longer than the release gate can afford. Against the unbounded
scan the gate reports forty slow cases and a worst of 7054 ms; against the
bounded one, none and 16 ms.

#### Model files

`tests fuzz` mutates the synthetic container — truncation at an arbitrary
offset, single-bit flips, 64-bit and 32-bit field overwrites, and byte-run
splices — and feeds it to the whole load path: the parser, the tokenizer, the
chat-template compiler and model preparation. Only four outcomes are accepted:
loaded, structurally rejected, rejected against a resource limit, or cancelled.
Every accepted container is also rendered as `inspect` would render it, and a
control character surviving that is counted as an invalid acceptance: a file
that could steer a terminal has been accepted into a state it should not have
reached. One of the mutations writes control bytes deliberately, because a bit
flip reaches one only by chance.

Each campaign also reports how far its files got: of two thousand mutated
files, about twelve hundred prepare a model and nearly as many run a forward
pass. A campaign where none reached the engine fails, because clean totals
from files that all stopped at the parser would say nothing about everything
past it.

A campaign also fails on an internal invariant violation. That code means the
program found a state it believes impossible, and a file deciding when that
happens is a fault however it arrives — but it arrives as a refusal, so a
campaign counting refusals will not notice. Twenty-six cases in two thousand
were doing exactly that.

An escaped exception or an invalid container accepted into a usable state is a
failure. Each case is derived from the seed and the case number alone, so a
failure replays exactly.

### Conformance

`tests conformance` computes the same logits twice, by different routes, and
compares them. `Reference_Transformer` in the tests crate is written from the
architecture description and shares no arithmetic with the engine: it decodes
binary32 from the file bytes by reconstructing the value from its fields rather
than reinterpreting the host representation, computes in `Long_Float`
throughout, keeps the whole key and value history instead of a
reserved-and-committed cache, and expands key and value heads instead of
mapping query heads onto them. A mistake in cache indexing or head grouping
therefore cannot be common to both.

```
conformance: sequences 227688, logits compared 6056520,
             worst absolute 1.73819554385446E-04,
             worst relative 4.14812777523767E-01,
             rounded logits compared 510552,
             rounded worst absolute 3.16040618944414E-01,
             rounded worst relative 1.99884800440839E+00,
             cached logits compared 236848,
             cached worst absolute 2.65511191236011E-02,
             cached worst relative 1.98273081491582E+00,
             tiled logits compared 624536,
             tiled worst absolute 9.81579549905323E-02,
             tiled worst relative 1.99050021763666E+00,
             quantized logits compared 2160,
             quantized worst absolute 2.18175093729983E-01,
             quantized worst relative 1.92312577295959E+00,
             byte logits compared 423320,
             byte worst absolute 3.26659620511126E-01,
             byte worst relative 1.99611782818568E+00,
             nibble logits compared 238680,
             nibble worst absolute 2.90292333819480E-02,
             nibble worst relative 1.22329356129550E-02,
             mixed logits compared 47232,
             mixed worst absolute 3.03050851817588E-05,
             mixed worst relative 2.41367419233350E-02,
             outside tolerance 0, unlearned 0, refused 0,
             not applicable 11423, wanted 239111
```

The last three are the count's own accounting: what the loops asked for,
and how much of it a bidirectional architecture -- which has no token at a
time -- declined rather than ran. The sequences and the declined together
have to make the wanted figure, and for a week they did not: the
cache-precision arm had grown from two storages to four with the formula
still counting two, so the sweep failed its own count while every
comparison in it agreed, and nothing it printed said so. The arm is tallied
where it runs now, as the device pass is, and the line prints the three
numbers the verdict turns on.

Eight buckets, because eight things are being compared and mixing them
would let the loosest hide the tightest. The first is the exact path and answers to
1.0E-3 relative and 1.0E-4 absolute; the rounded, cached and byte ones are
`--repack bf16`, an f16 context and a q8 context, each with a measured pair
of its own; the tiled one is the device over a batch long enough for its
tile kernels -- forty-one positions in one batch and in chunks of seventeen
across a seam, on every architecture, on the mixture shape of every
architecture that holds one, and, with both packed caches, on a fixture of
two layers whose block is padded for the unpacking -- held to the
f16 context's pair, since the tile's operand is the same rounding, and
measured at a fifth of it; it is the bucket three device bugs in a day were
outside of, on a path no sequence of eight tokens reaches, and its count is
what says the tile was under the sweep at all; the nibble one is a q4 context held not to the exact reference
but to the reference rounding its own keys and values the same way, since on
these fixtures' rows of four elements sixteen levels move a logit by whole
units -- 4.14 against the exact reference -- which measures the rounding
and says nothing about the cache; the mixed one is the two pairings of
byte keys with nibble values and the other way round, held the same way; the quantized one is `--arith int8`, the arithmetic a run uses by
default, held to 5.0E-2 and 5.0E-1. A count of zero in any of them would say
the sweep ran none of that kind -- which is what a mode that quietly fell
back to another path would look like, and is the reason the counts are
published rather than only the worst differences.

The run above crossed 32 architectures, in 28 formats and 6 shapes,
of which 7795 ran on a device -- which is the same claim the paragraph below makes in
words, and is checked against the run rather than kept by hand.

Thirty-two architectures -- `llama`, `qwen2`, `qwen3`, `gemma`, `gemma2`, `gemma3`, `phi3`, `falcon`, `phi2`,
`gpt2`, `bert`, `nomic-bert`, `jina-bert-v2`, `qwen35`, `granite`, `olmo2`, `glm4`, `starcoder2`, `stablelm`, `gptneox`, `internlm2`, `baichuan`, `mpt`, `chatglm`, `command-r`, `mamba`, `mamba2`, `rwkv6`, `jamba`, `deepseek2`, `lfm3` and `qwen2vl` -- each in those of the six shapes a supported model comes in: dense, sliding-window, a mixture of
experts, a stretched rotation, heads wider than the embedding implies with
keys and values different widths again, and a window and a stretch at once -- the shape a Gemma 3 of the 4B and up comes in, which stretches the rotation for the layers that see everything and turns its windowed layers as trained, and which the sweep did not have until a published 4B showed the engine stretching every layer. Twenty-nine of the thirty-two are compared on the
last position's logits and in every shape they can hold; the three that
produce states rather than a distribution are compared on
what the model made of every position, which is the only answer they have and a
stronger one -- a logit is the last state through one more matrix, and these
are every state before that matrix. `bert` holds two of the six shapes: a
mixture wants a gate it has not got, a stretched rotation wants a rotation it
has not got, and a window is a bound on how far back a position may look,
which a model that looks both ways has not got. `nomic-bert` rotates and
gates, so it holds all but the two that window; `jina-bert-v2` gates but rotates
nothing at all, so it holds all but the window, the stretch and the two at once. `qwen35` holds all but
the widths apart: the gate beside each of its attention heads has the head's
width and scales the head's blend, so a value width that is not the head size
is a model the architecture does not define, and the engine refuses it by name. They answer fewer of the
sweep's asks for the same reason -- there is no evaluating a position of one
before the text it reads exists, so a token at a time and a text in pieces are
both refused -- and the ones they decline are counted rather than quietly
missing. The processor and the binary64 backends, every evaluation path -- a token at a
time, a whole prompt in one pass, and a prompt handed over in several --
serial and across a worker pool, every repacking mode -- the panel layout
among them, so the kernels that read it are crossed with every architecture
and shape the sweep has -- and every one of the twenty-eight weight formats the
engine decodes: binary32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q2_K,
Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ4_XS, IQ3_S, IQ2_XXS, IQ2_XS, IQ2_S,
IQ3_XXS, IQ1_S, IQ1_M, TQ1_0, TQ2_0, Q1_0, Q2_0, MXFP4 and NVFP4. The fixture writes each of
them and the reference reads each of them, both worked out from the layouts
rather than by calling the engine, so a packing mistake cannot be common to
the two sides. Tolerance is 1e-3 relative with a 1e-4 absolute floor, and nothing is
outside it -- which this run first was not: Mamba's batch on the device, at
the 256-element formats' widths, answered as much as nine units away, its
scan's answer past half precision's range reaching the tile kernel's
half-precision operand; Mamba's projection back now reads it in binary32.

The device backend is compared separately rather than crossed with the rest,
and it is compared in every one of the twenty-eight formats: the shader has a
branch for each, so each is a transcription of a bit layout that could be
wrong on its own.
That is what this crossing is for. A shift by the wrong amount, a sub-block
scale read from the wrong byte or a level table off by one produces an answer
that is merely wrong, and nothing downstream can tell a slightly wrong weight
from a right one. It runs each of the thirty-two architectures in each of the
twenty-eight formats, through both evaluation paths, against the same independent
implementation; on a machine with no device it runs nothing and says so by
the count. Its arithmetic is
where the worst relative figure above comes from -- the shader accumulates a
row in binary32 where the processor's kernels accumulate in binary64 and
round once -- and it is a relative figure on a logit near zero.

The reference runs once for each fixture and sequence rather than once for
each comparison. It reads the file and the tokens and nothing else -- it does
not know which backend it is being compared against, and cannot, because it
has none -- so the eight comparisons that differ only in backend, repacking,
batching or pooling all check against one answer. That is 780 forward passes
where there were 6435, and it took the sweep from nine minutes to two and a
half without dropping a comparison: every figure above is what the eight-fold
version reported, to the last digit.

Two combinations are left out of that sweep, and the reason for both is a
measurement. Repacking to brain floats halves the mantissa, and both a sliding
window and a mixture sharpen what that perturbation reaches: a window makes the
attention softmax sharper, so a difference full attention would average away
moves a logit instead, and a mixture puts a softmax on the router, where the
same difference moves the shares the experts are summed with and, where two
experts score nearly the same, moves which of them runs at all. Against the
reference, worst absolute over this sweep:

| model | `--repack bf16` |
|---|---|
| dense, no window | 0.137 |
| window 6 | 0.137 |
| window 5 | 0.517 |
| window 4 | 0.517 |
| window 3 | 1.677 |
| experts, four of four used | 0.330 |
| experts, two of four used | 0.509 |
| yarn, with a divisor table | 0.325 |
| key heads 2x, value heads 3x | 0.707 |

against a lossy tolerance of 0.3. The two expert rows are what separate the
mixture's two causes: running every expert leaves no choice to flip, so 0.330
is what the shares alone cost, and the rest of the way to 0.509 is the route
changing. The exact repacking modes agree everywhere in that table -- 2.2e-05
at a window of three and on the mixture, against 3.5e-06 dense -- so none of
this says the window or the routing is wrong, and all of it says what
`--repack bf16` costs on those models. Comparing them in the sweep would mean
asserting a tolerance nobody has grounds for. Five of the six shapes sit outside that
tolerance, which is worth saying plainly rather than burying in a table:
**0.137 is what `--repack bf16` costs a dense model with full attention and
heads the width its embedding implies, and it does not carry over to a model
that does anything else**. The last row needs no theory -- wider heads mean
more terms in every dot product to accumulate eight mantissa bits of error
over. Use `--repack
f32`, which is exact and costs memory instead.

One thing to know before taking any of these figures again: `tests speed`
and the `run` command do not count a prompt's tokens the same way. The
checked-in long prompt is 110 tokens as the tool counts it and 130 as the
command reports it, because the command counts what a chat run adds and the
tool counts what the figure describes. Every prompt length quoted here is the
tool's count.

The cached figures are explicitly `--kv-cache f16`, which stores what a
session has committed as binary16 rather than binary32. It was the default
from 2026-10-03 through 2026-11-19; commands reproducing these figures should
keep naming it. The `tests speed` benchmark retains f16 when no cache is named
so historical recipes continue to reproduce these tables; `run` and the other
model commands default to q4t. `--kv-cache f32` selects exact storage. F16 takes half the
memory for the context,
and **0.0327** worst absolute on these fixtures against 2.2e-05 for the exact
cache. That is measured with and without a sliding window; without one it is
0.0218, and a window raises it for the reason a window raises everything
lossy here -- it sharpens the softmax, so a rounded value moves a logit
further. That is three orders of magnitude worse than exact and six times better
than rounding the weights, which is what one would expect from where each
rounding happens -- a weight is rounded once and read into every product, a
key is rounded once and read back by every later position. Both evaluation
paths are compared, because the two storages are two procedures.

`--kv-cache q8` stores it in one byte an element instead, with a scale for
each row -- a row being one position's keys, or its values, for one layer,
which is the unit the evaluator already writes and reads whole. A quarter of
the memory the exact cache takes, and **0.303** worst absolute on these
fixtures, which is thirty times what the halved cache costs and four
thousand times the exact one. The bound this sweep holds it to is 0.4,
measured over every architecture, shape and format it crosses and rounded up.
It is offered for the case the halved cache does not fit rather than as a
default: nothing chooses it unless asked.

`--kv-cache f8_e4m3` is the other one-byte storage: each element is an OCP
E4M3FN floating-point value, with one interpretation everywhere rather than
the row-dependent scale of q8. It keeps signed zero, rounds ties to even,
saturates overflow at 448, and preserves the format's NaN for validation.
The host and device attention paths read it in batches and one token at a
time, including snapshots, context shifts, packed blocks and paged caches.
On a device, rows are converted to E4M3 by the placing shader, read directly
by token and packed-attention shaders, and widened to binary16 when matrix
attention uses its cache copy. The format has its own packed-cache code, so
no signed-q8 kernel is silently given FP8 bytes. The public identifier uses
the GGML `f8_e4m3` storage spelling.

`run --kv-cache fit` asks for that choice to be made for you: the halved
cache where the context fits on the device beside a dense model's
matrices, the byte one where only that does, and the halved one with the
model split as before where neither does. Without a named context the
longer one the device holds is taken -- the byte cache where it keeps a
longer context whole than the halved one would. Steelman-14B with
`--context-size 32768` stays whole on the device this way where the halved
cache sends 1.5 GiB of its weights to the processor: a 16,243-token prompt
reads at 117 tokens a second against 115 and generates at 5.32 against
4.60.

`--kv-cache q4` stores it in four bits an element, two to a byte, with a
scale for every thirty-two rather than for the row: sixteen levels are too
few to spread over a row whose one outlying channel would set the step for
the hundreds beside it, and a block of thirty-two is the unit llama.cpp's
four-bit cache scales by -- the block's largest element, sign and all, over
minus eight, and each element its share of that plus eight and a half cut to
a whole number -- and this rounds the way it rounds. Five bits an element
with its scales, a sixth and a bit of the exact cache's bytes, and the
coarsest thing this program does to a number it will read back. It is not
measured against the exact reference as the other two are: these fixtures'
rows are four elements, and sixteen levels over four elements move a logit
by whole units -- **4.14** worst absolute -- which measures the rounding
and says nothing about whether the cache does it right. So the sweep holds
it to the independent implementation rounding its own keys and values the
same way, in binary64, and there it reads **0.029** worst absolute, held to
0.1: what is left between the two is binary32 against binary64 at the
rounding's edges, an element a level off where its share sits on a half.
On TinyLlama the four storages answer the same first sentence and the
nibble one parts from the other three in the second.

`--kv-cache q4t` has the same bytes as Q4 but applies a fixed orthonormal
transform to keys before quantization; values remain ordinary Q4. Across the
completed eight-chunk, four-model quality sweep it lowers aggregate mean KL
by **75.7%** from Q4 and raises average top-token agreement by **12.5
percentage points**. Its device generation rate is level with Q4 at short and
17K-token depths. It is therefore the default since 2026-11-20. A model whose
attention-head width is not divisible by 32 automatically uses `f16` when no
cache was named; explicitly naming `--kv-cache q4t` remains strict and reports
that incompatibility.

`--kv-values q8|q4` beside a packed `--kv-cache` stores the values in the
other packed storage from the keys. Attention reads the two sides
differently: a key through a dot product with the query, where a rounded
element moves every score it enters, and a value through a weighted sum
over the positions, where the roundings average out. So the values bear
the coarser storage, and on TinyLlama byte keys with nibble values answer
both sentences as the exact cache does, where nibble keys with byte values
part from it in the first; the session takes **20,043,942** bytes, between
the byte cache's and the nibble one's. The sweep crosses the two pairings
in a bucket of their own, against the reference rounding each side its
way, and holds them to the nibble bucket's bound.

What it saves is now a number the program will tell you rather than one this
document works out: `inspect --kv-cache` reports what a session would take in
each storage, and on TinyLlama-1.1B-Chat Q8_0 at its full 2048-token context
that is **97,251,904** bytes exact, **48,807,695** halved, **24,585,588**
in bytes and **15,502,296** in nibbles -- a little under a quarter and a
sixth, the difference being the buffers a session holds whatever it stores
its context in, and the scales.

On the device it is a different story and worth stating separately. A
packed context stays packed there, and a kernel of its own reads it: a
workgroup eight rows that share one group's keys and values -- a token's
eight heads of a group, or a batch's eight positions of a head -- each
key read once, a word of four elements at a time, and dotted into every
row, the softmax carried along a tile of sixty-four positions at a time
through subgroup reductions, a long cache cut into slices and merged as
the exact kernel's is. And the layer goes over whole, as an exact
session's does: the keys and values are packed where they are made, by a
step of the same sequence that rounds as the host rounds -- every
division through a double, because a device's single-precision quotient
need only be within two and a half units of the last place and the
host's is exact -- so the host's copy of the block, read back once the
token is done, is the bytes the host would have packed, which the suite
holds to the bit. Twelve tokens read **0.270 s** with the byte cache
against **0.291 s** with the exact one on the six-token prompt, which is
to say the same; after a prompt of 1,419 tokens, sixty-four more read
**1.65 s** generating against **1.38 s** -- 25.8 ms a token against
21.5. The first form of this kernel, a workgroup a head reading a byte
at a time and the keys twice, with the host packing every row between
the two halves of a layer, took 36.5 ms a token there. A batch goes
another way: an exact session's batch attends through the matrix
instruction over the half-precision copy the cache keeps beside itself,
and a packed block keeps no copy -- so a step of the layer's sequence
unpacks the layer's keys and values into the room that copy would have
had for this block, which is nobody's while the block is packed, and the
matrix kernel reads them there as it reads an exact session's. A layer
in halves is a fraction of the block, which holds every layer in bytes
or nibbles, so it fits where the model has four layers or more in bytes
and eight in nibbles; a shallower model's batch takes the packed kernel,
eight positions at a time. The 1,419-token prompt reads **0.701 s** with
the byte cache against **0.729 s** with the exact one, which is to say
the same, from the 2.07 s it read through the packed kernel a block of
eight positions at a time.

What it costs in time is nothing this machine can measure: twelve tokens of
TinyLlama-1.1B Q8_0 take **1.912 s** with the byte cache against **1.871 s**
with the exact one, and two runs of the same figure an hour apart on this
machine differ by more than that. Packing a row is one pass over what a
projection had just written hundreds of products into, and unpacking is a
multiply where a read used to be, so this is what one would expect rather
than a surprise -- but it was arithmetic about memory until it was a
measurement about time, and those are different claims.

What it costs in what the model says is not nothing. The same twelve tokens
come out as a different digest -- `7d3e2df2d776ba62` against
`5abff916f9d83ca6` -- so at eleven hundred million parameters and twelve
tokens the byte cache has already changed the text. The exact and halved
caches agree with each other on that run; this one does not agree with
either. A storage offered for the case the halved cache does not fit is a
storage whose output is its own.

A rolling context in that storage loses a little more of what it keeps every
time it rolls. `Shift` turns the surviving keys back by the angle it dropped,
which means decoding a row that was already rounded and rounding it again --
the price of the storage rather than a fault in the shift, and worth knowing
before running a long conversation on it.

The rounded figures are `--repack bf16`, counted apart because mixing them in
would let the lossy path's error hide the exact path's. They are the number
that flag never had: rounding every weight to eight mantissa bits moves a
logit **on these fixtures** by up to **0.137**, and a logit close to zero moves
by almost all of itself, which is what the relative figure says.

On this fixture is not a small qualification. Rounding error accumulates with
the length of a dot product and the depth of the stack, and the widest fixture is
256 wide and two deep where a small real model is two thousand wide and
twenty-two deep. The figure has read 0.032, 0.064, 0.090, 0.254 and now 0.137 as the fixtures
changed -- which is the shape of the thing rather than a number to trust to
three places: wider means more terms means more accumulated rounding, coarser
weights mean a rounding step that matters more, and halving the feed-forward
width of the widest fixtures brought it down again. What it says is that the
flag costs a tenth of a logit or so on a model this size, and that a model of
a useful size is where the question actually gets answered. The figure bounds what was measured, not what the flag does
to a model you have. What exists for real models is behaviour rather than
logits: sixty greedy tokens from TinyLlama Q8_0 and forty from Q4_K come out
identical either way, which is worth knowing and is not a bound.
`tests external-model --model PATH --repack bf16` runs a model you have both
ways and says whether the identifiers still match. `--repack f32`
is in the first set, where it belongs: it lands exactly where the stored
layout does. The bound the rounded path is held to is 5e-2 relative with a
1e-1 absolute floor -- what it measures, rounded up -- rather than the exact
one, which would only restate that rounding rounds.

A prompt longer than `--batch-size` is evaluated in several calls, and the
seam between them -- where the cache position carries from one call to the
next -- is where an off-by-one would live. Eight tokens three at a time is
two of those seams, and every comparison used to hand the whole sequence over
at once. What decides where the seams fall is the loop in `Generation`, and
that loop is checked against the engine itself: a test asserts that a batch
produces the same bits as the same tokens one at a time. So the seam is
compared independently and the arithmetic that chooses it is not, which is
the honest division here.

The partitioned path is compared for the same reason the batched one is: a
run uses it and only the engine had ever read what it produced. Row
partitioning is where a boundary error would live, and the two checks that
exercise a pool -- worker-count stability here and in `tests external-model`
-- compare the engine against itself, so a partition that is wrong the same
way at every worker count passes both.

The batched path is compared because it is the one a prompt goes through, and
it was checked only against the engine's own single-token results: the
strongest statement here -- that the arithmetic agrees with an implementation
written from the architecture description -- was being made about the decode
path alone. The reference backend takes a token at a time by design, so the
batched half of the sweep runs on the backend that batches, which the sweep
asks rather than assumes.

Running the reference backend through the same comparison is worth the
seconds it costs: that the two backends agree with each other says the fast
path's partitioning and batching change nothing, and that both agree with an
independently written forward pass says the arithmetic is right. The second
is the stronger statement and it used to be made about only one of them.

The relative figure is dominated by one logit that is very close to zero,
where a difference of six ten-millionths is a large fraction of a small
number. Measured apart, `llama` reaches 1.22e-06 absolute and 1.22e-05
relative, and `qwen2` reaches 6.08e-07 absolute and 8.27e-04 relative -- so
the architecture with the larger relative figure is the one whose two
implementations agree more closely in absolute terms. That is worth saying
because the relative number moved seventy-fold when `qwen2` was added and it
would otherwise read as a regression.

Those digits are what the run prints, and `tests conformance` checks that this
file still quotes them. It had gone stale twice before that check existed: the
counts here read 4 and 64 while the run had grown to 8 and 128, and the worst
divergence was quoted six times smaller than it is. A figure worth publishing
is worth failing the release checklist over.

`tests external-model --model PATH [--expect FILE]` runs the same kind of
validation against a model you already have — container, architecture, session,
greedy generation, valid UTF-8, seed reproducibility and worker-count stability
— and, when given a recording from a trusted reference runtime, compares the
tokenization, the greedy token identifiers and any recorded logits against it.
Nothing is downloaded, and a missing file is a skip rather than a failure. See
[docs/reference-runtime.md](docs/reference-runtime.md).

Ada applications can use the bounded, reusable in-process completion boundary
described in [docs/inference-api.md](docs/inference-api.md); its public-surface
compatibility rules are in [docs/api-lifecycle.md](docs/api-lifecycle.md).

`--backend NAME` points it at any backend this build has, which is what makes
it a validation of a backend on somebody's own model rather than of the
processor path alone. `--draft-model PATH` runs the model again with that one
proposing for it and checks that the text is identical, which is the claim
drafting makes and the only place it can be checked against a model anybody
cares about; the summary reports how many proposals were made and taken.

What this runner generates is what the command generates from the same
inputs, and a test holds that by running both and comparing a digest of the
text. It samples greedily and seeds itself with forty-two, which is a choice
rather than the command's default, so the test gives the command those
settings explicitly. `tests benchmark` has no such counterpart and needs
none: it measures kernels on synthetic tensors it builds itself, so there is
no command it could differ from. A backend that does not partition rows is not asked
whether the worker count changes its answer, and says so rather than
reporting an unrun check as one that held; a machine with no device is a skip
for the same reason a missing model is.

The optional real-artifact path also covers the llama.cpp-inspired runtime
features directly. Repeat `--shard PATH` (or use `--ple PATH`) for external
PLE/engram tensors, name `--kv-cache f8_e4m3` for the native byte cache, set
`--expert-cache BYTES` for routing-adaptive MoE residency, and pass
`--panel-cache PATH` to exercise combined-input panel reuse. Supplying
`--expect FILE` keeps these checks differential: the altered storage path must
still match the trusted runtime's token identifiers and recorded logits.

```
$ tests external-model --model /nowhere/x.gguf
external-model: skipped (no model at /nowhere/x.gguf)

$ tests external-model --model fixtures/tiny-model.gguf --prompt "ab" \
      --threads 4 --max-tokens 8
external-model: ok, architecture llama, 21 tensors, no reference comparison,
                prompt 3 tokens, generated 8, backend cpu,
                deterministic TRUE, thread-stable TRUE

$ tests external-model --model fixtures/tiny-model.gguf --prompt "ab"
external-model: FAILED (generation failed: MR-GEN-0002)
```

The third is worth showing. The committed fixture holds sixteen tokens of
context and the runner asks for sixteen tokens by default, so a three-token
prompt leaves no room and the engine refuses before generating anything. The
failure names the code it refused with, which is how anyone reading it can
tell an unusable request from a broken engine without reproducing the run by
hand. It printed only "generation failed" until this was written down, and
this example was published for two years as though it had succeeded.

### Repository checks

`tests check` performs its checks in Ada: crate structure and declared
dependencies, the version in `alire.toml` against `Model_Runner.Version`,
absence of scripting-language build files, that production code never reaches
AUnit or `project_tools`, that nothing below the presentation layer reaches the
message catalog, terminal styling, the command-line layer or a standard stream,
the 120-character line budget, a catalog entry for every diagnostic code, and
that the generated error-code reference is current.

Diagnostics are held in three states, not two. `Reserved_Codes` names the
codes nothing raises; `Unreached_Codes` names the codes the program raises
that no test names, each with why — naming is the proxy for reaching, and it
errs towards calling a code reached, so the list going empty would not mean
every refusal has been made to happen. Seventeen codes were in that third state
with nothing saying so — a refusal written and never made to happen is a
promise the program has not been asked to keep, and the check that every code
is *produced somewhere* counts a raise nobody reaches exactly as it counts a
raise everybody reaches. Ten of the seventeen are now reached; the rest are on
the list with a reason. Both lists are held in both directions. The checks are
negative-tested: injecting a violation makes them fail, and they run on every
host the project supports rather than on the one they were written on.

They also hold the changelog against git — no commit touching the library, the
message catalog or the release gate may be newer than the newest commit
touching `CHANGELOG.md`, so a change and its entry arrive together — and the
release checklist ends by running `check_all_selftest`, which requires the
checklist to refuse a directory that is not a model_runner tree, and to refuse
it for that reason rather than by failing somewhere else.

They also compile every host body, not only the two a build uses — in the
tests crate as well as the library, which has its own per-host directories and
had been left out of the walk. And a host call may only be bound by name from
one of those directories: anywhere else in the tests crate is one directory
built for whatever machine you are on, so a POSIX-spelled import links there
and nowhere else.
`src/platform` holds five directories and a Linux build uses `linux` and
`posix`; the other three are production code no compiler here would otherwise
see, and reading them as text is not compiling them. The sibling `hostkit`
crate shipped a Windows body holding `('\\')` where Ada spells a backslash,
found by building on Windows and nowhere else. `gcc -gnatc` stops before code
generation but after analysis, so profiles are checked against the spec all
five share and names are resolved — and nothing here needs the host's own
libraries, because these bodies reach their host through `Interfaces.C`, whose
declarations are the same everywhere. That is what makes the question askable
from a machine of the wrong kind.

They also check that each host gets exactly one body for each platform spec.
Compiling a body says it is well formed and says nothing about whether the
host that needs it has one; the project file builds `linux` with `posix`,
`macos` with `posix`, `windows` alone and `unsupported` alone, so a spec whose
bodies were written for some of those and not the rest fails to link on the
others — on that host and nowhere else.

## Layering

CLI and presentation sit above command execution, which sits above generation,
the conversation and template layer, the tokenizer, the model and session
interfaces, the architecture implementation, the tensor layer and the platform
abstractions. No package below the presentation layer writes to standard
output or standard error, depends on the message catalog, or depends on
terminal styling.

**Work crosses the layering downwards through one pair of interfaces rather
than upwards through a dependency.** `Model_Runner.Shares` declares `Work` --
something a range of items can be asked of -- and `Team` -- something that
can run the pieces of a job at the same time. The worker pool in the CPU
backend wears `Team`; the engine's shares and the sampler's wear `Work`. That
is how a package which decides what a model says gets shared out without
naming a package that asks the platform what it has and creates tasks. What a
team may be handed is bounded by one rule, stated there: the answer must not
depend on where the cuts fall.

## Security posture

Every GGUF file is untrusted input. Counts are checked against explicit limits
before they size a loop or an allocation; offsets, element counts and byte sizes
are derived with checked arithmetic that reports overflow instead of wrapping;
strings are validated as UTF-8; tensor ranges are checked against the file and
against each other. Embedded chat templates are compiled into a bounded
allowlisted form that has no operation capable of reaching a file, a process,
the environment or the network. Metadata values are escaped before they reach a
terminal, and so is message text from the catalog, which is a file beside the
executable rather than part of the program. Model files are opened read-only
and are never modified, which a
test holds by comparing the file's bytes and its modification time across a
run. The units that interpret what a container holds -- the template engine,
the tokenizer, the metadata accessors, the engine itself -- may not name a
file, a stream, a directory, the environment or the command line at all, and
the release checklist fails if one of them does.

Generated text is passed through as the model produced it. It is never styled
and never escaped: a model that generates a terminal escape sequence has
generated one, and rewriting it would corrupt output a reader asked for. The
line is between what the program says about a file — keys, names, values,
diagnostics, all escaped — and what it hands back. Redirect to a file, or
filter, if the model is one you do not trust with your terminal.

Prompt text given with `--prompt` may be visible to other local processes. Use
`--prompt-file` or standard input for sensitive text.

A project's checks run code its agents may have written -- a test, a build
script -- and run it as you. What an agent's own tools may write is held to the
roots its permissions name, judged where a path lands once links are followed,
and never the project's state or `.git`; what a check run on its behalf writes
is not, unless the project sets `scalar execution.confine_writes = true`. Then
every check runs under `bwrap`, the host read-only to it but for the project or
workspace tree it runs for -- its state and `.git` still read-only within it --
and a `/tmp` of its own; on a host without `bwrap`, checks are refused rather
than run unconfined. It is off by default because a build that writes outside
its tree -- a compiler's cache in your home -- would then fail. Alire is one:
with the home directory read-only, `alr` takes its settings from `/tmp`, does
not see the toolchain you selected, and tries to download another; it works
only with a writable home, so an Alire project leaves this off. Values the
harness fills into a check (`{tests}`, `{scope}`) are passed as their own
arguments, quoted, and a value with a quote or a control character in it is
refused.

The programs a check may run are the ones `set execution.allowed` lists, a
program given by name found on `PATH` and one given as a path allowed only as
the list writes it. That list holds only while checks run without a shell:
`scalar execution.shell = allowed` lets a check be a shell line, and a shell
line runs whatever it names. Confined checks also get their own process,
IPC and session namespaces and an empty `/run`, so the sockets of your desktop
session are out of their reach; `scalar execution.network = denied` takes the
network away, and on a host that cannot, checks are refused. A limit on
processes (`scalar execution.max_processes`) is the host's limit on your user's
processes as a whole, not on the check's alone: set it above what your session
already runs, or every check fails to start one.

## Not implemented

No item is currently listed here.

## Native SIMD

The processor backend includes hand-written SIMD kernels in native Ada through
`System.Machine_Code`: x86-64-v3 variants use AVX2, FMA and F16C, and
x86-64-v4 variants add AVX-512 VNNI byte products. Runtime dispatch selects a
wide kernel only when CPUID identifies every feature in the complete inherited
ISA level and XGETBV confirms that the operating system saves the required
vector state. The same predicate is used on Linux, Windows and Intel macOS;
synthetic feature-mask tests remove each required member in turn. On supported
x86-64 hosts, the scalar path remains the fallback. Equivalence tests run the
scalar and vector implementations over the same inputs, including half,
floating-point and
quantized products.

There is no separately compiled C, C++ or assembly source in the repository.
`src/shaders/row_product.comp` is GLSL because the graphics driver compiles the
compute shader. Its source digest is recorded beside the compiled form, so an
edited shader that has not been recompiled fails the release check instead of
silently running the old binary.

## Speed

Native Inkling Q4_K_M with Q4T KV storage was measured with a 2,048-token prompt,
16 output tokens, eight CPU threads, and one measured pass after warmup:

| Configuration | Prefill tok/s | Decode tok/s |
| --- | ---: | ---: |
| Q4T, no drafting | 16.90 | 3.72 |
| Q4T, context-lookup drafting | 16.93 | 4.85 |
| Q4T, drafting and fused packed attention | 16.72 | 4.97 |
| Q4T, previous CPU integer activations | 11.65 | 6.73 |
| Q4T, tiled CPU integer activations | 15.39 | 7.66 |
| Q4T, streaming CPU integer activations | 21.57 | 10.04 |
| Q4T, joint integer products and eight-vector tiles | 22.89 | 10.16 |
| Q4T, K-format tiles and four-query attention | 23.30 | 10.11 |
| Q4T, indexed integer inputs and wider value updates | 24.04 | 9.89 |
| Q4T, parallel softcap, SiTU packing and relative bias | 24.87 | 10.50 |
| Q4T, fused scores and incremental cache bookkeeping | 25.07 | 10.52 |
| Q4T, shared projections and checkpoint ownership | 25.20 | 10.38 |
| Q4T, fused normalization and grouped CPU dispatch | 24.87 | 10.30 |
| Q4T, fused K experts and parallel preparation | 25.93 | 10.32 |
| Q4T, scheduled integer kernels and fused output | 26.20 | 10.06 |
| Q4T, tiled output and reusable work plans | 26.19 | 10.26 |

All rows use Q4_K_M model weights. The first three use F32 activations;
the integer-profile trials explicitly select `--backend cpu --arith int8 --repack none`.
The CLI activation default remains F32. All sixteen selected samples produce the same
output digest, with eight of eight lookup drafts accepted where enabled.
These single runs do not establish repeated-run confidence. Q4T's five-bit
cache footprint including scales is unchanged. Native and interleaved CPU
integer products pass independent checkpoint conformance on the recorded
AVX-512 host. Commands, validation and measurements are retained in the
[Q4T evidence](docs/inkling2-q4t-four-evidence.json),
[integer baseline](docs/inkling2-integer-native-evidence.json),
[integer tile evidence](docs/inkling2-integer-eight-evidence.json) and
[streaming integer evidence](docs/inkling2-integer-stream-eight-evidence.json) and
[joint product evidence](docs/inkling2-integer-pair-eight-evidence.json) and
[previous quantized-path evidence](docs/inkling2-quantized-next-eight-evidence.json) and
[previous evaluation](docs/inkling2-quantized-followup-eight-evidence.json) and
[six-candidate evaluation](docs/inkling2-decode-six-evidence.json) and
[routing evaluation](docs/inkling2-routing-eight-evidence.json) and
[projection evaluation](docs/inkling2-projection-eight-evidence.json) and
[batch-chain evaluation](docs/inkling2-batch-chain-eight-evidence.json) and
[K-format evaluation](docs/inkling2-super-eight-evidence.json) and
[dispatch evaluation](docs/inkling2-dispatch-eight-evidence.json) and
[latest evaluation](docs/inkling2-plans-eight-evidence.json).
A further register-fused depth-bank reduction was tested and rejected: it
gave 26.14 tok/s prefill and 9.96 tok/s decode versus the selected
26.19/10.26 in one measured pass. It passed exact numerical checks, but the
observed throughput did not justify selecting it. The original engine is
restored; its complete code and constant sections match the preceding selected
build. The candidate patch, binaries and failed performance outcome remain in
[the investigation evidence](docs/inkling2-dspark-depth-mix-evidence.json).

The published Q8 DSpark drafter now has a native CPU adapter using the existing
generation verifier and shared target tensors. Q4_K_M target weights and Q4T
storage remain; no external runtime is used for inference. See the
[adapter contract](docs/inkling2-dspark-native.md) and
[measured qualification](docs/inkling2-dspark-native-evidence.json).

The latest sample reaches 26.19 tok/s prefill and 10.26 tok/s decode
versus 26.20/10.06 previously, with identical output. Prefill is effectively
unchanged (-0.03%) and decode improves by 1.99% in this single sample.
There is no individual attribution or repeated-run confidence. Batched greedy
verification and 128-row output tiles preserve complete logits. Expert chunks
follow actual routed token counts; repeated exact assignments can reuse work
descriptors while router math and activations are recomputed. The measured pass
records 41 descriptor reuse hits and 343 misses. Metadata priorities are cached
within a visit and loop layers can borrow space within the same 128 MiB limit.

Native Vulkan gate/up products can share activation packing. Batched GPU
weighted aggregation is eligible for a common ordered resident expert set
with token-specific shares; other route layouts retain the host sum. Independent
operator tests and a 48-visit full-model fixture match CPU results exactly.
The long-prompt GPU trial reached its 300-second limit before the measured
pass finished, so it has no valid tok/s result. CPU remains selected.

The preceding dispatch sample reaches 26.20 tok/s prefill and 10.06 tok/s decode
versus 25.93/10.32 previously, with identical output. Prefill improves by
1.04% while decode regresses by 2.45% in this single sample. There
is no individual attribution or repeated-run confidence. Eight-token native
K kernels interleave independent integer operations. Metadata replacement
estimates saved decoding work per byte inside the existing 128 MiB budget;
expert chunks follow the fused kernels. CPU output projection and softcap
share a pool dispatch; eligible greedy callers also get a deterministic
argmax while retaining complete logits.

Resident GPU experts with matching token counts share submissions. The main
thread handles the one existing device while CPU workers process nonresident
experts. Packed Q4T attention can now feed the native gating, projection,
convolution and residual epilogue in one sequence. Primitive and full-checkpoint
lifecycle checks pass. Native device packing reuses the existing 4 MiB scratch
with explicit read/write barriers; a wide-group regression covers the initial
long-prompt refusal. The scratch fix left CPU code sections unchanged. Later
capability guards and native 256-bit dispatch are qualified and measured separately.
The same test prefill uses 28 resident submissions versus 42 previously. The bounded GPU throughput outcome is
recorded separately. CPU remains selected.

A separate 256-bit native integer comparison gives 14.15 tok/s
prefill and 7.42 tok/s decode with the same output.
The final native run records zero floating fallback shares. The 512-bit
implementation remains selected. Q4_K_M weights and Q4T storage
are retained throughout. See the linked evidence for every sample, including
slower outcomes.

`tests outside` runs another measuring tool through the same host-load gate as native benchmarks.
Use `tests outside --wait MINUTES -- COMMAND [ARGUMENT ...]`; it reports load before and after the command
and preserves that tool's output. `--anyway` explicitly bypasses the load gate.

The shared-engine regression workload uses the local Qwen3.5 0.8B Q8_0 CPU case with a release engine.
The [current no-adapter requalification](docs/inkling2-no-adapter-evidence.json) used two batches of seven
pairs under the [current quantized-path regression protocol](docs/inkling2-plans-eight-no-adapter-protocol.json). Both phases passed the unchanged
+5% paired-median time boundary after the Inkling shared-engine changes. Earlier comparison evidence is preserved.

| Batch | Baseline prefill tok/s | Current prefill tok/s | Baseline decode tok/s | Current decode tok/s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 32.47 | 144.49 | 12.37 | 28.77 |
| 2 | 32.45 | 142.28 | 12.33 | 28.65 |

Every measured run read 100 prompt tokens, generated sixteen tokens and produced identical text.
All samples remain in the linked evidence. These medians do not
establish significance, tail latency or performance on other configurations. Native Inkling measurements are recorded separately in the
[dated CPU and private-GPU baseline](docs/inkling2-benchmarks.md), including exact
reference output, complete sample ranges and the operation-count correction. Synthetic active-adapter
measurements are documented in [the execution report](docs/harness-adapter-execution.md).

### The reference backend

The reference path is qualified for numerical comparison. No current relative-speed claim is published.

### The device backend

No current GPU timing table is published. Device capability support is separate from available hardware
and measured performance; runtime LoRA remains CPU-only. Archived GPU observations are not current claims.

### Historical observations

[PERFORMANCE_HISTORY.md](PERFORMANCE_HISTORY.md) preserves the previous README, including older kernel,
format-quality, inference, drafting, scaling, llama.cpp, panel, image and speech observations.
Their original measurement records and fingerprints are preserved in
[the historical ledger](docs/measured-figures-history.txt), without restamping them as current.
The active ledger, [docs/measured-figures.txt](docs/measured-figures.txt), covers current qualified evidence.

## License

MIT. See [LICENSE](LICENSE).
