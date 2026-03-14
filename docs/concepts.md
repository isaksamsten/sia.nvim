# Concepts

## Tool Confirmation

Sia includes a flexible confirm system that allows you to control how tool
operations are confirmed. You can choose between blocking (traditional) and
non-blocking (async) confirm modes.

### Async Confirm Mode

https://github.com/user-attachments/assets/7d9607c9-0846-4415-b32a-db1b51abbf56

When enabled with `ui.confirm.async = true`, tool confirm requests are queued
in the background without interrupting your workflow. This allows you to:

- **Continue working** while approvals accumulate
- **Batch process confirm** when you're ready
- **Maintain focus** on editing without constant interruptions

**How it works:**

1. **Queued notifications**: When a tool needs confirm, a notification appears
   in a floating window at the top of your screen:

   ```
   󱇥 [conversation-name] Execute bash command 'git status'
   ```

Related requests are grouped by conversation and tool name, so parallel `view`
or `bash` calls collapse into a single summary instead of spamming the strip.
In the expanded view, those tool groups are nested under conversation headers so
it is easier to scan mixed agent and chat approvals.
   The notification uses `SiaApproveInfo`, `SiaApproveSafe`, or
   `SiaApproveWarn` highlight groups depending on the highest risk level in the
   visible group summary (all linked to `StatusLine` by default).

2. **Process confirm**: When you're ready, use one of these functions:
   - `require("sia").confirm.prompt()` - Shows the full confirm prompt
   - `require("sia").confirm.accept()` - Auto-accepts without showing prompt
   - `require("sia").confirm.always()` - Persist an allow rule when supported, then execute
   - `require("sia").confirm.decline()` - Auto-declines without showing prompt
   - `require("sia").confirm.preview()` - Preview without showing prompt
   - `require("sia").confirm.expand()` - Open a detailed grouped view of pending approvals

`accept()` and `decline()` operate on whole input groups when possible, while
`prompt()` and `preview()` let you drill into individual requests. The
`expand()` view keeps the same top-of-screen placement as the default notifier,
but grows downward into a focusable strip with conversation headers,
horizontally packed tool groups, selected-item details, and built-in actions.

Inside the expanded view:

- `h` / `l` - Move between groups
- `j` / `k` - Move between items in the selected group
- `a` / `d` - Accept or decline the selected item
- `A` / `D` - Accept or decline the whole selected group
- `r` / `R` - Always allow the selected item or group when supported
- `p` / `v` - Open the normal prompt or preview for the selected item
- `g?` - Show a cursor-relative help popup with the available mappings
- `q` - Close the expanded view

**Customizing Notifications:**

By default, confirm notifications are shown in a non-focusable floating window
at the top of the editor. Sia provides built-in notifiers you can choose from,
or you can provide your own custom notifier.

**Built-in notifiers:**

- `require("sia.ui.confirm").floating_notifier()` - Non-focusable floating window at top (default)
- `require("sia.ui.confirm").winbar_notifier()` - Shows in the current window's winbar

**Example using winbar:**

```lua
require("sia").setup({
  settings = {
    ui = {
      confirm = {
        async = {
          enable = true,
          notifier = require("sia.ui.confirm").winbar_notifier(),
        },
      },
    },
  },
})
```

**Custom notifiers:**

The `notifier` must implement the `sia.ConfirmNotifier` interface:

- `show(args)` - Show/update the notification. Called whenever the message changes. `args` is a table with:
  - `level` - Risk level (`"safe"`, `"info"`, or `"warn"`)
  - `name` - Conversation name
  - `message` - The notification message
  - `total` - Number of pending confirms
- `clear()` - Clear/dismiss the notification

**Example using nvim-notify:**

```lua
require("sia").setup({
  settings = {
    ui = {
      confirm = {
        async = {
          enable = true,
          notifier = (function()
            local notif_id = nil

            return {
              show = function(args)
                notif_id = vim.notify(args.message, vim.log.levels.INFO, {
                  title = "Sia confirm",
                  timeout = false,
                  replace = notif_id,  -- Replace if exists, create if not
                })
              end,

              clear = function()
                if notif_id then
                  vim.notify("", vim.log.levels.INFO, {
                    timeout = 0,
                    replace = notif_id
                  })
                  notif_id = nil
                end
              end,
            }
          end)(),
        },
      },
    },
  },
})
```

3. **Suggested keybindings**:
   ```lua
   keys = {
     { "<Leader>ac", mode = "n", function() require("sia").confirm.prompt() end, desc = "Confirm pending tool" },
     { "<Leader>ay", mode = "n", function() require("sia").confirm.accept() end, desc = "Accept pending tool" },
     { "<Leader>aA", mode = "n", function() require("sia").confirm.always() end, desc = "Always allow pending tool" },
     { "<Leader>an", mode = "n", function() require("sia").confirm.decline() end, desc = "Decline pending tool" },
     { "<Leader>ae", mode = "n", function() require("sia").confirm.expand() end, desc = "Expand pending tools" },
   }
   ```

**Configuration example:**

```lua
require("sia").setup({
  settings = {
    ui = {
      confirm = {
        use_vim_ui = false,  -- Use custom preview UI
        show_preview = true, -- Show detailed preview in prompts

        async = {
          enable = true,     -- Enable non-blocking confirm mode
          -- notifier = { ... } -- Optional: customize notification display
        },
      },
    },
  }
})
```

**Traditional (Blocking) Mode:**

If you prefer immediate prompts (the default behavior), keep `async.enable = false`.
Tool operations will show an approval prompt immediately and wait for your
response before continuing.

## Agent Memory

Sia maintains persistent memory across conversations using the `.sia/memory/` directory in your project root. This allows the AI assistant to:

- **Track progress on complex tasks**: Remember what it has tried, what worked,
  and what didn't
- **Learn from iterations**: Build on previous attempts and avoid repeating
  mistakes
- **Resume after interruption**: Continue work seamlessly even if the
  conversation or Neovim session ends
- **Document decisions**: Keep a record of architectural choices, bug fixes,
  and implementation details

**How it works:**

1. The assistant checks `.sia/memory/` at the start of each conversation
2. It reads relevant memory files to understand previous progress
3. As work progresses, it updates memory files with new findings and status
4. Memory files use markdown format for human readability

You can safely view, edit, or delete files in `.sia/memory/` - they're meant to be human-readable and editable. The assistant will adapt to any changes you make.

**Note:** Add `.sia/` to your `.gitignore` if you don't want to commit memory files to version control, or commit them if you want to share context with your team.

## Task Tracking with Todos

https://github.com/user-attachments/assets/0db7be98-2ec5-4bba-ba51-3afe8201f0ae

When working on complex tasks, Sia can create and manage a todo list to track
progress. This helps you stay organized and gives visibility into multi-step
workflows.

**How it works:**

When you ask Sia to work on a task with multiple steps, it will automatically:

1. **Break down the task** into concrete, actionable todos
2. **Update status** as it completes each step (pending → current → done)
3. **Track progress** throughout the conversation

**Viewing todos:**

Todos are shown in a floating status window that appears automatically when
they're being used. You can also check the current todo list at any time by
asking Sia "what's the status?" or "show todos".

**Collaborative todos:**

The todo list is collaborative - you can manually update todo statuses at any
time, and Sia will respect your changes. This is useful if you want to:

- Skip a step that's no longer needed
- Mark something as done that you completed yourself
- Reprioritize what Sia should work on next

Todos help Sia stay focused on your goals and make it easier to resume work
after interruptions or context switches.

## Custom Agent Registry

You can define custom agents that the AI can invoke using the `task` tool. Agents
are specialized assistants with specific capabilities, tools, and system prompts
tailored for particular tasks.

**Creating Custom Agents:**

1. Create a `.sia/agents/` directory in your project root
2. Add agent definition files as markdown with JSON frontmatter
3. Agents become automatically available to the AI assistant

**Agent File Format:**

```markdown
---
description: Brief description of what this agent does
tools:
  - tool1
  - tool2
  - tool3
model: openai/gpt-5.2
require_confirmation: false
---

System prompt for the agent goes here.
```

**Frontmatter Fields:**

- **`description`** (required): A clear, concise description of the agent's purpose
  - This is shown to the AI when it lists available agents
  - Example: `"Searches through code to find specific patterns, functions, or implementations"`

- **`tools`** (required): Array of tool names the agent can use
  - Available tools: `glob`, `grep`, `view`, `bash`, `fetch`, etc. The tools
    must be defined in `setup({..})`.
  - Example: `["glob", "grep", "view"]`

- **`model`** (optional): Override the model for this agent
  - Defaults to `fast_model` if not specified
  - Example: `"openai/gpt-4.1"`

- **`require_confirmation`** (optional): Whether tool operations need user approval
  - Default: `true` (requires approval)
  - Set to `false` for read-only agents that should work autonomously

**How Agents Work:**

1. The AI assistant can use the `agent` tool to list available agents
2. When it identifies a agents that matches an agent's description, it launches
   that agent
3. The agent runs autonomously in the background with its own conversation
4. Progress updates appear in the `status` window
5. Results are integrated back into the main conversation

**Viewing Running Agents:**

You can view and track running agents in the tasks window:

- **In chat:** Press `a` (or your configured binding) to toggle the tasks window
- **Programmatically:** Call `require("sia").status("toggle")`

**Tips:**

- Keep agent system prompts focused and specific
- Use `require_confirmation: false` for read-only agents to avoid interruptions
- Choose appropriate tool sets for each agent's purpose
- Name agents descriptively (e.g., `code-searcher`, `test-runner`, `doc-finder`)
- You can organize agents in subdirectories: `.sia/agents/code/searcher.md` becomes agent name `code/searcher`

## Concurrent Conversations

Sia supports running multiple conversations simultaneously, each maintaining
its own independent view of file changes.

**How it works:**

When conversation A makes changes to a file using the edit/write/insert tools:

- **Conversation A** (which made the changes) continues to see the original
  content it read, allowing it to understand what changed and continue its work
  coherently
- **Conversation B** (which also read the same file) sees that content
  invalidated with "History pruned... read again if needed", prompting it to
  refresh if that file is relevant to its task

**Example:**

1. Both conversations A and B read `auth.py`
2. Conversation A refactors a function in `auth.py`
3. Conversation A still sees the original content (knows what it changed)
4. Conversation B sees the content marked as outdated (knows it needs to
   re-read the modified version)

This allows multiple conversations to work independently while staying aware of
each other's changes.

## Context Window Management

Long-running conversations — especially those with many tool calls — can grow
to exceed a model's context window. Sia automatically manages this by
estimating the current token usage and pruning old messages when the
conversation approaches the limit.

**How token estimation works:**

Sia uses a fast heuristic to estimate tokens: it sums up the byte size of all
message content, tool call arguments, and tool results, then divides by 4
(roughly 4 bytes per token for English text and code). This runs only at the
start of each round (before each API call), not on every render, so it has
negligible performance impact.

**When pruning is triggered:**

Pruning activates when the estimated token count exceeds `prune_threshold`
(default: 85%) of the model's `context_window`. Sia then applies a series of
increasingly aggressive strategies to bring usage down to `target_after_prune`
(default: 70%):

1. **Drop oldest tool call pairs**: Assistant messages containing tool calls
   and their matching tool result messages are fully removed from the
   conversation, starting from the oldest. Messages that are already marked
   as outdated (from cross-conversation invalidation) are dropped first,
   since they're already stale. Tool names listed in `context.exclude`
   (e.g., `grep`, `glob`) are never dropped.

2. **Compact the conversation** (last resort): If dropping all eligible tool
   calls isn't enough, Sia summarizes the entire conversation history into a
   concise summary using the `fast_model`. The summary replaces the old
   messages while preserving key technical details, decisions, and file paths.

**Winbar indicator:**

When a model has `context_window` defined, the winbar displays a context budget
indicator showing estimated usage as a percentage of the available window:

```
▰▱▱ 28% of 200K
```

The indicator changes color as usage increases:

- Normal highlight below 85%
- Warning highlight (`DiagnosticWarn`) at 85%+
- Error highlight (`DiagnosticError`) at 95%+

**Relationship to tool call pruning:**

Context window management works alongside — not instead of — the existing tool
call pruning system (`context.max_tool` / `context.keep`). Tool call pruning
operates based on _count_ (how many tool calls exist), while context window
management operates based on _size_ (how many tokens the conversation uses).
Both can be active simultaneously: tool pruning marks old results as outdated
(replacing content with a short note), and context window management can then
fully drop those outdated messages when space is needed.

**Configuration:**

See [Context Management](configuration.md#context-management) for the
available threshold settings.

**Defining context windows for custom models:**

See [Setting Context Window Size](configuration.md#setting-context-window-size)
for how to add `context_window` to your model definitions. All built-in models
already have this set.
