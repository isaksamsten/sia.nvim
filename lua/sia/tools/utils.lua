local M = {}

--- @alias sia.PermissionOpts { auto_allow: integer}|{deny: boolean}|{ask: boolean}
--- @alias sia.PatternDef string|{pattern: string, negate: boolean?}

--- Helper function for consistent pattern matching with negate support
--- @param value string
--- @param pattern_def sia.PatternDef
--- @return boolean
local function matches_pattern(value, pattern_def)
  local pattern, negate
  if type(pattern_def) == "string" then
    pattern = pattern_def
    negate = false
  else
    pattern = pattern_def.pattern
    negate = pattern_def.negate or false
  end

  local matches = string.match(value, pattern)
  return negate and not matches or not negate and matches
end

--- @param name string
--- @param args table
--- @return sia.PermissionOpts?
local function get_permission(name, args)
  local config = require("sia.config")
  local lc = config.get_local_config()

  -- If any argument is denied
  local deny = lc and lc.permission and lc.permission.deny and lc.permission.deny[name] or {}
  if deny.arguments then
    for key, arg_value in pairs(args) do
      if arg_value then
        for _, pattern_def in ipairs(deny.arguments[key] or {}) do
          if matches_pattern(arg_value, pattern_def) then
            return { deny = true }
          end
        end
      end
    end
  end

  -- If any argument requires user confirmation
  local ask = lc and lc.permission and lc.permission.ask and lc.permission.ask[name] or {}
  if ask.arguments then
    for key, patterns in pairs(ask.arguments) do
      local arg_value = args[key]
      if arg_value then
        for _, pattern_def in ipairs(patterns) do
          if matches_pattern(arg_value, pattern_def) then
            return { ask = true }
          end
        end
      end
    end
  end

  --- If all arguments allow automatic confirmation
  local allowed = lc and lc.permission and lc.permission.allow and lc.permission.allow[name] or {}
  if not allowed.arguments or vim.tbl_isempty(allowed.arguments) then
    return nil
  end

  for key, patterns in pairs(allowed.arguments) do
    local found_match = false
    local arg_value = args[key]
    if arg_value then
      for _, pattern_def in ipairs(patterns) do
        if matches_pattern(arg_value, pattern_def) then
          found_match = true
          break
        end
      end
    end
    if not found_match then
      return nil
    end
  end

  return { auto_allow = allowed.choice or 1 }
end

--- @param items string[]
--- @param opts table
--- @param on_choice fun(item: string?, idx:integer?):nil
local function select(items, opts, on_choice)
  local choices = vim.split(opts.prompt, "\n")
  for i, item in ipairs(items) do
    table.insert(choices, string.format("%d: %s", i, item))
  end
  local clear_confirmation = require("sia.confirmation").show(choices)
  vim.cmd.redraw()
  vim.ui.input({ prompt = "Type number and Enter or (Esc or empty cancels): " }, function(resp)
    if clear_confirmation then
      clear_confirmation()
    end

    local idx = tonumber(resp or "")
    if resp == nil or idx < 0 or idx > #items then
      on_choice(nil, nil)
    end
    on_choice(items[idx], idx)
  end)
end

local function input(opts, on_confirm)
  local last_dash_pos = nil
  local search_pos = 1
  while true do
    local found = opts.prompt:find(" %- ", search_pos)
    if not found then
      break
    end
    last_dash_pos = found
    search_pos = found + 1
  end

  local prompt, confirmation_text
  if last_dash_pos then
    prompt = opts.prompt:sub(1, last_dash_pos - 1)
    confirmation_text = opts.prompt:sub(last_dash_pos + 3)
  else
    prompt = opts.prompt
    confirmation_text = nil
  end

  local clear_confirmation
  if #prompt > 80 or prompt:find("\n") then
    clear_confirmation = require("sia.confirmation").show(vim.split(prompt, "\n", { trimempty = true, plain = true }))
    vim.cmd.redraw()
  elseif confirmation_text then
    confirmation_text = string.format("%s - %s", prompt, confirmation_text)
  else
    confirmation_text = prompt
  end

  vim.ui.input({ prompt = confirmation_text }, function(resp)
    if clear_confirmation then
      clear_confirmation()
    end
    on_confirm(resp)
  end)
end

---@class sia.NewToolOpts
---@field name string
---@field description string
---@field read_only boolean?
---@field auto_apply (fun(args: table, conversation:sia.Conversation):integer?)?
---@field message string|(fun(args:table):string)?
---@field system_prompt string?
---@field required string[]
---@field parameters table

--- @class sia.NewToolExecuteUserChoiceOpts
--- @field choices string[]
--- @field on_accept fun(choice:integer):nil
--- @field must_confirm boolean?

--- @class sia.NewToolExecuteUserInputOpts
--- @field on_accept fun():nil
--- @field must_confirm boolean?

--- @alias sia.NewToolExecuteUserInput fun(prompt: string, opts: sia.NewToolExecuteUserInputOpts):nil
--- @alias sia.NewToolExecuteUserChoice fun(prompt: string, opts: sia.NewToolExecuteUserChoiceOpts):nil
--- @class sia.NewToolExecuteOpts
--- @field cancellable sia.Cancellable?
--- @field user_input sia.NewToolExecuteUserInput
--- @field user_choice sia.NewToolExecuteUserChoice

---@param opts sia.NewToolOpts
---@param execute fun(args: table, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), opts: sia.NewToolExecuteOpts?)
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  --- @param args table
  --- @param conversation sia.Conversation
  --- @return sia.PermissionOpts?
  local resolve_permission = function(args, conversation)
    local permission = get_permission(opts.name, args)

    if permission then
      return permission
    elseif not permission or not permission.ask then
      if conversation.auto_confirm_tools[opts.name] then
        return { auto_allow = conversation.auto_confirm_tools[opts.name] }
      else
        local choice = (opts.auto_apply and opts.auto_apply(args, conversation)) or nil
        return choice and { auto_allow = choice } or nil
      end
    end
  end

  --- @type sia.config.Tool
  return {
    name = opts.name,
    message = opts.message,
    parameters = opts.parameters,
    system_prompt = opts.system_prompt,
    allow_parallel = function(conversation, args)
      if conversation.ignore_tool_confirm and opts.read_only then
        return true
      end

      if not opts.read_only then
        return false
      end

      local permission = resolve_permission(args, conversation)
      return permission ~= nil and permission.auto_allow ~= nil
    end,
    description = opts.description,
    required = opts.required,
    execute = function(args, conversation, callback, cancellable)
      --- @type sia.NewToolExecuteUserInput
      local user_input

      --- @type sia.NewToolExecuteUserChoice
      local user_choice

      local permission = resolve_permission(args, conversation)
      user_input = function(prompt, input_args)
        if conversation.ignore_tool_confirm or (permission and permission.auto_allow) then
          input_args.on_accept()
          return
        end

        if prompt == nil then
          prompt = "Execute " .. (opts.name or "tool")
        end

        local confirmation_text
        if input_args.must_confirm then
          confirmation_text = "Proceed? (y/N): "
        else
          confirmation_text = "Proceed? (Y/n/[a]lways): "
        end

        local input_fn = input
        if require("sia.config").options.defaults.ui.use_vim_ui then
          input_fn = vim.ui.input
        end

        input_fn({ prompt = string.format("%s - %s", prompt, confirmation_text) }, function(resp)
          if resp == nil then
            callback({
              content = {
                string.format("User cancelled %s operation. Ask the user what they want you to do!", opts.name),
              },
            })
            return
          end
          local response = resp:lower():gsub("^%s*(.-)%s*$", "%1")
          if response == "n" or response == "no" then
            callback({
              content = {
                string.format("User declined to execute %s. Ask the user what they want you to do!", opts.name),
              },
            })
            return
          end

          if not input_args.must_confirm and (response == "a" or response == "always") then
            conversation.auto_confirm_tools[opts.name] = 1
            input_args.on_accept()
            return
          end

          local should_proceed = false
          if input_args.must_confirm then
            should_proceed = response == "y" or response == "yes"
          else
            should_proceed = response == "" or response == "y" or response == "yes"
          end

          if should_proceed then
            input_args.on_accept()
          else
            callback({
              content = {
                string.format("User declined to execute %s. Ask the user what they want you to do!", opts.name),
              },
            })
          end
        end)
      end
      user_choice = function(prompt, choice_args)
        if permission and permission.auto_allow and not choice_args.must_confirm then
          choice_args.on_accept(permission.auto_allow)
          return
        end
        local select_fn = select
        if require("sia.config").options.defaults.ui.use_vim_ui then
          select_fn = vim.ui.select
        end
        select_fn(choice_args.choices, { prompt = prompt }, function(_, idx)
          if idx then
            choice_args.on_accept(idx)
          else
            callback({
              content = {
                string.format("User cancelled %s operation. Ask the user what they want you to do!", opts.name),
              },
            })
          end
        end)
      end
      if not permission or not permission.deny then
        execute(args, conversation, callback, {
          cancellable = cancellable,
          user_input = user_input,
          user_choice = user_choice,
        })
      else
        callback({
          content = {
            string.format("User has denied %s with the provided parameters in its local configuration", opts.name),
          },
        })
      end
    end,
  }
end

return M
