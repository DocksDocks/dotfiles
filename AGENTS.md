# dotfiles repository rules

## Model floor

`omp/config.yml` selects a model for every OMP role and every fallback chain
entry. Only these model versions may appear there:

- OpenAI GPT: GPT-5.6 or later.
- Anthropic Claude: Claude Opus 5 or later.

The floor governs the models this configuration selects. These are the role
assignments in `modelRoles` and the entries of every fallback chain. A fallback
chain key is not a selection. Such a key names a model that already failed, so
it may name a model outside the floor when the user selects that model by hand.
The entries of that chain must still satisfy the floor.

The floor sets the model version, not the effort tier. Every effort tier of an
allowed model is allowed. A later release on the same vendor line, for example
GPT-5.7, satisfies the floor without a change to this rule.

Never propose an older release as a candidate, in configuration or in a
comparison, whatever its price advantage. Stating a fact about an older release
stays permitted when the reader asks about that release directly.

## Fallback chains

`retry.fallbackChains` in `omp/config.yml` names the model that replaces a
failing model. Every entry of a chain must name a provider different from the
provider of the failing model.

The quota shape of the OpenAI Codex plan sets this rule. The models
`gpt-5.6-sol`, `gpt-5.6-luna`, and `gpt-5.6-terra` all draw on one account
window, the weekly chat window. Only a model identifier that contains `-spark`
draws on the separate Spark window. A cooldown, in contrast, suppresses one
model identifier at a time. A second Codex entry therefore looks available
after the first Codex entry fails, and the harness spends a request that the
exhausted window rejects again.

An entry that names the failing model at another effort tier is also dead. The
cooldown key drops the effort suffix, so `claude-opus-5:medium` stays
suppressed while `claude-opus-5:max` cools down.

Keep every chain short. One cross-provider entry is enough. When that entry is
unavailable, the retry loop must wait for the primary model instead of moving
to a lighter model, because a lighter model degrades the role for the rest of
the turn.
