local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "get_diagnostics",
    description = "Get LSP diagnostics for a specific file",
    parameters = {
      file = { type = "string", description = "The file path to get diagnostics for" },
    },
    required = { "file" },
  },
  read_only = true,
  summary = function()
    return "Retrieving diagnostics..."
  end,
  instructions = [[Get LSP diagnostics for a specific file - includes syntax errors,
type errors, warnings, and hints from the Language Server Protocol.

Use this tool FIRST when investigating code problems. It provides instant feedback
without compilation:
- Syntax and parse errors
- Type checking errors (TypeScript, Java, Rust, etc.)
- Linting warnings and style issues
- Unused variables, imports, dead code
- LSP hints and suggestions

Prefer this over bash compilation commands - it's instant, requires no build setup, and
provides the same error information that a compiler would show.

If no diagnostics are found, the code has no LSP-detected issues.]],
}, function(args, conversation, callback)
  if not args.file then
    callback({
      content = "Error: No file path was provided",
      summary = icons.error .. " Failed to read diagnostics",
      ephemeral = true,
    })
    return
  end

  if vim.fn.filereadable(args.file) == 0 then
    callback({
      content = "Error: File cannot be found or is not readable",
      summary = icons.error .. " Failed to read diagnostics",
      ephemeral = true,
    })
    return
  end
  local buf = utils.ensure_file_is_loaded(args.file, {
    read_only = true,
    listed = false,
  })
  if not buf then
    callback({
      content = "Error: Cannot load file into buffer",
      summary = icons.error .. " Failed to read diagnostics",
      ephemeral = true,
    })
    return
  end

  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    callback({
      summary = string.format(
        "%s No diagnostics found for %s",
        icons.diagnostics,
        args.file
      ),
      content = string.format("No diagnostics found for %s", args.file),
    })
    return
  end

  local content = { string.format("Diagnostics for %s:", args.file), "" }

  local severity_names = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARNING",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
  }

  for _, diagnostic in ipairs(diagnostics) do
    local severity = severity_names[diagnostic.severity] or "UNKNOWN"
    local line = diagnostic.lnum + 1
    local col = diagnostic.col + 1
    local source = diagnostic.source and string.format(" [%s]", diagnostic.source) or ""

    table.insert(
      content,
      string.format(
        "  Line %d:%d %s%s: %s",
        line,
        col,
        severity,
        source,
        diagnostic.message
      )
    )
  end

  callback({
    content = table.concat(content, "\n"),
    region = {
      buf = buf,
      stale = {
        content = "File changed",
      },
    },
    summary = string.format(
      "%s Found %d diagnostics for %s",
      icons.diagnostics,
      #diagnostics,
      args.file
    ),
  })
end)
