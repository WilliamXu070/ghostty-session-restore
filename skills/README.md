# Newmux Agent Skills

Each subdirectory is a reusable skill for a specific agent workflow. Skills contain reference materials, scripts, and templates that agents can load when a task matches the skill's description.

## Skill Index

| Skill Directory | Purpose | Status |
|---|---|---|
| `recovery-testing/` | Testing soft-delete, recovery stack, restore flows | Empty — populate when needed |
| `recovery-testing/reference/` | Recovery data structures, command signatures | Empty |
| `recovery-testing/scripts/` | Reusable test helpers for recovery | Empty |
| `scroll-bridge/` | Ghostty scroll bridge integration, tuning | Empty |
| `scroll-bridge/reference/` | Scroll metadata structs, constants | Empty |
| `tmux-build/` | Building newmux fork, autoconf, signing | Empty |
| `testing-golden-flow/` | Writing golden flow tests, assertion patterns | Empty |
| `dashboard/` | Recovery dashboard TUI, UI bridge client | Empty |

## When to Create or Update a Skill

- A bug is fixed with a reusable testing pattern
- A stable API strategy is discovered
- A repo-specific implementation detail is learned
- A workflow is repeated across multiple tasks

## Skill File Convention

Each skill uses:
- `SKILL.md` — main skill instructions (loaded by agent)
- `reference/` — reference docs, struct layouts, config snippets
- `scripts/` — reusable shell/Python scripts for the skill

See `AGENTS.md` → Skill Update Rule for the required format.
