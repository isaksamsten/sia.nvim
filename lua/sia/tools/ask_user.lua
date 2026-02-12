local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "ask_user",
  read_only = true,
  message = "Asking user for input...",
  system_prompt = [[Ask the USER to choose from a list of options using an interactive selection interface. ]],
  description = "Ask the USER to choose from a list of options",
  parameters = {
    prompt = {
      type = "string",
      description = "The question or prompt to show the USER",
    },
    options = {
      type = "array",
      items = { type = "string" },
      description = "List of options for the USER to choose from",
    },
    default = {
      type = "integer",
      description = "Index of the default/recommended option (1-based).",
    },
  },
  required = { "prompt", "options", "default" },
}, function(args, conversation, callback, opts)
  local prompt = args.prompt
  local options = args.options
  local default_idx = args.default

  if not prompt or not options or #options == 0 then
    callback({
      content = { "ERROR: Invalid arguments to ask_user" },
    })
    return
  end

  if type(default_idx) ~= "number" or default_idx < 1 or default_idx > #options then
    default_idx = 1
  end

  local display_options = {}
  for i, option in ipairs(options) do
    if i == default_idx then
      table.insert(display_options, string.format("%s (default)", option))
    else
      table.insert(display_options, option)
    end
  end
  table.insert(display_options, "Do something else (type your answer)")

  opts.user_choice(prompt, {
    choices = display_options,
    on_accept = function(choice)
      if not choice then
        vim.ui.input({
          prompt = "Your answer: ",
        }, function(custom_answer)
          if custom_answer and custom_answer ~= "" then
            callback({
              content = {
                string.format("USER's response to: %s", prompt),
                "",
                string.format('Custom answer: "%s"', custom_answer),
              },
            })
          else
            callback({
              content = {
                "USER CANCELLED",
                "",
                "The USER cancelled the custom input prompt without providing an answer.",
                "",
                "Please ask the USER how they would like to proceed.",
              },
              cancelled = true,
              kind = "user_cancelled",
            })
          end
        end)
      end

      callback({
        content = {
          string.format("USER's response to: %s", prompt),
          "",
          string.format("Selected option: %s", choice),
        },
      })
    end,
  })
end)
