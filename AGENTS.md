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
