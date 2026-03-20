# Agents

Agents are specialized assistants that the AI can launch autonomously to handle
subtasks. Each agent has its own tools, system prompt, and conversation,
running in the background while the main conversation continues.

## Creating Agents

1. Create an agent definition file in `.sia/agents/` (project-level) or
   `~/.config/sia/agents/` (global).
2. List the agent name in your [project config](../3-configuration/3-project.md)
   under the `agents` key.

### Agent File Format

Agent files are markdown with YAML frontmatter:

```markdown
---
description: Searches through code to find patterns, functions, or implementations
tools:
  - glob
  - grep
  - view
model: openai/gpt-4.1
require_confirmation: false
interactive: false
---

You are a code search specialist. When given a search task, use the available
tools to find relevant code patterns, function definitions, and implementations.
Report your findings clearly with file paths and line numbers.
```

### Frontmatter Fields

| Field                    | Required | Default      | Description                                                        |
| ------------------------ | -------- | ------------ | ------------------------------------------------------------------ |
| **description**          | yes      | —            | Shown to the AI when listing available agents                      |
| **tools**                | yes      | —            | Array of tool names the agent can use                              |
| **model**                | no       | `fast_model` | Override the model for this agent                                  |
| **require_confirmation** | no       | `true`       | Whether tool operations need user approval                         |
| **interactive**          | no       | `false`      | Open the agent as an interactive chat automatically when it starts |

### Naming

The agent name is derived from the file path relative to the agents directory:

- `.sia/agents/searcher.md` is `searcher`
- `.sia/agents/code/review.md` is `code/review`
- `~/.config/sia/agents/docs/writer.md` is `docs/writer`

### Enabling Agents

Agents must be listed in your project's `.sia/config.json` to be available:

```json
{
  "agents": ["code/review", "code/explore", "searcher"]
}
```

### Resolution Order

When the same agent name exists in multiple locations, the first match wins:

1. Project-level: `.sia/agents/`
2. Global: `~/.config/sia/agents/`

## How Agents Work

1. The main conversation's AI uses the `agent` tool to list available agents.
2. When it identifies a matching agent, it launches it with a task description.
3. The agent runs in the background with its own conversation and tools.
4. Progress updates appear in the status panel (press `a` in the chat buffer).
5. Results are returned to the main conversation when the agent completes.

You can also start agents manually with `:SiaAgent start <name> <task>` from
any chat buffer. Manually started agents are attached as hidden context on
your next message, so the assistant sees their results automatically.

## Interacting with Agents

### Status Panel

Toggle the status panel in a chat buffer to see running and completed agents.
You can also call `require("sia").ui.status()` programmatically.

The status panel supports these keybindings:

| Key     | Action                                |
| ------- | ------------------------------------- |
| `<CR>`  | Toggle expanded details for the item  |
| `=`     | Toggle expanded details for the item  |
| `s`     | Cancel the agent or stop the process  |
| `e`     | Open the agent as an interactive chat |
| `n`     | Jump to the next item                 |
| `p`     | Jump to the previous item             |
| `r`     | Refresh the panel                     |
| `q`     | Close the panel                       |
| `<Esc>` | Close the panel                       |

### Opening an Agent as a Chat

You can open any running or completed agent as a full interactive chat buffer.
This lets you review the agent's conversation, send follow-up messages, and
refine the output before returning it to the parent conversation.

To open an agent, use one of these methods:

- Press `e` on an agent in the status panel.
- Run `:SiaAgent open <id>` from the parent chat buffer.
- Set `interactive: true` in the agent's frontmatter to open it automatically
  whenever it starts, whether launched by the AI or by `:SiaAgent start`.

If the agent is still running, it is flagged to open when it completes. Press
`e` again (or re-run the command) to toggle the flag off. If the agent has
already completed, the chat opens immediately.

The opened chat buffer shows the agent ID and a link to the parent conversation
in the winbar.

### Completing an Agent Chat

After reviewing or refining the agent's output in the opened chat, run
`:SiaAgent complete` to send the last assistant message back to the parent
conversation. This closes the agent chat buffer.

If you close the agent chat buffer without completing, the agent is cancelled.

### Cancelling an Agent

Cancel a running or completed agent with `:SiaAgent cancel <id>` or press `s`
on the agent in the status panel.

## Agent Commands

All `:SiaAgent` subcommands operate in the context of the current chat buffer.

| Command                         | Description                                              |
| ------------------------------- | -------------------------------------------------------- |
| `:SiaAgent start <name> <task>` | Start an agent manually with a task                      |
| `:SiaAgent open <id>`           | Open an agent as an interactive chat (toggle if running) |
| `:SiaAgent complete`            | Send the agent chat result back to the parent            |
| `:SiaAgent cancel <id>`         | Cancel a running or completed agent                      |

Tab-completion is available for subcommands, agent names, and agent IDs.

## Tips

- Set `require_confirmation: false` for read-only agents to avoid interruptions.
- Set `interactive: true` for agents that need user review or follow-up questions
  before their result goes back to the parent conversation.
- Keep system prompts focused and specific to the agent's purpose.
- Choose minimal tool sets, agents work better with fewer, relevant tools.
- Use descriptive names that help the AI understand when to use each agent.
- Open an agent as a chat when you want to iterate on its output before the
  parent conversation sees the result.
