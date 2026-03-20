# Interaction Modes

Sia supports three interaction modes. Each mode determines how the assistant
responds and how its output is presented.

## Chat Mode

**Usage:** `:Sia [query]` or `:Sia /action [query]`

Chat mode opens a conversational interface in a split window. The assistant can
use tools (read files, search code, run shell commands, make edits) and
maintains conversation history across multiple exchanges.

Chat mode is suited for:

- Exploring and understanding a codebase
- Multi-step problem solving where the assistant gathers information
- Code review and architectural discussions
- Tasks that require tool use (file edits, searches, shell commands)

The chat window persists, so you can continue the conversation by typing
follow-up queries. When the assistant makes file edits, you can review them
with the [change review workflow](3-reviewing-changes.md).

### Compose Window

You can open a floating compose window to start a new conversation with
optional model selection:

```lua
require("sia").chat.compose()
```

Keybindings in the compose window:

- `<CR>` — submit the prompt
- `m` — select a different model
- `q` or `<Esc>` — close

### Chat Window Features

Inside a chat buffer (`ft=sia`), you have access to several views:

- **Todos** — when the assistant works on multi-step tasks, it creates a todo
  list to track progress. Toggle the todo panel to see current status.
- **Status** — shows running agents and background processes. Toggle it to
  monitor autonomous work.
- **Messages** — browse individual messages in the conversation.
- **Contexts** — open a quickfix list showing all files and selections
  referenced in the conversation.

See [Keybindings](4-keybindings.md) for the chat buffer mappings.

### Task Tracking with Todos

When you ask Sia to work on a task with multiple steps, it automatically breaks
the work into a todo list and updates the status as it progresses (pending →
active → done). You can view the todo list in the floating panel, or ask
"what's the status?" at any time.

The todo list is collaborative. You can manually update statuses, skip steps, or
mark items as done. Sia respects your changes and adjusts its plan accordingly.

https://github.com/user-attachments/assets/0db7be98-2ec5-4bba-ba51-3afe8201f0ae

### Concurrent Conversations

Sia supports running multiple conversations at the same time. Each conversation
maintains its own independent view of file changes.

When conversation A edits a file that conversation B has also read, conversation
A continues to see the original content it read (so it understands what it
changed), while conversation B sees the content marked as outdated and knows to
re-read the file if needed.

### Conversation Modes

Chat actions can define conversation modes that temporarily restrict which
tools are available and how the assistant behaves. A mode sets up allow/deny
rules for tools, injects a guiding prompt when entered, and provides an exit
prompt when the assistant finishes.

Activate a mode when starting a conversation with the `@mode` syntax:

```vim
:Sia @plan refactor the authentication module
:Sia /action @plan add caching support
```

Inside an existing chat, type `@mode` followed by your query to switch modes:

```vim
@plan redesign the config loading
```

Use `@default` to return to unrestricted mode without ending the conversation.

The built-in **plan** mode restricts the assistant to read-only exploration
tools and limits file writes to a `PLAN_*.md` document. The assistant analyzes
the codebase, identifies affected files and risks, and writes an ordered
implementation plan. When it finishes, it calls the `exit_mode` tool to return
to full access and can then follow the plan.

Plan mode uses `truncate = true`, which means all the intermediate exploration
and planning messages are removed from the conversation history when the mode
exits. Only the exit prompt (which references the plan file) remains, keeping
the context window clean for the implementation phase.

The active mode name appears in the winbar next to the conversation ID.

You can define custom modes in your action configuration. See
[Actions](../5-features/1-actions.md) for the mode definition format.

## Insert Mode

**Usage:** `:Sia! [query]` (without a range)

Insert mode generates text and places it directly at the cursor position. The
assistant outputs only the content to insert, without explanations or markdown
formatting.

Insert mode is suited for:

- Code generation at the cursor
- Writing boilerplate
- Generating documentation or comments
- Quick text generation

https://github.com/user-attachments/assets/84a412d4-ff42-437a-86cc-bdb8e9eb85e9

## Diff Mode

**Usage:** `:'<,'>Sia! [query]` (with a range or visual selection)

Diff mode shows the assistant's suggested changes as an inline diff. The
assistant analyzes your selected code and proposes modifications. You review
each change individually and accept or reject it.

Diff mode is suited for:

- Refactoring existing code
- Bug fixes with suggested patches
- Style or formatting changes
- Targeted improvements to a specific section

See [Reviewing Changes](3-reviewing-changes.md) for the full accept/reject
workflow.

https://github.com/user-attachments/assets/c8a5f031-b032-4a04-96c5-a6407fe43545

## Choosing the Right Mode

| Goal                                  | Mode   | Command              |
| ------------------------------------- | ------ | -------------------- |
| Explore, discuss, or get guidance     | Chat   | `:Sia [query]`       |
| Generate code at the cursor           | Insert | `:Sia! [query]`      |
| Modify existing code with suggestions | Diff   | `:'<,'>Sia! [query]` |

You can customize the default behavior for each mode using
[actions](../5-features/1-actions.md) and
[project configuration](../3-configuration/3-project.md).
