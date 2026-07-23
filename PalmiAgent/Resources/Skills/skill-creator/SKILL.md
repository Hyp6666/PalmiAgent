---
name: skill-creator
description: Create or update reusable Palmi skills. Use when the user explicitly asks to create, package, revise, or install a skill with specialized instructions, references, scripts, or assets.
---

# Skill Creator

Create concise, reusable skill packages inside the current Palmi project workspace, then install them with `import_skill`.

## Required structure

Create one folder named exactly after the skill:

```text
skill-name/
├── SKILL.md
├── scripts/       optional deterministic helpers
├── references/    optional detailed knowledge loaded on demand
└── assets/        optional templates or output resources
```

Do not add README files, installation guides, changelogs, or other process documentation.

## Write SKILL.md

Use only `name` and `description` in YAML frontmatter:

```markdown
---
name: skill-name
description: State what the skill does and the user requests or situations that should trigger it.
---

# Skill Name

Write imperative, task-focused instructions here.
```

Follow these rules:

- Use lowercase letters, digits, and hyphens for `name`; keep it at most 64 characters.
- Make the folder name exactly match `name`.
- Put all trigger guidance in `description`, because only metadata is available before the skill is read.
- Keep SKILL.md focused and preferably below 500 lines.
- Move detailed schemas, variants, and long examples into `references/` and link to them directly from SKILL.md.
- Use `scripts/` only for repeatable deterministic work; do not assume importing a skill executes a script.
- Use `assets/` for templates and resources that should be copied or transformed, not loaded as instructions.
- Avoid duplicating the same information between SKILL.md and references.

## Mobile sandbox workflow

1. Clarify the intended triggers and concrete usage examples when they are not already clear.
2. Plan only the reusable files the skill actually needs.
3. Use `workspace` and `edit` to create the skill folder in the current project workspace.
4. Review SKILL.md and every referenced file for consistency.
5. Call `import_skill` with the workspace-relative folder path.
6. If validation fails, fix the reported files in the project workspace and call `import_skill` again.

Never attempt to access desktop paths such as `$HOME`, `~/.codex/skills`, or `CODEX_HOME`. The installed skill container is intentionally closed; `import_skill` is the only supported write path into it.

When updating an installed skill, rebuild the complete package in the project workspace and call `import_skill` with `replace_existing=true`. System skills cannot be replaced.
