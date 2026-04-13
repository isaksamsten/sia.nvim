--- @param invocation sia.Invocation
--- @return sia.config.ActionMode
local function get_action_mode(invocation)
  if invocation.bang and invocation.mode == "n" then
    return "insert"
  elseif invocation.bang and invocation.mode == "v" then
    return "diff"
  else
    return "chat"
  end
end

local CommandParser = require("sia.utils").CommandParser

local SIA_PARSER = CommandParser.new({ flags = { "m", "s" } })

--- @param conversation sia.Conversation
--- @param skill_name string?
--- @return string?
local function resolve_invoked_skill_message(conversation, skill_name)
  if not skill_name then
    return nil
  end

  local registry = require("sia.skills.registry")
  local skill, err = registry.get_skill(skill_name)
  if not skill then
    vim.notify(
      string.format(
        "sia: failed to load skill '%s': %s",
        skill_name,
        err or "unknown error"
      ),
      vim.log.levels.ERROR
    )
    return nil
  end

  local missing_tools = registry.get_missing_tools(skill, function(name)
    return conversation:has_tool(name)
  end)
  if #missing_tools > 0 then
    vim.notify(
      string.format(
        "sia: skill '%s' requires unavailable tools: %s",
        skill_name,
        table.concat(missing_tools, ", ")
      ),
      vim.log.levels.ERROR
    )
    return nil
  end
  local lines = {
    string.format(
      "The user explicitly invoked the skill `%s` for this conversation.",
      skill.name
    ),
    "Use it when it helps with the user's current request unless they redirect you.",
    "",
    "Skill definition:",
    "- name: " .. skill.name,
    "- description: " .. skill.description,
    "- entrypoint: " .. skill.filepath,
    "- directory: " .. skill.dir,
    "",
    "If you need to reopen this skill later, use the `skills` tool with the same skill name.",
    "If you need supporting files, examples, or scripts for this skill, inspect the skill directory above with your normal file tools.",
    "",
    string.format('<invoked_skill name="%s">', skill.name),
    table.concat(skill.content, "\n"),
    "</invoked_skill>",
  }

  return table.concat(lines, "\n")
end

vim.api.nvim_create_user_command("Sia", function(args)
  local utils = require("sia.utils")

  local parsed = SIA_PARSER:parse(args.fargs)

  local chat = require("sia.strategy").get_chat()
  if chat and not parsed.action then
    local skill_message =
      resolve_invoked_skill_message(chat.conversation, parsed.flags.s)
    if parsed.flags.s and not skill_message then
      return
    end

    if #parsed.positional > 0 or parsed.mode or skill_message then
      chat:submit({
        content = #parsed.positional > 0 and table.concat(parsed.positional, " ")
          or nil,
        mode = parsed.mode,
        hidden_messages = skill_message and { skill_message } or nil,
      })
    end
    return
  end
  --- @type sia.Invocation
  local invocation = utils.new_invocation(args)

  local config = require("sia.config")
  --- @type sia.config.Action
  local action
  if parsed.action then
    action = config.options.actions[parsed.action or vim.b.sia] --[[@as sia.config.Action]]
    if not action then
      error(parsed.action .. " not found")
    end
  else
    action = config.options.settings.actions[get_action_mode(invocation)] --[[@as sia.config.Action]]
    if not action then
      error("action " .. get_action_mode(invocation) .. " is not defined")
    end
  end

  if parsed.mode and action.mode ~= "chat" then
    error("modes are only possible with chat actions")
  end

  if parsed.flags.m and not require("sia.provider").has_model(parsed.flags.m) then
    vim.notify("sia: model is not defined", vim.log.levels.ERROR)
    return
  end

  if action.capture and invocation.mode ~= "v" then
    local capture = action.capture(invocation)
    if not capture then
      vim.notify("sia: unable to capture current context", vim.log.levels.ERROR)
      return
    end
    invocation.pos = { capture.start_row, capture.end_row }
    invocation.mode = "v"
  end

  if action.range == true and invocation.mode ~= "v" then
    vim.notify(
      "sia: action " .. parsed.action .. " must be used with a range",
      vim.log.levels.ERROR
    )
    return
  end

  local is_range = invocation.mode == "v"
  local is_range_valid = action.range == nil or action.range == is_range
  if utils.is_action_disabled(action) or not is_range_valid then
    vim.notify(
      "sia: action " .. parsed.action .. " is not enabled in the current context",
      vim.log.levels.ERROR
    )
    return
  end

  if action.input == "require" and #parsed.positional == 0 then
    error("requires input")
  end

  local user_input
  if action.input ~= "ignore" then
    user_input = parsed.positional
  end

  local conversation = require("sia.conversation").from_action(action, invocation, {
    model = parsed.flags.m,
  })

  if parsed.mode and action.mode == "chat" then
    local info = conversation:enter_mode(parsed.mode)
    if info and info.content then
      conversation:add_user_message(info.content, nil, { hide = true })
    end
  end

  local skill_message = resolve_invoked_skill_message(conversation, parsed.flags.s)
  if parsed.flags.s and not skill_message then
    return
  end
  if skill_message then
    conversation:add_user_message(skill_message, nil, { hide = true })
  end

  if user_input then
    conversation:add_user_message(table.concat(user_input, " "))
  end

  local strategy = require("sia.strategy").from_action(action, invocation, conversation)
  require("sia.assistant").execute_strategy(strategy)
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
    local is_bang = require("sia.utils").is_bang_command(CmdLine)

    local chat = require("sia.strategy").get_chat()

    local prefix = string.sub(CmdLine, 1, CursorPos)
    local args_before = {}
    local args_text = prefix:match("^%S+%s+(.*)$") or ""
    for arg in args_text:gmatch("%S+") do
      table.insert(args_before, arg)
    end

    local parsed = SIA_PARSER:parse(args_before)

    local flag_completions = SIA_PARSER:complete_flag(parsed, prefix, {
      m = require("sia.provider").list(),
      s = require("sia.skills.registry").list_skill_names(),
    })
    if flag_completions then
      return flag_completions
    end

    local positional = parsed.positional

    if chat and #positional == 1 then
      if vim.startswith(ArgLead, "@") then
        local term = ArgLead:sub(2)
        local completions = {}
        for mode_name, _ in pairs(chat.conversation.modes) do
          if vim.startswith(mode_name, term) then
            table.insert(completions, mode_name)
          end
        end
        return completions
      end
    elseif vim.startswith(ArgLead, "/") and #positional == 1 then
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
    elseif vim.startswith(ArgLead, "@") then
      local action_modes = nil
      if #positional <= 1 and not is_bang then
        local action = config.options.settings.actions.chat
        action_modes = action and action.modes
      elseif #positional == 2 and vim.startswith(positional[1], "/") then
        local action_name = positional[1]:sub(2)
        local action = config.options.actions[action_name] --[[@as sia.config.Action]]
        if action.mode == "chat" then
          action_modes = action and action.modes
        end
      end

      if action_modes then
        local term = ArgLead:sub(2)
        local complete = {}
        for mode_name, _ in pairs(action_modes) do
          if vim.startswith(mode_name, term) then
            table.insert(complete, "@" .. mode_name)
          end
        end
        if vim.startswith("default", term) then
          table.insert(complete, "@default")
        end
        table.sort(complete)
        return complete
      end
    end

    return {}
  end,
})

vim.api.nvim_create_user_command("SiaDebug", function()
  local chat = require("sia.strategy").get_chat()
  if not chat then
    vim.notify("sia: no active chat in this buffer", vim.log.levels.WARN)
    return
  end
  local ok, result = pcall(chat.conversation.serialize, chat.conversation)
  if not ok then
    vim.notify(
      "sia: error generating conversation query: " .. tostring(result),
      vim.log.levels.ERROR
    )
    return
  end

  local order = {}
  for _, message in ipairs(result) do
    table.insert(
      order,
      string.format(
        "Role: %s %s",
        message.role,
        (message.tool_call and message.tool_call.id or "")
      )
    )
  end

  local provider = chat.conversation.model.provider
  local data = { model = chat.conversation.model.api_name }
  provider.prepare_parameters(data, chat.conversation.model)
  provider.prepare_messages(data, chat.conversation.model.api_name, result)
  provider.prepare_tools(data, chat.conversation.tool_definitions)
  local json_str = vim.json.encode(data)
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
  local lines = vim.split(pretty, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, order)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, "*SiaDebug*")
end, {})

--- @class sia.AddCommand
--- @field completion (fun(s:string):string[])?
--- @field execute_local fun(args: vim.api.keyset.create_user_command.command_args, c: sia.Conversation):nil
--- @field execute_global (fun(args: vim.api.keyset.create_user_command.command_args):nil)?
--- @field require_range boolean
--- @field only_visible boolean?
--- @field non_sia_buf boolean?

--- @type table<string, sia.AddCommand>
local SIA_ADD_CMD = {
  file = {
    only_visible = true,
    require_range = false,
    completion = function(lead)
      return vim.fn.getcompletion(lead, "file")
    end,
    execute_local = function(args, conversation)
      local utils = require("sia.utils")
      local files = utils.glob_pattern_to_files(args.fargs)
      for _, file in ipairs(files) do
        local buf = utils.ensure_file_is_loaded(file, {
          listed = false,
          read_only = true,
        })
        if buf then
          local get_buffer =
            require("sia.instructions").current_buffer({ show_line_numbers = true })
          local invocation = {
            buf = buf,
            mode = "v",
          }
          local content, region = get_buffer(invocation)
          if content then
            conversation:add_user_message(content, region)
          end
        end
      end
    end,
  },
  context = {
    require_range = true,
    only_visible = true,
    execute_local = function(args, conversation)
      local context = require("sia.utils").new_invocation(args)
      local get_current_context =
        require("sia.instructions").current_context({ show_line_numbers = true })
      local content, region = get_current_context(context)
      if content then
        conversation:add_user_message(content, region)
      end
    end,
  },
  buffer = {
    require_range = false,
    completion = function(lead)
      return vim.fn.getcompletion(lead, "buffer")
    end,
    execute_local = function(args, conversation)
      for _, bufname in ipairs(args.fargs) do
        local buf = vim.fn.bufnr(bufname)
        if buf ~= -1 then
          local get_buffer =
            require("sia.instructions").current_buffer({ show_line_numbers = true })
          local context = {
            buf = buf,
            mode = "v",
          }
          local content, region = get_buffer(context)
          if content then
            conversation:add_user_message(content, region)
          end
        end
      end
    end,
  },
}

vim.api.nvim_create_user_command("SiaAccept", function(args)
  if args.bang then
    require("sia").edit.accept_all()
  else
    require("sia").edit.accept()
  end
end, { bang = true })

vim.api.nvim_create_user_command("SiaReject", function(args)
  if args.bang then
    require("sia").edit.reject_all()
  else
    require("sia").edit.reject()
  end
end, { bang = true })

vim.api.nvim_create_user_command("SiaDiff", function()
  require("sia").edit.show()
end, {})

vim.api.nvim_create_user_command("SiaRollback", function(args)
  local ChatStrategy = require("sia.strategy").ChatStrategy
  local diff = require("sia.diff")

  local chat = ChatStrategy.by_buf()
  if not chat then
    return
  end

  if chat.is_busy then
    vim.notify("sia: chat is busy, wait for completion", vim.log.levels.WARN)
    return
  end

  local turn_id = args.fargs[1] --[[@as string?]]
  if not turn_id then
    turn_id = chat.conversation:last_turn_id()
    if not turn_id then
      vim.notify("sia: no turns to rollback", vim.log.levels.WARN)
      return
    end
  end
  local dropped_turn_ids = chat.conversation:rollback_to(turn_id)
  if not dropped_turn_ids then
    vim.notify(string.format("sia: turn '%s' not found", turn_id), vim.log.levels.ERROR)
    return
  end

  diff.rollback(dropped_turn_ids)
  chat:redraw()
end, {
  nargs = "?",
  complete = function(arg_lead)
    local chat = require("sia.strategy").get_chat()
    if not chat or not chat.conversation then
      return {}
    end

    local completions = {}
    local seen = {}
    for _, msg in ipairs(chat.conversation.entries) do
      if msg.turn_id and not seen[msg.turn_id] and not msg.dropped then
        seen[msg.turn_id] = true
        if vim.startswith(msg.turn_id, arg_lead) then
          table.insert(completions, msg.turn_id)
        end
      end
    end
    return completions
  end,
})

vim.api.nvim_create_user_command("SiaConfirm", function(args)
  local command = args.fargs[1]
  local approval = require("sia").confirm
  if command == "prompt" then
    approval.prompt({ first = args.bang })
  elseif command == "accept" then
    approval.accept({ first = args.bang })
  elseif command == "always" then
    approval.always({ first = args.bang })
  elseif command == "decline" then
    approval.decline({ first = args.bang })
  elseif command == "preview" then
    approval.preview({ first = args.bang })
  elseif command == "expand" then
    approval.expand()
  end
end, {
  nargs = 1,
  bang = true,
  complete = function(arg_lead)
    local commands = { "prompt", "accept", "always", "decline", "preview", "expand" }
    return vim
      .iter(commands)
      :filter(function(command)
        return vim.startswith(command, arg_lead)
      end)
      :totable()
  end,
})

vim.api.nvim_create_user_command("SiaAdd", function(args)
  local cmd_name = table.remove(args.fargs, 1)
  local command = SIA_ADD_CMD[cmd_name]
  if command then
    if command.non_sia_buf and vim.bo.ft == "sia" then
      vim.notify("sia: not a valid context", vim.log.levels.WARN)
      return
    end

    require("sia.utils").with_chat_strategy({
      on_select = function(chat)
        command.execute_local(args, chat.conversation)
      end,
      on_none = function()
        if command.execute_global then
          command.execute_global(args)
        end
      end,
      only_visible = true,
    })
  end
end, {
  nargs = "*",
  bang = true,
  bar = true,
  range = true,
  complete = function(arg_lead, line, pos)
    local is_range = require("sia.utils").is_range_commend(line)
    local complete = {}

    if string.sub(line, 1, pos):match("SiaAdd%s%w*$") then
      for command, command_args in pairs(SIA_ADD_CMD) do
        local non_sia_buf = command_args.non_sia_buf == nil
          or (command_args.non_sia_buf and vim.bo.ft ~= "sia")
        if
          non_sia_buf
          and vim.startswith(command, arg_lead)
          and command_args.require_range == is_range
        then
          complete[#complete + 1] = command
        end
      end
    else
      local command = SIA_ADD_CMD[string.sub(line, 1, pos):match("SiaAdd%s+(%w*)")]
      if command and command.completion then
        for _, subcmd in ipairs(command.completion(arg_lead)) do
          complete[#complete + 1] = subcmd
        end
      end
    end
    return complete
  end,
})

local SIA_FORK_PARSER = CommandParser.new({ flags = { "t" } })
vim.api.nvim_create_user_command("SiaFork", function(args)
  local fork_conversation = require("sia.conversation").fork_conversation
  local chat = require("sia.strategy").get_chat()

  if not chat or not chat.conversation then
    vim.notify("sia: no active chat in this buffer", vim.log.levels.ERROR)
    return
  end

  if chat.is_busy then
    vim.notify("sia: current conversation is busy", vim.log.levels.WARN)
    return
  end

  local parsed = SIA_FORK_PARSER:parse(args.fargs)
  local turn_id = parsed.flags.t
  if not turn_id then
    turn_id = chat.conversation:last_turn_id()
    if not turn_id then
      vim.notify("sia: no turns to fork from", vim.log.levels.WARN)
      return
    end
  end

  local prompt = table.concat(parsed.positional, " ")
  if prompt == "" then
    vim.notify("sia: no prompt provided", vim.log.levels.ERROR)
    return
  end

  local forked = fork_conversation(chat.conversation, turn_id)
  if not forked then
    vim.notify(string.format("sia: turn '%s' not found", turn_id), vim.log.levels.ERROR)
    return
  end

  forked:add_instruction({
    role = "user",
    content = prompt,
  }, nil)
  local new_strategy = require("sia.strategy").new_chat(forked, chat.options)
  require("sia.assistant").execute_strategy(new_strategy)
end, {
  nargs = "+",
  complete = function(_, cmd_line, cursor_pos)
    local prefix = string.sub(cmd_line, 1, cursor_pos)
    local chat = require("sia.strategy").get_chat()
    if chat and chat.conversation then
      local args_before = {}
      local args_text = prefix:match("^%S+%s+(.*)$") or ""
      for arg in args_text:gmatch("%S+") do
        table.insert(args_before, arg)
      end

      local parsed = SIA_FORK_PARSER:parse(args_before)

      local flag_completions = SIA_FORK_PARSER:complete_flag(parsed, prefix, {
        t = vim.tbl_keys(chat.conversation:turn_ids()),
      })
      if flag_completions then
        return flag_completions
      end
    end

    return {}
  end,
})

vim.api.nvim_create_user_command("SiaShell", function(args)
  local chat = require("sia.strategy").get_chat()
  if not chat or not chat.conversation then
    vim.notify("sia: no active chat found", vim.log.levels.ERROR)
    return
  end

  local subcommand = args.fargs[1]

  if subcommand == "stop" then
    local id = tonumber(args.fargs[2])
    if not id then
      vim.notify("sia: process ID required", vim.log.levels.ERROR)
      return
    end

    local proc = chat.conversation.process_runtime:get(id)
    if not proc then
      vim.notify(string.format("sia: no process with ID %d", id), vim.log.levels.ERROR)
      return
    end

    if proc.kind ~= "running" then
      return
    end

    chat.conversation.process_runtime:stop(id)
  elseif subcommand == "list" or subcommand == nil then
    local procs = chat.conversation.process_runtime:list()
    if #procs == 0 then
      return
    end

    local lines = {}
    for _, proc in ipairs(procs) do
      local status_icon = ({
        running = "●",
        completed = "✓",
        failed = "✗",
        timed_out = "⏱",
      })[proc.outcome] or "?"

      local elapsed = ""
      if proc.kind == "finished" then
        elapsed = string.format(" (%.1fs)", proc.duration)
      end

      table.insert(
        lines,
        string.format("  %s [%d] %s%s", status_icon, proc.id, proc.command, elapsed)
      )
    end

    vim.api.nvim_echo(
      { { "sia: processes\n" .. table.concat(lines, "\n"), "Normal" } },
      true,
      {}
    )
  else
    vim.notify(
      "sia: unknown subcommand '" .. subcommand .. "'. use 'list' or 'stop <id>'",
      vim.log.levels.ERROR
    )
  end
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local prefix = string.sub(cmd_line, 1, cursor_pos)

    if prefix:match("SiaShell%s%w*$") then
      local subcommands = { "list", "stop" }
      local result = {}
      for _, cmd in ipairs(subcommands) do
        if vim.startswith(cmd, arg_lead) then
          table.insert(result, cmd)
        end
      end
      return result
    end

    if prefix:match("SiaShell%s+stop%s") then
      local ChatStrategy = require("sia.strategy").ChatStrategy
      local chat = ChatStrategy.by_buf()
      if not chat then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          local c = ChatStrategy.by_buf(buf)
          if c then
            chat = c
            break
          end
        end
      end

      if chat and chat.conversation then
        local ids = {}
        for _, proc in ipairs(chat.conversation.process_runtime:list()) do
          if proc.kind == "running" then
            local id_str = tostring(proc.id)
            if vim.startswith(id_str, arg_lead) then
              table.insert(ids, id_str)
            end
          end
        end
        return ids
      end
    end

    return {}
  end,
})

vim.api.nvim_create_user_command("SiaAgent", function(args)
  local subcommand = args.fargs[1]

  local chat = require("sia.strategy").get_chat()
  if not chat then
    return
  end

  if subcommand == "start" then
    local agent_name = args.fargs[2]
    if not agent_name then
      vim.notify(
        "sia: agent name required. usage: SiaAgent start <name> <task>",
        vim.log.levels.ERROR
      )
      return
    end

    local task = table.concat(vim.list_slice(args.fargs, 3), " ")
    if task == "" then
      vim.notify(
        "sia: task required. usage: SiaAgent start <name> <task>",
        vim.log.levels.ERROR
      )
      return
    end

    local winbar = require("sia.ui.winbar")
    local icons = require("sia.ui").icons
    local agent = chat.conversation.agent_runtime:spawn(agent_name, task, {
      on_complete = function(agent)
        if chat:buf_is_loaded() then
          local status_msg
          if agent.status == "pending" then
            status_msg = {
              message = string.format("%s %s completed", icons.success, agent.name),
              status = "info",
            }
          elseif agent.status == "cancelled" then
            status_msg = {
              message = string.format("%s %s cancelled", icons.error, agent.name),
              status = "warning",
            }
          else
            status_msg = {
              message = string.format(
                "%s %s failed %s",
                icons.error,
                agent.name,
                agent.error or ""
              ),
              status = "error",
            }
          end
          winbar.update_status(chat.buf, status_msg)
          winbar.clear_status(chat.buf, 5000)
        end
      end,
    })

    if not agent then
      vim.notify("sia: agent not found", vim.log.levels.ERROR)
      return
    end

    vim.api.nvim_echo({
      {
        string.format("%s started (id: %d)", agent_name, agent.id),
        "SiaProgress",
      },
    }, false, {})
  elseif subcommand == "open" then
    local id = tonumber(args.fargs[2])
    if not id then
      return
    end

    chat.conversation.agent_runtime:open(id)
  elseif subcommand == "cancel" then
    local id = tonumber(args.fargs[2])
    if not id then
      return
    end
    chat.conversation.agent_runtime:stop(id)
  else
    vim.notify(
      "sia: unknown subcommand '"
        .. tostring(subcommand)
        .. "'. use 'start', 'open', 'complete', or 'cancel'",
      vim.log.levels.ERROR
    )
  end
end, {
  nargs = "+",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local prefix = string.sub(cmd_line, 1, cursor_pos)

    if prefix:match("SiaAgent%s%w*$") then
      local subcommands = { "start", "open", "complete", "cancel" }
      return vim.tbl_filter(function(cmd)
        return vim.startswith(cmd, arg_lead)
      end, subcommands)
    end

    if prefix:match("SiaAgent%s+start%s+[%w/%-_]*$") then
      local agents = vim
        .iter(require("sia.agent.registry").filter(function(agent)
          print(agent.name)
          return vim.startswith(agent.name, arg_lead)
        end))
        :map(function(agent)
          return agent.name
        end)
        :totable()
      return agents
    end

    if prefix:match("SiaAgent%s+open%s") then
      local chat = require("sia.strategy").get_chat()
      if chat and chat.conversation then
        local ids = {}
        for _, agent in ipairs(chat.conversation.agent_runtime:list()) do
          if chat.conversation.agent_runtime:can_open(agent.id) then
            local id_str = tostring(agent.id)
            if vim.startswith(id_str, arg_lead) then
              table.insert(ids, id_str)
            end
          end
        end
        return ids
      end
    end

    if prefix:match("SiaAgent%s+cancel%s") then
      local chat = require("sia.strategy").get_chat()
      if chat and chat.conversation then
        local ids = {}
        for _, agent in ipairs(chat.conversation.agent_runtime:list()) do
          if
            agent.status == "running"
            or agent.status == "idle"
            or agent.status == "pending"
          then
            local id_str = tostring(agent.id)
            if vim.startswith(id_str, arg_lead) then
              table.insert(ids, id_str)
            end
          end
        end
        return ids
      end
    end

    return {}
  end,
})

vim.api.nvim_create_user_command("SiaAuth", function(args)
  local provider_name = args.fargs[1]
  if not provider_name then
    vim.notify("sia: provider name required", vim.log.levels.ERROR)
    return
  end

  local registry = require("sia.provider")
  registry.authorize(provider_name, function(data)
    if data then
      vim.notify(
        string.format("sia: ready to use %s/ models", provider_name),
        vim.log.levels.INFO
      )
    else
      vim.notify(
        string.format("sia: %s authorization failed", provider_name),
        vim.log.levels.ERROR
      )
    end
  end)
end, {
  nargs = 1,
  complete = function(arg_lead)
    local registry = require("sia.provider")
    local completions = {}
    for _, name in ipairs(registry.list_authorizers()) do
      if vim.startswith(name, arg_lead) then
        table.insert(completions, name)
      end
    end
    return completions
  end,
})

vim.api.nvim_create_user_command("SiaModel", function(args)
  local subcmd = args.fargs[1]
  local target = args.fargs[2]
  local registry = require("sia.provider")

  if not subcmd or subcmd == "list" then
    local models = registry.list(target)
    if #models > 0 then
      vim.notify(table.concat(models, "\n"), vim.log.levels.INFO)
    end
  elseif subcmd == "show" then
    if not target then
      return
    end
    local ok, entry = pcall(registry.resolve_model, target)
    if not ok then
      return
    end

    local lines = {
      string.format("Model: %s", entry.name),
      string.format("  Provider: %s", entry.provider_name),
      string.format("  API Name: %s", entry.api_name),
    }
    if entry.context_window then
      table.insert(lines, string.format("  Context Window: %d", entry.context_window))
    end
    if entry.support then
      local flags = {}
      for k, v in pairs(entry.support) do
        if v then
          table.insert(flags, k)
        end
      end
      if #flags > 0 then
        table.sort(flags)
        table.insert(lines, "  Support: " .. table.concat(flags, ", "))
      end
    end
    if entry.pricing then
      table.insert(
        lines,
        string.format(
          "  Pricing: $%.2f/$%.2f per 1M tokens",
          entry.pricing.input,
          entry.pricing.output
        )
      )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  elseif subcmd == "refresh" then
    registry.refresh(vim.schedule_wrap(function(results)
      local refreshed = {}
      for provider_name, result in pairs(results) do
        if result.ok then
          table.insert(refreshed, provider_name)
        end
      end
      if #refreshed > 0 then
        vim.notify(
          string.format("sia: %s are up to date", table.concat(refreshed, ", "))
        )
      end
    end))
  else
    vim.notify(
      "sia: unknown subcommand '" .. subcmd .. "'. Use: list, show, refresh",
      vim.log.levels.ERROR
    )
  end
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line)
    local registry = require("sia.provider")
    local parts = vim.split(cmd_line, "%s+")
    if #parts <= 2 then
      local subcmds = { "list", "show", "refresh" }
      local matches = {}
      for _, s in ipairs(subcmds) do
        if vim.startswith(s, arg_lead) then
          table.insert(matches, s)
        end
      end
      return matches
    elseif parts[2] == "show" then
      local models = registry.list()
      local matches = {}
      for _, m in ipairs(models) do
        if vim.startswith(m, arg_lead) then
          table.insert(matches, m)
        end
      end
      return matches
    elseif parts[2] == "list" then
      local provider_names = registry.list_providers()
      table.sort(provider_names)
      local matches = {}
      for _, p in ipairs(provider_names) do
        if vim.startswith(p, arg_lead) then
          table.insert(matches, p)
        end
      end
      return matches
    end
    return {}
  end,
})
