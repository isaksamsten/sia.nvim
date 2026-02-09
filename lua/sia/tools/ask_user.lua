local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "ask_user",
  read_only = true,
  message = "Asking user for input...",
  system_prompt = [[Ask the USER to choose from a list of options using an interactive selection interface.

Use this tool when you need the USER to make a choice between multiple options, such as:
- Selecting between different implementation approaches
- Choosing configuration values or settings
- Picking from a list of alternatives
- Making decisions about how to proceed

The tool presents options in a selection interface and allows the USER to either:
1. Pick one of the provided options
2. Type a custom answer (if they choose "Do something else")

You MUST indicate which option is the default/recommended choice.]],
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
      description = "Index of the default/recommended option (1-based). This option will be marked as the default choice.",
    },
  },
  required = { "prompt", "options", "default" },
  auto_apply = function(_, _)
    return 1
  end,
}, function(args, conversation, callback, opts)
  local prompt = args.prompt
  local options = args.options
  local default_idx = args.default

  if not prompt or not options or #options == 0 then
    callback({
      content = {
        "ERROR: Invalid arguments to ask_user",
        "- prompt: required, non-empty string",
        "- options: required, non-empty array of strings",
        "- default: required, integer between 1 and #options",
      },
    })
    return
  end

  if type(default_idx) ~= "number" or default_idx < 1 or default_idx > #options then
    callback({
      content = {
        string.format(
          "ERROR: Invalid default index %s. Must be between 1 and %d",
          tostring(default_idx),
          #options
        ),
      },
    })
    return
  end

  -- Add the fallback option
  local display_options = {}
  for i, option in ipairs(options) do
    if i == default_idx then
      table.insert(display_options, string.format("%s (default)", option))
    else
      table.insert(display_options, option)
    end
  end
  table.insert(display_options, "Do something else (type your answer)")

  -- Use vim.ui.select
  vim.ui.select(display_options, {
    prompt = prompt,
    format_item = function(item)
      return item
    end,
  }, function(choice, choice_idx)
    if not choice or not choice_idx then
      -- User cancelled
      callback({
        content = {
          "USER CANCELLED",
          "",
          "The USER cancelled the selection prompt without choosing an option.",
          "",
          "Please ask the USER how they would like to proceed.",
        },
        cancelled = true,
        kind = "user_cancelled",
      })
      return
    end

    if choice_idx == #display_options then
      -- User chose "Do something else" - ask for custom input
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
    else
      -- User chose one of the provided options
      local selected_option = options[choice_idx]
      local is_default = (choice_idx == default_idx)

      callback({
        content = {
          string.format("USER's response to: %s", prompt),
          "",
          string.format('Selected option %d: "%s"%s', 
            choice_idx,
            selected_option,
            is_default and " (the default option)" or ""
          ),
        },
      })
    end
  end)
end)

