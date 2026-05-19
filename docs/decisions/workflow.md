# Workflow

Non-trivial work moves through a lightweight, artifact-based chain.

## Default Chain

```text
Coordinator
  -> packet (docs/decisions/packets/)
  -> implementation
  -> review
  -> QA
  -> MEMORY.md and QUEUE.md updates
```

## Rules

- No non-trivial implementation without a packet.
- One packet, one intent — no scope expansion mid-change.
- Non-trivial changes require deterministic verification.
- Update `MEMORY.md` and `QUEUE.md` when work state or durable knowledge
  changes.
