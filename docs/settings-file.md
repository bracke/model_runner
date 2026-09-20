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
| `repeat-penalty` | `--repeat-penalty` | `1.1`          |
| `paged`        | `--paged`/`--no-paged` | `true` / `false` |

A true/false value becomes the option's `--flag` or `--no-flag`. Any option
the `run` command accepts works this way; a key the command does not take is
ignored.

Three keys are **not** options — they are places and a secret:

| key            | falls back for                | env override           |
|----------------|-------------------------------|------------------------|
| `models-dir`   | where a bare model name is found and a download is kept | `MODEL_RUNNER_MODELS` |
| `sessions-dir` | where a bare session name is kept | `MODEL_RUNNER_SESSIONS` |
| `hf-token`     | the Hugging Face token for a gated repository | `HF_TOKEN` |

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
