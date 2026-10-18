local tool_utils = require("sia.tools.utils")
local tool_names = tool_utils.tool_names

local SUPPORTED_EXTENSIONS = {
  pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  pot = "application/vnd.ms-powerpoint",
  ppt = "application/vnd.ms-powerpoint",
  keynote = "application/vnd.apple.keynote",
  docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  doc = "application/msword",
  odt = "application/vnd.oasis.opendocument.text",
  pdf = "application/pdf",
  xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  xls = "application/vnd.ms-excel",
  xla = "application/vnd.ms-excel",
  xlb = "application/vnd.ms-excel",
}

local SUPPORTED_LIST = vim.tbl_keys(SUPPORTED_EXTENSIONS)
table.sort(SUPPORTED_LIST)

local MAX_FILE_SIZE = 20 * 1024 * 1024 -- 20MB

--- @param path string
--- @return string? mime_type
local function get_mime_type(path)
  local ext = path:match("%.(%w+)$")
  if ext then
    return SUPPORTED_EXTENSIONS[ext:lower()]
  end
  return nil
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_names.view_document,
    description = "Views a document file from the local filesystem.",
    parameters = {
      path = {
        type = "string",
        description = "The file path to the document",
      },
    },
    required = { "path" },
  },
  is_supported = function(model)
    return model.support.document == true
  end,
  read_only = true,
  summary = function(args)
    if args.path then
      return "Viewing document " .. vim.fn.fnamemodify(args.path, ":t")
    else
      return "Viewing document..."
    end
  end,
  instructions = string.format(
    [[Views a document file from the local filesystem and returns it as file content
for analysis. Supports the following formats: %s. Use this tool when you need to
view or analyze the contents of a document file.]],
    table.concat(SUPPORTED_LIST, ", ")
  ),
  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
  is_approved = function(args, _)
    if args.path and require("sia.utils").dirs.is_safe(args.path) then
      return true
    end
    return nil
  end,
}, function(args, _, callback, opts)
  if not args.path then
    callback({
      content = "Error: No file path was provided",
      summary = "Failed to view document",
      ephemeral = true,
    })
    return
  end

  local mime_type = get_mime_type(args.path)
  if not mime_type then
    local ext = args.path:match("%.(%w+)$") or "unknown"
    callback({
      content = string.format(
        "Error: Unsupported document format '.%s'. Supported formats: %s",
        ext,
        table.concat(SUPPORTED_LIST, ", ")
      ),
      summary = "Unsupported document format",
      ephemeral = true,
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = "Error: Document file cannot be found",
      summary = "Failed to view document",
      ephemeral = true,
    })
    return
  end

  local stat = vim.uv.fs_stat(args.path)
  if stat and stat.size > MAX_FILE_SIZE then
    callback({
      content = string.format(
        "Error: Document file is too large (%d bytes). Maximum size is %d bytes.",
        stat.size,
        MAX_FILE_SIZE
      ),
      summary = "Document too large",
      ephemeral = true,
    })
    return
  end

  local filename = vim.fn.fnamemodify(args.path, ":t")
  local confirm_message = string.format("View document %s", args.path)

  opts.user_input(confirm_message, {
    on_accept = function()
      local file = io.open(args.path, "rb")
      if not file then
        callback({
          content = "Error: Cannot open " .. args.path,
          summary = "Failed to view document",
          ephemeral = true,
        })
        return
      end

      local data = file:read("*a")
      file:close()

      if not data or #data == 0 then
        callback({
          content = "Error: Document file is empty",
          summary = "Failed to view document",
          ephemeral = true,
        })
        return
      end

      local base64_data = vim.base64.encode(data)
      local data_url = string.format("data:%s;base64,%s", mime_type, base64_data)

      local summary = "Viewed document " .. vim.fn.fnamemodify(args.path, ":~:.")

      --- @type sia.Content[]
      local content = {
        {
          type = "text",
          text = string.format("Document: %s (%s)", filename, mime_type),
        },
        {
          type = "file",
          file = {
            filename = filename,
            file_data = data_url,
          },
        },
      }

      callback({
        content = content,
        summary = summary,
      })
    end,
  })
end)
