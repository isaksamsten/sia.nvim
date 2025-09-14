local function find_and_remove_flag(flag, fargs)
  local index_of_flag
  for i, v in ipairs(fargs) do
    if v == flag then
      index_of_flag = i
    end
  end
  if index_of_flag and #fargs > index_of_flag then
    local value = table.remove(fargs, index_of_flag + 1)
    table.remove(fargs, index_of_flag)
    return value
  end
end

local flags = {
  ["-m"] = { pattern = "", completion = function() end },
}

vim.api.nvim_create_user_command("Sia", function(args)
  local utils = require("sia.utils")

  local model = find_and_remove_flag("-m", args.fargs)

  if #args.fargs == 0 and not vim.b.sia then
    vim.api.nvim_echo({ { "Sia: No prompt provided.", "ErrorMsg" } }, false, {})
    return
  end

  --- @type sia.ActionContext
  local context = utils.create_context(args)
  if vim.b.sia and #args.fargs == 0 then
    args.fargs = { vim.b.sia }
  end

  local action, named = utils.resolve_action(args.fargs, context)

  if not action then
    return
  end

  if action.capture and context.mode ~= "v" then
    local capture = action.capture(context)
    if not capture then
      vim.api.nvim_echo({ { "Sia: Unable to capture current context.", "ErrorMsg" } }, false, {})
      return
    end
    context.start_line, context.end_line = capture[1], capture[2]
    context.pos = { capture[1], capture[2] }
    context.mode = "v"
  end

  if action.range == true and context.mode ~= "v" then
    vim.api.nvim_echo(
      { { "Sia: The action " .. args.fargs[1] .. " must be used with a range", "ErrorMsg" } },
      false,
      {}
    )
    return
  end

  local is_range = context.mode == "v"
  local is_range_valid = action.range == nil or action.range == is_range
  if utils.is_action_disabled(action) or not is_range_valid then
    vim.api.nvim_echo(
      { { "Sia: The action " .. args.fargs[1] .. " is not enabled in the current context.", "ErrorMsg" } },
      false,
      {}
    )
    return
  end

  require("sia").main(action, { context = context, model = model, named_prompt = named })
end, {
  range = true,
  bang = true,
  nargs = "*",
  complete = function(ArgLead, CmdLine, CursorPos)
    local config = require("sia.config")
    local cmd_type = vim.fn.getcmdtype()
    local is_range = false

    if cmd_type == ":" then
      is_range = require("sia.utils").is_range_commend(CmdLine)
    end

    local match = string.match(string.sub(CmdLine, 1, CursorPos), "-m ([%w-_/]*)$")
    if match then
      local models = vim
        .iter(config.options.models)
        :map(function(item)
          return item
        end)
        :filter(function(model)
          return vim.startswith(model, match)
        end)
        :totable()
      return models
    else
      if vim.startswith(ArgLead, "/") then
        local complete = {}
        local term = ArgLead:sub(2)
        for key, prompt in pairs(config.options.actions) do
          if
            vim.startswith(key, term)
            and not require("sia.utils").is_action_disabled(prompt)
            and vim.bo.ft ~= "sia"
          then
            if prompt.range == nil or (prompt.range == is_range) then
              table.insert(complete, "/" .. key)
            end
          end
        end
        return complete
      end
    end

    return {}
  end,
})

vim.api.nvim_create_user_command("SiaDebug", function()
  local ChatStrategy = require("sia.strategy").ChatStrategy
  local chat = ChatStrategy.by_buf()
  if not chat or not chat.conversation or not chat.conversation.to_query then
    vim.notify("SiaDebug: No active Sia chat in this buffer.", vim.log.levels.WARN)
    return
  end
  local ok, result = pcall(chat.conversation.to_query, chat.conversation)
  if not ok then
    vim.notify("SiaDebug: Error generating conversation query: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  local json_str = vim.json.encode(result)
  local pretty = json_str
  if vim.fn.executable("jq") == 1 then
    local jq_out = vim.fn.system({ "jq", "." }, json_str)
    if vim.v.shell_error == 0 then
      pretty = jq_out
    end
  end
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "json", { buf = buf })
  local lines = vim.split(pretty, "\n", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, "*SiaDebug*")
end, {})
