local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "exit_mode",
  read_only = true,
  message = function(args)
    if args.summary and args.summary ~= "" then
      return "Exiting mode: " .. args.summary:sub(1, 60)
    end
    return "Exiting mode..."
  end,
  system_prompt = [[Exit the current conversation mode and return to unrestricted tool access.

Call this tool when the mode's objective is complete, or when you need access to tools
that are restricted in the current mode. Provide a brief summary of what was accomplished.]],
  description = "Exit the current conversation mode",
  parameters = {
    summary = {
      type = "string",
      description = "Brief summary of what was accomplished in the current mode",
    },
  },
  required = {},
  auto_apply = function(_, _)
    return 1
  end,
}, function(args, conversation, callback, _)
  if not conversation.active_mode then
    callback({
      content = {
        "No active mode to exit. You are already in the default mode.",
      },
    })
    return
  end

  local prompt = conversation:exit_mode(args.summary, true)
  if prompt then
    callback({
      content = vim.split(prompt, "\n"),
    })
  else
    callback({
      content = {
        string.format("Failed to exit mode"),
      },
    })
  end
end)
