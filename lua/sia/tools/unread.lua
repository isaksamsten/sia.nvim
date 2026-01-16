local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "unread",
  read_only = true,
  message = function(args)
    local files = args.files or {}
    if #files == 0 then
      return "Dropping file context..."
    end
    return string.format(
      "Dropping context for %d file%s...",
      #files,
      #files == 1 and "" or "s"
    )
  end,
  description = "Mark file contexts as outdated in the conversation",
  system_prompt = [[Use this tool when previously read/edited file context is no longer needed
(e.g. task switch). Provide a list of file paths to mark their contexts as outdated so
they are excluded from future interactions.]],
  parameters = {
    files = {
      type = "array",
      items = { type = "string" },
      description = "File paths to drop from context",
    },
  },
  required = { "files" },
}, function(args, conversation, callback, _)
  if not args.files or #args.files == 0 then
    callback({
      content = { "Error: files is required" },
      kind = "failed",
    })
    return
  end

  local targets = {}
  for _, file in ipairs(args.files) do
    if type(file) == "string" and file ~= "" then
      targets[file] = true
      targets[vim.fn.fnamemodify(file, ":.")] = true
      targets[vim.fn.fnamemodify(file, ":p")] = true
    end
  end

  local updated = 0
  for _, message in ipairs(conversation.messages) do
    if
      message.status == nil
      and message.context
      and message.context.buf
      and vim.api.nvim_buf_is_valid(message.context.buf)
    then
      local name = vim.api.nvim_buf_get_name(message.context.buf)
      if name ~= "" then
        local abs = vim.fn.fnamemodify(name, ":p")
        local rel = vim.fn.fnamemodify(name, ":.")
        if targets[name] or targets[abs] or targets[rel] then
          message.status = "outdated"
          updated = updated + 1
        end
      end
    end
  end

  if updated == 0 then
    callback({
      content = { "No matching file context found to mark as outdated." },
      kind = "failed",
    })
    return
  end

  callback({
    content = { "Files have been marked as outdated" },
    kind = "failed",
  })
end)
