# Skills

Skills are reusable technique descriptions that teach the assistant how to
combine tools effectively for specific tasks. Unlike agents (which run
autonomously), skills are injected into the system prompt as knowledge the
assistant can draw on.

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

The markdown body after the frontmatter is the actual skill content injected
into the system prompt. You can use `{{skill_dir}}` in the body, which is
replaced with the absolute path to the skill's directory.

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

## Resolution Order

When the same skill name exists in multiple locations, the first match wins:

1. Project-level: `.sia/skills/`
2. Global: `~/.config/sia/skills/`
3. Extra paths from `skills_extras`

## Skills vs Agents

|                   | Skills                                                | Agents                                   |
| ----------------- | ----------------------------------------------------- | ---------------------------------------- |
| **How they work** | Injected into the system prompt as knowledge          | Run as separate autonomous conversations |
| **Tool use**      | Assistant uses its own tools, guided by skill content | Agent has its own dedicated tool set     |
| **Interaction**   | Part of the main conversation                         | Background task with results returned    |
| **Use case**      | Teaching techniques and workflows                     | Delegating independent subtasks          |
