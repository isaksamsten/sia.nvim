# Tools

Sia comes with a comprehensive set of tools that enable the AI assistant to
interact with your codebase and development environment.

## File Operations

- **read** - Read file contents with optional line ranges and limits (up to
  2000 lines by default, with line number display)
- **write** - Write complete file contents to create new files or overwrite
  existing ones (ideal for large changes >50% of file content)
- **edit** - Make precise targeted edits using search and replace with fuzzy
  matching and context validation
- **rename_file** - Rename or move files within the project with automatic
  buffer updates
- **remove_file** - Safely delete files with optional trash functionality
  (moves to `.sia_trash` by default)

## Code Navigation & Search

- **grep** - Fast content search using ripgrep with regex support and glob
  patterns (max 100 results, sorted by file modification time)
- **glob** - Find files matching patterns using `fd` (supports `*.lua`,
  `**/*.py`, etc.) with hidden file options
- **workspace** - Show currently visible files with line ranges, cursor
  positions, and background buffers
- **show_locations** - Create navigable quickfix lists for multiple locations
  (supports error/warning/info/note types)
- **get_diagnostics** - Retrieve diagnostics with severity levels and
  source information

## Development Environment

- **bash** - Execute shell commands in persistent sessions with security
  restrictions and output truncation (8000 char limit)
- **fetch** - Retrieve and convert web content to markdown using pandoc, with
  AI-powered content analysis
- **lsp** - Interact with Language Server Protocol servers for code intelligence

## Advanced Capabilities

- **task** - Launch autonomous agents with access to read-only tools
  (glob, grep, read) for complex search tasks
- **compact_conversation** - Intelligently summarize and compact conversation
  history when topics change
- **history** - Access and search saved conversation history (see
  [Conversation History](concepts.md#conversation-history))

## Task Management

- **write_todos** - Create and manage todo lists for tracking multi-step tasks
  (add new todos, update status, or clear completed items)
- **read_todos** - Read the current todo list with IDs, descriptions, and
  status for each item

The assistant combines these tools intelligently to handle complex development
workflows, from simple file edits to multi-file refactoring, debugging, and
project analysis.

