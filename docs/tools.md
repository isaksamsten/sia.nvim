# Tools

Sia comes with a comprehensive set of tools that enable the AI assistant to
interact with your codebase and development environment.

## Core Tools

These tools are available via `require("sia.tools")`. Tools marked with **★**
are included in the default chat action.

### File Operations

- **★ read** - Read file contents with optional line offset and limit (up to
  2000 lines by default, with line number display)
- **★ write** - Write complete file contents to create new files or overwrite
  existing ones (ideal for large changes or new files)
- **★ edit** - Make precise targeted edits using search and replace with fuzzy
  matching and context validation
- **★ insert** - Insert text at a specific line in a file (1-based, text is
  inserted before the specified line)
- **apply_diff** - Apply patches using the Codex apply_patch format (automatically
  added to the default chat action for GPT-5 models)

### Code Navigation & Search

- **★ grep** - Fast content search using ripgrep with regex support, glob
  patterns, and multiline matching (max 100 results, sorted by file
  modification time)
- **★ glob** - Find files matching patterns using `fd` (supports `*.lua`,
  `**/*.py`, etc.) with hidden file options

### Development Environment

- **★ bash** - Execute shell commands with persistent sessions, async support,
  process management (start/status/wait/kill), timeout control, and output
  truncation (8000 char limit)
- **★ diagnostics** - Retrieve LSP diagnostics for a specific file with severity
  levels and source information
- **★ websearch** - Search the web using Google
- **★ memory** - Manage persistent agent memory in `.sia/memory/` (view, create,
  edit, delete, rename, search)
- **fetch** - Retrieve and convert web content to markdown using pandoc, with
  AI-powered content analysis (requires curl; pandoc optional)

### Task Management

- **★ write_todos** - Create and manage todo lists for tracking multi-step tasks
  (add new todos, update status, replace all, or clear completed items)
- **★ read_todos** - Read the current todo list with IDs, descriptions, and
  status for each item

### Interaction

- **★ ask_user** - Ask the user to choose from a list of options using an
  interactive selection interface

### Agents

- **task** - Launch autonomous agents with their own tools and system prompts
  for complex tasks (see [Custom Agent Registry](concepts.md#custom-agent-registry))

## Extra Tools

These tools are available under `require("sia.tools.extra")` and can be added
to custom actions or agent configurations.

### File Operations

- **rename** - Rename or move files within the project with automatic buffer
  updates
- **remove** - Safely delete files with optional trash functionality (moves to
  `.sia_trash` by default)
- **replace_region** - Replace a line region in a file (useful for targeted
  block replacements)
- **unread** - Mark file contexts as outdated in the conversation, prompting
  re-reads

### Code Navigation

- **workspace** - Show currently visible files with line ranges, cursor
  positions, and background buffers
- **locations** - Create navigable quickfix lists for multiple locations
  (supports error/warning/info/note types)
- **lsp** - Interact with Language Server Protocol servers (hover, definition,
  references, rename, etc.)

### Research

These tools are available via direct `require` but not exported in
`require("sia.tools.extra")`:

- **search_papers** - Search for research articles using the CORE API
  (`require("sia.tools.extra.search_papers")`)
- **paper** - Retrieve a specific research paper by its CORE ID
  (`require("sia.tools.extra.paper")`)

### Advanced Capabilities

- **history** - Access and search saved conversation history with search,
  view, and table-of-contents modes (see
  [Conversation History](concepts.md#conversation-history))
- **plan** - Planning tool for task decomposition

## Adding Tools to Actions

You can include any combination of core and extra tools in your custom actions:

```lua
require("sia").setup({
  actions = {
    research = {
      mode = "chat",
      tools = function()
        local tools = require("sia.tools")
        local extra = require("sia.tools.extra")
        return {
          tools.read,
          tools.grep,
          tools.glob,
          tools.bash,
          extra.lsp,
          extra.workspace,
          extra.history,
        }
      end,
      -- ...
    },
  }
})
```

The assistant combines these tools intelligently to handle complex development
workflows, from simple file edits to multi-file refactoring, debugging, and
project analysis.

