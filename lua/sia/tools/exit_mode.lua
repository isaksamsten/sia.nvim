local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "exit_mode",
    description = "Exit the current conversation mode",
    parameters = {
      summary = {
        type = "string",
        description = "Brief summary of what was accomplished in the current mode",
      },
    },
    required = {},
  },
  read_only = true,
  summary = function(args)
    if args.summary and args.summary ~= "" then
      return "Exiting mode: " .. args.summary:sub(1, 60)
    end
    return "Exiting mode..."
  end,
  instructions = [[Exit the current conversation mode and return to unrestricted tool access.

Call this tool when the mode's objective is complete, or when you need access to tools
that are restricted in the current mode. Provide a brief summary of what was accomplished.]],
  is_approved = function(_, _)
    return true
  end,
}, function(args, conversation, callback, _)
  if not conversation.active_mode then
    callback({
      content = "No active mode to exit. You are already in the default mode.",
    })
    return
  end

  local info = conversation:exit_mode(args.summary)
  if info then
    callback({
      content = info.content,
      actions = info.truncate_after_id and {
        { type = "drop_after", message_id = info.truncate_after_id },
      } or nil,
    })
  else
    callback({
      content = string.format("Failed to exit mode"),
    })
  end
end)
