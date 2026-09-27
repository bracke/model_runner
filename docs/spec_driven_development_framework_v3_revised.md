# Spec-Driven Development Framework — V3 Revised Initial Implementation Specification

Version: 3.1  
Status: Initial implementation specification  
Target harness: `model_runner`  
Primary implementation language: Ada  
Primary initial use case: Ada development  
Language applicability: language-independent where practical

---

# 1. Purpose

The Spec-Driven Development Framework provides a deterministic development environment around one or more LLM-based coding agents.

The framework is integrated directly into the existing `model_runner` harness.

V3 is the first implementation target. V1 and V2 were design iterations only and were never implemented. V3.1 is a refinement of the V3 initial implementation specification and does not introduce backward-compatibility obligations to any unimplemented design.

There are therefore:

- no V1/V2 migration requirements;
- no V1/V2 persistence formats to preserve;
- no V1/V2 command semantics to preserve;
- no V1/V2 internal interfaces to preserve.

The central architectural principle is:

> The LLM reasons. The harness remembers, retrieves, executes, validates, tracks, isolates, and enforces.

Whenever work can be performed reliably and deterministically by the harness, it SHALL NOT be delegated to the LLM.

Conversation history is never authoritative project state.

---

# 2. Objectives

The framework SHALL:

1. minimize project state held only in model context;
2. minimize irrelevant information sent to models;
3. construct model context deterministically;
4. support relatively small local-model context windows;
5. support recursive agents without uncontrolled context growth;
6. maintain project and task state independently of conversation history;
7. maintain requirements, decisions, dependencies, provenance, and verification state;
8. understand repository structure and source relationships;
9. provide semantic repository queries where supported;
10. perform change-impact analysis;
11. select affected tests automatically where confidence is sufficient;
12. execute routine development operations without unnecessary model turns;
13. normalize build, compiler, static-analysis, and test diagnostics;
14. maintain requirements-to-task-to-code-to-test traceability;
15. isolate concurrent write agents;
16. integrate agent results deterministically where possible;
17. enforce task completion gates;
18. remain auditable, resumable, and recoverable after interruption;
19. support languages other than Ada;
20. provide first-class Ada semantic support;
21. provide efficient terminal-native workflows;
22. use reusable project templates for initialization;
23. keep project-type semantics out of command dispatch;
24. support deterministic and reasoning-assisted task creation;
25. distinguish persistent tasks from temporary execution agents;
26. clearly separate authored, runtime, historical, and derived state;
27. make all authoritative state transitions explicit and validated;
28. provide stable persistence and schema contracts;
29. make model invocations reproducible and inspectable;
30. support scoped permissions rather than only Boolean capabilities;
31. define deterministic failure, cancellation, and recovery semantics;
32. build a complete single-agent workflow before enabling recursive execution.

---

# 3. Non-Goals

The harness SHALL NOT independently:

- invent project requirements;
- reinterpret ambiguous requirements as authoritative;
- redesign subsystems where substantive judgment is required;
- choose architecture where substantive judgment is required;
- remove accepted requirements;
- weaken acceptance criteria;
- change project scope;
- silently alter program semantics;
- silently resolve contradictory authoritative specifications;
- silently widen task or agent permissions;
- treat model output as authoritative state without validation.

The harness MAY derive deterministic consequences of accepted project state.

---

# 4. Responsibility Boundary

## 4.1 Harness responsibilities

The harness SHALL preferentially own:

- project persistence;
- project-template discovery;
- project initialization;
- resolved project configuration;
- configuration revisions;
- persistent task state;
- task provenance;
- task dependencies;
- task identifier allocation;
- deterministic task derivation;
- task readiness calculation;
- lifecycle transition validation;
- specification indexing;
- requirement indexing;
- decision indexing;
- repository indexing;
- source dependency tracking;
- symbol lookup;
- context retrieval;
- context construction;
- context manifests;
- token budgeting;
- context deduplication;
- model invocation bookkeeping;
- Git state;
- workspace management;
- process execution;
- build execution;
- test execution;
- static analysis;
- formatting;
- diagnostic parsing;
- impact analysis;
- affected-test selection;
- verification;
- completion gates;
- result persistence;
- recursive-agent lifecycle;
- recursion limits;
- permissions;
- child-result transport;
- generated metadata;
- consistency checking;
- deterministic scheduling;
- terminal selectors and forms;
- durable events;
- transaction boundaries;
- interruption recovery.

## 4.2 LLM responsibilities

The LLM SHOULD primarily perform:

- interpretation;
- implementation reasoning;
- architectural reasoning;
- debugging reasoning;
- specification reasoning;
- ambiguity analysis;
- code generation and modification;
- test design;
- semantic conflict analysis;
- reasoning-based task decomposition;
- reasoning-based task proposals;
- analysis of unexpected failures.

The LLM SHALL NOT directly mutate authoritative state.

## 4.3 Human responsibilities

The human remains authoritative for:

- project purpose;
- project scope;
- requirement approval where policy requires it;
- architectural policy;
- significant specification changes;
- policy overrides;
- prioritization where no deterministic policy exists;
- approval of proposals where required.

---

# 5. Core System Invariants

The following invariants are normative.

1. Every persistent entity SHALL have one stable unique identifier within its namespace.
2. Every authoritative task lifecycle transition SHALL occur through Task Management.
3. No task may be executable while a required dependency is incomplete.
4. No task may reference an undefined authoritative requirement, task, component, or decision.
5. Task dependency cycles SHALL be rejected.
6. Parent-child task relationships SHALL NOT introduce cycles.
7. No effective permission may exceed the maximum permitted by higher-authority policy.
8. A write agent SHALL NOT operate concurrently on shared mutable repository state when isolation is required.
9. No model output may directly mutate authoritative project state without harness validation.
10. No derived index may be treated as authoritative.
11. No live project template may change an initialized project except through an explicit reconfiguration operation.
12. Historical verification evidence SHALL remain immutable once committed.
13. Current verification validity SHALL be derived from historical evidence and current applicability conditions.
14. A configuration or requirement revision that invalidates prior evidence SHALL NOT silently retain a verified status.
15. Every externally visible authoritative mutation SHALL be durable before dependent events are exposed.
16. Event handlers that may be replayed SHALL be idempotent.
17. Cancellation of an execution entity SHALL NOT silently imply cancellation of persistent project intent.
18. Conversation history SHALL NOT be required to recover project or task state.
19. Authoritative state SHALL be recoverable after process termination at any transaction boundary.
20. Unknown or unsupported authoritative schema fields SHALL never be silently assigned execution semantics.

---

# 6. High-Level Architecture

```text
                         Human
                           │
                           ▼
                    Slash Commands
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
  Template Registry   Task Management   Project State
          │                │                │
          └────────┬───────┴───────┬────────┘
                   ▼               ▼
          Specification Engine   Event/Transition Core
                   │               │
                   └───────┬───────┘
                           ▼
                    Repository Engine
                           │
                           ▼
                     Context Engine
                           │
                           ▼
                  Model Invocation Layer
                           │
                           ▼
                    Agent Controller
                           │
                           ▼
                    Workspace Manager
                           │
                           ▼
                  Verification Engine
                           │
                           ▼
                       Result Store
```

Task Management, persistence, event/transition infrastructure, repository intelligence, context construction, model invocation, verification, and workspace isolation are first-class subsystems.

Project templates initialize projects.

Normal project execution uses a persisted Resolved Project Configuration, not a live template.

---

# 7. Project Model

The harness SHALL maintain an explicit persisted project model.

Conceptually:

```text
Project
├── project identity
├── template provenance
├── resolved project configuration
├── configuration history
├── specifications
├── specification revisions
├── requirements
├── requirement revisions
├── decisions
├── project facts
├── components
├── source files
├── source symbols
├── dependencies
├── tests
├── generated artifacts
├── tasks
├── task runtime state
├── agents
├── model invocations
├── workspaces
├── verification evidence
├── events
├── stored results
└── derived indexes
```

Conversation history SHALL NOT be authoritative project state.

---

# 8. Persistent State Classification

The framework SHALL distinguish four state classes.

## 8.1 Authored authoritative state

Examples:

- accepted specifications;
- accepted requirement revisions;
- accepted decisions;
- task definitions;
- explicit traceability links;
- project policy;
- resolved project configuration revisions.

## 8.2 Runtime authoritative state

Examples:

- task runtime state;
- active agent records;
- active workspace records;
- locks or leases;
- cancellation requests;
- transaction metadata.

## 8.3 Historical immutable state

Examples:

- verification evidence;
- model invocation records;
- committed events;
- result objects;
- previous accepted revisions;
- integration reports.

## 8.4 Reconstructable derived state

Examples:

- symbol indexes;
- dependency indexes;
- search indexes;
- derived traceability edges;
- readiness;
- current verification applicability;
- cached impact data;
- context retrieval caches.

Reconstructable state MAY be deleted and rebuilt without changing project meaning.

---

# 9. Persistence Root and Storage Ownership

Each initialized project SHALL have one framework state root.

The default SHOULD be:

```text
.model_runner/
```

The exact physical representation MAY evolve, but logical ownership SHALL be equivalent to:

```text
.model_runner/
├── project/
├── config/
├── specs/
├── requirements/
├── decisions/
├── tasks/
├── runtime/
├── results/
├── events/
├── verification/
├── invocations/
├── workspaces/
└── indexes/
```

A project template MAY select another state root only through resolved configuration.

The state root SHALL contain a format identifier and schema version.

The framework SHALL distinguish:

- repository-portable state;
- local machine state;
- derived cache state.

Repository policy SHALL determine which categories are committed to Git.

Machine-local transient state SHALL NOT be required for semantic project recovery unless explicitly declared.

---

# 10. Schema System

Every persisted authoritative record SHALL identify:

```text
schema_id
schema_version
entity_id
revision_or_generation
```

where applicable.

The schema system SHALL define:

- validation rules;
- required fields;
- optional fields;
- unknown-field behavior;
- extension namespaces;
- migration hooks between implemented V3 schema revisions;
- canonical serialization rules where required for fingerprinting.

Unknown fields SHALL be preserved where safe when rewriting a record, unless schema policy explicitly rejects them.

Unknown fields SHALL NOT gain execution semantics implicitly.

The absence of V1/V2 compatibility requirements does not remove the requirement for versioned V3 persistence.

---

# 11. Entity Identity and Revision Semantics

Stable entity identifiers identify conceptual entities.

Revisions identify accepted changes to mutable authored entities.

Examples:

```text
REQ-PARSER-017 revision 4
DEC-IO-003 revision 2
CONFIG revision 7
```

Tasks SHALL retain stable task identifiers through their lifecycle.

A task definition MAY itself have revisions if edited after creation.

Traceability SHALL be capable of referencing a specific revision where applicability requires it.

Historical records SHALL NOT be rewritten to pretend they applied to later revisions.

---

# 12. Transaction Model

Every authoritative mutation SHALL execute inside a harness-managed transaction.

A transaction SHALL:

1. validate requested mutation;
2. validate preconditions;
3. compute deterministic side effects;
4. persist the complete authoritative state change atomically;
5. commit any durable event records associated with the mutation;
6. expose resulting events only after successful commit.

A failed transaction SHALL NOT leave a partially authoritative semantic state.

Where the underlying filesystem cannot provide a single multi-file atomic transaction, the harness SHALL use a recoverable journal or equivalent commit protocol.

On startup, incomplete transactions SHALL be detected and either:

- completed safely;
- rolled back safely;
- or marked as requiring explicit recovery.

---

# 13. Event Model

Events are durable descriptions of committed state transitions or significant execution outcomes.

Events SHALL NOT themselves be the sole authoritative representation of project state unless a future implementation explicitly adopts event sourcing.

Core events SHOULD include:

```text
Project_Initialized
Configuration_Changed
Specification_Accepted
Requirement_Accepted
Requirement_Revised
Requirement_Obsoleted
Decision_Accepted

Task_Candidate_Created
Task_Accepted
Task_Rejected
Task_Became_Ready
Task_Started
Task_Blocked
Task_Verification_Started
Task_Completed
Task_Failed
Task_Cancelled

Source_Changed
Build_Completed
Test_Completed
Test_Failed

Agent_Spawned
Agent_Completed
Agent_Failed
Agent_Cancelled

Workspace_Created
Workspace_Integrated

Requirement_Verified
Requirement_Verification_Invalidated
```

Events SHALL contain stable identifiers for their subject and transaction.

Event consumers SHALL be idempotent where replay is possible.

Duplicate delivery SHALL NOT create duplicate authoritative consequences.

---

# 14. Authority Model

The default authority order is:

```text
explicit current human instruction
        >
accepted project decision
        >
accepted component specification
        >
accepted project specification
        >
resolved project configuration
        >
project baseline
        >
language baseline
        >
agent assumption
```

The live template SHALL NOT participate in runtime authority after initialization.

Higher authority SHALL NOT silently erase a conflicting lower-authority normative statement.

The framework SHALL distinguish:

```text
refinement
explicit override
conflict
```

An explicit override MUST identify the overridden source where practical.

An unresolved normative conflict SHALL be surfaced as a consistency error or proposal requiring resolution.

The Effective Task SHALL include applicable authoritative sources and any explicit override relationships.

---

# 15. Project Template Architecture

Project types SHALL be represented by installed project templates.

The harness SHALL NOT contain a hardcoded project-type enumeration.

The project types shown by `/init` SHALL come entirely from installed templates.

A template defines initialization behavior and initial project policy.

The template is an initializer and provenance source, not a permanent runtime dependency.

---

# 16. Project Template Registry

Each template SHALL provide:

```text
template identifier
display name
description
version or fingerprint
availability
```

It MAY additionally provide:

```text
category
language
tags
origin
provider
```

The `/init` command SHALL enumerate the registry.

---

# 17. No Hardcoded Project-Type Semantics

`/init` SHALL understand only generic operations:

```text
discover templates
select template
load template
validate template
collect declared inputs
run declared discovery
produce initialization plan
execute initialization
validate result
persist project
```

It SHALL NOT contain project-type-specific branches.

---

# 18. Template Contents

A template MAY define:

```text
identifier
display name
description
version

language
build system
test framework

required inputs
optional inputs
default values

repository layout
source roots
test roots
generated roots

initial files
generated files

baseline specifications
specification structure

verification profiles
project facts

repository discovery rules
validation rules

bootstrap policy

task kinds
task schemas
task defaults
task creation policy

component conventions

language adapter
build adapter
test adapter
formatter adapter
static-analysis adapter

automation rules
execution policy
repository-state policy
```

---

# 19. Template-Defined Inputs

Templates SHALL define initialization inputs declaratively.

The harness SHALL render terminal controls generically.

The command layer SHALL NOT hardcode template-specific questions.

A declared input SHOULD include, where applicable:

```text
identifier
type
label
description
required
default
validation
choices or provider
secret flag
persistence policy
```

Secret inputs SHALL NOT be written to ordinary project state unless explicitly permitted.

---

# 20. Template Composition

Templates SHOULD support composition and reuse.

Example:

```text
ada-cli
    =
ada
+ alire
+ terminal-cli
+ aunit
+ standard-development
```

Composition precedence SHALL be deterministic.

The template schema SHALL classify values by merge semantics.

Default merge semantics SHALL be explicit for:

```text
scalar
map
set
ordered list
schema
adapter
verification profile
task kind
input declaration
file-generation rule
```

Recommended semantics:

- scalar: duplicate values conflict unless an explicit override exists;
- map: merge by key; incompatible duplicate keys conflict;
- set: union;
- ordered list: stable concatenation with defined duplicate policy;
- schema: structural merge only when compatible;
- adapter: at most one effective provider per capability unless chaining is explicitly supported;
- file generation rule: path collision requires explicit resolution;
- task kind: duplicate definitions require compatibility or explicit override;
- verification profile: duplicate names require compatibility or explicit override.

Unresolvable conflicts SHALL fail template validation.

---

# 21. Template Versioning and Provenance

The initialized project SHALL record:

```text
template_id
template_version_or_fingerprint
template_origin
```

These are provenance fields.

They SHALL NOT imply a live dependency on the installed template.

Removing or upgrading the installed template SHALL NOT change an initialized project.

---

# 22. Resolved Project Configuration

Initialization SHALL produce a persisted Resolved Project Configuration.

It becomes authoritative for normal project operation.

Conceptually it contains:

```text
Resolved Project Configuration
├── adapters
├── roots
├── baselines
├── task policy
├── task kinds
├── task schemas
├── verification profiles
├── automation rules
├── execution policy
├── workspace policy
├── repository-state policy
└── project defaults
```

The resolved configuration SHALL have:

```text
configuration_revision
configuration_fingerprint
```

All runtime operations SHALL use the resolved configuration rather than the live template.

---

# 23. Reconfiguration

Existing projects SHALL be changed through an explicit reconfiguration mechanism.

The command surface MAY include:

```text
/config
/config edit
/reconfigure
```

The exact final command spelling is implementation-defined until the command layer is frozen.

Reconfiguration SHALL:

1. start from the current resolved configuration;
2. propose or accept explicit changes;
3. validate the complete new configuration;
4. compute impact;
5. identify invalidated derived state or verification applicability;
6. create a new configuration revision;
7. atomically commit it;
8. emit `Configuration_Changed`.

Reconfiguration SHALL NOT query a live template for new defaults unless the human explicitly requests template reapplication or import.

Template reapplication, if supported, SHALL be an explicit merge operation and SHALL NOT silently overwrite project configuration.

---

# 24. Project Initialization

Initialization uses:

```text
/init
```

In an interactive TTY, `/init` SHALL open a project-template selector.

Example:

```text
Select project type:

  ▸ Ada CLI Application
    Ada Library
    Existing Ada Project
    Generic Existing Repository

↑/↓ move   Enter select   / filter   Tab details   Esc cancel
```

Every row SHALL correspond to an installed template.

After selection, the harness SHALL:

1. load the selected template;
2. validate it;
3. run declared deterministic discovery;
4. resolve required inputs;
5. avoid asking for values already known;
6. render generic input controls;
7. produce an initialization plan;
8. confirm where policy requires it;
9. perform initialization transactionally;
10. validate the result;
11. produce the Resolved Project Configuration;
12. persist template provenance;
13. create requested project state;
14. build requested initial indexes;
15. emit `Project_Initialized`.

---

# 25. Non-Interactive Initialization

For automation:

```text
/init <template-id>
```

SHALL bypass the selector.

If required inputs cannot be obtained non-interactively, initialization SHALL fail with structured missing-input information.

Non-interactive commands SHALL never silently prompt through terminal-specific UI.

---

# 26. Bootstrap

Initialization and specification bootstrap are separate.

```text
/init
```

establishes project configuration.

```text
/bootstrap
```

establishes or reconstructs project-specific specification state according to the resolved bootstrap policy.

Bootstrap SHALL NOT contain a separate task-generation system.

Instead:

```text
bootstrap discovers/imports/proposes requirements
            ↓
requirement acceptance occurs
            ↓
normal requirement-change processing occurs
            ↓
task derivation policy executes
```

Bootstrap MAY use deterministic discovery and reasoning agents.

Bootstrap outputs SHALL be classified explicitly as one of:

```text
discovered fact
imported authoritative item
requirement candidate
decision candidate
specification candidate
issue
```

Reasoning-derived requirements SHALL NOT become authoritative merely because bootstrap proposed them unless project policy explicitly permits automatic acceptance.

Bootstrap SHALL be repeatable.

Repeated bootstrap execution SHALL avoid creating duplicate authoritative entities when provenance and identity indicate an existing item.

---

# 27. Specification Model

Specifications SHALL remain primarily human-readable.

They MAY define:

- requirements;
- acceptance criteria;
- dependencies;
- components;
- decisions;
- implementation constraints;
- verification requirements.

Accepted authored specifications are authoritative.

Each accepted specification SHALL have stable identity or source identity and a revision or fingerprint sufficient to determine whether downstream evidence still applies.

---

# 28. Requirement Registry

Each persistent requirement SHALL have a stable identifier.

The registry SHALL record, where known:

```text
identifier
revision
source
status
dependencies
components
implementation links
task links
test links
verification links
provenance
```

Core requirement statuses SHALL be defined by project policy.

The default core set is:

```text
candidate
accepted
implemented
verified
blocked
obsolete
rejected
```

`pending` MAY be provided as a presentation alias but SHALL NOT have ambiguous semantics.

---

# 29. Requirement Lifecycle

The default requirement lifecycle is:

```text
candidate
   ├──> accepted
   └──> rejected

accepted
   ├──> implemented
   ├──> blocked
   └──> obsolete

implemented
   ├──> verified
   ├──> blocked
   └──> obsolete

verified
   ├──> implemented    when verification applicability is invalidated
   └──> obsolete
```

Projects MAY extend this lifecycle, but semantics SHALL be explicit.

A requirement SHALL NOT become verified solely because a linked task completes.

Requirement verification SHALL depend on:

- implementation traceability;
- applicable acceptance criteria;
- current verification evidence;
- project verification policy.

---

# 30. Requirement Revisions and Invalidation

Changing an accepted requirement SHALL create a new revision rather than rewriting historical meaning.

When a requirement revision changes normative semantics or acceptance criteria, the harness SHALL evaluate impact.

Potential consequences include:

```text
verified -> implemented
implemented -> accepted
derived task creation
verification invalidation
traceability invalidation
affected-test recalculation
```

The exact transition SHALL be policy-driven and based on whether existing implementation and evidence remain applicable.

Historical verification evidence SHALL remain preserved but may become non-current.

---

# 31. Decision Registry

The harness SHALL maintain proposed and accepted decisions outside conversation history.

Applicable accepted decisions SHALL be injected into task context automatically.

Decisions SHALL support stable identity and revision where edits are allowed.

A superseding decision SHOULD identify the superseded decision explicitly.

---

# 32. Project Facts Registry

The harness MAY maintain project facts such as:

```text
language = Ada_2022
build_system = Alire
test_framework = AUnit
```

Each fact SHOULD carry provenance.

Template-derived facts SHALL be copied into resolved project configuration or persistent project facts during initialization.

Derived facts SHOULD identify their derivation source and confidence.

---

# 33. Task Model

Tasks are persistent project entities representing units of work.

Tasks are distinct from:

- requirements;
- agents;
- model invocations;
- verification runs;
- results.

Requirements define desired or required outcomes.

Tasks define work undertaken toward those outcomes.

---

# 34. Task State Layers

The framework SHALL distinguish:

```text
Task Definition
    persistent intent and provenance
         │
         ▼
Task Runtime State
    authoritative execution lifecycle
         │
         ▼
Effective Task
    derived execution view
```

These are separate concepts.

---

# 35. Task Definition

A Task Definition contains durable task intent.

Typical fields MAY include:

```text
identifier
revision
title
kind
component
requirements
depends_on
priority
acceptance
scope constraints
origin
created_by
parent_task
notes
```

A Task Definition SHALL NOT directly control authoritative lifecycle state.

---

# 36. Task Runtime State

Task Runtime State SHALL be maintained by the harness.

It MAY include:

```text
state
active_agent
current_workspace
current_failure
current_verification
blocking_reasons
last_result
next_action
generation
```

Users and agents SHALL NOT directly write lifecycle state fields as arbitrary data.

State transitions SHALL go through Task Management.

---

# 37. Ready Is Derived

`ready` SHALL be a derived execution condition, not an independently authoritative stored lifecycle state.

A task is ready when:

- its authoritative state is `accepted`;
- all required dependencies are complete;
- no blocking condition remains;
- required project state exists;
- policy permits execution;
- required resources are available if resource gating is enabled.

The harness MAY cache readiness but SHALL be able to recompute it.

Presentation commands MAY display `[ready]` as if it were a state.

An event such as `Task_Became_Ready` MAY be emitted when readiness changes from false to true.

---

# 38. Effective Task

The Effective Task is a derived execution view.

It MAY include:

```text
resolved task definition
resolved runtime state
readiness
applicable requirement revisions
applicable decisions
derived permissions
verification profile
relevant symbols
relevant source
relevant tests
context policy
workspace policy
completion gates
resource policy
```

The Effective Task is not independently authored.

It SHOULD have a deterministic fingerprint.

---

# 39. Task Identifier Allocation

Every candidate or accepted persistent task SHALL receive a stable identifier when created.

Identifiers therefore exist before acceptance.

The harness SHALL allocate and validate identifiers centrally.

Agents SHALL NOT create unregistered identifiers as authoritative task IDs.

---

# 40. Typical Task Definition

A typical task SHOULD remain compact.

```text
TASK-PARSER-021

title:
  Implement invalid UTF-8 rejection

kind:
  implementation

component:
  parser

requirements:
  - REQ-PARSER-017

depends_on:
  - TASK-UTF8-004
```

Derived files, symbols, tests, decisions, and readiness SHALL NOT be duplicated if the harness can calculate them reliably.

---

# 41. Task Kinds

Task kinds SHALL be defined by resolved project configuration.

Examples MAY include:

```text
implementation
bugfix
test
documentation
analysis
specification
refactor
integration
verification
```

The core SHALL NOT depend on these exact names.

---

# 42. Task-Kind Schemas

Each task kind MAY define:

```text
required fields
optional fields
default permissions
maximum permissions
verification profile
workspace policy
completion gates
child-agent policy
task-proposal policy
resource policy
```

Custom task fields SHALL have explicit schema definitions.

Arbitrary opaque fields SHALL NOT be assumed to have execution semantics.

---

# 43. Task Acceptance Criteria

Requirement acceptance criteria SHOULD NOT be duplicated unnecessarily.

A task MAY reference requirement criteria:

```text
acceptance:
  from_requirements
```

Task-local criteria SHOULD only describe conditions specific to that unit of work.

---

# 44. Task Creation Sources

Tasks MAY originate from:

1. deterministic requirement derivation;
2. explicit user creation;
3. LLM proposal;
4. decomposition of another task;
5. deterministic project events;
6. verification events;
7. import from an existing project source.

Every task SHALL record provenance.

---

# 45. Task Provenance

A task SHALL record:

```text
created_by
origin
```

Examples:

```text
created_by:
  user
```

```text
created_by:
  requirement_derivation

origin:
  REQ-PARSER-017@4
```

```text
created_by:
  agent AG-4

origin:
  TASK-PARSER-021
```

```text
created_by:
  verification_engine

origin:
  VER-2041
```

---

# 46. Candidate and Accepted Semantics

`candidate` means:

> a proposed persistent task that is not approved for execution.

`accepted` means:

> a task approved as valid project work.

`ready` is a derived condition over an accepted task.

Thus:

```text
candidate
    ↓ approval
accepted
    ↓ prerequisites satisfied
ready = true
```

These meanings SHALL be consistent across all commands and subsystems.

---

# 47. Task Lifecycle State Machine

The default authoritative task states are:

```text
candidate
accepted
running
blocked
verification
complete
failed
cancelled
rejected
```

The default valid transitions are:

```text
candidate    -> accepted
candidate    -> rejected

accepted     -> running
accepted     -> blocked
accepted     -> cancelled

blocked      -> accepted
blocked      -> cancelled
blocked      -> failed

running      -> verification
running      -> blocked
running      -> failed
running      -> cancelled

verification -> complete
verification -> running
verification -> blocked
verification -> failed
verification -> cancelled

failed       -> accepted
failed       -> cancelled

complete     -> accepted      only through explicit reopen policy
cancelled    -> accepted      only through explicit reopen policy
rejected     -> candidate     only through explicit reconsideration policy
```

Projects MAY restrict or extend these transitions.

Any extension SHALL define semantics and completion behavior.

Invalid transitions SHALL fail without changing authoritative state.

---

# 48. Task Transition Preconditions and Side Effects

Every transition SHALL define:

```text
initiating actor or event
preconditions
authoritative changes
derived invalidations
events emitted
resource consequences
child-agent consequences
workspace consequences
```

Examples:

## accepted -> running

Requires:

- task is ready;
- execution permission exists;
- required workspace is available;
- no exclusive lock conflict exists.

Effects:

- creates or assigns execution agent;
- creates workspace where required;
- records start generation;
- emits `Task_Started`.

## running -> verification

Requires:

- implementation agent returned a valid completion claim;
- required changes are present;
- no unresolved blocking issue exists.

Effects:

- releases or pauses implementation agent according to policy;
- starts verification;
- records verification reference;
- emits `Task_Verification_Started`.

## verification -> complete

Requires:

- all configured completion gates pass.

Effects:

- records final result references;
- closes task execution generation;
- emits `Task_Completed`;
- triggers requirement-verification reevaluation.

---

# 49. Failure, Retry, and Reopen Semantics

`failed` means the current execution attempt failed in a way that ended that attempt.

It does not mean the underlying project work is permanently invalid.

A retry SHALL normally use:

```text
failed -> accepted
```

after the failure has been acknowledged or retry policy authorizes automatic reset.

The next execution creates a new execution generation.

Historical failed attempts SHALL remain recorded.

A completed, cancelled, or rejected task MAY only be reopened through explicit policy or user action.

Reopen SHALL preserve historical execution records.

---

# 50. Deterministic Task Derivation

When task creation is mechanically derivable, the harness MAY create a task without an LLM.

Example:

```text
REQ-PARSER-017
component: parser
implementation_required: true
```

may derive:

```text
TASK-PARSER-021

title:
  Implement REQ-PARSER-017

kind:
  implementation

component:
  parser

requirements:
  - REQ-PARSER-017
```

Deterministic derivation SHALL use stable duplicate-detection keys where possible.

Replaying the same derivation event SHALL NOT create duplicate tasks.

---

# 51. Automatic Acceptance Policy

Deterministic derivation and automatic acceptance are separate.

A derived task SHALL become:

```text
candidate
```

unless resolved project policy explicitly permits automatic acceptance for that task class.

Automatic acceptance SHALL be auditable.

Readiness is always calculated separately.

---

# 52. Ambiguous Task Decomposition

The harness SHALL NOT invent work boundaries when those boundaries require design judgment.

It SHALL instead:

- create separate candidates only when boundaries are deterministic;
- invoke a reasoning agent to propose decomposition;
- or request human selection.

Reasoning-generated decomposition SHALL be treated as proposal data until accepted according to policy.

---

# 53. User-Created Tasks

Users SHALL be able to create tasks via:

```text
/task new
```

In an interactive terminal, the form SHALL be driven by the task-kind schema from resolved project configuration.

The command SHALL NOT hardcode task kinds or fields.

The shorthand:

```text
/task new "Fix parser EOF classification"
```

SHOULD use the supplied title and request only missing required fields.

---

# 54. LLM-Proposed Tasks

LLMs MAY propose tasks during bootstrap, planning, analysis, or active development.

Unless policy explicitly permits automatic acceptance, such tasks SHALL begin as `candidate`.

An agent SHALL require:

```text
propose_tasks
```

permission to propose persistent tasks.

Without that permission, discovered additional work SHALL be returned as an issue rather than persisted as a task proposal.

---

# 55. Task Approval

Candidate tasks SHALL be manageable using:

```text
/task accept <id>
/task reject <id>
```

Acceptance and rejection SHALL be auditable.

If generic commands are provided:

```text
/accept
/reject
```

they SHALL operate only on the currently active unique pending proposal shown by the harness.

They SHALL refuse ambiguous use.

---

# 56. Parent and Child Tasks

Persistent task decomposition MAY create child tasks.

Each child SHALL record its parent.

When a task is fully decomposed into required child tasks, the parent SHALL normally become blocked with a reason referencing those children.

A project MAY instead define a coordination-task policy, but this SHALL be explicit.

The parent SHALL NOT remain independently executable if all of its implementation work has been delegated to required children.

A parent SHALL NOT become complete solely because children are complete.

Its own completion gates SHALL still be evaluated.

---

# 57. Task vs Agent

A task:

- is persistent;
- represents project work;
- has a project lifecycle;
- may survive multiple sessions;
- may be executed by multiple agents over time.

An agent:

- is an execution entity;
- may be temporary;
- executes a task or subproblem;
- has an execution lifecycle;
- does not define persistent project intent.

---

# 58. Child Agent vs Child Task

A child agent is appropriate for:

- temporary analysis;
- bounded investigation;
- review;
- exploration;
- immediate subproblem execution.

A child task is appropriate for:

- persistent work;
- independently schedulable work;
- work with dependencies;
- separately verifiable work;
- work that may outlive the current agent.

Agents SHALL NOT silently enlarge persistent task scope.

If additional persistent work is discovered, the agent SHALL propose a task when permitted or report an issue.

---

# 59. Task Dependencies

Dependencies SHALL be recorded where known.

Deterministically known dependencies MAY be created automatically.

Reasoning-dependent dependencies SHALL be proposed rather than asserted.

Cycles SHALL be rejected.

Dependency satisfaction SHALL be calculated without an LLM.

Dependency discovery MAY use reasoning when not mechanically derivable.

---

# 60. Scoped Permission Model

Permissions SHALL be capabilities with optional scope, not merely Boolean flags.

Possible capabilities include:

```text
read_source
write_source
read_specs
write_specs
run_build
run_tests
run_static_analysis
create_children
propose_tasks
request_integration
use_network
execute_external_process
```

A permission MAY include constraints such as:

```text
write_source:
  roots:
    - src/parser/
  deny:
    - src/security/

run_tests:
  profiles:
    - parser
    - quick

create_children:
  max_depth: 1
  max_children: 2
```

Effective permissions are the intersection of:

```text
project maximum
task-kind maximum
task-local restriction
agent-role restriction
runtime sandbox restriction
```

Task-local configuration SHALL NOT widen permissions beyond higher-authority maximums.

Least privilege SHALL be the default.

---

# 61. Process Execution Policy

All external process execution SHALL pass through the harness execution layer.

Execution policy SHOULD support:

```text
allowed executable or adapter class
working-directory constraints
environment filtering
stdin policy
stdout/stderr limits
timeout
cancellation
network permission
shell-vs-direct execution policy
resource limits
command provenance
```

Build and test adapters MAY expand a trusted configured command graph.

An agent SHALL NOT gain arbitrary shell authority merely because it has permission to run a build or test.

Raw process output SHALL remain retrievable.

---

# 62. Repository Engine

The Repository Engine SHALL maintain structured knowledge of:

- files;
- languages;
- components;
- symbols;
- dependencies;
- references;
- tests;
- modifications;
- generated files.

Semantic support SHALL use language adapters.

```text
Repository Engine
    │
    ├── Ada
    ├── C
    ├── Rust
    ├── Python
    └── generic fallback
```

---

# 63. Ada Semantic Adapter

Ada SHALL be the initial first-class semantic implementation.

It SHOULD use Libadalang or equivalent tooling and understand:

- compilation units;
- packages;
- child packages;
- subprograms;
- types;
- interfaces;
- generics;
- generic instantiations;
- dependencies;
- calls;
- references;
- overriding operations.

The adapter SHALL report unsupported or uncertain relationships rather than pretending certainty.

---

# 64. Repository Relationship Provenance

Derived repository relationships SHOULD carry:

```text
derivation_source
confidence
```

Recommended derivation sources:

```text
explicit
semantic_analysis
build_metadata
naming_convention
heuristic
```

Recommended confidence levels:

```text
authoritative
certain
probable
uncertain
```

Policy MAY use confidence to determine verification escalation.

---

# 65. Symbol Queries

The harness SHALL support deterministic symbol lookup.

Example:

```text
/sym Parser.Parse_Value
```

This SHALL normally require no LLM invocation.

Reference queries SHOULD use:

```text
/refs <symbol>
```

---

# 66. Change-Impact Analysis

The harness SHOULD determine:

```text
changed symbols
direct dependents
transitive dependents
affected components
affected requirement revisions
affected tasks
affected tests
affected specifications
```

Every non-explicit impact edge SHOULD preserve derivation provenance and confidence.

Uncertain relationships SHALL remain marked as uncertain.

---

# 67. Test Registry and Affected-Test Selection

Tests MAY be linked to:

- requirements;
- tasks;
- components;
- symbols;
- features.

Associations MAY be explicit or derived.

Explicit associations SHALL take precedence.

Verification policy SHALL determine escalation.

Example:

```text
certain affected tests
        ↓
component tests
        ↓
full suite
```

Uncertainty SHOULD cause broader verification rather than narrower verification.

There SHALL NOT be one universal pipeline for every task kind.

---

# 68. Traceability Model

Traceability SHALL be a graph.

Relationships are many-to-many unless explicitly constrained.

Node types MAY include:

```text
requirement revision
task
component
symbol
source file
test
decision revision
verification evidence
result
configuration revision
```

Edges SHALL distinguish explicit from derived provenance.

Example:

```text
REQ-PARSER-017@4
      │
      ├────► TASK-PARSER-021
      │           │
      │           └────► Parser.Validate_UTF8
      │
      ├────► TEST-PARSER-042
      │
      └────► VER-2041
```

A traceability edge SHOULD record:

```text
origin
confidence
created_at
source_record
```

where meaningful.

---

# 69. Consistency Engine

The harness SHALL detect inconsistencies including:

```text
undefined requirement
duplicate identifiers
unknown task reference
unknown parent task
cyclic task dependency
cyclic parent relationship
accepted task with invalid kind
task treated as ready with incomplete dependency
complete task with failed required gate
task linked to missing component
invalid custom task field
invalid permission widening
traceability to missing symbol
conflicting authoritative specification
stale verification treated as current
workspace assignment conflict
schema mismatch
incomplete transaction
```

Consistency checking SHALL be runnable without an LLM.

---

# 70. Generated Metadata and Indexes

The harness MAY generate:

```text
requirements.index
tasks.index
decisions.index
components.index
symbols.index
tests.index
traceability.index
dependency.index
search.index
```

Indexes are derived metadata.

They SHALL NOT be authoritative when reconstructable.

Whether indexes are committed, ignored, or cached is project policy.

---

# 71. Context Engine

Context SHALL be constructed from:

```text
system rules
resolved project configuration
effective task
requirements
decisions
specification fragments
symbols
source excerpts
tests
runtime state
selected results
```

Context construction SHALL be deterministic given:

```text
project revision state
effective task
model profile
context policy
retrieval/index state
```

When a semantic index is unavailable, the Context Engine MAY use a generic textual fallback and SHALL record that reduced capability in the context manifest.

---

# 72. Token Budgeting

The harness SHALL account for:

```text
context limit
reserved output
mandatory context
optional context
tool overhead where relevant
```

Context items SHALL have priorities.

Low-priority data SHALL be dropped before critical data.

The harness SHOULD reserve sufficient output space for the requested task class.

A context build that cannot fit mandatory content SHALL fail explicitly or invoke a configured reduction policy rather than silently omit mandatory state.

---

# 73. Context Deduplication

Equivalent inherited rules SHALL appear once.

Resolved configuration SHOULD reference reusable policy rather than duplicate verbose material.

Repeated source excerpts SHOULD be coalesced where this does not remove required provenance.

---

# 74. Context Manifest

Every model invocation SHALL reference a Context Manifest.

The manifest SHALL record at least:

```text
context_manifest_id
fingerprint
task
task execution generation
model profile
included source/result identifiers
applicable requirement revisions
applicable decision revisions
configuration revision
priority decisions
truncation decisions
excluded candidate items and reason, where useful
estimated token cost
```

The manifest allows model behavior to be audited without treating conversation history as authoritative state.

The full rendered context MAY be retained according to storage policy.

---

# 75. Model Capability Profiles

A model profile SHALL describe relevant capabilities and constraints, including where known:

```text
model identifier
provider
context limit
recommended output reserve
tool support
structured-output support
reasoning mode
streaming support
parallel-call support
cost or local resource class
```

Profiles SHALL be resolved independently of task content.

The Context Engine SHALL use the selected model profile when budgeting.

---

# 76. Model Invocation

A model invocation is an execution record distinct from an agent and a task.

It SHALL record:

```text
invocation_id
agent_id
task_id if any
execution generation
model profile
context manifest
tool policy
structured result contract
start/end state
usage
result reference
failure reference
cancellation state
```

Model invocations are historical records.

A retry SHALL create a new invocation record.

A model invocation SHALL NOT directly modify authoritative project state.

It returns structured claims or proposed changes that the harness validates.

---

# 77. Agent Lifecycle

Agents are harness-managed execution entities.

An agent record SHOULD include:

```text
agent_id
role
parent_agent
task
execution generation
permissions
workspace
status
active invocation
children
resource budget
result
```

Default agent statuses MAY include:

```text
created
running
waiting
completed
failed
cancelled
```

Agent lifecycle SHALL be distinct from task lifecycle.

---

# 78. Agent Claims

Agents MAY return structured claims such as:

```text
implementation_complete
blocked
verification_requested
task_proposal
decision_proposal
specification_proposal
issue
```

The harness SHALL validate these claims and perform authoritative state transitions.

A malformed or unauthorized claim SHALL be rejected or converted into a non-authoritative issue.

---

# 79. Recursive Agents

The harness SHALL control:

```text
maximum recursion depth
maximum children
maximum active agents
token budget
tool budget
workspace policy
permissions
wall-clock or execution budget
```

Children SHALL receive newly constructed contexts.

They SHALL NOT automatically inherit:

- parent transcripts;
- sibling transcripts;
- unrelated results;
- unrelated requirements;
- raw historical logs.

---

# 80. Child Ownership and Completion

Every child agent SHALL have one owning parent agent or root controller.

The parent SHALL know whether each child is:

```text
required
optional
advisory
```

A parent SHALL NOT claim successful completion while a required child remains active unless policy explicitly permits detached execution.

Child results SHALL be structured.

The full child transcript SHALL normally remain outside parent context.

---

# 81. Child Failure Semantics

If a required child fails, the parent SHALL receive a structured failure result.

Policy SHALL determine whether the parent may:

- retry the child;
- continue with another strategy;
- block the task;
- fail the current execution generation.

Optional or advisory child failure SHALL not automatically fail the parent.

A child failure SHALL never silently disappear.

---

# 82. Cancellation Semantics

Cancellation SHALL distinguish:

```text
foreground operation cancellation
model invocation cancellation
agent cancellation
persistent task cancellation
```

Bare:

```text
/cancel
```

SHOULD cancel the current foreground operation or active invocation associated with the interactive session.

Persistent task cancellation SHALL use:

```text
/task cancel <id>
```

or an equivalent explicit task-management operation.

Cancelling an agent SHALL NOT automatically cancel the task unless policy explicitly maps the event to a task transition.

Parent-agent cancellation SHALL propagate to active child agents by default unless they are explicitly detached.

Cancellation requests SHALL be persisted when they affect authoritative runtime state.

---

# 83. Workspace Isolation

Concurrent write agents SHALL operate in isolated workspaces.

Read-only agents MAY share repository state where safe.

A workspace record SHALL identify:

```text
workspace_id
base revision
owning agent
owning task
execution generation
path or backend identity
status
```

A write workspace SHOULD be based on an immutable or stable baseline.

The default Git implementation SHOULD use worktrees where practical.

---

# 84. Workspace Integration

Integration SHALL be a harness-managed operation.

The harness SHALL manage:

- baseline validation;
- workspace changes;
- conflict detection;
- integration;
- semantic conflict escalation;
- post-integration verification.

An agent with write permission SHALL NOT automatically gain integration permission.

Integration MAY require:

```text
request_integration
```

or higher authority.

Post-integration verification SHALL operate on the integrated target state, not only the isolated workspace.

---

# 85. Result Store

Significant outputs SHALL be persisted as immutable result objects.

Possible result types include:

```text
analysis
implementation
verification
diagnostic
decision_proposal
task_proposal
impact_report
integration_report
child_result
context_report
bootstrap_report
```

A result SHALL have:

```text
result_id
type
producer
created_at
summary
payload or payload reference
provenance
```

Large payloads MAY be stored separately from compact metadata.

Result objects MAY reference other result objects.

Task Runtime State SHOULD reference results by identifier rather than duplicate large content.

---

# 86. Result Retention

Result retention policy SHALL distinguish:

```text
required historical evidence
debug/audit results
cache-like results
large raw logs
```

Verification evidence referenced by completed work SHALL NOT be garbage-collected while it remains required for auditability.

Derived caches MAY be evicted.

Raw logs MAY have configurable retention provided normalized diagnostics and required evidence remain available.

---

# 87. Deterministic Execution

The harness SHALL own routine:

- builds;
- tests;
- formatting;
- static analysis;
- generators;
- Git inspection;
- indexing.

Successful deterministic stages SHALL not cause unnecessary model turns.

Unexpected failures MAY trigger reasoning only after structured diagnostics have been produced.

---

# 88. Verification Profiles

Verification profiles SHALL come from resolved project configuration.

Examples MAY include:

```text
quick
component
full
documentation
analysis-only
```

Names are project-defined.

A profile SHALL define ordered or dependency-structured checks.

Checks MAY declare:

```text
required
optional
retry policy
timeout
failure severity
evidence retention
```

---

# 89. Automatic Verification

After source changes, the harness SHALL select the applicable pipeline from the Effective Task.

Example:

```text
source edit
   ↓
effective verification profile
   ↓
impact/test selection
   ↓
configured checks
```

Affected-test selection SHALL honor relationship confidence and escalation policy.

Automatic verification SHALL not require a model unless interpretation of an unexpected failure is needed.

---

# 90. Diagnostic Normalization

Tool output SHOULD be converted into structured diagnostics.

A diagnostic SHOULD identify, where available:

```text
tool
severity
code
message
file
line
column
symbol
related locations
raw output reference
```

Raw logs SHALL remain retrievable.

---

# 91. Verification Evidence

Verification evidence SHALL record:

```text
verification_id
task
task execution generation
repository revision
workspace revision
configuration revision
configuration fingerprint
profile
checks performed
results
tool versions
adapter versions
environment fingerprint
start time
end time
invocation parameters
```

Evidence is immutable historical state.

---

# 92. Verification Applicability

Historical evidence is not automatically current evidence.

Current applicability SHALL be derived using at least:

```text
repository revision relationship
configuration fingerprint
requirement revision
verification profile
toolchain policy
affected scope
```

A project MAY allow evidence reuse across revisions only when policy can prove or conservatively establish applicability.

If applicability is invalidated, requirement/task verification state SHALL be reevaluated.

---

# 93. Completion Gates

Task completion SHALL be determined by configured gates.

Examples:

```text
implementation present
required verification passes
traceability sufficient
documentation current
no blocking issue
integration complete where required
```

The agent's own completion claim SHALL NOT be authoritative.

A task SHALL transition to `complete` only through Task Management after all required gates pass.

---

# 94. Requirement Verification

Completing a task SHALL NOT automatically mark linked requirements verified.

Requirement verification SHALL depend on:

- current implementation traceability;
- applicable requirement revision;
- applicable acceptance criteria;
- current verification evidence;
- project verification policy.

A task may be complete while a requirement remains implemented but unverified.

When a requirement becomes verified, the harness SHALL record the supporting evidence references and emit `Requirement_Verified`.

---

# 95. LLM Call Avoidance

The harness SHOULD avoid LLM calls for:

```text
template discovery
configuration lookup
task readiness
dependency satisfaction calculation
symbol lookup
reference lookup
test selection when derivable
Git status
build execution
test execution
requirement lookup
traceability lookup
schema validation
state transitions
consistency checks
```

Dependency discovery, semantic conflict resolution, debugging, architecture, and ambiguous decomposition MAY require reasoning.

---

# 96. Slash Commands

Core commands SHALL include:

```text
/init
/init <template-id>

/bootstrap

/task
/task new
/task new <title>
/task accept <id>
/task reject <id>
/task cancel <id>

/work
/work <selector>

/state
/tree

/req <id>
/trace <id>
/sym <symbol>
/refs <symbol>
/impact <symbol|file>

/check
/check full

/result <id>

/cancel

/accept
/reject
```

A configuration command SHOULD be added before implementation freeze, for example:

```text
/config
/reconfigure
```

Exact spelling MAY be finalized with the command subsystem.

---

# 97. `/task` Semantics

`/task` is the persistent task-management interface.

It SHOULD display or filter by:

```text
candidate
accepted
ready
running
blocked
verification
complete
failed
cancelled
rejected
```

`ready` in this UI is derived.

Filtering SHOULD support:

```text
state
readiness
kind
component
requirement
origin
parent
```

---

# 98. `/work` Semantics

`/work` is the task-execution interface.

It SHALL primarily present accepted tasks whose readiness is true.

Blocked tasks MAY be shown for inspection but SHALL NOT be executable unless explicit override policy permits it.

Candidate, rejected, cancelled, and completed tasks SHALL not appear as normal executable work.

In an interactive TTY:

```text
Select work:

  ▸ [ready]   TASK-PARSER-021   Invalid UTF-8 rejection
    [ready]   TASK-CONFIG-014   Environment overrides
    [blocked] TASK-IO-031       Partial stream reads

↑/↓ move   Enter select   / filter   Tab details   Esc cancel
```

Selecting a blocked task SHALL show its blocking reason rather than start it by default.

Even if only one ready task exists, interactive `/work` SHOULD still show the selector unless project policy explicitly enables automatic single-item selection.

---

# 99. `/work <selector>`

An exact task identifier SHALL start the selected ready task directly.

A textual selector MAY:

- resolve uniquely;
- or open a filtered selector.

Ambiguous non-interactive selection SHALL fail and return candidate matches.

---

# 100. Non-Interactive Command Behavior

Interactive selectors SHALL only be used on interactive TTYs.

In non-interactive mode:

```text
/init
/task
/work
```

SHALL return deterministic plain or structured output rather than attempting terminal UI.

Commands requiring selection SHALL require an explicit selector.

Structured output format SHOULD be configurable and stable enough for automation.

---

# 101. Terminal UI Requirements

Reusable terminal controls SHALL support:

```text
selection
filtering
details
paging
resize
cancel
terminal restoration
```

They SHALL work through SSH and tmux.

The harness, not the LLM, SHALL manage terminal state.

Terminal restoration SHALL occur after normal completion, cancellation, and recoverable errors.

---

# 102. Project Status

The harness SHOULD provide status without an LLM.

Example:

```text
Template provenance: Ada CLI Application
Config revision:      7
Requirements:         142
Verified:             118
Candidate tasks:      3
Accepted tasks:       2
Ready tasks:          6
Blocked tasks:        2
Running tasks:        1
Agents active:        2
Last full test:       PASS
```

Status SHALL derive counts from authoritative and reconstructable state consistently.

---

# 103. Typical Greenfield Flow

```text
$ model_runner
> /init
```

The user selects an installed template.

The harness creates the first Resolved Project Configuration revision.

If required:

```text
> /bootstrap
```

Bootstrap discovers/imports/proposes specification state.

Accepted requirements trigger normal task derivation.

The user manages candidates:

```text
> /task
```

Then selects executable work:

```text
> /work
```

The harness:

```text
constructs Effective Task
      ↓
creates Context Manifest
      ↓
starts Agent
      ↓
creates isolated workspace when required
      ↓
invokes model
      ↓
validates returned claims/changes
      ↓
runs verification
      ↓
integrates if required
      ↓
runs post-integration verification
      ↓
evaluates completion gates
      ↓
completes task
      ↓
reevaluates linked requirements
```

---

# 104. Typical Existing Project Flow

```text
> /init
```

The user selects an installed existing-project template.

The template defines deterministic discovery behavior.

Initialization produces the Resolved Project Configuration.

If bootstrap analysis is required:

```text
> /bootstrap
```

Bootstrap classifies discoveries and proposals explicitly.

Accepted requirements and events then drive ordinary task derivation.

---

# 105. Typical Task Creation Flow

Requirement revision accepted:

```text
REQ-PARSER-017@4
```

Task policy derives:

```text
TASK-PARSER-021
state: candidate
```

If automatic acceptance is disabled:

```text
> /task accept TASK-PARSER-021
```

The task becomes:

```text
state: accepted
```

The harness computes readiness.

When prerequisites are satisfied:

```text
ready = true
```

The task becomes selectable through `/work`.

---

# 106. Typical Agent-Discovered Work

While executing a task, an agent discovers unrelated work.

If it has `propose_tasks`, it returns:

```text
task_proposal:
  title: Correct parser error positions
  kind: bugfix
  component: parser
```

The harness validates the proposal and creates a candidate task.

The current task's scope does not silently expand.

---

# 107. Failure Recovery

Project recovery SHALL NOT require conversation reconstruction.

Recovery SHALL use persisted:

```text
resolved project configuration
configuration history
task definitions
task runtime state
repository state
requirements
decisions
events
stored results
verification evidence
agent/workspace runtime records
transaction journal
```

On startup, the harness SHALL:

1. validate state root format;
2. recover or reject incomplete transactions;
3. detect stale runtime leases;
4. classify abandoned agents or invocations;
5. reconcile workspaces;
6. rebuild missing reconstructable indexes;
7. reevaluate readiness and current verification applicability;
8. report unresolved recovery actions.

A crashed `running` task SHALL NOT remain indefinitely running without an active execution owner.

Policy SHALL define whether it becomes blocked, failed, or accepted-for-retry after recovery.

---

# 108. Concurrency

The harness SHALL define one authoritative concurrency policy.

Concurrent read-only operations MAY execute freely subject to resource limits.

Concurrent authoritative writes SHALL use transactions and conflict detection.

Concurrent write agents SHALL use isolated workspaces.

The scheduler SHALL prevent two execution entities from holding mutually exclusive project resources where policy forbids it.

Runtime ownership SHOULD use leases or equivalent crash-detectable records rather than unbounded permanent locks.

---

# 109. Resource Accounting

The harness SHOULD account for:

```text
active agents
model invocations
token budgets
tool budgets
process slots
workspace slots
memory/resource class where known
```

Recursive execution SHALL never bypass root project limits.

Resource exhaustion SHALL result in a deterministic blocked/waiting condition or execution failure according to policy, not uncontrolled recursive spawning.

---

# 110. Performance

Indexes SHOULD update incrementally.

Commands such as:

```text
/init
/task
/work
/state
/req
/trace
/sym
/impact
```

SHOULD not require an LLM unless their semantics genuinely require reasoning.

Startup SHOULD avoid rebuilding reconstructable indexes that are valid and current.

Large result payloads SHOULD be loaded lazily.

---

# 111. Security Boundary

The framework does not assume a hostile local user, but it SHALL maintain architectural boundaries suitable for least-privilege agent execution.

At minimum:

- agent permissions are validated by the harness;
- process execution is centralized;
- environment exposure is controlled;
- secret values are not injected into model context unless authorized;
- workspace roots are enforced;
- tool calls are attributable to agents and invocations;
- model output cannot directly bypass state validation.

Future sandbox backends MAY provide OS-level isolation without changing task semantics.

---

# 112. Implementation Phases

Implementation SHALL prioritize a complete reliable single-agent workflow before recursive execution.

## Phase A — Foundational State and Schemas

Implement:

- project identity;
- state root;
- schema system;
- stable identifiers;
- revisions;
- atomic persistence;
- transaction journal;
- Result Store foundation;
- project facts;
- startup recovery foundation.

Exit criterion:

> authoritative state can be created, committed, reopened, validated, and recovered without an LLM.

## Phase B — Templates and Resolved Configuration

Implement:

- template format;
- Template Registry;
- discovery;
- validation;
- composition;
- merge semantics;
- versioning;
- template-defined inputs;
- `/init`;
- Resolved Project Configuration generation;
- provenance;
- configuration fingerprints.

Exit criterion:

> a project can be initialized generically from a template and reopened without the template installed.

## Phase C — Event and Transition Core

Implement:

- transaction-coupled durable events;
- event identifiers;
- idempotent consumption;
- transition validation framework;
- consistency engine foundation;
- runtime ownership/lease foundation.

Exit criterion:

> authoritative transitions are atomic, auditable, and replay-safe.

## Phase D — Specifications, Requirements, and Decisions

Implement:

- specification identity/revisions;
- Requirement Registry;
- requirement lifecycle;
- invalidation;
- Decision Registry;
- authority resolution;
- conflict reporting;
- `/bootstrap` foundation.

Exit criterion:

> authoritative project intent exists independently of conversation history and supports revision-aware invalidation.

## Phase E — Task Management

Implement:

- Task Definition;
- Task Runtime State;
- Effective Task foundation;
- task registry;
- task identifiers;
- provenance;
- lifecycle transition matrix;
- derived readiness;
- dependencies;
- task schemas;
- `/task`;
- task creation;
- acceptance/rejection/cancellation;
- parent/child semantics;
- deterministic event-driven derivation.

Exit criterion:

> persistent work can be created, approved, blocked, retried, cancelled, and completed through validated state transitions.

## Phase F — Terminal Interaction

Implement reusable:

- selector;
- filtering;
- details panes;
- forms;
- TTY detection;
- non-interactive fallback;
- resize handling;
- terminal restoration.

Exit criterion:

> `/init`, `/task`, and later `/work` share one generic terminal UI layer.

## Phase G — Repository Foundation

Implement:

- repository inventory;
- generic language fallback;
- adapter interface;
- Ada semantic adapter;
- dependency graph;
- symbol queries;
- reference queries;
- relationship provenance/confidence.

Exit criterion:

> the harness can deterministically retrieve repository structure and Ada symbols without an LLM.

## Phase H — Context and Model Invocation

Implement:

- deterministic retrieval;
- Effective Task completion;
- context priorities;
- budgets;
- deduplication;
- Context Manifest;
- fingerprints;
- model capability profiles;
- Model Invocation records;
- structured result contracts.

Exit criterion:

> a model call is reproducible, inspectable, bounded, and independent of conversation history.

## Phase I — Minimal Verification Engine

Implement:

- process execution policy;
- build adapters;
- test adapters;
- static-analysis adapter interface;
- verification profiles;
- diagnostic normalization;
- evidence;
- evidence applicability;
- completion gates.

Exit criterion:

> changed source can be built/tested and task completion can be decided without model authority.

## Phase J — Single-Agent Work Execution

Implement:

- `/work`;
- root agent lifecycle;
- task execution generations;
- source modification flow;
- structured agent claims;
- cancellation;
- retry;
- verification transition flow;
- task completion;
- requirement reevaluation.

Exit criterion:

> one task can run end-to-end from ready through implementation, verification, and completion.

## Phase K — Workspace and Integration

Implement:

- isolated workspaces;
- Git worktree backend;
- baselines;
- workspace ownership;
- conflict detection;
- integration;
- integration permission;
- combined/post-integration verification.

Exit criterion:

> write execution can occur safely in isolation and integrate deterministically.

## Phase L — Advanced Traceability and Impact

Implement:

- full graph model;
- revision-aware traceability;
- provenance/confidence;
- impact analysis;
- affected-test selection;
- verification escalation;
- consistency checking expansion.

Exit criterion:

> change impact and verification scope are computed conservatively and traceably.

## Phase M — Recursive Agents

Implement:

- child agents;
- child ownership;
- delegation;
- recursive permissions;
- limits;
- resource accounting;
- child result contracts;
- failure propagation;
- cancellation propagation.

Exit criterion:

> recursive execution cannot bypass task scope, workspace isolation, resource limits, or authority rules.

## Phase N — Deterministic Orchestration and Scheduling

Implement:

- automation rules;
- event-driven scheduling;
- parallel task scheduling;
- resource-aware dispatch;
- automatic verification;
- automatic readiness transitions;
- LLM-call avoidance optimization.

Exit criterion:

> routine project progression requires model reasoning only where judgment is genuinely needed.

---

# 113. Initial Implementation Priority

Recommended implementation order:

1. persistence root and schema framework;
2. identifiers and revisions;
3. transaction/recovery layer;
4. Result Store foundation;
5. Resolved Project Configuration model;
6. Template Registry;
7. template composition;
8. `/init`;
9. durable event infrastructure;
10. specification/requirement/decision registries;
11. authority/conflict model;
12. Task Registry;
13. task lifecycle state machine;
14. derived readiness;
15. task schemas;
16. `/task`;
17. deterministic task derivation;
18. terminal selector/form framework;
19. repository inventory;
20. Ada semantic adapter;
21. Context Engine;
22. Context Manifest;
23. model capability profiles;
24. Model Invocation abstraction;
25. deterministic process execution;
26. minimal verification engine;
27. `/work`;
28. single-agent execution lifecycle;
29. completion gates;
30. workspace isolation;
31. deterministic integration;
32. traceability graph;
33. impact analysis;
34. affected-test selection;
35. recursive-agent controller;
36. parallel scheduling and advanced orchestration.

Recursive agents SHALL NOT be enabled for write execution before workspace isolation and the complete single-agent verification path are operational.

---

# 114. Acceptance Milestones

The implementation SHOULD be developed against milestone-level acceptance criteria.

## Milestone 1 — Durable project state

Pass when:

- initialization state survives restart;
- interrupted writes cannot silently corrupt authoritative state;
- schemas are validated;
- derived indexes can be deleted and rebuilt.

## Milestone 2 — Requirements and tasks

Pass when:

- requirement revisions are persistent;
- task derivation is idempotent;
- task transitions reject illegal state changes;
- readiness is derived correctly;
- dependency cycles are rejected.

## Milestone 3 — Single-agent execution

Pass when:

- `/work` selects a ready task;
- a Context Manifest is produced;
- the model invocation is recorded;
- changes are verified;
- completion gates determine task completion;
- restart does not require transcript reconstruction.

## Milestone 4 — Isolated integration

Pass when:

- write work executes in an isolated workspace;
- integration detects conflicts;
- post-integration verification executes against the integrated state.

## Milestone 5 — Recursive execution

Pass when:

- children receive isolated contexts;
- permissions cannot widen;
- recursion/resource limits are enforced;
- cancellation propagates;
- required-child failures are visible;
- child transcripts are not automatically injected into parents.

---

# 115. Testing Requirements

The framework implementation SHALL include tests for deterministic core semantics.

At minimum:

- schema validation;
- serialization round-trip;
- transaction interruption recovery;
- duplicate event replay;
- template composition conflicts;
- configuration fingerprint stability;
- requirement revision invalidation;
- task transition matrix;
- readiness recomputation;
- dependency cycle detection;
- task derivation idempotency;
- permission intersection;
- context-manifest determinism;
- cancellation propagation;
- workspace ownership;
- verification applicability;
- stale evidence invalidation;
- consistency checks;
- terminal restoration after cancellation.

Property-based or generated tests SHOULD be used where practical for state-machine and graph invariants.

---

# 116. Auditability

For any completed task, the harness SHOULD be able to answer deterministically:

```text
What requirement revisions applied?
What task definition revision applied?
Why was the task considered executable?
What decisions applied?
What context did the model receive?
Which model/profile was invoked?
What files changed?
Which workspace produced them?
What verification ran?
Which tool versions ran?
Which evidence justified completion?
Which integration produced the final repository state?
Which requirement verification changed as a consequence?
```

These answers SHALL be derived from project state, manifests, evidence, results, and events rather than reconstructed from chat history.

---

# 117. Implementation Constraint

No feature SHALL shift deterministic bookkeeping back onto the model.

In particular, the model SHALL NOT be responsible for:

- enumerating project types;
- remembering live template defaults;
- maintaining project configuration;
- allocating task identifiers;
- changing authoritative task lifecycle state;
- calculating readiness;
- maintaining dependency bookkeeping;
- maintaining traceability indexes;
- selecting mechanically affected tests;
- parsing routine diagnostics;
- managing terminal UI state;
- deciding whether a committed transition is legal;
- preserving persistence consistency;
- assigning event identifiers;
- determining whether verification evidence is current;
- enforcing permission ceilings;
- recovering interrupted transactions.

---

# 118. Final Architectural Principle

The framework SHALL be built around:

```text
deterministic development harness
              +
          LLM reasoning
```

The primary lifecycle is:

```text
Project Template
      │
      ▼
Resolved Project Configuration
      │
      ▼
Accepted Specifications / Requirements
      │
      ▼
Task Derivation
      │
      ▼
Candidate Tasks
      │
      ▼
Accepted Tasks
      │
      ▼
Derived Readiness
      │
      ▼
/work
      │
      ▼
Effective Task
      │
      ▼
Context Manifest
      │
      ▼
Agent / Model Invocation
      │
      ▼
Isolated Changes
      │
      ▼
Harness Verification
      │
      ▼
Integration
      │
      ▼
Post-Integration Verification
      │
      ▼
Task Completion
      │
      ▼
Requirement Verification
```

Requirements define what must be true.

Tasks define persistent units of work.

Agents perform reasoning and execution.

Model invocations are bounded historical execution records.

The harness owns authority, state, orchestration, persistence, transitions, context construction, verification, recovery, isolation, and deterministic project intelligence.

That separation is the defining architectural rule of V3.
