# OMP configuration

Portable configuration for [Oh My Pi](https://github.com/can1357/oh-my-pi)
focused on:

- high-quality implementation and review;
- deliberate reasoning depth per role, rather than a single global setting;
- cross-model fallback without silent provider substitution;
- controlled parallel delegation;
- reproducible installation on Linux and macOS, and frequent updates.

The configuration contains no API keys, OAuth tokens, session databases, or
machine-specific paths. Runtime authentication and local state stay outside
version control.

Source links in this document are pinned to `v17.1.7`, the installed release.

## Installation

The standalone release binary is self-contained and supports atomic in-place
updates through `omp update`.

The following installation flow detects the operating system and the
architecture, downloads the latest release, and verifies its GitHub-published
SHA-256 digest before installation. It works on Linux and on macOS:

```bash
set -euo pipefail

repo="can1357/oh-my-pi"

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="darwin" ;;
  *)
    printf 'Unsupported operating system: %s\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch="x64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *)
    printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

asset="omp-$os-$arch"
version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name')"

curl -fL \
  "https://github.com/$repo/releases/download/$version/$asset" \
  -o /tmp/omp

expected="$(
  curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$version" |
    jq -r --arg asset "$asset" \
      '.assets[] | select(.name == $asset) | .digest | sub("^sha256:"; "")'
)"

# macOS does not ship sha256sum. Its base system provides shasum.
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$expected" /tmp/omp | sha256sum -c -
else
  printf '%s  %s\n' "$expected" /tmp/omp | shasum -a 256 -c -
fi

# BSD install does not support -D. Create the target directory first.
install -d -m 0755 "$HOME/.local/bin"
install -m 0755 /tmp/omp "$HOME/.local/bin/omp"

omp --version
omp --smoke-test
```

Two commands in this flow differ between the two platforms:

| Step | Linux | macOS |
| --- | --- | --- |
| Digest check | `sha256sum -c -` | `shasum -a 256 -c -` |
| Binary install | `install -Dm0755 …` | `install -d`, then `install -m0755` |

The release publishes `omp-linux-x64`, `omp-linux-arm64`, `omp-darwin-x64`,
`omp-darwin-arm64`, and two musl Linux assets. The flow above selects the glibc
Linux asset. On a musl distribution such as Alpine, set `asset` to
`omp-linux-musl-x64` or `omp-linux-musl-arm64` instead.

Ensure `$HOME/.local/bin` is on `PATH`.

`curl` does not set the `com.apple.quarantine` attribute. macOS Gatekeeper
therefore does not block the downloaded binary.

From the dotfiles repository root, install the tracked settings, minimal global
context, and MCP policy with:

```bash
./install.sh omp
```

The installer copies `omp/AGENTS.md`, `omp/config.yml`, and `omp/mcp.json` to
the corresponding files under `~/.omp/agent/` with mode `0600`, and backs up
any differing existing file. Local runtime files such as `.env`, `agent.db`,
`secrets.yml`, sessions, logs, and caches must not be copied into the
repository.

`omp/config.yml` is kept byte-identical to the installed
`~/.omp/agent/config.yml`, including the serializer's trailing spaces after
mapping keys. That makes `./install.sh omp` a no-op while the two agree, so any
reported difference is real drift rather than formatting noise.

## Intent: model and reasoning depth per role

OMP resolves named roles to `provider/model:level` selectors. Both halves are
deliberate: the model decides capability, the `:level` suffix decides how much
reasoning that model spends.

| Roles | Selector | Intent |
| --- | --- | --- |
| `default`, `advisor`, `designer` | `anthropic/claude-opus-5:xhigh` | Primary session, advisor channel, and design specialization |
| `slow`, `plan` | `anthropic/claude-opus-5:max` | Difficult investigations, the bundled reviewer, and planning |
| `vision` | `anthropic/claude-opus-5:high` | Image inspection; dormant while the active model accepts images |
| `task` | `openai-codex/gpt-5.6-sol:high` | Delegated implementation |
| `commit`, `tiny` | `openai-codex/gpt-5.6-luna:high` | Commit helpers, titles, memory utilities |
| `smol` | `openai-codex/gpt-5.6-luna` | Backs the bundled research agents; level left to each agent |

The bundled OMP reviewer resolves through the `slow` role, while the general
task worker resolves through `task`.

`slow` and `plan` sit one tier above the other Opus roles because their output
is consumed as a decision rather than as a draft: a review or a plan is rarely
re-litigated, so the extra latency buys something the next turn cannot recover.
`default` stays at `xhigh` because the primary session pays that cost on every
single turn.

`vision` is dormant under this configuration and is set for the case where it
is not. It backs the `inspect_image` tool, which delegates an image to a
vision-capable model — and `inspect_image.mode` defaults to `auto`, registering
the tool only when the active model lacks native image input. Claude Opus 5
accepts image input directly, so with `default` on Opus the tool is never
registered and the role is never consulted.

It becomes live when that stops holding: an active model without image input, a
session-scoped `/vision` override, or `inspect_image.mode: on`. At that point
the tool resolves `@vision` first, falling back to `@default`. `high` rather
than `max` because reading an image is a perception task and the reasoning
ladder is the wrong axis for it — the top tier would add thinking time to a
call the user is waiting on without improving what the model sees.

Sources:

- [OMP model and provider configuration](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/models.md)
- [OMP bundled agent definitions](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/task/agents.ts)
- [OMP inspect_image tool](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/tools/inspect_image.md)

## Intent: reasoning levels chosen explicitly, not inherited

OMP accepts the levels `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and
`max`, plus `inherit`, and the session-only sentinel `auto`. Selectors accept
unambiguous abbreviations of at least two characters, so `xhi` parses as
`xhigh`.

Resolution order for a subagent spawn is fixed in the executor:

```ts
// Precedence: caller `effort` > explicit `:level` suffix on the resolved
// model pattern > agent-definition default (e.g. task's `auto`) >
// pattern-derived level.
effortLevel ?? (explicitThinkingLevel ? resolvedThinkingLevel : (thinkingLevel ?? resolvedThinkingLevel))
```

Three consequences drive this configuration.

**`defaultThinkingLevel` never reaches a spawn.** Startup resolution reads
`scoped.thinkingLevel ?? defaultThinkingSelector`, so a role's suffix wins and
the global setting covers only an unsuffixed selector — a manual `/model`
switch, say. That path is `findInitialModel`, which serves the main session
alone; the subagent resolver never reads the setting at all. With `default`
suffixed at `:xhigh`, `defaultThinkingLevel: xhigh` is currently decorative.

**An explicit suffix overrides an agent's own preference**, and that cuts both
ways. The bundled `task` agent declares `thinkingLevel: auto` and `sonic`
declares `medium`, but `task: …sol:high` supersedes the former, so the `auto`
classifier never engages for delegated work. That is deliberate: `auto`
classifies per turn and is capped at `xhigh`, which would make delegated depth
vary with prompt shape rather than with the role's purpose.

`smol` is deliberately left unsuffixed for the opposite reason. It backs the
read-only research agents, and each already declares the depth its author
intended — `scout` at `medium`, `librarian` at `minimal`, `sonic` at `medium`.
A suffix here would flatten all three to one level and silently discard that
tuning; without one, each agent keeps it. Every `@smol` agent declares a level,
so nothing falls through to an unpinned default.

**The per-spawn `effort` hint is disabled.** `task.enableEffort` defaults to
`false`, so the `task` tool exposes no `effort` parameter at all and
`task.maxEffort` has nothing to cap. Were it enabled, `lo`/`med`/`hi` would
index the resolved model's supported ladder — with the five-tier ladder every
model here exposes, `med` resolves to `high` and `hi` to `max`. Reasoning depth
is therefore fixed before a spawn starts — by the role's suffix, or by the
agent's own frontmatter where the role leaves the level open. Both are
properties of the work being delegated; neither is the caller's per-call guess.

### `xhigh` and `max` are genuinely different on these models

Claude Opus 5 is an Anthropic *adaptive* thinking model: any Anthropic-family
model at generation 4.6 or newer resolves to `anthropic-adaptive` control mode,
and Opus 4.7+/Sonnet 5+/Fable 5+ expose the full five-tier scale. Adaptive
requests send a wire `effort` string and no token budget, and the adaptive
effort ladder is wire-exact — no remapping — so `:xhigh` and `:max` transmit
different values.

This is worth stating because the `thinkingBudgets.*` settings invite the
opposite conclusion: `thinkingBudgets.xhigh` and `thinkingBudgets.max` share
the default `32768`, as does the built-in `ANTHROPIC_THINKING` table. Those
budgets apply to *budget-mode* models only. On Opus 5 the budget is computed
and then discarded by the adaptive branch, so raising `thinkingBudgets.max`
would change nothing here. The `openai-codex` models are distinct for a
different reason: they emit `reasoning.effort` as an enum, mapped `xhigh` and
`max` to separate wire tiers.

Artificial Analysis measures the two Opus tiers as separate entries, which
corroborates the source reading: index 60 at `xhigh` against 61 at `max`, with
time-to-first-token rising from 39.35s to 67.72s.

Sources:

- [OMP thinking levels and task effort](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/thinking.ts)
- [OMP subagent model and effort resolution](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/task/executor.ts)
- [OMP startup model and level resolution](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/config/model-resolver.ts)
- [OMP thinking control mode and effort ladders](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/catalog/src/model-thinking.ts)
- [OMP provider request construction](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/ai/src/stream.ts)
- [OMP settings definitions](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/config/settings-schema.ts)
- [OMP bundled agent frontmatter](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/prompts/agents/scout.md)

## Intent: cheap models for mechanical work, at useful depth

The `commit` and `tiny` roles use `openai-codex/gpt-5.6-luna:high`, and `smol`
uses the same model with no level:

```yaml
commit: openai-codex/gpt-5.6-luna:high
tiny:   openai-codex/gpt-5.6-luna:high
smol:   openai-codex/gpt-5.6-luna
```

`commit` and `tiny` produce short text directly — commit messages, titles,
retained memories — so the role sets their depth. `smol` only supplies the
model to agents that set their own, as described above. The model is chosen for
price and throughput; where this configuration does pick a level, it picks the
point on the ladder where reasoning is still nearly free in latency terms.

Artificial Analysis reports the following, retrieved 2026-07-28:

| Model (tier) | Intelligence Index | Output speed | Time to first token | Price in / out per 1M |
| --- | ---: | ---: | ---: | ---: |
| Luna low | 33 | 173.9 tok/s | 1.55s | $1.00 / $6.00 |
| Luna medium | 38 | 199.5 tok/s | 2.31s | $1.00 / $6.00 |
| Luna high | 46 | 203.1 tok/s | 8.01s | $1.00 / $6.00 |
| Luna xhigh | 49 | 189.1 tok/s | 34.45s | $1.00 / $6.00 |
| Luna max | 51 | 200.8 tok/s | 139.79s | $1.00 / $6.00 |
| Sol low | 49 | 79.5 tok/s | 3.25s | $5.00 / $30.00 |
| Sol medium | 54 | 74.1 tok/s | 4.13s | $5.00 / $30.00 |
| Sol high | 56 | 77.7 tok/s | 10.23s | $5.00 / $30.00 |
| Sol xhigh | 58 | 81.8 tok/s | 36.36s | $5.00 / $30.00 |
| Opus 5 high | 59 | 54.0 tok/s | 18.28s | $5.00 / $25.00 |
| Opus 5 xhigh | 60 | 53.7 tok/s | 39.35s | $5.00 / $25.00 |
| Opus 5 max | 61 | 53.5 tok/s | 67.72s | $5.00 / $25.00 |
| Fable 5 | 60 | 73.1 tok/s | 197.59s | $10.00 / $50.00 |

The case for Luna-high is that it is the knee of the curve. It scores 46 —
thirteen points above `low`, and only three below `xhigh` — while costing a
fifth of Sol per token, generating output faster than any other Luna tier at
203.1 tok/s, and reaching the first token in 8.01s. Measured against the
Intelligence Index as a whole, Luna-high costs $0.12 per task where Sol-max
costs $1.54 and Opus 5-max costs $2.03.

The third column is why the ladder stops here. Time to first token includes
thinking time, and on Luna it does not rise smoothly: 1.55s at `low`, 2.31s at
`medium`, 8.01s at `high`, then 34.45s at `xhigh` and 139.79s at `max`. The
step from `high` to `xhigh` costs 26 seconds and buys three index points. For
`commit` and `tiny`, which run in the foreground of an otherwise finished
action, that delay would be the dominant term and nothing about the higher
score shortens it.

`high` is also the cheaper and terser tier outright: 37M output tokens across
the Intelligence Index against 67M at `xhigh`, so the extra reasoning at
`xhigh` is spent on length as much as on quality. A workflow that wants these
roles to feel instantaneous should drop to `medium`, which returns to 2.31s for
an eight-point loss.

The Intelligence Index is a weighted composite of nine evaluations — agentic
work 34%, coding 24%, scientific reasoning 24%, general 18% — measured
text-only and in English. Artificial Analysis reports an aggregate 95%
confidence interval under ±1%, with wider intervals for individual evaluations,
and cautions that the aggregate may not transfer to any specific use case.
These figures compare benchmark behavior; they do not predict the duration of
an individual coding task.

Sources:

- [GPT-5.6 Luna (low)](https://artificialanalysis.ai/models/gpt-5-6-luna-low)
- [GPT-5.6 Luna (high)](https://artificialanalysis.ai/models/gpt-5-6-luna-high)
- [GPT-5.6 Sol (medium)](https://artificialanalysis.ai/models/gpt-5-6-sol-medium)
- [Claude Opus 5 (xhigh)](https://artificialanalysis.ai/models/claude-opus-5-xhigh)
- [Claude Opus 5 (max)](https://artificialanalysis.ai/models/claude-opus-5)
- [Artificial Analysis intelligence methodology](https://artificialanalysis.ai/methodology/intelligence-benchmarking)
- [OMP commit model selection](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/commit/model-selection.ts)

## Intent: predictable fallback behavior

Fallback chain entries are full model selectors, parsed exactly like
`modelRoles` values — an entry without a `:level` suffix carries no level and
recovers at the model's default rather than at the level that just failed.
Every entry here is therefore suffixed:

```yaml
retry:
  fallbackChains:
    default:
      - anthropic/claude-fable-5:xhigh
      - openai-codex/gpt-5.6-sol:xhigh
    advisor:
      - openai-codex/gpt-5.6-sol:xhigh
    slow:
      - openai-codex/gpt-5.6-sol:xhigh
    designer:
      - openai-codex/gpt-5.6-sol:xhigh
    openai-codex/gpt-5.6-luna:
      - openai-codex/gpt-5.6-sol:medium
    anthropic/claude-fable-5:
      - openai-codex/gpt-5.6-sol:xhigh
```

Model-specific keys take precedence over role and default chains. The policy
preserves the purpose of each role across a provider outage:

- Opus-led work — `default`, `advisor`, `slow`, `designer` — recovers to
  Sol-xhigh, which scores 58 against Opus 5-xhigh's 60. A provider-level
  Anthropic failure leaves review, investigation, and design on a comparable
  model from the other provider rather than on a cheaper tier.
- The `default` role recovers first to Fable-xhigh, keeping the primary session
  on a 1M-context Anthropic model; a Fable failure then recovers to Sol-xhigh
  through the model-specific chain.
- Luna failures recover to Sol-medium. Sol-medium scores 54 against Luna-high's
  46 and answers faster in absolute terms — 4.13s to first token against
  8.01s — so a mechanical role degrades into a quicker, stronger, costlier
  model instead of a slower one. Sol is five times the token price, which is
  acceptable for the retry path and would not be for steady state.

Anthropic server-side fallback is disabled:

```yaml
providers:
  anthropic:
    serverSideFallback: false
```

This prevents a classifier-blocked Fable request from being silently retried on
Opus. Model changes remain controlled by the explicit OMP fallback chains.

Sources:

- [OMP retry fallback chain parsing](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/session/retry-fallback-chains.ts)
- [OMP settings-aware provider streaming](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/session/settings-stream-fn.ts)
- [OMP retry policy](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/non-compaction-retry-policy.md)

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

- [OMP delegation prompt](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/prompts/system/system-prompt.md)
- [OMP task tool behavior](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/tools/task.md)
- [OMP task setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/config/settings-schema.ts)

## Intent: asynchronous cross-model review

```yaml
advisor:
  enabled: true
  subagents: false
  syncBacklog: "off"
```

The advisor supplies an independent review channel to the primary session only.
Disabling advisor inheritance for subagents avoids multiplying review traffic,
model cost, and steering across delegated work. Backlog synchronization stays
off so a slow advisor does not pause the main implementation loop for up to 30
seconds. Advisor observations can still arrive asynchronously.

Source:

- [OMP advisor and backlog behavior](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/advisor-watchdog.md)

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

- [OMP compaction and snapcompact behavior](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/compaction.md)

## Intent: minimal OMP-native global context

`omp/AGENTS.md` is deliberately short but non-empty. Installed at
`~/.omp/agent/AGENTS.md`, the native user context shadows
`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` without disabling the Claude or
Codex discovery providers and their skills, hooks, commands, or tools.

Only durable user-level behavior absent from project context belongs there:
current official documentation for unfamiliar or version-sensitive interfaces,
assessment-only requests staying read-only, and standing Docks plan-review
consent. Model routing lives in `config.yml`; skill and agent authoring rules
belong in project context or lazily loaded skills.

An empty native file would contribute nothing and would not reliably shadow the
external user context files, so the minimal explicit file is intentional.

Source:

- [OMP context discovery and shadowing](https://github.com/can1357/oh-my-pi/blob/v17.1.7/docs/context-files.md)

## Intent: no approval prompts and explicit MCP exclusions

```yaml
tools:
  approvalMode: yolo
```

`yolo` allows tool calls without approval prompts. The separately tracked
`mcp.json` disables `chrome-devtools`, `context7:context7`, and
`openaiDeveloperDocs`; OMP must not load those MCP servers even when discovery
finds them. Other discovered MCP servers remain eligible.

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

- [OMP AutoQA reporting implementation](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/tools/report-tool-issue.ts)
- [OMP Codex reset policy](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/session/codex-auto-reset.ts)

## Intent: useful visibility without prompt noise

Token usage and resolved subagent model badges are visible:

```yaml
display:
  showTokenUsage: true

task:
  showResolvedModelBadge: true
```

The resolved-model badge matters more with per-role levels than it would
otherwise: it reports the level a spawn actually received, which is the only
direct confirmation that the precedence chain resolved as intended.

Thinking summaries remain enabled at the provider (`omitThinking: false`) but
hidden in the terminal (`hideThinkingBlock: true`), so reasoning still informs
the model's own output without occupying the display. The workspace tree remains
excluded from the system prompt because frequently changing tree content
increases prompt size and can reduce cache stability.

## Intent: web access

```yaml
providers:
  fetch: jina
  webSearchOrder:
    - codex
    - perplexity
    - gemini
    - ...
```

Jina Reader is preferred for converting fetched pages into model-friendly text.
Web search is an ordered preference list headed by the Codex provider, with the
remaining engines as successive fallbacks. Provider secrets and environment
files are runtime concerns and are intentionally outside this configuration.

Sources:

- [OMP provider setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.1.7/packages/coding-agent/src/config/settings-schema.ts)
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
omp config get defaultThinkingLevel --json
omp config get retry.fallbackChains --json
omp config get task.enableEffort --json
omp config get task.maxEffort --json
omp config get codexResets.autoRedeem --json
```

Confirm which reasoning levels a model actually supports before pinning one:

```bash
omp models --json | jq -c '.models[]
  | select(.selector == "anthropic/claude-opus-5")
  | {selector, thinking}'
```

Release source:

- [OMP releases](https://github.com/can1357/oh-my-pi/releases)
