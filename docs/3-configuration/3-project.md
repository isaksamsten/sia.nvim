# Project Configuration

You can customize Sia for a specific project by creating `.sia/config.json` in
the project root. Local settings override global ones.

## Example

```json
{
  "model": "copilot/gpt-5-mini",
  "fast_model": {
    "name": "openai/gpt-4.1-mini",
    "options": { "temperature": 0.1 }
  },
  "plan_model": "openai/gpt-5.2",
  "action": {
    "insert": "custom_insert_action",
    "diff": "custom_diff_action",
    "chat": "custom_chat_action"
  },
  "context": {
    "tools": {
      "max_calls": 50,
      "preserve": ["grep", "glob"],
      "strip_inputs": false,
      "keep_last": 10
    },
    "tokens": {
      "prune": {
        "at_fraction": 0.9,
        "to_fraction": 0.75
      },
      "compact": { "oldest_fraction": 0.4 }
    }
  },
  "skills": ["monitor-logs", "tmux-interactive"],
  "skills_extras": ["~/my-custom-skills"],
  "agents": ["code/review", "code/explore"]
}
```

## Available Options

### Model Overrides

- **model** — override the main model. Accepts a string (`"openai/gpt-4.1"`)
  or an object (`{ "name": "openai/gpt-4.1", "options": { "temperature": 0.7 } }`).
- **fast_model** / **plan_model** — same format as **model**.
- **models** — override parameters for specific models, organized by provider:

  ```json
  {
    "models": {
      "openai": {
        "gpt-5.1": { "reasoning_effort": "medium" }
      }
    }
  }
  ```

- **aliases** — create shorthand names for models with custom parameters:

  ```json
  {
    "aliases": {
      "codex-high": {
        "name": "codex/gpt-5.3-codex",
        "options": { "reasoning_effort": "high" }
      }
    }
  }
  ```

  Use with `:Sia -m codex-high your prompt here`.

### Action Overrides

- **action** — override the default action for each interaction mode:
  - **insert** — used by `:Sia!`
  - **diff** — used by `:'<,'>Sia!`
  - **chat** — used by `:Sia`

  Each field should reference an action name defined in your global
  configuration. See [Actions](../5-features/1-actions.md).

### Context Settings

- **context** — project-specific context retention settings. Same structure as
  the global `context` option:
  - **tools** — tool call pruning (`max_calls`, `preserve`, `strip_inputs`, `keep_last`)
  - **tokens** — token-budget control (`prune.at_fraction`, `prune.to_fraction`, `compact.oldest_fraction`)

Local `context` values override the global value directly, including arrays such
as `context.tools.preserve`.

### Agents and Skills

- **agents** — array of agent names to enable from `~/.config/sia/agents/`
  or `.sia/agents/`. See [Agents](../5-features/2-agents.md).
- **skills** — array of skill names to enable from `~/.config/sia/skills/`,
  `.sia/skills/`, or extra paths. See [Skills](../5-features/3-skills.md).
- **skills_extras** — additional directory paths to search for skill
  definitions.

### Permissions and Risk

- **permission** — fine-grained tool access control. See
  [Permission Rules](../4-permissions/2-rules.md).
- **risk** — visual risk level indicators. See
  [Permission Rules](../4-permissions/2-rules.md#risk-levels).

## Auto-Persisted Rules

When you answer a tool confirmation prompt with "always", Sia writes an allow
rule to `.sia/auto.json`. This file has the same format as the `permission`
section and is loaded alongside `config.json`. You can edit or delete it
manually.
