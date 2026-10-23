# Project Configuration

You can customize Sia for a specific project by creating `.sia/config.json` in
the project root. Local settings override global ones.

## Setting options from Neovim

Use `:SiaConfig` to inspect effective model and context settings, or provide a
dot-separated path and a scalar value to save a project override:

```vim
:SiaConfig model codex/gpt-6-sol
:SiaConfig model.coding.mini codex/gpt-6-luna
:SiaConfig model.default.default.options.reasoning.effort high
:SiaConfig context.tools.max_calls 50
:SiaConfig context.tools.strip_inputs false
:SiaConfig action.chat code/assistant
```

A path without a value displays its effective value. `:SiaConfig! <path>` removes
the generated override. Model names may be quoted as JSON strings. Model option
values accept strings, numbers, and booleans. Context paths support tool limits,
input stripping, pruning fractions, and compaction fractions.

Changes are written to `.sia/auto.json`. Model and context precedence is global
settings, then `config.json`, then `auto.json`. Options-only overrides require
an inherited model at that exact role/tier. `SiaConfig model <name>` sets all
tiers of the default role.

`SiaConfig action.chat <name>` selects an existing agent or globally configured
Lua action for the default chat, with completion for both. Use
`:SiaConfig action.chat` to inspect the selection and `:SiaConfig! action.chat`
to remove the generated override.

### Skills and agents

```vim
:SiaConfig skill +my-skill
:SiaConfig skill -my-skill
:SiaConfig! skill
:SiaConfig agent +code/review
```

Skills and agents combine the lists in `config.json` and `auto.json`, without
duplicates. Adding an enabled entry is a no-op. Removing an entry, or clearing
the list with `!`, only removes generated entries from `auto.json` so that
handwritten entries remain enabled. Use `skill` or `agent` without arguments to
inspect the effective list. Both support the same add, remove, and clear
syntax.

## Example

```json
{
  "model": {
    "default": {
      "default": "copilot/gpt-5-mini",
      "mini": {
        "name": "openai/gpt-4.1",
        "options": { "temperature": 0.1 }
      },
      "pro": "openai/gpt-5.2"
    },
    "vision": "openai/gpt-5.2"
  },
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
      "compact": { "oldest_fraction": 0.4 },
      "media": {
        "max_bytes": 8388608,
        "keep_last": 1
      }
    }
  },
  "skills": ["monitor-logs", "tmux-interactive"],
  "skills_extras": ["~/my-custom-skills"],
  "agents": ["code/review", "code/explore"]
}
```

## Available Options

### Model Overrides

- **model** — override [model roles and tiers](2-models.md#model-roles-and-tiers).
  Accepts a model name for all default tiers, or an object mapping role names to
  model names or tier objects. Model leaves also accept `{ "name": "...", "options": {...} }`.
  Local tiers override global tiers; other roles and tiers are preserved.
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

  Claude Code model overrides use the underlying Anthropic request fields. For
  example:

  ```json
  {
    "models": {
      "claude": {
        "sonnet-4-6": {
          "max_tokens": 16000,
          "thinking": { "type": "adaptive", "display": "summarized" },
          "output_config": { "effort": "high" }
        }
      }
    }
  }
  ```

  For `thinking`, Sia passes through Anthropic's supported fields such as
  `type`, `budget_tokens`, and `display`.

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

### Chat Agent

Set **action.chat** to an existing agent name to use its system prompt, tools,
tool approvals, model selection, and capability requirements for the default chat:

```json
{
  "action": { "chat": "code/assistant" }
}
```

The agent is loaded from the existing global or project-local `agents/`
directories. Agent definitions take precedence over globally configured Lua
actions with the same name. Chat UI settings and initial user context are
retained from the default action. If no matching agent exists, the name selects
a globally configured Lua action.

### Context Settings

- **context** — project-specific context retention settings. Same structure as
  the global `context` option:
  - **tools** — tool call pruning (`max_calls`, `preserve`, `strip_inputs`, `keep_last`)
  - **tokens** — token-budget control (`prune.at_fraction`, `prune.to_fraction`, `compact.oldest_fraction`, `media.max_bytes`, `media.keep_last`)

Local `context` values override the global value directly, including arrays such
as `context.tools.preserve`.

### Agents and Skills

- **agents** — array of agent names to enable from `~/.config/sia/agents/`
  or `.sia/agents/`. Use this for project-local overrides. For
  action-specific workflows, a chat action can also declare its own `agents`
  set directly. See [Agents](../5-features/2-agents.md).
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
