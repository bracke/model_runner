# The settings file

Running the same command with the same flags every time? Put those flags'
values in a settings file and drop them from the command line.

## Where

The file is looked for, in order:

1. `MODEL_RUNNER_CONFIG`, if set — the path to the file, named outright.
2. `$XDG_CONFIG_HOME/model_runner/config`, if `XDG_CONFIG_HOME` is set.
3. `$HOME/.config/model_runner/config`.

A missing or unreadable file is simply no settings — never an error. Nothing
is ever written back.

## Format

One `key = value` a line. `#` begins a comment. Blank lines are ignored. A
key given twice keeps the first, as a flag given twice on the command line
is refused.

```
# ~/.config/model_runner/config
backend      = device
kv-cache     = q8
context-size = 4096
temperature  = 0.7
models-dir   = /srv/models
```

## Keys

Most keys are an **option name without the dashes**, and take the value that
option takes:

| key            | like the flag        | example        |
|----------------|----------------------|----------------|
| `backend`      | `--backend`          | `device`       |
| `kv-cache`     | `--kv-cache`         | `q8`           |
| `kv-values`    | `--kv-values`        | `q4`           |
| `threads`      | `--threads`          | `6`            |
| `context-size` | `--context-size`     | `4096`         |
| `max-tokens`   | `--max-tokens`       | `512`          |
| `temperature`  | `--temperature`      | `0.7`          |
| `top-k`        | `--top-k`            | `40`           |
| `top-p`        | `--top-p`            | `0.95`         |
| `repeat-penalty` | `--repeat-penalty` | `1.0`          |
| `paged`        | `--paged`/`--no-paged` | `true` / `false` |

A true/false value becomes the option's `--flag` or `--no-flag`.

Speech input is set the same way: `speech-model` (a Whisper GGUF; naming
one turns speech on), `speech-language` (`auto`, `en`, `da`, ...),
`speech-device`, `speech-max-seconds`, `speech-keep-loaded`,
`speech-initial-prompt`, `speech-enabled` (false turns it off where a model
is named) and `speech-shortcut` (`ctrl-g` unless said). Any option
the `run` command accepts works this way; a key the command does not take is
ignored.

Six keys are **not** options — a model, places, a secret and what the lists leave out:

| key            | falls back for                | env override           |
|----------------|-------------------------------|------------------------|
| `model`        | the model `model_runner` and `run` take when none is named, in place of the list to choose from: a path, an alias or a Hugging Face reference | — |
| `models-dir`   | where a bare model name is found and a download is kept | `MODEL_RUNNER_MODELS` |
| `sessions-dir` | where a bare session name is kept | `MODEL_RUNNER_SESSIONS` |
| `conversations-dir` | where conversations are kept as they go, for `--continue` and `--resume` | `MODEL_RUNNER_CONVERSATIONS` |
| `hf-token`     | the Hugging Face token for a gated repository | `HF_TOKEN` |
| `models-hide`  | models the lists to choose from leave out -- `run` without a model, `/model` in a conversation: name patterns, a space between them, `*` for any run of characters, matched to a file's name in any case (`models-hide = tinyllama* *-f32.gguf`) | — |

## Hooks

Two keys run a command of yours in a conversation that uses the tools, by
the host's shell in the session's folder:

| key | runs | what it says |
|-----|------|--------------|
| `hook.after-edit` | after each `write_file` or `edit_file` that ran; `$FILE` in it is the file's quoted path | put after the tool's answer, so the model reads it too |
| `hook.after-turn` | after each turn with the tools | shown; where it fails, the model is told with the next message |

```
hook.after-edit = gnatpp $FILE
hook.after-turn = alr build
```

## Code Health

Native Code Health can check files changed by an agent in an ordinary
conversation. It is disabled by default; generated spec-driven Ada projects
carry their own authoritative project policy instead.

| key | default | meaning |
|-----|---------|---------|
| `code-health.enabled` | `false` | enable native Code Health for the conversation |
| `code-health.on-edit` | `true` | return an immediate assessment after filesystem changes |
| `code-health.fast-profile` | `ada-fast` | profile named on immediate assessments |
| `code-health.focused-profile` | `ada-focused` | focused profile name |
| `code-health.focused-test` | empty | reliable root-directory test command for focused checks |
| `code-health.max-stagnant` | `3` | repair assessments without material progress |
| `code-health.max-assessments` | `12` | total assessments in one remediation sequence |
| `code-health.feedback-limit` | `8192` | most model-facing feedback, in bytes |
| `code-health.fast-deadline` | `10` | fast assessment deadline, in seconds |
| `code-health.focused-deadline` | `120` | focused assessment deadline, in seconds |

The limits are validated before the conversation starts. An unknown
`code-health.*` key, malformed value, zero deadline, or stagnant limit greater
than the assessment limit is an error rather than a silent change in
enforcement. A mandatory check that cannot run is reported as unavailable and
does not pass completion.

Setting `code-health.on-edit = false` suppresses immediate post-edit checks;
it does not disable the completion gate. The final-answer boundary reconciles
the actual tree against the task baseline and runs the focused assessment.

Enabling interactive Code Health authorizes its built-in Ada profiles to run
`gnatmake`, `gprbuild`, `alr` and `gnatprove` directly, without a shell, under
the configured deadlines. A nonempty `focused-test` must likewise be a direct
command using one of those programs. Project-task execution instead remains
bounded by the project's `execution.*` policy.

See [Code Health](code-health.md) for project configuration, evidence and
security semantics. The hook settings above remain independent and their
output is not trusted Code Health evidence.

## Rules for the tools

Two keys decide, for a conversation, which tool calls run without asking:

| key | does |
|-----|------|
| `tools.allow` | a call it names runs unasked |
| `tools.deny` | a call it names is refused unasked -- any tool's, one that only reads too; the model is told the settings refuse it |

A rule is a tool's name, or its name with a pattern in parentheses matched to
what the call is on: its `command`, else its `path`, else its `url`, else its
arguments as written. `*` stands for any run of characters; rules have a space
between them, and a pattern may hold spaces. Deny goes before allow; a call
neither names is asked about as before; plan mode refuses a change even where
`tools.allow` names it.

```
tools.allow = shell(alr build*) shell(git status) write_file(src/*) edit_file(src/*)
tools.deny  = shell(git push*) shell(rm -rf*) fetch_url
```

## MCP servers

A key `mcp.NAME` names a Model Context Protocol server -- a program of
yours, or one published, that offers tools of its own -- and the command
that starts it, by the host's shell in the session's folder:

```
mcp.files  = npx -y @modelcontextprotocol/server-filesystem /home/me/notes
mcp.github = GITHUB_PERSONAL_ACCESS_TOKEN=... npx -y @modelcontextprotocol/server-github
```

A conversation starts them when its first turn with the tools begins,
speaks the protocol with each on its standard input and output (a JSON-RPC
message a line; what a server writes to standard error is not shown), and
offers their tools to the model as `mcp__NAME__TOOL`, described and shaped
as the server says. A call is sent to its server and waited for up to five
minutes -- Ctrl-C stops the wait and asks the server to stop -- and its
answer's text is the tool's answer, a picture or other content said to be
there, up to 64 KiB. An error the server answers is a failed call the model
is told of. Every call is asked about first, as a shell's is; `tools.allow`
lets one run unasked (`mcp__files__*` for all of a server's tools), and
plan mode refuses them. A server that will not start or list its tools is
said once and the others are used; `/mcp` lists the servers, whether each
runs, and how many tools it gives. They are stopped when the conversation
ends. Only servers spoken to on standard input and output are supported,
not those reached over HTTP.

## A language server

`lsp` names a language server, a command speaking the Language Server
Protocol on standard input and output, started by the host's shell in the
session's folder the first time a tool writes or edits a file. Each written
or edited file is sent to it, and what it finds -- up to 20 problems, as
`line N: error: MESSAGE` -- is put after the tool's answer, or that it finds
none, so the model sees what its change broke. A server that says nothing of
the file within 8 seconds is not waited for; one that will not start is not
tried again in that conversation; it is stopped when the conversation ends.

```
lsp = ada_language_server
```

## Your own commands

A Markdown file `NAME.md` in `.model_runner/commands` under the session's
folder, or in `commands` beside this file, is the command `/NAME` in a
conversation: its text is sent as a message, `$ARGUMENTS` in it replaced by
the words after the command -- or, where it holds none, the words put after
it. Its first line that holds words is what `/help` says it does. A command
of the conversation's or the project's own of the same name is that one.

## Aliases

A key beginning `alias.` gives a short name for a model — a path or a
Hugging Face reference — so you need not type the whole thing:

```
alias.tiny = bartowski/SmolLM2-360M-Instruct-GGUF:Q4_K_M
alias.work = /srv/models/my-finetune.gguf
```

Then `model_runner run tiny` runs whatever `alias.tiny` stands for. A name
with no matching alias is taken as itself.

## Download suggestions

A key beginning `suggest.` adds a model to the list `model_runner run`
offers when no model is named. The part after `suggest.` is the label
shown; the value is a Hugging Face reference and, after a space, the file
size in bytes:

```
suggest.My-Coder-7B  = some-org/My-Coder-7B-GGUF:Q4_K_M 4_100_000_000
suggest.Tiny-Starter = another-org/Tiny-GGUF:Q4_K_M
```

The size may be grouped with underscores. It is what the shown size and
the "too big to run here" mark are read from; leave it off and the size
shows as unknown and the model is never marked too big, since nothing is
known of its size until it is fetched. Your suggestions are listed before
the built-in starters. Where a repository carries more than one file of a
quant, name one exactly — `…:r6-Q4_K_M` rather than `…:Q4_K_M` — or the
reference is refused as ambiguous.

## Precedence

A command-line flag beats the file, and the file beats a built-in default:

```
flag  >  file  >  built-in default
```

For the three place/secret keys an environment variable beats the file too:

```
flag / env  >  file  >  built-in default
```

So `model_runner run mymodel.gguf --backend cpu` runs on the processor even
if the file says `backend = device`, and a bare `model_runner run
mymodel.gguf` takes the file's backend.
