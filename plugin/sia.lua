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

local possible_flags = { "-m" }
vim.api.nvim_create_user_command("Sia", function(args)
  local utils = require("sia.utils")

  local model = find_and_remove_flag("-m", args.fargs)

  if #args.fargs == 0 and not vim.b.sia then
    vim.notify("No prompt")
    return
  end

  --- @type sia.ActionArgument
  local opts = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
    start_line = args.line1,
    end_line = args.line2,
    bang = args.bang,
  }
  if args.count == -1 then
    opts.mode = "n"
  else
    opts.mode = "v"
  end

  local action
  if vim.b.sia and #args.fargs == 0 then
    action = utils.resolve_action({ vim.b.sia }, opts)
  else
    action = utils.resolve_action(args.fargs, opts)
  end

  if not action then
    return
  end

  if action.capture and opts.mode ~= "v" then
    local capture = action.capture(opts)
    if not capture then
      vim.notify("Failed to capture context")
      return
    end
    opts.start_line, opts.end_line = capture[1], capture[2]
    opts.mode = "v"
  end

  if action.range == true and opts.mode ~= "v" then
    vim.notify(args.fargs[1] .. " must be used with a range")
    return
  end

  local is_range = opts.mode == "v"
  local is_range_valid = action.range == nil or action.range == is_range
  if utils.is_action_disabled(action) or not is_range_valid then
    vim.notify(args.fargs[1] .. " is not enabled")
    return
  end

  if model then
    action.model = model
  end

  require("sia").main(action, opts)
end, {
  range = true,
  bang = true,
  nargs = "*",
  complete = function(ArgLead)
    local config = require("sia.config")
    local cmd_type = vim.fn.getcmdtype()
    local cmd_line = vim.fn.getcmdline()
    local is_range = false
    local has_bang = false

    if cmd_type == ":" then
      local range_patterns = {
        "^%s*%d+", -- Single line number (start), with optional leading spaces
        "^%s*%d+,%d+", -- Line range (start,end), with optional leading spaces
        "^%s*%d+[,+-]%d+", -- Line range with arithmetic (start+1, start-1)
        "^%s*%d+,", -- Line range with open end (start,), with optional leading spaces
        "^%s*%%", -- Whole file range (%), with optional leading spaces
        "^%s*[$.]+", -- $, ., etc., with optional leading spaces
        "^%s*[$.%d]+[%+%-]?%d*", -- Combined offsets (e.g., .+1, $-1)
        "^%s*'[a-zA-Z]", -- Marks ('a, 'b), etc.
        "^%s*[%d$%.']+,[%d$%.']+", -- Mixed patterns (e.g., ., 'a)
        "^%s*['<>][<>]", -- Visual selection marks ('<, '>)
        "^%s*'<[,]'?>", -- Combinations like '<,'>
      }

      for _, pattern in ipairs(range_patterns) do
        if cmd_line:match(pattern) then
          is_range = true
          break
        end
      end
      if cmd_line:match(".-%w+!%s+.*") then
        has_bang = true
      end
    end

    if vim.startswith(ArgLead, "/") then
      local complete = {}
      local term = ArgLead:sub(2)
      for key, prompt in pairs(config.options.actions) do
        if vim.startswith(key, term) and not require("sia.utils").is_action_disabled(prompt) and vim.bo.ft ~= "sia" then
          if prompt.range == nil or (prompt.range == is_range) then
            table.insert(complete, "/" .. key)
          end
        end
      end
      return complete
    else
      if string.match(cmd_line, "-m %w*$") then
        local models = vim
          .iter(config.options.models)
          :map(function(item)
            return item
          end)
          :filter(function(model)
            print(model, ArgLead, vim.startswith(model, ArgLead))
            return vim.startswith(model, ArgLead)
          end)
          :totable()
        return models
      end
    end

    return {}
  end,
})
