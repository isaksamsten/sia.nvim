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
  "plan_model": "openai/o3-mini",
  "auto_continue": true,
  "action": {
    "insert": "custom_insert_action",
    "diff": "custom_diff_action",
    "chat": "custom_chat_action"
  },
  "context": {
    "max_tool": 50,
    "exclude": ["grep", "glob"],
    "clear_input": false,
    "keep": 10
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
- **models** — override parameters for specific models by name:

  ```json
  {
    "models": {
      "openai/gpt-5.1": {
        "options": { "reasoning_effort": "medium" }
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

- **context** — project-specific tool pruning settings. Same fields as the
  global `context` option (`max_tool`, `exclude`, `clear_input`, `keep`).

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

### Other Options

- **auto_continue** — when set to `true`, Sia automatically continues
  execution when a tool operation is cancelled, without prompting. Useful for
  automated workflows. Default: `false`.

## Auto-Persisted Rules

When you answer a tool confirmation prompt with "always", Sia writes an allow
rule to `.sia/auto.json`. This file has the same format as the `permission`
section and is loaded alongside `config.json`. You can edit or delete it
manually.

