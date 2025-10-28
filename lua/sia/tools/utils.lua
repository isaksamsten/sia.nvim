local M = {}

-- Permission type aliases are defined in lua/sia/permissions.lua
-- @alias sia.PermissionOpts
-- @alias sia.PatternDef

--- @param clear_args string[]
--- @return fun(t:sia.ToolCall):sia.ToolCall
function M.gen_clear_outdated_tool_input(clear_args)
  local function clear_outdated_tool_input(tool)
    local f = tool["function"]
    if f then
      local new_func = { name = f.name, arguments = f.arguments }
      local ok, arguments = pcall(vim.json.decode, f.arguments)
      if ok then
        for key, _ in pairs(arguments) do
          if vim.tbl_contains(clear_args, key) then
            arguments[key] = "text has been pruned"
          end
        end
        new_func.arguments = vim.json.encode(arguments)
      end
      return { id = tool.id, type = tool.type, ["function"] = new_func }
    end
    return tool
  end
  return clear_outdated_tool_input
end

local function cancellation_message(name)
  return {
    "OPERATION DECLINED BY USER",
    "",
    string.format("The USER declined to execute the %s operation.", name),
    "",
    "IMPORTANT: Do not proceed with your original plan. Instead:",
    "1. Acknowledge that the operation was declined",
    "2. Ask the USER how they would like to proceed",
    "3. Wait for their guidance before taking any further action",
    "",
    "Do not attempt to continue with alternative approaches unless explicitly requested by the USER.",
  }
end

--- @param items string[]
--- @param opts table
--- @param on_choice fun(item: string?, idx:integer?):nil
local function select(items, opts, on_choice)
  local choices = vim.split(opts.prompt, "\n")
  for i, item in ipairs(items) do
    table.insert(choices, string.format("%d: %s", i, item))
  end
  local clear_preview = require("sia.preview").show(choices)
  vim.cmd.redraw()
  vim.ui.input(
    { prompt = "Type number and Enter or (Esc or empty cancels): " },
    function(resp)
      if clear_preview then
        clear_preview()
      end

      local idx = tonumber(resp or "")
      if resp == nil or idx < 0 or idx > #items then
        on_choice(nil, nil)
      end
      on_choice(items[idx], idx)
    end
  )
end

--- @class sia.InputOpts
--- @field prompt string
--- @field preview (fun(buf:integer):integer?)?
--- @field wrap boolean?

--- @param opts sia.InputOpts
--- @param on_confirm fun(resp:string?)
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

  local clear_preview
  if #prompt > 80 or prompt:find("\n") then
    clear_preview = require("sia.preview").show(
      vim.split(prompt, "\n", { trimempty = true, plain = true }),
      { wrap = opts.wrap }
    )
    vim.cmd.redraw()
  elseif confirmation_text then
    confirmation_text = string.format("%s - %s", prompt, confirmation_text)
  else
    confirmation_text = prompt
  end

  local show_preview = require("sia.config").options.defaults.ui.approval.show_preview
  if show_preview and opts.preview and not clear_preview then
    clear_preview = require("sia.preview").show(opts.preview, { wrap = opts.wrap })
    vim.cmd.redraw()
  end

  vim.ui.input({ prompt = confirmation_text }, function(resp)
    if clear_preview then
      clear_preview()
    end
    on_confirm(resp)
  end)
end

---@class sia.NewToolOpts
---@field name string
---@field description string
---@field read_only boolean?
---@field is_available (fun():boolean)?
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
--- @field on_accept fun()
--- @field must_confirm boolean?
--- @field preview (fun(buf:integer):integer?)?
--- @field wrap boolean?

--- @alias sia.NewToolExecuteUserInput fun(prompt: string, opts: sia.NewToolExecuteUserInputOpts):nil
--- @alias sia.NewToolExecuteUserChoice fun(prompt: string, opts: sia.NewToolExecuteUserChoiceOpts):nil
--- @class sia.NewToolExecuteOpts
--- @field cancellable sia.Cancellable?
--- @field user_input sia.NewToolExecuteUserInput
--- @field user_choice sia.NewToolExecuteUserChoice

--- @param resp string?
--- @param must_confirm boolean
--- @param opts {on_accept: fun(mode:"always"|nil), on_cancel: fun(kind:"user_cancelled"|"user_declined")}
local function handle_user_response(resp, must_confirm, opts)
  if resp == nil then
    return opts.on_cancel("user_cancelled")
  end

  local response = resp:lower():gsub("^%s*(.-)%s*$", "%1")

  if response == "n" or response == "no" then
    return opts.on_cancel("user_declined")
  end

  if not must_confirm and (response == "a" or response == "always") then
    return opts.on_accept("always")
  end

  local should_proceed = must_confirm and (response == "y" or response == "yes")
    or (response == "" or response == "y" or response == "yes")

  if should_proceed then
    opts.on_accept()
  else
    opts.on_cancel("user_declined")
  end
end

--- Create a user_input handler for tool execution
--- @param tool_name string
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
--- @param permission sia.PermissionOpts?
--- @return sia.NewToolExecuteUserInput
local function create_user_input_handler(tool_name, conversation, callback, permission)
  local approval_conf = require("sia.config").options.defaults.ui.approval
  local ignore_confirm = conversation.ignore_tool_confirm
    or (permission and permission.auto_allow)

  return function(prompt, input_args)
    if not input_args.must_confirm and ignore_confirm then
      input_args.on_accept()
      return
    end

    prompt = prompt or ("Execute " .. tool_name)

    local function prompt_user()
      local confirmation_text = input_args.must_confirm and "Proceed? (y/N): "
        or "Proceed? (Y/n/[a]lways): "

      local input_fn = approval_conf.use_vim_ui and vim.ui.input or input

      input_fn({
        prompt = string.format("%s - %s", prompt, confirmation_text),
        preview = input_args.preview,
        wrap = input_args.wrap,
      }, function(resp)
        handle_user_response(resp, input_args.must_confirm, {
          on_accept = function(mode)
            if mode == "always" then
              conversation.auto_confirm_tools[tool_name] = 1
            end
            input_args.on_accept()
          end,
          on_cancel = function(kind)
            callback({
              content = cancellation_message(tool_name),
              kind = kind,
              cancelled = true,
            })
          end,
        })
      end)
    end

    if approval_conf.async and approval_conf.async.enable then
      require("sia.approval").show(conversation, prompt, {
        level = input_args.must_confirm and "warn" or "info",
        on_accept = input_args.on_accept,
        on_cancel = function()
          callback({
            content = cancellation_message(tool_name),
            kind = "user_declined",
            cancelled = true,
          })
        end,
        on_prompt = prompt_user,
        on_preview = function()
          local clear = require("sia.preview").show(
            input_args.preview,
            { wrap = true, focusable = true }
          )
          vim.cmd.redraw()
          return clear
        end,
      })
    else
      prompt_user()
    end
  end
end

--- @param tool_name string
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
--- @param permission sia.PermissionOpts?
--- @return sia.NewToolExecuteUserChoice
local function create_user_choice_handler(tool_name, conversation, callback, permission)
  return function(prompt, choice_args)
    if permission and permission.auto_allow and not choice_args.must_confirm then
      choice_args.on_accept(permission.auto_allow)
      return
    end

    local approval_conf = require("sia.config").options.defaults.ui.approval

    local function prompt_user()
      local select_fn = select
      if approval_conf.use_vim_ui then
        select_fn = vim.ui.select
      end

      select_fn(choice_args.choices, { prompt = prompt }, function(_, idx)
        if idx then
          choice_args.on_accept(idx)
        else
          callback({
            content = cancellation_message(tool_name),
            kind = "user_cancelled",
            cancelled = true,
          })
        end
      end)
    end

    if approval_conf.async and approval_conf.async.enable then
      require("sia.approval").show(conversation, prompt, {
        on_accept = prompt_user,
        on_cancel = function()
          callback({
            content = cancellation_message(tool_name),
            kind = "user_declined",
            cancelled = true,
          })
        end,
        on_prompt = prompt_user,
      })
    else
      prompt_user()
    end
  end
end

---@param opts sia.NewToolOpts
---@param execute fun(args: table, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), opts: sia.NewToolExecuteOpts?)
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  --- @param args table
  --- @param conversation sia.Conversation
  --- @return sia.PermissionOpts?
  local resolve_permission = function(args, conversation)
    local permission = require("sia.permissions").get_permission(opts.name, args)

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
      local permission = resolve_permission(args, conversation)
      if permission and permission.deny then
        callback({
          content = {
            "OPERATION BLOCKED BY LOCAL CONFIGURATION",
            "",
            string.format(
              "The USER's local configuration denies executing the %s operation with the provided parameters.",
              opts.name
            ),
            "",
            "IMPORTANT: Do not proceed with alternative approaches. Instead:",
            "1. Acknowledge that this operation is denied by policy",
            "2. Ask the USER if they want to adjust permissions or choose a different approach",
            "3. Wait for their guidance before taking any further action",
          },
        })
        return
      end

      local user_input =
        create_user_input_handler(opts.name, conversation, callback, permission)
      local user_choice =
        create_user_choice_handler(opts.name, conversation, callback, permission)

      execute(args, conversation, callback, {
        cancellable = cancellable,
        user_input = user_input,
        user_choice = user_choice,
      })
    end,
  }
end

return M
