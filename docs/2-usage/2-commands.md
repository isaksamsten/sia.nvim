# Commands

## Main Commands

| Command                        | Description                                       |
| ------------------------------ | ------------------------------------------------- |
| `:Sia [query]`                 | Start or continue a chat conversation             |
| `:Sia /action [query]`         | Run a named action with optional extra text       |
| `:Sia @mode [query]`           | Start a chat in a conversation mode               |
| `:Sia /action @mode [query]`   | Run an action in a conversation mode              |
| `:Sia! [query]`                | Insert generated text at cursor (insert mode)     |
| `:'<,'>Sia [query]`            | Send selection to chat                            |
| `:'<,'>Sia! [query]`           | Show suggested changes as inline diff (diff mode) |
| `:Sia -m model [query]`        | Override the model for this conversation          |

Any Vim range works. For example, `:%Sia explain this file` sends the entire
buffer to chat.

### Buffer-Local Default Prompt

You can set `vim.b.sia` to define a default prompt for a buffer. When set,
`:Sia` without arguments uses this prompt automatically:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function() vim.b.sia = "/doc numpydoc" end,
})
```

## Context Management

| Command                   | Description                                             |
| ------------------------- | ------------------------------------------------------- |
| `:SiaAdd file <pattern>`  | Add file(s) matching a glob pattern (e.g., `src/*.lua`) |
| `:SiaAdd buffer <buffer>` | Add a buffer by name or number                          |
| `:'<,'>SiaAdd context`    | Add the current visual selection                        |

If no conversation is visible, context is queued and added to the next new
conversation.

## Change Management

| Command                  | Description                                                     |
| ------------------------ | --------------------------------------------------------------- |
| `:SiaAccept`             | Accept the change under the cursor                              |
| `:SiaReject`             | Reject the change under the cursor                              |
| `:SiaAccept!`            | Accept all changes in the current buffer                        |
| `:SiaReject!`            | Reject all changes in the current buffer                        |
| `:SiaDiff`               | Show all changes in a diff view                                 |
| `:SiaRollback [turn_id]` | Roll back changes from a turn onward (tab-completion available) |

See [Reviewing Changes](3-reviewing-changes.md) for details.

## Tool Approval

| Command               | Description                                    |
| --------------------- | ---------------------------------------------- |
| `:SiaConfirm prompt`  | Show the confirm prompt for pending operations |
| `:SiaConfirm accept`  | Auto-accept pending operations                 |
| `:SiaConfirm always`  | Persist an allow rule and execute              |
| `:SiaConfirm decline` | Auto-decline pending operations                |
| `:SiaConfirm preview` | Preview pending operations                     |

Add `!` (e.g., `:SiaConfirm! accept`) to process only the first pending item.

See [Confirmation](../4-permissions/1-confirmation.md) for the full approval
system.

## Conversation Management

| Command             | Description                                          |
| ------------------- | ---------------------------------------------------- |
| `:SiaClear`         | Remove outdated tool calls from conversation history |
| `:SiaFork <prompt>` | Fork the current conversation into a new chat buffer |
| `:SiaDebug`         | Show the conversation's JSON payload in a new buffer |

`:SiaFork` supports `-t <turn_id>` to specify which turn to fork from (keeps
messages before that turn). Tab-completion is available for turn IDs.

## Shell Process Management

| Command               | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `:SiaShell`           | List all bash processes for the current conversation |
| `:SiaShell stop <id>` | Send SIGTERM to a running background process         |

## Agent Management

| Command                         | Description                                              |
| ------------------------------- | -------------------------------------------------------- |
| `:SiaAgent start <name> <task>` | Start an agent manually with a task                      |
| `:SiaAgent open <id>`           | Open an agent as an interactive chat (toggle if running) |
| `:SiaAgent complete`            | Send the agent chat result back to the parent            |
| `:SiaAgent cancel <id>`         | Cancel a running or completed agent                      |

See [Agents](../5-features/2-agents.md) for the full agent interaction
workflow.

## Authentication

| Command            | Description                                          |
| ------------------ | ---------------------------------------------------- |
| `:SiaAuth codex`   | Authenticate with OpenAI Codex (browser-based OAuth) |
| `:SiaAuth copilot` | Authenticate with GitHub Copilot (device flow)       |
