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

The plain `./install.sh` command runs the `all` target. It treats `remote-pi`
0.7.0 as a minimum version, not a fixed one: it installs the newest published
release, keeps an already newer install, and upgrades anything older. When the
version lookup fails, for example offline, it holds at the minimum instead of
failing. It also configures the relay. A relay problem prints a notice and
never blocks the rest of the install.

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

To run only the `remote-pi` installation and relay configuration, run:

```bash
./install.sh remote
```

The `remote` target discovers its relay automatically. It supports Linux and
macOS. It requires `curl` and uses Tailscale for relay discovery.

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

The installer manages the global `remote-pi` relay configuration at
`$HOME/.pi/remote/config.json`. Version 0.7.0 stores each session setup at
`<cwd>/.pi/remote-pi/config.json`. `PI_CODING_AGENT_DIR` does not change either
path.

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
4. When Tailscale is present but no relay answers, the installer checks for
   existing configuration. It keeps an existing file and continues
   successfully. If no file exists, the target fails.

Without configuration, `remote-pi` falls back to a public community relay. The
installer refuses this silent substitution.

The installer prefers loopback on the relay machine itself. This route avoids
a Tailscale dependency for local sessions.

The installer uses the raw address only when it cannot read the MagicDNS
suffix. It prefers the MagicDNS name because it survives an address change.

The installer supports Linux and macOS. The `remote` target requires `curl` and
uses Tailscale. On macOS, the installer also checks the Tailscale application
bundle when `PATH` does not provide the CLI. That bundle executable can start
either the graphical application or the CLI. The installer therefore sets
`TAILSCALE_BE_CLI=1`, which forces CLI mode and prevents a GUI launch.

Without `curl`, the installer cannot probe any relay. The `remote` target
therefore fails.

When the Tailscale CLI is absent, the installer detects the operating system
with `uname`. It prints a warning that names the matching install command. The
warning states that missing configuration makes `remote-pi` use the public
community relay. The installer leaves the relay configuration unchanged. It
continues successfully. It does not fail.

On Linux, the warning prints this command:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

On macOS, the warning prints the same script command. That script opens the Mac
App Store page. The warning also names `brew install --cask tailscale` as an
alternative.

The installer applies the URL through `remote-pi set-relay`. This command merges
the configuration and keeps unrelated keys.

## Intent: model and reasoning depth per role

OMP resolves named roles to `provider/model:level` selectors. Both halves are
deliberate: the model decides capability, the `:level` suffix decides how much
reasoning that model spends.

| Roles | Selector | Intent |
| --- | --- | --- |
| `default`, `slow`, `plan` | `anthropic/claude-opus-5:max` | Primary session, difficult investigations, and planning |
| `designer` | `anthropic/claude-opus-5:high` | Design specialization |
| `advisor` | `openai-codex/gpt-5.6-sol:high` | Advisor channel, on the second provider |
| `vision` | `openai-codex/gpt-5.6-sol:low` | Image inspection; dormant while the active model accepts images |
| `task` | `openai-codex/gpt-5.6-sol:high` | Delegated implementation |
| `commit`, `tiny` | `openai-codex/gpt-5.6-luna:high` | Commit helpers, titles, memory utilities |
| `smol` | `openai-codex/gpt-5.6-luna` | Backs the bundled research agents; level left to each agent |

The general task worker resolves through `task`. The bundled reviewer resolves
through `slow` by default. This configuration overrides that agent, and three
other review agents, in `## Intent: aggressive but bounded delegation`.

`default`, `slow`, and `plan` sit at the top of the ladder. For `slow` and
`plan`, the output is consumed as a decision rather than as a draft: a review
or a plan is rarely re-litigated, so the extra latency buys something the next
turn cannot recover. `default` joins them by explicit choice: the primary
session takes the maximum reasoning depth on every turn, and pays 58.23s to the
first answer token and $2.34 per task for it. Measured against `medium`, `max`
scores 63.1 against 58.6, at roughly three times the cost per task.

`advisor` runs on the other provider at `high`. The advisor channel exists to
review the primary session, so a second opinion from a different model family
is worth more than one more Opus 5 instance. Sol-high scores 57.3 and answers
in 15.73s at $0.55 per task, which keeps the review channel cheaper and faster
than the session it reviews.

`designer` runs at `high`. Design output is consumed as a decision, like `slow`
and `plan`, so it sits above the `medium` tier it used to occupy: 61.5 index
points against 58.6, for $1.23 per task against $0.72. It stays below `max`
because a design answer is read and revised before anything acts on it.

`vision` is dormant under this configuration and is set for the case where it
is not. It backs the `inspect_image` tool, which delegates an image to a
vision-capable model — and `inspect_image.mode` defaults to `auto`, registering
the tool only when the active model lacks native image input. Claude Opus 5
accepts image input directly, so with `default` on Opus the tool is never
registered and the role is never consulted.

It becomes live when that stops holding: an active model without image input, a
session-scoped `/vision` override, or `inspect_image.mode: on`. At that point
the tool resolves `@vision` first, falling back to `@default`. The role takes
Sol at `low`, because reading an image is a perception task and the reasoning
ladder is the wrong axis for it.

Artificial Analysis measures image input separately from the Intelligence Index,
with MMMU-Pro. That score barely responds to reasoning effort. Across the Sol
tiers it moves from 81.0 at `low` to 83.4 at `max`, while time to the first
answer token moves from 3.28s to 153.87s. The ladder buys latency here, not
perception.

Sol at `low` is not the strongest image model the floor allows. Opus 5 at `max`
is, at 84.7. The role selects for cost and latency instead, because
`inspect_image` runs in the foreground of a call the user is waiting on.

Sol at `low` scores 81.0 and answers in 3.28s, the highest score of any tier
under four seconds. Opus 5 at `low` is the nearest alternative and scores 1.2
points lower. The cost column separates them further, $0.23 against $0.43, but
that column prices one Intelligence Index task, not one image call. Treat it as
a relative price proxy between models, not as the cost of `inspect_image`.

MMMU-Pro is the image measurement in this table. It is multiple-choice reasoning
over images, not a test of screenshot description or of text extraction. Its
transfer to `inspect_image` work is therefore an inference, not a measurement.

Sources:

- [OMP model and provider configuration](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/models.md)
- [OMP bundled agent definitions](https://github.com/can1357/oh-my-pi/blob/v17.2.1/packages/coding-agent/src/task/agents.ts)
- [OMP inspect_image tool](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/tools/inspect_image.md)

## Intent: version floor per vendor

Model choice is bounded before any other consideration:

- OpenAI GPT: GPT-5.6 or later.
- Anthropic Claude: Claude Opus 5 or later.

The floor sets the model version, not the effort tier. Every tier of an allowed
model stays available, which is why the reference table below carries all five
tiers of only four models.

A floor removes a recurring decision. Older releases keep reappearing in
comparisons because they cost less per token, and each appearance costs a fresh
argument about whether the saving is worth the capability loss. Deciding once at
the vendor line ends that argument. A later release on the same line, for
example GPT-5.7, satisfies the floor with no change here.

The floor is stated in the repository context file, `AGENTS.md`, rather than in
`config.yml`. A configuration key can only pin the models this configuration
already selects, while the rule also has to reach a model choice made in prose,
such as a fallback chain proposed in review. The rule binds work in this
repository, which is where `config.yml` is edited, and it installs nothing into
the home directory.

Source:

- [OMP model and provider configuration](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/models.md)

## Reference: measured model tiers

This table carries every effort tier of every model this configuration uses,
not only the tiers currently selected. A change of effort therefore needs no
new measurement round. The table also carries GPT-5.6 Terra, which this
configuration does not use. Terra is the third Codex model, so the table is
where that choice stays checkable without a new measurement round.

Artificial Analysis reports the following, retrieved 2026-08-12 against
Intelligence Index v4.1.1. Every model listed has a 1,000,000-token context
window. "Time to first answer token" includes model thinking time. "Cost per
task" is the weighted average cost of one Intelligence Index task. "Image
(MMMU-Pro)" is the multiple-choice image evaluation, as a percentage.
Artificial Analysis runs it outside the Intelligence Index, so it does not
contribute to the index column.

| Model (tier) | Intelligence Index | Image (MMMU-Pro) | Output speed | Time to first answer token | Cost per task | Price in / out per 1M |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Opus 5 low | 52.5 | 79.8 | 52.7 tok/s | 3.08s | $0.43 | $5.00 / $25.00 |
| Opus 5 medium | 58.6 | 81.6 | 53.5 tok/s | 8.59s | $0.72 | $5.00 / $25.00 |
| Opus 5 high | 61.5 | 82.4 | 51.9 tok/s | 12.00s | $1.23 | $5.00 / $25.00 |
| Opus 5 xhigh | 62.5 | 84.0 | 52.2 tok/s | 25.09s | $1.80 | $5.00 / $25.00 |
| Opus 5 max | 63.1 | 84.7 | 54.1 tok/s | 58.23s | $2.34 | $5.00 / $25.00 |
| Sol low | 50.7 | 81.0 | 51.6 tok/s | 3.28s | $0.23 | $5.00 / $30.00 |
| Sol medium | 55.6 | 81.4 | 58.3 tok/s | 5.75s | $0.37 | $5.00 / $30.00 |
| Sol high | 57.3 | 81.8 | 56.7 tok/s | 15.73s | $0.55 | $5.00 / $30.00 |
| Sol xhigh | 59.0 | 82.7 | 60.7 tok/s | 43.35s | $0.81 | $5.00 / $30.00 |
| Sol max | 60.9 | 83.4 | 62.7 tok/s | 153.87s | $1.23 | $5.00 / $30.00 |
| Terra low | 41.3 | 76.1 | 102.3 tok/s | 1.67s | $0.094 | $2.00 / $12.00 |
| Terra medium | 46.8 | 76.8 | 103.6 tok/s | 1.50s | $0.12 | $2.00 / $12.00 |
| Terra high | 50.1 | 79.1 | 105.1 tok/s | 3.10s | $0.22 | $2.00 / $12.00 |
| Terra xhigh | 52.8 | 79.5 | 107.7 tok/s | 29.77s | $0.31 | $2.00 / $12.00 |
| Terra max | 56.6 | 80.7 | 123.2 tok/s | 173.50s | $0.51 | $2.00 / $12.00 |
| Luna low | 33.9 | 74.0 | 143.1 tok/s | 1.77s | $0.009 | $0.20 / $1.20 |
| Luna medium | 38.9 | 75.8 | 142.5 tok/s | 2.35s | $0.011 | $0.20 / $1.20 |
| Luna high | 47.0 | 77.6 | 164.8 tok/s | 14.68s | $0.022 | $0.20 / $1.20 |
| Luna xhigh | 50.1 | 78.6 | 157.7 tok/s | 50.93s | $0.032 | $0.20 / $1.20 |
| Luna max | 52.3 | 78.6 | 162.3 tok/s | 136.64s | $0.047 | $0.20 / $1.20 |

Terra is the price-and-speed member of the Codex family: $2.00 / $12.00 per 1M
tokens, and 102 to 123 output tokens per second against 52 to 63 for Sol. It
still loses on the axis this configuration selects for. Terra-max scores 56.6,
below Sol-high at 57.3 for a comparable cost per task. Terra-high scores 50.1,
which Luna-xhigh matches at 50.1 for one seventh of the cost. Artificial
Analysis states the same result: for every Terra effort level there is a Sol or
Luna level that is more intelligent at no extra cost, or as intelligent at
lower cost.

The Intelligence Index is a weighted composite of nine evaluations — agentic
work 34%, coding 24%, scientific reasoning 24%, general 18% — measured
text-only and in English. Artificial Analysis reports an aggregate 95%
confidence interval under ±1%, with wider intervals for individual evaluations,
and cautions that the aggregate may not transfer to any specific use case.
These figures compare benchmark behavior; they do not predict the duration of
an individual coding task.

Sources:

- [Claude Opus 5](https://artificialanalysis.ai/models/claude-opus-5)
- [GPT-5.6 Sol](https://artificialanalysis.ai/models/gpt-5-6-sol)
- [GPT-5.6 Terra](https://artificialanalysis.ai/models/gpt-5-6-terra)
- [GPT-5.6 Luna](https://artificialanalysis.ai/models/gpt-5-6-luna)
- [GPT-5.6 intelligence against cost](https://artificialanalysis.ai/articles/gpt-5-6-intelligence-vs-cost-across-sol-terra-luna)
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
measure as five distinct points. The Intelligence Index climbs from 52.5
through 58.6, 61.5, and 62.5 to 63.1. Time to first answer token rises from
3.08s to 58.23s. See `## Reference: measured model tiers` for the full table.

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
point that balances score, cost, and time to the first answer token.

All measured figures live in `## Reference: measured model tiers`; this
section cites only the ones the argument needs.

The case for Luna-high is that it is the knee of the curve. It scores 47.0 —
13.1 points above `low` at 33.9, and only 3.1 below `xhigh` at 50.1. Luna
costs $0.20 / $1.20 per 1M tokens against $5.00 / $30.00 for Sol, one
twenty-fifth of the Sol input price. Every Luna tier also generates output
faster than any Sol or Opus 5 tier. Measured against the Intelligence Index
as a whole, Luna-high costs $0.022 per task where Sol-max costs $1.23 and
Opus 5-max costs $2.34.

Time to first answer token is why the ladder stops here. It includes thinking
time. On Luna it does not rise smoothly: 1.77s at `low`, 2.35s at `medium`,
14.68s at `high`, then 50.93s at `xhigh` and 136.64s at `max`. The step from
`high` to `xhigh` costs 36 seconds and buys 3.1 index points. `commit` and
`tiny` run in the foreground of an otherwise finished action. There, that
delay would be the dominant term, and nothing about the higher score
shortens it.

`high` is also the cheaper tier outright: $0.022 per task against $0.032 at
`xhigh`. A workflow that wants these roles to feel instantaneous should drop
to `medium`. That tier returns the first answer token in 2.35s and scores
38.9, an 8.1-point drop from `high`.

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
    advisor:
      - anthropic/claude-opus-5:high
    openai-codex/gpt-5.6-luna:
      - openai-codex/gpt-5.6-sol:medium
      - anthropic/claude-opus-5:medium
    openai-codex/gpt-5.6-sol:
      - openai-codex/gpt-5.6-luna:max
    anthropic/claude-opus-5:
      - openai-codex/gpt-5.6-sol:high
```

Resolution picks the chain that owns the failing model by specificity: the
exact `provider/model-id` key first, then a `provider/*` wildcard, then the
role chain, then `default`. Two consequences shape the table above.

The `default` chain is not the chain for the `default` role. OMP copies it
onto every role that declares no chain of its own. It decides a recovery only
when no model key matches, because the exact `provider/model-id` keys are
tested first. Every model this configuration selects owns such a key, so the
`default` chain covers a model picked by hand with `/model`. Its first entry
names an Anthropic model, so that path also leaves the Codex provider.

Most chains must be able to leave the provider they started on. A quota wall is
provider-wide, so a chain that recovers a model onto its own provider is a dead
end for that failure. Anthropic failures move to Sol. Luna lists Sol first,
because a single model outage is more common than a provider outage, and Opus 5
second, for the case where the whole Codex provider is unavailable. The retry
policy skips selectors that are still cooling down, so the directions cannot
ping-pong.

The Sol chain is the deliberate exception. It recovers onto Luna at `max`, which
keeps delegated work inside Codex. Opus 5 max is reserved for the orchestrating
session. The previous entry, Opus 5 high, was the only route from a subagent
onto Opus. Luna shares the Codex quota, so this chain recovers a Sol-specific
outage or a classifier refusal, but not an account-wide limit.

OMP pins the fallback role at the first switch and reuses it. A Sol subagent
that fails again keeps walking this one-entry chain and stops. It never enters
Luna's own chain.

The policy preserves the purpose of each role across a provider outage:

- Opus-led work — `default`, `slow`, `plan`, `designer` — recovers to Sol-high,
  which scores 57.3. For `designer`, that is a fall from Opus 5-high at 61.5.
  For the roles at Opus 5-max, it is a fall from 63.1, so the loss is larger.
  The configuration accepts both losses because the alternative is no answer at
  all, and the recovered work still runs on a top-tier model rather than a
  cheaper one.
- `advisor` no longer recovers to Opus 5-high, and the `advisor` role chain that
  names it is now unreachable. Specificity puts the exact
  `openai-codex/gpt-5.6-sol` key ahead of any role chain, and that key now
  recovers to Luna at `max`. The advisor and every `task` subagent share one
  model, so one key decides both. This configuration resolves the conflict in
  favor of keeping subagents off Opus 5, and the advisor loses its cross-family
  property on the retry path: Luna-max scores 52.3 against Sol-high's 57.3. The
  role chain is retained because it costs nothing and becomes reachable again if
  the advisor moves to a model with no exact key of its own.
- The model-specific Opus 5 key covers every Opus-led role, including `plan`,
  which declares no role chain of its own. It takes precedence over the role
  chains, so all Opus 5 work recovers to Sol-high.
- Luna failures recover to Sol-medium first. Sol-medium scores 55.6 against
  Luna-high's 47.0 and reaches the first answer token in 5.75s against 14.68s
  for Luna-high. A mechanical role therefore degrades into a quicker, stronger,
  costlier model instead of a slower one. Sol costs twenty-five times the Luna
  token price: $5.00 against $0.20 per 1M input tokens. That price is
  acceptable on the retry path and would not be acceptable in steady state.

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
  agentModelOverrides:
    reviewer: "@task"
    security-reviewer: "@task"
    code-reviewer: "@task"
    plan-reviewer: "@task"
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

`task.agentModelOverrides` keeps Opus 5 max on the orchestrating session. Two
routes put subagents on it otherwise. The bundled `reviewer` declares `@slow` in
its frontmatter. The bundled `security-reviewer` and the `plan-lifecycle` plugin
agents declare no model, so they inherit the parent's active model. An override
outranks both frontmatter and the parent model, so pinning these four agents to
`@task` routes them to Sol-high. The review agents then run on a different model
family from the session they review, which keeps their findings independent.

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
Installed [`remote-pi`](https://github.com/jacobaraujo7/remote_pi) 0.7.0 meets
all three requirements. It registers `agent_send`, `agent_request`, and
`list_peers`. The bare `/remote-pi` command runs the setup wizard when the
current folder has no local configuration. No `/remote-pi join` command is
registered. For a configured folder, `/remote-pi` always joins the local mesh.

It starts the relay only when the local configuration enables relay auto-start.
An interactive session also connects automatically at startup when relay
auto-start is enabled.

Relay use costs confidentiality. Version 0.7.0 sends base64-encoded JSON without
encryption or a message authentication code. A relay operator can therefore see
routed plaintext.

Running `jacobmoura7/remote-pi-relay` under `docker run` and pointing the
extension at it removes that operator from the trust path. Both
`/remote-pi set-relay <url>` and `/remote-pi relay url <url>` persist a new relay
URL. Run `/remote-pi relay stop`. Then run `/remote-pi relay start` to apply it.
The stop command disconnects the relay and leaves the local mesh connected.

`/remote-pi relay status` prints the status panel. `/remote-pi config` prints
the effective relay URL and its source.

Contrast `/collab`, which seals every payload with AES-256-GCM before the
socket, so its relay sees only ciphertext, room ids, and frame sizes.

Peers are addressed as `<cwd>@<name>`, so addressing
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
sets one compaction ceiling, adds idle maintenance, and saves handoff
documents:

```yaml
compaction:
  thresholdTokens: 231200
  idleEnabled: true
  handoffSaveToDisk: true
```

Snapcompact archives older history locally into model-aware image frames rather
than requiring a separate summarization API call. Idle maintenance performs
context work while the session is not actively streaming.

A settings change reaches only OMP processes that start after it. OMP reads
the configuration once per process and installs no watcher on the file. A
session resumed in a new process therefore loads the current values, while an
instance left running keeps the ceiling it started with until it restarts.

`thresholdTokens` gives every model one working-set ceiling. Without it, OMP
compacts when the context passes the model window minus a reserve, and that
reserve is the larger of 16,384 tokens and 15% of the window. The rule scales
with the window rather than with the work: Claude Opus 5 declares 1,000,000
tokens and runs to 850,000, while GPT-5.6 Sol and GPT-5.6 Luna declare 272,000
and stop at 231,200. The tracked value is exactly that Codex figure, so the
setting changes nothing for Sol and Luna and brings Opus 5 to the same point.

The ceiling is global on purpose, because OMP has no per-model compaction
setting. Issue #6835 requests one. Two apparent alternatives were measured and
rejected:

- A per-model `contextWindow` override in `models.yml` moves the trigger, but
  it declares model capability rather than compaction policy. The same number
  also drives overflow detection, output budgets, retry fit checks, branch
  summary budgets, and the `/context` display, so it makes the harness believe
  Opus 5 is a smaller model than it is.
- A global `compaction.reserveTokens` large enough to lower Opus 5 alone looks
  safe, because a reserve larger than the whole window falls back to the
  proportional 15% reserve and leaves the Codex threshold at 231,200. It is not
  safe. Snapcompact sizes its frame budget and its post-render overflow check
  from the unclamped reserve, so a 616,000-token reserve gives a 272,000-token
  model a budget of -344,000. Snapcompact then aborts on every Codex
  compaction: one path throws, and the other degrades to context-full
  summarization through the model.

231,200 is a measured choice. Across 51 recorded Opus 5 compactions on this
machine, the trigger point had a median of 272,621 tokens and a 90th percentile
of 544,157, because idle maintenance at 200,000 tokens fired long before the
850,000 ceiling did. The ceiling therefore tightens a median that idle
maintenance already produced, and removes a tail that reached 793,039 tokens.

It also keeps the cross-provider escape usable. A retryable Anthropic error
moves the live session to Sol-high, and OMP does not yet check that the target
window can hold the context it is about to send; issue #8065 tracks the missing
check, and the fix in pull request #8068 is open and absent from 17.2.13. The
ceiling removes the large steady-state mismatch, which was 618,800 tokens, but
it does not guarantee a fit: compaction triggers only above the limit, so a
single large tool result can carry a turn past Sol's usable window before
maintenance runs. A ceiling of 200,000 would add 31,200 tokens of slack.

The cost is working room. One compaction leaves a floor near 81,510 tokens,
which is 23,254 tokens of system prompt, tool schemas, and skills, plus 21,652
tokens kept verbatim, plus the imaged archive and its text edges. That leaves
roughly 149,690 tokens of fresh evidence between two compactions on a
continuously active run. Idle maintenance still fires near 200,000 tokens after
five minutes, so a session that pauses keeps the cadence it had before. Three
levers cover a task that needs more: delegate bulk exploration to `task`
agents, which hold their own context; run `/shake` to trade large tool results
for recoverable `artifact://` references; or start one run with an overlay,
`omp --config <file>`, that raises the ceiling without changing the tracked
configuration.

Sources:

- [OMP compaction and snapcompact behavior](https://github.com/can1357/oh-my-pi/blob/v17.2.1/docs/compaction.md)
- [OMP issue 6835: per-model compaction thresholds](https://github.com/can1357/oh-my-pi/issues/6835)
- [OMP issue 8065: oversized context on retry fallback](https://github.com/can1357/oh-my-pi/issues/8065)
- [OMP pull request 8068: fit-check retry fallback](https://github.com/can1357/oh-my-pi/pull/8068)

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
