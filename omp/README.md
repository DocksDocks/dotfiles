# OMP configuration

Portable configuration for [Oh My Pi](https://github.com/can1357/oh-my-pi)
focused on:

- high-quality implementation and review;
- fast, concise models for mechanical background work;
- cross-model fallback without silent provider substitution;
- controlled parallel delegation;
- reproducible Linux installation and frequent updates.

The configuration contains no API keys, OAuth tokens, session databases, or
machine-specific paths. Runtime authentication and local state stay outside
version control.

## Installation

The standalone release binary is self-contained and supports atomic in-place
updates through `omp update`.

The following Linux x86-64 installation flow downloads the latest release and
verifies its GitHub-published SHA-256 digest before installation:

```bash
set -euo pipefail

repo="can1357/oh-my-pi"
asset="omp-linux-x64"
version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name')"

curl -fL \
  "https://github.com/$repo/releases/download/$version/$asset" \
  -o /tmp/omp

expected="$(
  curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$version" |
    jq -r --arg asset "$asset" \
      '.assets[] | select(.name == $asset) | .digest | sub("^sha256:"; "")'
)"

printf '%s  %s\n' "$expected" /tmp/omp | sha256sum -c -
install -Dm0755 /tmp/omp "$HOME/.local/bin/omp"

omp --version
omp --smoke-test
```

For ARM64 Linux, replace `omp-linux-x64` with `omp-linux-arm64`. Ensure
`$HOME/.local/bin` is on `PATH`.

From the dotfiles repository root, install the tracked configuration with:

```bash
./install.sh omp
```

The installer copies `omp/config.yml` to `~/.omp/agent/config.yml` with mode
`0600` and backs up a differing existing file. Local runtime files such as
`.env`, `agent.db`, `secrets.yml`, sessions, logs, and caches must not be copied
into the repository.

## Intent: frontier models for substantive work

OMP resolves named roles to model selectors. The configuration assigns the
frontier coding model to implementation, planning, and vision work:

| Roles | Selector | Intent |
| --- | --- | --- |
| `default`, `plan`, `task`, `vision` | `openai-codex/gpt-5.6-sol:high` | Strong coding and reasoning without making every task xhigh |
| `slow` | `openai-codex/gpt-5.6-sol:xhigh` | Difficult investigations and the bundled reviewer agent |
| `advisor`, `designer` | `anthropic/claude-fable-5:xhigh` | Independent cross-model review and design specialization |

The bundled OMP reviewer resolves through the `slow` role, while the general
task worker resolves through `task`. Explicit effort suffixes in the model
selectors keep these role choices stable.

Sources:

- [OMP model and provider configuration](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/models.md)
- [OMP bundled agent definitions](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/task/agents.ts)
- [OMP subagent model and effort resolution](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/task/executor.ts)

## Intent: efficient models for mechanical work

The `smol`, `commit`, and `tiny` roles use:

```yaml
openai-codex/gpt-5.6-luna:low
```

These roles cover lightweight work such as commit helpers, titles, memory
utilities, classification, and small background operations. Luna-low provides a
large latency advantage and concise output, while Sol remains available for work
where stronger reasoning changes the outcome.

Artificial Analysis reports the following first-party API measurements:

| Metric | Luna low | Luna medium | Terra medium | Sol low |
| --- | ---: | ---: | ---: | ---: |
| Intelligence Index | 33 | 38 | 46 | 49 |
| Output speed | 173.7 tok/s | 167.1 tok/s | 108.0 tok/s | 50.9 tok/s |
| Time to first token | 1.33s | 1.94s | 1.78s | 3.21s |
| 500-token response time | 4.21s | 4.93s | 6.41s | 13.04s |

These figures compare benchmark behavior; they do not predict the exact duration
of an individual coding task. The practical conclusion is narrow: Luna-low is
well suited to short mechanical roles, while the more capable model is reserved
for implementation, planning, and review.

Sources:

- [GPT-5.6 Luna low analysis](https://artificialanalysis.ai/models/gpt-5-6-luna-low)
- [GPT-5.6 Luna medium analysis](https://artificialanalysis.ai/models/gpt-5-6-luna-medium)
- [GPT-5.6 Terra medium analysis](https://artificialanalysis.ai/models/gpt-5-6-terra-medium)
- [GPT-5.6 Sol low analysis](https://artificialanalysis.ai/models/gpt-5-6-sol-low)
- [Artificial Analysis intelligence methodology](https://artificialanalysis.ai/methodology/intelligence-benchmarking)
- [OMP commit model selection](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/commit/model-selection.ts)

## Intent: predictable fallback behavior

Model-specific fallback keys take precedence over role and default chains:

```yaml
retry:
  fallbackChains:
    openai-codex/gpt-5.6-luna:
      - openai-codex/gpt-5.6-sol:low
    anthropic/claude-fable-5:
      - openai-codex/gpt-5.6-sol:high
```

The fallback policy preserves the purpose of each role:

- Luna failures recover to Sol-low rather than escalating lightweight work to a
  high-effort frontier call.
- Fable failures recover to Sol-high so advisor and designer work still receives
  a strong model.
- The default Sol-led roles may fall back to Fable-xhigh during supported
  provider failures.

Anthropic server-side fallback is disabled:

```yaml
providers:
  anthropic:
    serverSideFallback: false
```

This prevents a classifier-blocked Fable request from being silently retried on
Opus. Model changes remain controlled by the explicit OMP fallback chains.

Sources:

- [OMP retry fallback resolution](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/config/settings-schema.ts)
- [OMP settings-aware provider streaming](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/session/settings-stream-fn.ts)

## Intent: aggressive but bounded delegation

```yaml
task:
  eager: always
  batch: true
  enableLsp: true
  maxConcurrency: 16
  maxRecursionDepth: 3
  softRequestBudget: 200
  softRequestBudgetNotice: true
```

`task.eager: always` makes delegation the default for decomposable work. OMP's
prompt still keeps direct answers, explicit commands, tiny edits, and work with
only one runnable slice in the primary agent. It also requires the primary agent
to settle the design and cross-slice contracts before delegating.

Batch mode lets independent slices launch together with shared context.
Concurrency 16 keeps broad parallelism available without the quota spikes of an
unbounded or 64-agent fan-out. Recursion depth 3 permits specialist trees while
remaining finite. LSP access is retained because delegated implementation and
review benefit from definitions, references, diagnostics, and code actions.

The 200-request soft budget injects a wrap-up reminder and eventually forces a
yield instead of allowing an unbounded subagent loop. The wall-clock timeout
remains at OMP's default `0` because long legitimate tasks should not be aborted
solely for duration.

Task isolation remains disabled. Non-isolated agents can stay live and receive
follow-up messages, while isolated agents are parked after their workspace is
merged and cannot be resumed.

Sources:

- [OMP delegation prompt](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/prompts/system/system-prompt.md)
- [OMP task tool behavior](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/tools/task.md)
- [OMP task setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/config/settings-schema.ts)

## Intent: asynchronous cross-model review

```yaml
advisor:
  enabled: true
  subagents: true
  syncBacklog: "off"
```

The advisor supplies an independent Fable review channel to primary and
subagent sessions. Backlog synchronization stays off so a slow advisor does not
pause the main implementation loop for up to 30 seconds. Advisor observations
can still arrive asynchronously.

Source:

- [OMP advisor and backlog behavior](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/advisor-watchdog.md)

## Intent: context preservation without remote summarizer dependence

OMP defaults to the local `snapcompact` strategy. The tracked configuration
adds idle maintenance and saves handoff documents:

```yaml
compaction:
  idleEnabled: true
  handoffSaveToDisk: true
```

Snapcompact archives older history locally into model-aware image frames rather
than requiring a separate summarization API call. Idle maintenance performs
context work while the session is not actively streaming.

Source:

- [OMP compaction and snapcompact behavior](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/compaction.md)

## Intent: controlled diagnostics and irreversible actions

AutoQA reporting is disabled and consent is denied:

```yaml
dev:
  autoqa: false
  autoqaConsent: denied
```

Automatic saved Codex reset redemption is also disabled:

```yaml
codexResets:
  autoRedeem: "no"
```

The latter disables the eligibility check entirely instead of allowing OMP to
spend a saved reset automatically.

Sources:

- [OMP AutoQA reporting implementation](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/tools/report-tool-issue.ts)
- [OMP Codex reset policy](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/session/codex-auto-reset.ts)

## Intent: useful visibility without prompt noise

Token usage and resolved subagent model badges are visible:

```yaml
display:
  showTokenUsage: true

task:
  showResolvedModelBadge: true
```

The workspace tree remains excluded from the system prompt because frequently
changing tree content increases prompt size and can reduce cache stability.
Thinking summaries remain available to the runtime but are hidden from the
terminal display.

## Intent: web access

```yaml
providers:
  fetch: jina
  webSearch: codex
```

Jina Reader is preferred for converting fetched pages into model-friendly text,
while web search stays on the Codex provider. Provider secrets and environment
files are runtime concerns and are intentionally outside this configuration.

Sources:

- [OMP provider setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.0.1/packages/coding-agent/src/config/settings-schema.ts)
- [Jina Reader](https://jina.ai/reader/)

## Updates and verification

OMP checks for new releases at startup. Manual update and verification:

```bash
omp update --check
omp update
omp --version
omp --smoke-test
```

Inspect the effective settings after installation:

```bash
omp config get modelRoles --json
omp config get retry.fallbackChains --json
omp config get task.eager --json
omp config get task.maxConcurrency --json
omp config get codexResets.autoRedeem --json
```

Release source:

- [OMP releases](https://github.com/can1357/oh-my-pi/releases)
