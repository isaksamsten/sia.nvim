local tracker = require("sia.tracker")
local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local FAILED_TO_GET_DIAGNOSTICS = "❌ Failed to read diagnostics"

return tool_utils.new_tool({
  name = "get_diagnostics",
  read_only = true,
  message = "Retrieving diagnostics...",
  description = "Get LSP diagnostics for a specific file",
  parameters = {
    file = { type = "string", description = "The file path to get diagnostics for" },
  },
  required = { "file" },
}, function(args, _, callback)
  if not args.file then
    callback({
      content = { "Error: No file path was provided" },
      display_content = { FAILED_TO_GET_DIAGNOSTICS },
      kind = "failed",
    })
    return
  end

  if vim.fn.filereadable(args.file) == 0 then
    callback({
      content = { "Error: File cannot be found or is not readable" },
      display_content = { FAILED_TO_GET_DIAGNOSTICS },
      kind = "failed",
    })
    return
  end
  local buf = utils.ensure_file_is_loaded(args.file)
  if not buf then
    callback({
      content = { "Error: Cannot load file into buffer" },
      display_content = { FAILED_TO_GET_DIAGNOSTICS },
      kind = "failed",
    })
    return
  end

  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    callback({
      display_content = { string.format("🩺 No diagnostics found for %s", args.file) },
      content = { string.format("No diagnostics found for %s", args.file) },
      context = { buf = buf, tick = tracker.ensure_tracked(buf) },
      kind = "diagnostics",
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
    content = content,
    context = { buf = buf, tick = tracker.ensure_tracked(buf) },
    kind = "diagnostics",
    display_content = { string.format("🩺 Found %d diagnostics", #diagnostics) },
  })
end)
