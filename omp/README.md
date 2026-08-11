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

This configuration targets Oh My Pi `v17.2.1` or newer. That version is a
floor, not a gate. Nothing in this repository inspects the running version or
refuses to install against another release.

Source links below point at the `v17.2.1` tree. A tagged link keeps each
citation stable, so a later release cannot silently invalidate the statement it
supports.

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
context, MCP policy, and pi-intercom broker configuration with:

```bash
./install.sh omp
```

This target does not reach the network. To install the `pi-intercom` npm plugin
and provision the same broker configuration, run:

```bash
./install.sh intercom
```

The `intercom` target reaches the network for the plugin install. `bun` must be
on `PATH` because it runs the broker.

To install the `remote-pi` npm plugin, run:

```bash
./install.sh remote
```

The `remote` target discovers its relay automatically. It supports Linux and
macOS. It requires `curl` and Tailscale.

The installer handles the three tracked files under `~/.omp/agent/` as
follows:

- `AGENTS.md` and `mcp.json` remain managed files: each is replaced by the
  repository copy, with the existing file backed up when its contents differ.
- `config.yml` is recursively overlaid onto the destination. Mapping values
  merge at every depth, so destination-only mapping keys remain, including
  custom `modelRoles` entries and destination-only keys under `task`.
  Repository scalar values replace matching destination values. Repository
  lists replace matching destination lists as complete values; their existing
  elements are not preserved.

The separate `omp/intercom.json` is installed as
`$HOME/.pi/agent/intercom/config.json`, or as
`$PI_CODING_AGENT_DIR/intercom/config.json` when that variable is set. The
extension keeps its runtime files under the Pi agent directory rather than
under `$HOME/.omp`.

The `remote-pi` plugin stores its configuration at
`$HOME/.pi/remote/config.json`. The plugin always uses this home-directory path.
Unlike pi-intercom, `PI_CODING_AGENT_DIR` does not change this path.

The resulting files are installed with mode `0600`, and `config.yml` is backed
up only when the merged output changes the destination. Local runtime files such
as `.env`, `agent.db`, `secrets.yml`, sessions, logs, and caches must not be
copied into the repository.

The standalone installer regression check can be run from the repository root:

```bash
bash tests/install-omp.sh
```

## Intent: automatic relay discovery

A relay URL differs for each network. Users must not commit it to this public
repository. The installer discovers the URL at install time.

Each probe sends a `GET /health` request. The installer uses this discovery
order:

1. When `REMOTE_PI_RELAY` is set, the installer uses it.
2. Otherwise, a relay answering at `http://127.0.0.1:3000` wins. This keeps
   local sessions working when Tailscale is down.
3. Otherwise, the installer probes every online Tailscale peer on port `3000`.
   It uses the MagicDNS name of the first peer that answers.
4. When no relay answers, the installer checks for existing configuration. It
   keeps an existing file and continues successfully. If no file exists, the
   target fails.

Without configuration, `remote-pi` falls back to a public community relay. The
installer refuses this silent substitution.

The installer prefers loopback on the relay machine itself. This route avoids
a Tailscale dependency for local sessions.

The installer uses the raw address only when it cannot read the MagicDNS
suffix. It prefers the MagicDNS name because it survives an address change.

The installer supports Linux and macOS. The `remote` target requires `curl` and
Tailscale. On macOS, the installer also checks the Tailscale application bundle
when `PATH` does not provide the CLI.

If `curl` or the Tailscale CLI is missing, the target prints a message that
names the missing prerequisite. The target then fails. It does not report
success.

A relay problem never blocks the rest of the `all` install. The installer
prints a notice and continues.

The installer applies the URL through `remote-pi set-relay`. This command merges
the configuration and keeps unrelated keys.

## Intent: model and reasoning depth per role

OMP resolves named roles to `provider/model:level` selectors. Both halves are
deliberate: the model decides capability, the `:level` suffix decides how much
reasoning that model spends.

| Roles | Selector | Intent |
| --- | --- | --- |
| `default`, `slow`, `plan` | `anthropic/claude-opus-5:max` | Primary session, difficult investigations, the bundled reviewer, and planning |
| `designer` | `anthropic/claude-opus-5:medium` | Design specialization |
| `advisor` | `openai-codex/gpt-5.6-sol:high` | Advisor channel, on the second provider |
| `vision` | `anthropic/claude-opus-5:high` | Image inspection; dormant while the active model accepts images |
| `task` | `openai-codex/gpt-5.6-sol:high` | Delegated implementation |
| `commit`, `tiny` | `openai-codex/gpt-5.6-luna:high` | Commit helpers, titles, memory utilities |
| `smol` | `openai-codex/gpt-5.6-luna` | Backs the bundled research agents; level left to each agent |

The bundled OMP reviewer resolves through the `slow` role, while the general
task worker resolves through `task`.

`default`, `slow`, and `plan` sit at the top of the ladder. For `slow` and
`plan`, the output is consumed as a decision rather than as a draft: a review
or a plan is rarely re-litigated, so the extra latency buys something the next
turn cannot recover. `default` joins them by explicit choice: the primary
session takes the maximum reasoning depth on every turn, and pays 34.56s to the
first answer token and $2.34 per task for it. Measured against `medium`, `max`
gains 4.4 index points at roughly three times the cost per task.

`advisor` runs on the other provider at `high`. The advisor channel exists to
review the primary session, so a second opinion from a different model family
is worth more than one more Opus 5 instance. Sol-high scores 55.9 and answers
in 14.07s at $0.55 per task, which keeps the review channel cheaper and faster
than the session it reviews. `designer` stays at `medium` for the same cost
reason that used to apply to the primary session.

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

- [OMP model and provider configuration](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/models.md)
- [OMP bundled agent definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/task/agents.ts)
- [OMP inspect_image tool](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/tools/inspect_image.md)

## Reference: measured model tiers

This table carries every effort tier of every model this configuration uses,
not only the tiers currently selected. A change of effort therefore needs no
new measurement round.

Artificial Analysis reports the following, retrieved 2026-08-06 against
Intelligence Index v4.1. Every model listed has a 1,000,000-token context
window. "Time to first answer token" includes model thinking time. "Cost per
task" is the weighted average cost of one Intelligence Index task.

| Model (tier) | Intelligence Index | Output speed | Time to first answer token | Cost per task | Price in / out per 1M |
| --- | ---: | ---: | ---: | ---: | ---: |
| Opus 5 low | 50.6 | 52.3 tok/s | 2.76s | $0.43 | $5.00 / $25.00 |
| Opus 5 medium | 56.3 | 54.6 tok/s | 6.43s | $0.72 | $5.00 / $25.00 |
| Opus 5 high | 58.9 | 53.4 tok/s | 11.73s | $1.23 | $5.00 / $25.00 |
| Opus 5 xhigh | 60.1 | 54.8 tok/s | 26.27s | $1.80 | $5.00 / $25.00 |
| Opus 5 max | 60.7 | 53.7 tok/s | 34.56s | $2.34 | $5.00 / $25.00 |
| Sol low | 49.4 | 63.1 tok/s | 3.15s | $0.24 | $5.00 / $30.00 |
| Sol medium | 53.6 | 60.7 tok/s | 6.19s | $0.39 | $5.00 / $30.00 |
| Sol high | 55.9 | 63.5 tok/s | 14.07s | $0.55 | $5.00 / $30.00 |
| Sol xhigh | 57.7 | 62.9 tok/s | 26.17s | $0.83 | $5.00 / $30.00 |
| Sol max | 58.9 | 64.1 tok/s | 99.36s | $1.23 | $5.00 / $30.00 |
| Luna low | 33.3 | 137.1 tok/s | 1.55s | $0.009 | $0.20 / $1.20 |
| Luna medium | 38.1 | 155.7 tok/s | 3.66s | $0.011 | $0.20 / $1.20 |
| Luna high | 46.1 | 175.0 tok/s | 10.43s | $0.022 | $0.20 / $1.20 |
| Luna xhigh | 49.1 | 167.8 tok/s | 26.43s | $0.032 | $0.20 / $1.20 |
| Luna max | 51.2 | 184.5 tok/s | 72.86s | $0.047 | $0.20 / $1.20 |

The Intelligence Index is a weighted composite of nine evaluations — agentic
work 34%, coding 24%, scientific reasoning 24%, general 18% — measured
text-only and in English. Artificial Analysis reports an aggregate 95%
confidence interval under ±1%, with wider intervals for individual evaluations,
and cautions that the aggregate may not transfer to any specific use case.
These figures compare benchmark behavior; they do not predict the duration of
an individual coding task.

Sources:

- [Claude Opus 5 (medium)](https://artificialanalysis.ai/models/claude-opus-5-medium)
- [Claude Opus 5 (xhigh)](https://artificialanalysis.ai/models/claude-opus-5-xhigh)
- [Claude Opus 5 (max)](https://artificialanalysis.ai/models/claude-opus-5)
- [GPT-5.6 Sol (high)](https://artificialanalysis.ai/models/gpt-5-6-sol-high)
- [GPT-5.6 Sol (medium)](https://artificialanalysis.ai/models/gpt-5-6-sol-medium)
- [GPT-5.6 Luna (high)](https://artificialanalysis.ai/models/gpt-5-6-luna-high)
- [Artificial Analysis intelligence methodology](https://artificialanalysis.ai/methodology/intelligence-benchmarking)

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
alone; the subagent resolver never reads the setting at all. Every role
except `smol` now carries an explicit suffix at `medium`, `high`, or `max`.
Every agent backed by `smol` declares its own thinking level.
`defaultThinkingLevel: high` is still present, and it remains decorative.

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

### The adaptive tiers are genuinely different on these models

Claude Opus 5 is an Anthropic *adaptive* thinking model: any Anthropic-family
model at generation 4.6 or newer resolves to `anthropic-adaptive` control
mode. Adaptive requests send a wire `effort` string and no token budget, and
the adaptive effort ladder is wire-exact — no remapping — so `:medium`,
`:high`, and `:max` each transmit a different value.

The five-tier scale hinges on a version threshold in the OMP source, not on
a model this configuration runs. In `model-thinking.ts`,
`anthropicModelHasRealXHighEffort` returns
`isAnthropicAdaptiveGenAtLeast(parsedModel, "4.7")`. Models at or above that
cutoff receive the five-tier `low`/`medium`/`high`/`xhigh`/`max` ladder;
Opus and Sonnet 4.6 stay on a four-tier ladder without `xhigh`. Opus 5 sits
above the cutoff, so all five tiers are live even though this configuration
selects only three of them.

This is worth stating because the `thinkingBudgets.*` settings invite the
opposite conclusion: they read as if a token budget defined each tier. Those
budgets apply to *budget-mode* models only. On Opus 5 the adaptive branch
computes the budget and then discards it, so raising `thinkingBudgets.max`
would change nothing here. The `openai-codex` models are distinct for a
different reason: they emit `reasoning.effort` as an enum, with each tier
mapped to a separate wire value.

Artificial Analysis corroborates the source reading: the five Opus 5 tiers
measure as five distinct points. The Intelligence Index climbs from 50.6
through 56.3, 58.9, and 60.1 to 60.7. Time to first answer token rises from
2.76s to 34.56s. See `## Reference: measured model tiers` for the full table.

Sources:

- [OMP thinking levels and task effort](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/thinking.ts)
- [OMP subagent model and effort resolution](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/task/executor.ts)
- [OMP startup model and level resolution](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/config/model-resolver.ts)
- [OMP thinking control mode and effort ladders](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/catalog/src/model-thinking.ts)
- [OMP provider request construction](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/ai/src/stream.ts)
- [OMP settings definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/config/settings-schema.ts)
- [OMP bundled agent frontmatter](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/prompts/agents/scout.md)

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

All measured figures live in `## Reference: measured model tiers`; this
section cites only the ones the argument needs.

The case for Luna-high is that it is the knee of the curve. It scores 46.1 —
12.8 points above `low` at 33.3, and only 3.0 below `xhigh` at 49.1. Luna
costs $0.20 / $1.20 per 1M tokens against $5.00 / $30.00 for Sol, one
twenty-fifth of the Sol input price. Every Luna tier also generates output
faster than any Sol or Opus 5 tier. Measured against the Intelligence Index
as a whole, Luna-high costs $0.022 per task where Sol-max costs $1.23 and
Opus 5-max costs $2.34.

Time to first answer token is why the ladder stops here. It includes thinking
time. On Luna it does not rise smoothly: 1.55s at `low`, 3.66s at `medium`,
10.43s at `high`, then 26.43s at `xhigh` and 72.86s at `max`. The step from
`high` to `xhigh` costs 16 seconds and buys 3.0 index points. `commit` and
`tiny` run in the foreground of an otherwise finished action. There, that
delay would be the dominant term, and nothing about the higher score
shortens it.

`high` is also the cheaper tier outright: $0.022 per task against $0.032 at
`xhigh`. A workflow that wants these roles to feel instantaneous should drop
to `medium`. That tier returns the first answer token in 3.66s and scores
38.1, an 8.0-point drop from `high`.

Sources:

- [OMP commit model selection](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/commit/model-selection.ts)

## Intent: predictable fallback behavior

Fallback chain entries are full model selectors, parsed exactly like
`modelRoles` values — an entry without a `:level` suffix carries no level and
recovers at the model's default rather than at the level that just failed.
Every entry here is therefore suffixed:

```yaml
retry:
  fallbackChains:
    default:
      - anthropic/claude-opus-5:medium
      - openai-codex/gpt-5.6-sol:high
    slow:
      - openai-codex/gpt-5.6-sol:high
    designer:
      - openai-codex/gpt-5.6-sol:high
    openai-codex/gpt-5.6-luna:
      - openai-codex/gpt-5.6-sol:medium
      - anthropic/claude-opus-5:medium
    openai-codex/gpt-5.6-sol:
      - anthropic/claude-opus-5:medium
    anthropic/claude-opus-5:
      - openai-codex/gpt-5.6-sol:high
```

Resolution picks the chain that owns the failing model by specificity: the
exact `provider/model-id` key first, then a `provider/*` wildcard, then the
role chain, then `default`. Two consequences shape the table above.

The `default` chain is not the chain for the `default` role. It is the
catch-all for every role that declares no chain of its own, and `task` is such
a role. A Sol failure in a delegated subagent therefore lands here, which is
why the first entry names an Anthropic model. That entry is not a self-loop
for the `default` role: an Opus 5 failure matches the exact
`anthropic/claude-opus-5` key first and never reaches it.

Every chain must be able to leave the provider it started on. A quota wall is
provider-wide, so a chain that recovers Sol onto Sol is a dead end. The two
model-specific keys make the escape bidirectional: Anthropic failures move to
Sol, and Sol failures move to Opus 5. Luna lists Sol first, because a single
model outage is more common than a provider outage, and Opus 5 second, for the
case where the whole Codex provider is unavailable. The retry policy skips
selectors that are still cooling down, so the two directions cannot ping-pong.

The policy preserves the purpose of each role across a provider outage:

- Opus-led work — `default`, `slow`, `plan`, `designer`, `vision` — recovers
  to Sol-high, which scores 55.9. For `designer` at Opus 5-medium, whose score
  is 56.3, the gap is 0.4 index points and recovery is close to lossless. For
  the roles at Opus 5-max, whose score is 60.7, the loss is measurable. The
  configuration accepts that loss because the alternative is no answer at all,
  and the recovered work still runs on a top-tier model rather than a cheaper
  one.
- `advisor` already runs on Sol, so it needs no role chain: a Sol failure
  matches the exact `openai-codex/gpt-5.6-sol` key first and recovers to Opus
  5-medium. The advisor channel therefore keeps its defining property across
  an outage — it reviews the session from a different model family.
- The model-specific Opus 5 key covers every Opus-led role, including `plan`
  and `vision`, which declare no role chain of their own. It takes precedence
  over the role chains, so all Opus 5 work recovers to Sol-high.
- Luna failures recover to Sol-medium first. Sol-medium scores 53.6 against
  Luna-high's 46.1 and reaches the first answer token in 6.19s against
  10.43s for Luna-high. A mechanical role therefore degrades into a quicker,
  stronger, costlier model instead of a slower one. Sol costs twenty-five
  times the Luna token price: $5.00 against $0.20 per 1M input tokens. That
  price is acceptable on the retry path and would not be acceptable in
  steady state.

See `## Reference: measured model tiers` for the full set of measured
figures.

Anthropic server-side fallback is disabled:

```yaml
providers:
  anthropic:
    serverSideFallback: false
```

This prevents a classifier-blocked Anthropic request from being silently
retried on a different Anthropic model. Model changes remain controlled by the
explicit OMP fallback chains.

Sources:

- [OMP retry fallback chain parsing](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/session/retry-fallback-chains.ts)
- [OMP settings-aware provider streaming](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/session/settings-stream-fn.ts)
- [OMP retry policy](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/non-compaction-retry-policy.md)

## Intent: no explicit service tier

```yaml
tier:
  openai: none
  anthropic: none
```

`tier.openai` becomes the `service_tier` field of the request, for OpenAI and
OpenAI-Codex models. Every OpenAI-family role in this configuration resolves to
an `openai-codex/*` model, and the Codex endpoint rejects `auto` with
`Unsupported service_tier: auto (code=invalid_request_error)`. Many subagent
sessions hit that rejection on 2026-08-03.

The `task`, `smol`, `commit`, and `tiny` roles all resolve to Codex models, and
`tier.subagent` defaults to `inherit`. Under the earlier `auto`, every
Codex-backed subagent therefore failed before its first turn, and the retry
path gave up after one attempt.

`none` makes OMP omit `service_tier` from the request and accept the
server-side default. `default` is not a safe substitute. The rejection message
shows that the endpoint validates `service_tier` against an allowlist, and no
OMP or OpenAI source confirms that `default` is on it. Omission is the only
outcome the allowlist cannot reject.

`anthropic: none` stays unchanged because `priority` is the only other accepted
value for that family.

Sources:

- [OMP settings definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/config/settings-schema.ts)
- [OMP provider request construction](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/ai/src/stream.ts)

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

- [OMP delegation prompt](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/prompts/system/system-prompt.md)
- [OMP task tool behavior](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/tools/task.md)
- [OMP task setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/config/settings-schema.ts)

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

- [OMP advisor and backlog behavior](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/advisor-watchdog.md)

## Intent: cross-session messaging between independent sessions

OMP's `hub` messaging is process-local and scoped to one session's subagent
tree. `/collab` shares one session with guests rather than connecting peer
sessions. Two independent top-level sessions therefore cannot address each
other natively. [Issue 7537](https://github.com/can1357/oh-my-pi/issues/7537)
documents the process boundary, [issue
8077](https://github.com/can1357/oh-my-pi/issues/8077) is the open request for
cross-session messaging, and [draft PR
7255](https://github.com/can1357/oh-my-pi/pull/7255) remains unmerged. Together
they show that this capability is missing rather than hidden.

The third-party Pi extension
[`pi-intercom`](https://www.npmjs.com/package/pi-intercom) fills this gap. OMP
is a fork of Pi, and its installed-package loader accepts legacy
`pi.extensions` manifests. Its compatibility loader also rewrites
`@earendil-works/*` imports onto OMP's bundled packages.

The extension's default broker launcher is `npx --no-install tsx`. That default
makes `getTsxCliPath()` resolve `tsx` through `createRequire`, which throws
under OMP. The function then returns its fallback path inside
`pi-intercom/node_modules`. OMP installs plugins into one flat store, so `tsx`
is a sibling of `pi-intercom` and that fallback path does not exist. Node exits
with code 1 and `MODULE_NOT_FOUND`. The extension reports only `Intercom broker
exited before startup with code 1`, because it spawns the broker with
`stdio: "ignore"` and discards the real error.

The literal `node` command that the launcher substitutes for OMP's own
executable is not the cause. `node` is on `PATH`, and the same command with the
real `tsx` path starts the broker. The tracked `brokerCommand` override uses
`bun`, which skips the `tsx` path entirely and runs the TypeScript broker
directly. `bun` must therefore be on `PATH`.

Measured against `pi-intercom@0.10.0`: `broker/spawn.ts:44-57` resolves `tsx`
and defines the fallback, `:148-160` selects it for the default launcher, and
`:175` discards the broker's output.

An end-to-end check used two independent, long-lived OMP sessions. They
discovered each other, a message reached a session while it was idle and
started a turn there, and a blocking ask returned the peer's answer. This is
measured behavior, not a compatibility guarantee.

Operational constraints:

- `/name` from the extension's README is not an OMP command. Address a peer by
  session ID or its automatically generated title.
- A print-mode (`omp -p`) sender cannot receive an ask reply. Each invocation is
  a fresh short-lived session that is gone when the reply is routed, so
  blocking asks require long-lived sessions on both ends.
- The broker connects sessions for one user on one machine; it is not a remote
  transport.

No public report was found of anyone else running pi-intercom under OMP. GitHub
API searches across the OMP, pi-intercom, and remote_pi repositories found no
mention, and a broad web search found nothing indexed. The extension declares
no OMP version floor, so a future OMP release could break this compatibility
without warning.

Alternatives were evaluated before adopting this extension. OMP provides no
native mechanism. Its `hub` messaging is in-process, `omp acp` serves ACP over
stdio as a server and cannot act as a client to another session, `omp share`
publishes an encrypted snapshot, and `omp join` joins one shared host session.
An MCP server cannot substitute for it either. OMP's MCP client advertises only
`roots` and answers other server-initiated requests with JSON-RPC `-32601`, so
no MCP server can start a turn in an idle session. The MCP message buses that
exist require the recipient to poll an inbox.

The closest third-party alternative is
[`@agent-ops/omp-nats-channel`](https://www.npmjs.com/package/@agent-ops/omp-nats-channel).
It is stronger on compatibility, because it declares a native `omp.extensions`
manifest and depends on `@oh-my-pi/pi-coding-agent` instead of Pi internals.
Self-hosting its server is clean. `nats-server` is Apache-2.0, a CNCF
Incubating project, and a single release binary. It runs from
`listen: 127.0.0.1:4222` with no documented telemetry, licence check, or update
check, and a plain loopback instance has no configured outbound destination.

It was rejected on measured behavior instead. Its `request` tool returns a
`taskId` and `TASK_STATE_WORKING` immediately, and the peer's answer does not
come back as the tool result. This was measured with JetStream both disabled
and enabled. In one run the answer arrived later as a separate inbound message.
In another it never arrived, although the peer had answered. The same prompt
was also delivered to the peer three times. Two further costs: with `NATS_URL`
unset it connects to the public `demo.nats.io` and forks a `sesh` process, and
its key-value and object buckets need JetStream, so core NATS is not enough.

The remaining four candidates were installed and executed, not only read.
[`remote-pi`](https://github.com/jacobaraujo7/remote_pi) meets all three
requirements. It loads under OMP v17.2.12 with no warning and registers
`agent_send`, `agent_request`, and `list_peers`. Every session must first run the
`/remote-pi join` wizard, which offers an external relay; declining it keeps the
mesh local to the machine. Accepting it costs confidentiality: its `relay/README`
states that a relay operator can see routed plaintext, so the shared relay is not
an end-to-end boundary. Running `jacobmoura7/remote-pi-relay` under `docker run`
and pointing the extension at it removes that operator from the trust path. The
setter is `/remote-pi set-relay <url>`, followed by a session restart; the
documented `/remote-pi relay url` and `/remote-pi relay stop` are inert in 0.5.5
and only reprint the status panel. Contrast `/collab`, which seals every payload with
AES-256-GCM before the socket, so its relay sees only ciphertext, room ids, and
frame sizes. Peers are addressed as `<cwd>@<name>`, so addressing
crosses projects by construction. Its `agent_request` returned the peer's answer
as the tool result. That was proven with a fact the sender could not hold: the
peer's working directory. Its own README, however, offers `agent_request` "only
as deprecated legacy behavior". The supported call is `agent_send`, which waits
for a delivery acknowledgement of `received`, `denied`, or `timeout`, and content
replies then arrive asynchronously through `re`. So the supported path is the
acknowledgement-only shape, and the correlated reply survives on a deprecated
one. `pi-intercom` remains the tracked choice for that reason, and because it
needs no per-session join and no relay decision.

The other three do not run here.
[`pi-messenger`](https://github.com/nicobailon/pi-messenger) imports `typebox`
without declaring it as a dependency. OMP fails to load it with `Sj(A).or is not
a function`, so its skills load while its tool never registers.
[`control`](https://github.com/jayshah5696/pi-agent-extensions) ships inside
`pi-agent-extensions`, and that install aborts on a missing
`@sinclair/typebox/value` and on `Export named 'ModelRuntime' not found in
module 'omp-legacy-pi-bundled:@oh-my-pi/pi-coding-agent'`.
[`crosstalk`](https://github.com/byteowlz/pi-agent-extensions) publishes no
package. That repository is `private: true`, and its released extensions carry
`@byteowlz/pi-*` names. OMP's own `swarm-extension` runs subprocess workers from
one session rather than connecting independent sessions.

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

- [OMP compaction and snapcompact behavior](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/compaction.md)

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

- [OMP context discovery and shadowing](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/context-files.md)

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

- [OMP AutoQA reporting implementation](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/tools/report-tool-issue.ts)
- [OMP Codex reset policy](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/session/codex-auto-reset.ts)

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

Thinking summaries remain enabled at the provider (`omitThinking: false`) and
visible in the terminal (`hideThinkingBlock: false`). The point is to watch the
reasoning as it streams, not only to let it inform the output. The workspace
tree remains excluded from the system prompt because frequently changing tree
content increases prompt size and can reduce cache stability.

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

- [OMP provider setting definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/config/settings-schema.ts)
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
