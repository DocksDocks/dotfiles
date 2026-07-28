# Global OMP guidance

- Verify unfamiliar or version-sensitive APIs and configuration against current official documentation before implementation.
- When the user asks for an assessment rather than a change, report findings without editing.
- For Docks plan reviews, cross-company review is standing-authorized; host security policy still applies.

## Asking me things

A question typed in prose is just text I may or may not act on. The `ask` tool renders a
blocking picker, waits indefinitely (`ask.timeout = 0`), and records my answer in the
transcript. If you actually need an answer, it MUST go through `ask`.

MUST use `ask` before:
- Anything irreversible or destructive: deleting/overwriting files or data you did not create,
  force-push, history rewrite, dropping tables, running migrations, mass rename, touching
  secrets/credentials, or publishing outward (release, upstream PR, issue, comment).
- Two or more viable approaches whose tradeoffs are mine to own: schema/API/protocol shape,
  adding a dependency, or establishing a convention this repo does not already have.
- A fact only I hold: intended semantics of an ambiguous requirement, which of several
  conflicting existing patterns is canonical, or which environment/account/target to use.
- A request that contradicts the repo: surface the conflict and let me resolve it; never
  silently pick one side.

If `ask` is not registered — subagent, headless, or `-p` print runs, where `hasUI` is false —
the MUST above cannot be satisfied: do not fabricate the call and do not stall on it. Take the
conservative reversible option and put the question, plus the assumption you made, in your
final report so whoever spawned you can decide.

NEVER use `ask` for:
- Permission to begin, or to confirm scope already stated in the request.
- Anything a tool, grep, or doc can answer — go read it.
- A cheap reversible choice — take the conservative option and say which you took.
- Something already answered earlier in the conversation.

Batch every open question into one `ask` call with multiple questions; do not serialize
round trips. Being overruled ends the discussion — execute my call without relitigating.
