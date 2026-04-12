local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local SUPPORTED_EXTENSIONS = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
}

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
    name = tool_names.view_image,
    description = "Views an image file from the local filesystem.",
    parameters = {
      path = {
        type = "string",
        description = "The file path to the image",
      },
    },
    required = { "path" },
  },
  is_supported = function(model)
    return model.support.image == true
  end,
  read_only = true,
  summary = function(args)
    if args.path then
      return "Viewing image " .. vim.fn.fnamemodify(args.path, ":t")
    else
      return "Viewing image..."
    end
  end,
  instructions = [[Views an image file from the local filesystem and returns it as an
image for visual analysis. Supports PNG, JPEG, GIF, and WebP formats. Use this tool
when you need to view or analyze the contents of an image file. The image is returned
as base64-encoded data that you can directly interpret.]],
  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
  is_approved = function(args, _)
    if args.path and require("sia.utils").dirs.is_safe(args.path) then
      return true
    end
    return false
  end,
}, function(args, _, callback, opts)
  if not args.path then
    callback({
      content = "Error: No file path was provided",
      summary = icons.error .. " Failed to view image",
      ephemeral = true,
    })
    return
  end

  local mime_type = get_mime_type(args.path)
  if not mime_type then
    local ext = args.path:match("%.(%w+)$") or "unknown"
    callback({
      content = string.format(
        "Error: Unsupported image format '.%s'. Supported formats: png, jpg, jpeg, gif, webp",
        ext
      ),
      summary = icons.error .. " Unsupported image format",
      ephemeral = true,
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = "Error: Image file cannot be found",
      summary = icons.error .. " Failed to view image",
      ephemeral = true,
    })
    return
  end

  local stat = vim.uv.fs_stat(args.path)
  if stat and stat.size > MAX_FILE_SIZE then
    callback({
      content = string.format(
        "Error: Image file is too large (%d bytes). Maximum size is %d bytes.",
        stat.size,
        MAX_FILE_SIZE
      ),
      summary = icons.error .. " Image too large",
      ephemeral = true,
    })
    return
  end

  local filename = vim.fn.fnamemodify(args.path, ":t")
  local confirm_message = string.format("View image %s", args.path)

  opts.user_input(confirm_message, {
    on_accept = function()
      local file = io.open(args.path, "rb")
      if not file then
        callback({
          content = { "Error: Cannot open " .. args.path },
          summary = icons.error .. " Failed to view image",
          ephemeral = true,
        })
        return
      end

      local data = file:read("*a")
      file:close()

      if not data or #data == 0 then
        callback({
          content = "Error: Image file is empty",
          summary = icons.error .. " Failed to view image",
          ephemeral = true,
        })
        return
      end

      local base64_data = vim.base64.encode(data)
      local data_url = string.format("data:%s;base64,%s", mime_type, base64_data)

      local size_str
      if stat then
        if stat.size < 1024 then
          size_str = string.format("%d B", stat.size)
        elseif stat.size < 1024 * 1024 then
          size_str = string.format("%.1f KB", stat.size / 1024)
        else
          size_str = string.format("%.1f MB", stat.size / (1024 * 1024))
        end
      end

      local summary = string.format(
        "%s Viewed image %s%s",
        icons.image,
        vim.fn.fnamemodify(args.path, ":~:."),
        size_str and (" (" .. size_str .. ")") or ""
      )

      --- @type sia.Content[]
      local content = {
        {
          type = "image",
          image = {
            url = data_url,
          },
        },
        {
          type = "text",
          text = string.format("Image: %s (%s)", filename, mime_type),
        },
      }

      callback({
        content = content,
        summary = summary,
      })
    end,
  })
end)
