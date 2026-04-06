# Skills

Skills are reusable technique descriptions that teach the assistant how to
combine tools effectively for specific tasks. Unlike agents (which run
autonomously), skills give the assistant reusable workflows it can draw on.

## Creating Skills

A skill is a directory containing a `SKILL.md` file with YAML frontmatter and
a markdown body.

```
~/.config/sia/skills/
  monitor-logs/
    SKILL.md
  tmux-interactive/
    SKILL.md
```

### Skill File Format

```markdown
---
name: monitor-logs
description: Monitor and analyze log files for errors and patterns
tools:
  - bash
  - grep
  - view
---

# Monitor Logs

When asked to monitor or analyze logs, follow these steps:

1. Use `bash` to tail the log file or check recent entries.
2. Use `grep` to search for error patterns.
3. ...
```

### Frontmatter Fields

| Field           | Required | Description                                        |
| --------------- | -------- | -------------------------------------------------- |
| **name**        | yes      | Must match the directory name                      |
| **description** | yes      | Shown to the AI as a trigger description           |
| **tools**       | no       | Tool names the skill requires (used for filtering) |

The markdown body after the frontmatter is the actual skill content. If the
skill refers to supporting files, scripts, or examples, keep those files next
to `SKILL.md` and describe them from the skill itself. When Sia injects a skill
explicitly, it includes both the `SKILL.md` path and the skill directory so the
assistant can inspect those files directly.

## Enabling Skills

List skill names in your [project config](../3-configuration/3-project.md):

```json
{
  "skills": ["monitor-logs", "tmux-interactive"],
  "skills_extras": ["~/my-custom-skills"]
}
```

A skill is included in the system prompt only if:

1. It is listed in the `skills` array.
2. All tools listed in the skill's `tools` field are available in the current
   conversation.

Configured skills are advertised in the base prompt by name and description so
the assistant knows they exist.

## Invoking a Skill Explicitly

Use `:Sia -s <skill> [query]` to apply a skill immediately, even if it is not
listed in the project's `skills` array.

For explicit invocation, Sia:

1. Resolves the named skill using the normal search order.
2. Verifies that the conversation has all tools required by the skill.
3. Adds a hidden user message containing the skill body, the `SKILL.md` path,
   and the skill directory.

This works for both a new conversation and an already-running chat. Because the
skill arrives as a hidden user message, it affects the current turn without
rewriting the conversation's system prompt. The hidden message is also kept in
the chat history, so follow-up turns continue to see the explicitly invoked
skill until the relevant history is pruned away.

## Resolution Order

When the same skill name exists in multiple locations, the first match wins:

1. Project-level: `.sia/skills/`
2. Global: `~/.config/sia/skills/`
3. Extra paths from `skills_extras`

## Skills vs Agents

|                   | Skills                                                | Agents                                   |
| ----------------- | ----------------------------------------------------- | ---------------------------------------- |
| **How they work** | Guide the main assistant with reusable workflow text  | Run as separate autonomous conversations |
| **Tool use**      | Assistant uses its own tools, guided by skill content | Agent has its own dedicated tool set     |
| **Interaction**   | Stay inside the main conversation                     | Background task with results returned    |
| **Use case**      | Teaching techniques and workflows                     | Delegating independent subtasks          |
