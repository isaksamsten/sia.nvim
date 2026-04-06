local M = {}

--- Global tool name map.
--- Use these constants whenever referring to tool names in strings (prompts, messages, etc.)
--- so that renaming a tool only requires changing one place.
--- @type table<string, string>
M.tool_names = {
  view = "view",
  skills = "skills",
  view_image = "view_image",
  view_document = "view_document",
  grep = "grep",
  glob = "glob",
  edit = "edit",
  insert = "insert",
  write = "write",
  bash = "bash",
  agent = "agent",
  diagnostics = "diagnostics",
  webfetch = "webfetch",
  websearch = "websearch",
  read_todos = "read_todos",
  write_todos = "write_todos",
  memory = "memory",
  ask_user = "ask_user",
  apply_diff = "apply_diff",
  exit_mode = "exit_mode",
}

--- TODO: refactor to only return the arguments..
--- fun(t:table):table
--- @param clear_args string[]
--- @return fun(t:sia.ToolCall):sia.ToolCall
function M.gen_clear_outdated_tool_input(clear_args)
  --- @param call sia.ToolCall
  --- @return sia.ToolCall
  local function clear_outdated_tool_input(call)
    if call.type == "custom" then
      --- @return sia.ToolCall
      return {
        id = call.id,
        call_id = call.call_id,
        type = call.type,
        name = call.name,
        input = "content has been pruned",
      }
    end

    if call.type == "function" then
      local new_arguments = call.arguments
      local ok, arguments = pcall(vim.json.decode, call.arguments)
      if ok then
        for key, _ in pairs(arguments) do
          if vim.tbl_contains(clear_args, key) then
            arguments[key] = "text has been pruned"
          end
        end
        new_arguments = vim.json.encode(arguments)
      end
      --- @type sia.ToolCall
      return {
        id = call.id,
        call_id = call.call_id,
        type = "function",
        name = call.name,
        arguments = new_arguments,
      }
    end
    return call
  end
  return clear_outdated_tool_input
end

local function cancellation_message(name)
  return string.format(
    [[OPERATION DECLINED BY USER
The USER declined to execute the %s operation

IMPORTANT: Do not proceed with your original plan. Instead:
1. Acknowledge that the operation was declined
2. Ask the USER how they would like to proceed
3. Wait for their guidance before taking any further action
Do not attempt to continue with alternative approaches unless explicitly requested by the USER.
]],
    name
  )
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
      if (resp == "" or resp == nil) or idx < 0 or idx > #items then
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

  local show_preview = require("sia.config").options.settings.ui.confirm.show_preview
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

--- @class sia.NewToolDeclaration
--- @field definition sia.tool.Definition
--- @field read_only boolean?
--- @field is_supported (fun(model: sia.Model):boolean)?
--- @field auto_apply (fun(args: any, conversation:sia.Conversation):integer?)?
--- @field persist_allow (fun(args: any, conversation:sia.Conversation):sia.PermissionAllowCandidate[]?)?
--- @field notification (fun(args:table):string)?
--- @field instructions string?

--- @class sia.NewToolExecuteUserChoiceOpts
--- @field choices string[]
--- @field on_accept fun(choice:integer):nil
--- @field on_cancel fun()?
--- @field level sia.RiskLevel?

--- @class sia.NewToolExecuteUserInputOpts
--- @field on_accept fun()
--- @field level sia.RiskLevel?
--- @field preview (fun(buf:integer):integer?)?
--- @field wrap boolean?

--- @alias sia.NewToolExecuteUserInput fun(prompt: string, opts: sia.NewToolExecuteUserInputOpts):nil
--- @alias sia.NewToolExecuteUserChoice fun(prompt: string, opts: sia.NewToolExecuteUserChoiceOpts):nil
--- @class sia.NewToolExecuteOpts
--- @field cancellable sia.Cancellable?
--- @field user_input sia.NewToolExecuteUserInput
--- @field user_choice sia.NewToolExecuteUserChoice
--- @field turn_id string?

--- @param resp string?
--- @param level sia.RiskLevel
--- @param opts {on_accept: fun(mode:"always"|nil), on_cancel: fun()}
local function handle_user_response(resp, level, opts)
  if resp == nil then
    return opts.on_cancel()
  end

  local response = resp:lower():gsub("^%s*(.-)%s*$", "%1")

  if response == "n" or response == "no" then
    return opts.on_cancel()
  end

  local risk = require("sia.risk")
  if risk.allows_auto_confirm(level) and (response == "a" or response == "always") then
    return opts.on_accept("always")
  end

  local should_proceed = response == "" or response == "y" or response == "yes"

  if should_proceed then
    opts.on_accept()
  else
    opts.on_cancel("user_declined")
  end
end

--- @param text string
--- @return string
local function escape_vim_pattern(text)
  return (text:gsub("([\\.^$~%[%]%(%){%}%-%+%*%?%|])", "\\%1"))
end

--- @param path string?
--- @return {label: string, pattern: string}[]
function M.path_allow_candidates(path)
  if type(path) ~= "string" or path == "" then
    return {}
  end

  local display_path = vim.fn.fnamemodify(path, ":.")
  if display_path == "" then
    display_path = path
  end

  local dir = vim.fn.fnamemodify(display_path, ":h")
  local basename = vim.fn.fnamemodify(display_path, ":t")

  local is_dotfile = basename:match("^%.[^.]+$") ~= nil
  local ext = (not is_dotfile) and basename:match("%.([^.]+)$") or nil
  local escaped_ext = ext and escape_vim_pattern(ext) or nil

  local candidates = {}

  -- 1. Exact path
  table.insert(candidates, {
    label = display_path,
    pattern = "^" .. escape_vim_pattern(display_path) .. "$",
  })

  -- 2. Any file with the same extension in the same directory (skip for dotfiles
  --    and extensionless files, and when the file is already at the project root)
  if escaped_ext and dir ~= "." then
    table.insert(candidates, {
      label = dir .. "/*." .. ext,
      pattern = "^" .. escape_vim_pattern(dir) .. "/[^/]+\\." .. escaped_ext .. "$",
    })
  end

  -- 3. Any file with the same extension anywhere in the project
  if escaped_ext then
    table.insert(candidates, {
      label = "**/*." .. ext,
      pattern = "[^/]+\\." .. escaped_ext .. "$",
    })
  end

  return candidates
end

--- Build a list of allow-rule candidates for a path-based argument.
--- @param arg_name string
--- @param path string?
--- @return sia.PermissionAllowCandidate[]
function M.path_allow_rules(arg_name, path)
  local candidates = M.path_allow_candidates(path)
  local rules = {}
  for _, c in ipairs(candidates) do
    table.insert(rules, {
      label = c.label,
      rule = {
        arguments = {
          [arg_name] = { c.pattern },
        },
      },
    })
  end
  return rules
end

--- @param tool_name string
--- @param args table
--- @param conversation sia.Conversation
--- @param persist_allow (fun(args: table, conversation:sia.Conversation):sia.PermissionAllowCandidate[]?)?
--- @param on_done fun()
local function persist_always_approval(
  tool_name,
  args,
  conversation,
  persist_allow,
  on_done
)
  if not persist_allow then
    conversation.auto_confirm_tools[tool_name] = 1
    on_done()
    return
  end
  local candidates = persist_allow(args, conversation)
  if not candidates or #candidates == 0 then
    conversation.auto_confirm_tools[tool_name] = 1
    on_done()
    return
  end

  local permissions = require("sia.permissions")
  if #candidates == 1 then
    permissions.persist_allow_rule(tool_name, candidates[1].rule)
    on_done()
    return
  end
  table.insert(candidates, 1, { label = "All for this conversation" })

  vim.ui.select(candidates, {
    prompt = "Select allow rule scope:",
    format_item = function(item)
      return item.label
    end,
    --- @param choice sia.PermissionAllowCandidate?
  }, function(choice)
    if not choice or choice.rule == nil then
      conversation.auto_confirm_tools[tool_name] = 1
    else
      permissions.persist_allow_rule(tool_name, choice.rule)
    end
    on_done()
  end)
end

--- Create a user_input handler for tool execution
--- @param tool_name string
--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
--- @param permission sia.PermissionOpts?
--- @return sia.NewToolExecuteUserInput
local function create_user_input_handler(
  tool_name,
  args,
  conversation,
  callback,
  permission,
  persist_allow
)
  local confirm_conf = require("sia.config").options.settings.ui.confirm
  local ignore_confirm = conversation.ignore_tool_confirm
    or (permission and permission.auto_allow)

  return function(prompt, input_args)
    local default_level = input_args.level or "info"
    local risk = require("sia.risk")
    local resolved_level = risk.get_risk_level(tool_name, args, default_level)

    if risk.allows_auto_confirm(resolved_level) and ignore_confirm then
      input_args.on_accept()
      return
    end

    prompt = prompt or ("Execute " .. tool_name)

    local function prompt_user()
      local confirmation_text = (resolved_level == "warn") and "Proceed? (y/N): "
        or "Proceed? (Y/n/[a]lways): "

      local input_fn = confirm_conf.use_vim_ui and vim.ui.input or input

      input_fn({
        prompt = string.format("%s - %s", prompt, confirmation_text),
        preview = input_args.preview,
        wrap = input_args.wrap,
      }, function(resp)
        handle_user_response(resp, resolved_level, {
          on_accept = function(mode)
            if mode == "always" then
              persist_always_approval(
                tool_name,
                args,
                conversation,
                persist_allow,
                input_args.on_accept
              )
              return
            end
            input_args.on_accept()
          end,
          on_cancel = function()
            callback({
              content = cancellation_message(tool_name),
            })
          end,
        })
      end)
    end

    local on_always = nil
    if require("sia.risk").allows_auto_confirm(resolved_level) then
      on_always = function()
        persist_always_approval(
          tool_name,
          args,
          conversation,
          persist_allow,
          input_args.on_accept
        )
      end
    end

    if confirm_conf.async and confirm_conf.async.enable then
      require("sia.ui.confirm").show(conversation, prompt, {
        level = resolved_level,
        tool_name = tool_name,
        kind = "input",
        on_accept = input_args.on_accept,
        on_always = on_always,
        on_cancel = function()
          callback({
            content = cancellation_message(tool_name),
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
--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
--- @param permission sia.PermissionOpts?
--- @return sia.NewToolExecuteUserChoice
local function create_user_choice_handler(
  tool_name,
  args,
  conversation,
  callback,
  permission
)
  return function(prompt, choice_args)
    local default_level = choice_args.level or "info"
    local risk = require("sia.risk")
    local resolved_level = risk.get_risk_level(tool_name, args, default_level)

    if
      permission
      and permission.auto_allow
      and risk.allows_auto_confirm(resolved_level)
    then
      choice_args.on_accept(permission.auto_allow)
      return
    end

    local confirm_conf = require("sia.config").options.settings.ui.confirm

    local function prompt_user()
      local select_fn = select
      if confirm_conf.use_vim_ui then
        select_fn = vim.ui.select
      end

      select_fn(choice_args.choices, { prompt = prompt }, function(_, idx)
        if idx then
          choice_args.on_accept(idx)
        else
          if choice_args.on_cancel then
            choice_args.on_cancel()
          else
            callback({
              content = cancellation_message(tool_name),
            })
          end
        end
      end)
    end

    if confirm_conf.async and confirm_conf.async.enable then
      require("sia.ui.confirm").show(conversation, prompt, {
        level = resolved_level,
        tool_name = tool_name,
        kind = "choice",
        on_accept = prompt_user,
        on_cancel = function()
          callback({
            content = cancellation_message(tool_name),
          })
        end,
        on_prompt = prompt_user,
      })
    else
      prompt_user()
    end
  end
end

---@param opts sia.NewToolDeclaration
---@param execute fun(args: any, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), opts: sia.NewToolExecuteOpts?)
---@return sia.Tool
M.new_tool = function(opts, execute)
  --- @param args table
  --- @param conversation sia.Conversation
  --- @return sia.PermissionOpts?
  local resolve_permission = function(args, conversation)
    local permissions = require("sia.permissions")
    if conversation.active_mode then
      local mode_permission = permissions.resolve_mode_permission(
        conversation.active_mode,
        opts.definition.name,
        args
      )
      if mode_permission then
        return mode_permission
      end
    end

    local permission = permissions.resolve_permissions(opts.definition.name, args)
    if permission then
      return permission
    elseif not permission then
      if conversation.auto_confirm_tools[opts.definition.name] then
        return { auto_allow = conversation.auto_confirm_tools[opts.definition.name] }
      else
        local choice = (opts.auto_apply and opts.auto_apply(args, conversation)) or nil
        return choice and { auto_allow = choice } or nil
      end
    end
  end

  --- @type sia.Tool
  return {
    implementation = {
      instructions = opts.instructions,
      is_supported = opts.is_supported,
      notification = opts.notification,
      allow_parallel = function(args, conversation)
        if
          opts.read_only
          and (
            (
              conversation.auto_confirm_tools
              and conversation.auto_confirm_tools[opts.definition.name]
            ) or conversation.ignore_tool_confirm
          )
        then
          return true
        end

        if
          opts.read_only
          and require("sia.config").options.settings.ui.confirm.async.enable
        then
          return true
        end

        if not opts.read_only then
          return false
        end

        local permission = resolve_permission(args, conversation)
        if not permission or not permission.auto_allow then
          return false
        end

        local risk = require("sia.risk")
        local resolved_level = risk.get_risk_level(opts.definition.name, args, "info")
        return risk.allows_auto_confirm(resolved_level)
      end,
      execute = function(args, callback, exeution_context)
        local permission = resolve_permission(args, exeution_context.conversation)
        if permission and permission.deny then
          callback({
            content = permission.reason
              or {
                "OPERATION BLOCKED",
                "",
                string.format("The %s operation was denied.", opts.definition.name),
              },
          })
          return
        end

        local user_input = create_user_input_handler(
          opts.definition.name,
          args,
          exeution_context.conversation,
          callback,
          permission,
          opts.persist_allow
        )
        local user_choice = create_user_choice_handler(
          opts.definition.name,
          args,
          exeution_context.conversation,
          callback,
          permission
        )

        execute(args, exeution_context.conversation, callback, {
          cancellable = exeution_context.cancellable,
          user_input = user_input,
          user_choice = user_choice,
          turn_id = exeution_context.turn_id,
        })
      end,
    },
    definition = opts.definition,
  }
end

return M
