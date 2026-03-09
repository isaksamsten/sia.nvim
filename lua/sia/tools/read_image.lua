local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons

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
  name = "read_image",
  read_only = true,
  message = function(args)
    if args.path then
      return "Reading image " .. vim.fn.fnamemodify(args.path, ":t")
    else
      return "Reading image..."
    end
  end,
  system_prompt = [[Reads an image file from the local filesystem and returns it as an
image for visual analysis. Supports PNG, JPEG, GIF, and WebP formats. Use this tool
when you need to view or analyze the contents of an image file. The image is returned
as base64-encoded data that you can directly interpret.]],
  description = "Reads an image file from the local filesystem.",
  parameters = {
    path = {
      type = "string",
      description = "The file path to the image",
    },
  },
  required = { "path" },
  auto_apply = function(args, _)
    if args.path and tool_utils.is_tool_output_path(args.path) then
      return 1
    end
    return nil
  end,
}, function(args, _, callback, opts)
  if not args.path then
    callback({
      content = { "Error: No file path was provided" },
      display_content = icons.error .. " Failed to read image",
      kind = "failed",
    })
    return
  end

  local mime_type = get_mime_type(args.path)
  if not mime_type then
    local ext = args.path:match("%.(%w+)$") or "unknown"
    callback({
      content = {
        string.format(
          "Error: Unsupported image format '.%s'. Supported formats: png, jpg, jpeg, gif, webp",
          ext
        ),
      },
      display_content = icons.error .. " Unsupported image format",
      kind = "failed",
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = { "Error: Image file cannot be found" },
      display_content = icons.error .. " Failed to read image",
      kind = "failed",
    })
    return
  end

  local stat = vim.uv.fs_stat(args.path)
  if stat and stat.size > MAX_FILE_SIZE then
    callback({
      content = {
        string.format(
          "Error: Image file is too large (%d bytes). Maximum size is %d bytes.",
          stat.size,
          MAX_FILE_SIZE
        ),
      },
      display_content = icons.error .. " Image too large",
      kind = "failed",
    })
    return
  end

  local filename = vim.fn.fnamemodify(args.path, ":t")
  local confirm_message = string.format("Read image %s", args.path)

  opts.user_input(confirm_message, {
    on_accept = function()
      local file = io.open(args.path, "rb")
      if not file then
        callback({
          content = { "Error: Cannot open " .. args.path },
          display_content = icons.error .. " Failed to read image",
          kind = "failed",
        })
        return
      end

      local data = file:read("*a")
      file:close()

      if not data or #data == 0 then
        callback({
          content = { "Error: Image file is empty" },
          display_content = icons.error .. " Failed to read image",
          kind = "failed",
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

      local display_content = string.format(
        "%s Read image %s%s",
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
        display_content = display_content,
        kind = "context",
      })
    end,
  })
end)
