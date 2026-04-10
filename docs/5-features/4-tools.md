# Tools

Sia comes with a comprehensive set of tools that the assistant uses to interact
with your codebase and development environment.

## Core Tools

These tools are available via `require("sia.tools")`. Tools marked with **★**
are included in the default chat action.

### File Operations

| Tool           | Default | Description                                                               |
| -------------- | ------- | ------------------------------------------------------------------------- |
| **view**       | ★       | View file contents with optional line offset and limit (up to 2000 lines) |
| **skills**     | ★       | Read a named skill definition with metadata and markdown body              |
| **write**      | ★       | Write complete file contents (create new or overwrite)                    |
| **edit**       | ★       | Targeted search-and-replace edits with fuzzy matching                     |
| **insert**     | ★       | Insert text at a specific line (1-based, before the line)                 |
| **apply_diff** |         | Apply patches in Codex format (auto-added for GPT-5 models)               |

### Code Search

| Tool     | Default | Description                                                            |
| -------- | ------- | ---------------------------------------------------------------------- |
| **grep** | ★       | Search with ripgrep (regex, glob patterns, multiline, max 100 results) |
| **glob** | ★       | Find files with fd (supports `*.lua`, `**/*.py`, hidden files)         |

### Development Environment

| Tool            | Default | Description                                                       |
| --------------- | ------- | ----------------------------------------------------------------- |
| **bash**        | ★       | Execute shell commands with persistent sessions and async support |
| **diagnostics** | ★       | Retrieve LSP diagnostics for a file                               |
| **websearch**   | ★       | Search the web using Google                                       |
| **webfetch**    | ★       | Fetch and convert web content to markdown                         |
| **memory**      | ★       | Manage persistent memory in `.sia/memory/`                        |

### Task Management

| Tool            | Default | Description                                       |
| --------------- | ------- | ------------------------------------------------- |
| **write_todos** | ★       | Create and manage todo lists for multi-step tasks |
| **read_todos**  | ★       | Read the current todo list                        |

### Interaction

| Tool          | Default | Description                                   |
| ------------- | ------- | --------------------------------------------- |
| **ask_user**  | ★       | Ask the user to choose from a list of options |
| **agent**     | ★       | Launch autonomous agents for subtasks         |
| **exit_mode** | ★       | Exit the current conversation mode            |

### Media

| Tool              | Default | Description         |
| ----------------- | ------- | ------------------- |
| **view_image**    | ★       | View image files    |
| **view_document** | ★       | View document files |

## Extra Tools

These tools are available under `require("sia.tools.extra")` and can be added
to custom actions or agent configurations.

### Code Navigation

| Tool          | Description                                                       |
| ------------- | ----------------------------------------------------------------- |
| **workspace** | Show visible files with line ranges and cursor positions          |
| **locations** | Create navigable quickfix lists for multiple locations            |
| **lsp**       | Interact with LSP servers (hover, definition, references, rename) |

## Tool Parameters for Permissions

When writing [permission rules](../4-permissions/2-rules.md), you match
against tool argument names. The table below lists the key arguments for each
tool that are useful for permission and risk patterns.

### Core Tools

| Tool              | Key arguments                                   | Description                                                                   |
| ----------------- | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| **view**          | **path**                                        | File path to read                                                             |
| **skills**        | **name**                                        | Skill name to resolve and read                                                |
| **write**         | **path**                                        | File path to write                                                            |
| **edit**          | **target_file**, **old_string**, **new_string** | File to modify and the strings involved                                       |
| **insert**        | **target_file**, **text**                       | File to modify and the text to insert                                         |
| **grep**          | **pattern**, **path**, **glob**                 | Search pattern, directory, and file glob                                      |
| **glob**          | **pattern**, **path**                           | File glob and directory to search                                             |
| **bash**          | **bash_command**, **command**, **async**        | Shell command, subcommand (`start`/`status`/`wait`/`kill`), and whether async |
| **diagnostics**   | **file**                                        | File path to get diagnostics for                                              |
| **websearch**     | **query**                                       | Search query string                                                           |
| **webfetch**      | **url**                                         | URL to fetch                                                                  |
| **view_image**    | **path**                                        | Image file path                                                               |
| **view_document** | **path**                                        | Document file path                                                            |
| **agent**         | **command**, **agent**, **task**, **id**, **message** | Session command plus agent name, task, session ID, and follow-up message |

### Permission Examples

Auto-approve file reads within `src/`:

```json
{
  "permission": {
    "allow": {
      "view": { "arguments": { "path": ["^src/"] } }
    }
  }
}
```

Only allow edits to Lua and Python files:

```json
{
  "permission": {
    "allow": {
      "edit": { "arguments": { "target_file": ["\\.(lua|py)$"] } },
      "insert": { "arguments": { "target_file": ["\\.(lua|py)$"] } },
      "write": { "arguments": { "path": ["\\.(lua|py)$"] } }
    }
  }
}
```

Allow safe shell commands, warn on destructive ones:

```json
{
  "permission": {
    "allow": {
      "bash": { "arguments": { "bash_command": ["^git (status|diff|log)"] } }
    },
    "deny": {
      "bash": { "arguments": { "bash_command": ["\\brm\\b", "\\bsudo\\b"] } }
    }
  },
  "risk": {
    "bash": {
      "arguments": {
        "bash_command": [
          { "pattern": "^(ls|cat|echo|git status|git diff)", "level": "safe" },
          { "pattern": "\\brm\\b", "level": "warn" }
        ]
      }
    }
  }
}
```

## Adding Tools to Actions

Include any combination of core and extra tools in custom actions:

```lua
require("sia").setup({
  actions = {
    research = {
      mode = "chat",
      tools = function(model)
        local tools = require("sia.tools")
        local extra = require("sia.tools.extra")
        return {
          tools.view,
          tools.grep,
          tools.glob,
          tools.bash,
          extra.lsp,
          extra.workspace,
        }
      end,
    },
  },
})
```
