# Claude instructions

## Models and Delegation

How Claude sessions divide work in this repository, local or remote.

- The session's own model designs, decides, writes the specs and reviews. It does not do bulk reading or implementation.
- Subagents run on a cheaper model: the `builder` agent (Haiku) for work that can be specified exactly, and the `investigator` agent (Sonnet) for work that needs judgment that cannot be written down in advance, such as debugging. Where those agent types do not exist, use `general-purpose` with `model: "haiku"` or `model: "sonnet"`. Never run a subagent on Opus or Fable unless asked.
- One subagent at a time unless asked for speed. Cut work so each part fits one context.
- Every spec says what is already done, what is left, what done looks like and what to report.
- Subagents commit in small steps and stop at a clean checkpoint when cut off.
