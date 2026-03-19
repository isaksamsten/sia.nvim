--- A generic command parser that enforces `[flags...] [positional...]` grammar.
--- Flags must appear before any positional arguments. Each flag consumes one
--- value token. The parser only parses; completion and validation are the
--- caller's responsibility.
---
--- @class sia.CommandParser
--- @field private _flags table<string, true>
local CommandParser = {}
CommandParser.__index = CommandParser

--- Create a new command parser.
--- @param spec { flags: string[] }
function CommandParser.new(spec)
  local flags = {}
  for _, name in ipairs(spec.flags or {}) do
    flags[name] = true
  end
  return setmetatable({ _flags = flags }, CommandParser)
end

--- Parse arguments into flags and positional args.
--- Flags are only recognised at the front; once a non-flag token is seen
--- everything from that point on is positional.
---
--- @param args string[]
--- @return { flags: table<string, string?>, positional: string[] }
function CommandParser:parse(args)
  local result = { flags = {}, positional = {} }
  local i = 1
  while i <= #args do
    local name = args[i]:match("^%-(.+)$")
    if name and self._flags[name] and not result.flags[name] then
      if i + 1 <= #args then
        result.flags[name] = args[i + 1]
      end
      i = i + 2
    else
      break
    end
  end
  for j = i, #args do
    table.insert(result.positional, args[j])
  end
  return result
end

--- Return completions for a flag value if the cursor is on one.
--- Only works when the parsed result has no positional args yet (still in
--- the flag zone). The caller provides a table mapping flag names to their
--- candidate values.
---
--- @param parsed { flags: table<string, string?>, positional: string[] }
--- @param prefix string The command-line text up to the cursor
--- @param candidates table<string, string[]> Flag name → possible values
--- @return string[]|nil completions Filtered completions, or nil if not on a flag value
function CommandParser:complete_flag(parsed, prefix, candidates)
  if #parsed.positional > 0 then
    return nil
  end
  for name, values in pairs(candidates) do
    if self._flags[name] then
      local partial = prefix:match("%-" .. vim.pesc(name) .. "%s+([%w%-_/.]*)$")
      if partial then
        local filtered = vim.tbl_filter(function(v)
          return vim.startswith(v, partial)
        end, values)
        table.sort(filtered)
        return filtered
      end
    end
  end
  return nil
end

local SIA_PARSER = CommandParser.new({ flags = { "m" } })
vim.api.nvim_create_user_command("Sia", function(args)
  local utils = require("sia.utils")

  local parsed = SIA_PARSER:parse(args.fargs)
  local model = parsed.flags.m

  if model and not require("sia.config").options.models[model] then
    vim.notify("sia: model is not defined", vim.log.levels.ERROR)
    return
  end

  local fargs = parsed.positional

  if #fargs == 0 and not vim.b.sia then
    vim.notify("sia: no prompt provided", vim.log.levels.ERROR)
    return
  end

  --- @type sia.ActionContext
  local context = utils.create_context(args)
  if vim.b.sia and #fargs == 0 then
    fargs = { vim.b.sia }
  end

  local action, new_action, mode_entry = utils.resolve_action(fargs, context)

  if not action then
    return
  end

  if action.capture and context.mode ~= "v" then
    local capture = action.capture(context)
    if not capture then
      vim.notify("sia: unable to capture current context", vim.log.levels.ERROR)
      return
    end
    context.start_line, context.end_line = capture[1], capture[2]
    context.pos = { capture[1], capture[2] }
    context.mode = "v"
  end

  if action.range == true and context.mode ~= "v" then
    vim.notify(
      "sia: action " .. fargs[1] .. " must be used with a range",
      vim.log.levels.ERROR
    )
    return
  end

  local is_range = context.mode == "v"
  local is_range_valid = action.range == nil or action.range == is_range
  if utils.is_action_disabled(action) or not is_range_valid then
    vim.notify(
      "sia: action " .. fargs[1] .. " is not enabled in the current context",
      vim.log.levels.ERROR
    )
    return
  end

  require("sia").execute_action(action, {
    context = context,
    model = model,
    new_action = new_action,
    mode = mode_entry,
  })
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
      m = vim.tbl_keys(config.options.models),
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
  if not chat or not chat.conversation or not chat.conversation.prepare_messages then
    vim.notify("sia: no active chat in this buffer", vim.log.levels.WARN)
    return
  end
  local ok, result = pcall(chat.conversation.prepare_messages, chat.conversation)
  if not ok then
    vim.notify(
      "sia: error generating conversation query: " .. tostring(result),
      vim.log.levels.ERROR
    )
    return
  end

  local provider = chat.conversation.model:get_provider()
  local data = { model = chat.conversation.model.api_name }
  provider.prepare_parameters(data, chat.conversation.model)
  provider.prepare_messages(data, chat.conversation.model.api_name, result)
  provider.prepare_tools(data, chat.conversation.tools)
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
  local lines = vim.split(pretty, "\n", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    execute_global = function(args)
      local utils = require("sia.utils")
      local files = utils.glob_pattern_to_files(args.fargs)
      for _, file in ipairs(files) do
        local buf = utils.ensure_file_is_loaded(file, {
          listed = false,
          read_only = true,
        })
        if buf then
          require("sia.conversation").Conversation.add_pending_instruction(
            "current_context",
            {
              buf = buf,
              tick = require("sia.tracker").ensure_tracked(buf),
              kind = "context",
              mode = "v",
            }
          )
        end
      end
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
          conversation:add_instruction("current_context", {
            buf = buf,
            tick = require("sia.tracker").ensure_tracked(buf, { id = conversation.id }),
            kind = "context",
            mode = "v",
          })
        end
      end
    end,
  },
  context = {
    require_range = true,
    only_visible = true,
    execute_global = function(args)
      local context = require("sia.utils").create_context(args)
      require("sia.conversation").Conversation.add_pending_instruction(
        "current_context",
        context
      )
    end,
    execute_local = function(args, conversation)
      local context = require("sia.utils").create_context(args)
      conversation:add_instruction("current_context", context)
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
          conversation:add_instruction("current_context", {
            buf = buf,
            tick = require("sia.tracker").ensure_tracked(buf, { id = conversation.id }),
            mode = "v",
          })
        end
      end
    end,
    execute_global = function(args)
      for _, bufname in ipairs(args.fargs) do
        local buf = vim.fn.bufnr(bufname)
        if buf ~= -1 then
          require("sia.conversation").Conversation.add_pending_instruction(
            "current_context",
            { buf = buf, tick = require("sia.tracker").ensure_tracked(buf), mode = "v" }
          )
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
    for _, msg in ipairs(chat.conversation.messages) do
      if msg.turn_id and not seen[msg.turn_id] and msg.status ~= "dropped" then
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

      local parsed = SIA_PARSER:parse(args_before)

      local flag_completions = SIA_PARSER:complete_flag(parsed, prefix, {
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

    local proc = chat.conversation:get_bash_process(id)
    if not proc then
      vim.notify(string.format("sia: no process with ID %d", id), vim.log.levels.ERROR)
      return
    end

    if proc.status ~= "running" then
      return
    end

    if proc.detached_handle then
      proc.detached_handle.kill()
    else
      vim.notify(
        string.format("sia: process %d is synchronous and cannot be stopped", id),
        vim.log.levels.WARN
      )
    end
  elseif subcommand == "list" or subcommand == nil then
    local procs = chat.conversation.bash_processes
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
      })[proc.status] or "?"

      local elapsed
      if proc.completed_at then
        elapsed = string.format("%.1fs", proc.completed_at - proc.started_at)
      else
        elapsed =
          string.format("%.1fs (running)", (vim.uv.hrtime() / 1e9) - proc.started_at)
      end

      table.insert(
        lines,
        string.format(
          "  %s [%d] %s (%s) %s",
          status_icon,
          proc.id,
          proc.command,
          elapsed,
          proc.status
        )
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
        for _, proc in ipairs(chat.conversation.bash_processes) do
          if proc.status == "running" then
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

  if subcommand == "complete" then
    local chat = require("sia.strategy").get_chat()
    if not chat then
      return
    end

    if require("sia.agents").complete(chat.conversation) then
      local win = vim.fn.bufwinid(chat.buf)
      if win ~= -1 then
        vim.api.nvim_win_close(win, false)
      end
      vim.api.nvim_buf_delete(chat.buf, {})
    end
    return
  end

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
    local agent = require("sia.agents").spawn(agent_name, task, chat.conversation, {
      on_complete = function(agent)
        if chat:buf_is_loaded() then
          local status_msg
          if agent.status == "completed" then
            status_msg = {
              message = string.format("%s %s completed", icons.success, agent.name),
              status = "info",
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

    require("sia.agents").open(chat.conversation, id)
  elseif subcommand == "cancel" then
    local id = tonumber(args.fargs[2])
    if not id then
      return
    end

    local agent = chat.conversation:get_agent(id)
    if not agent then
      return
    end

    if agent.status == "completed" then
      agent.status = "cancelled"
    elseif agent.status == "running" then
      agent:cancel()
      agent.status = "cancelled"
    end
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
      local registry = require("sia.agents.registry")
      local agents = registry.get_agents(false)
      local names = vim.tbl_keys(agents)
      table.sort(names)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, arg_lead)
      end, names)
    end

    if prefix:match("SiaAgent%s+open%s") then
      local chat = require("sia.strategy").get_chat()
      if chat and chat.conversation then
        local ids = {}
        for _, agent in ipairs(chat.conversation.agents) do
          if agent:can_open() then
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
        for _, agent in ipairs(chat.conversation.agents) do
          if agent.status == "running" or agent.status == "completed" then
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

--- @type table<string, { authorize: fun(callback: fun(data: any?)?), label: string }>
local SIA_AUTH_PROVIDERS = {
  codex = {
    label = "Codex",
    authorize = function(callback)
      require("sia.provider.codex").authorize(function(token_data)
        if token_data then
          vim.notify("sia: ready to use codex/ models", vim.log.levels.INFO)
        else
          vim.notify("sia: codex authorization failed", vim.log.levels.ERROR)
        end
        if callback then
          callback(token_data)
        end
      end)
    end,
  },
  copilot = {
    label = "Copilot",
    authorize = function(callback)
      require("sia.provider.copilot").authorize(function(token_data)
        if token_data then
          vim.notify("sia: ready to use copilot/ models", vim.log.levels.INFO)
        else
          vim.notify("sia: copilot authorization failed", vim.log.levels.ERROR)
        end
        if callback then
          callback(token_data)
        end
      end)
    end,
  },
}

vim.api.nvim_create_user_command("SiaAuth", function(args)
  local provider_name = args.fargs[1]
  if not provider_name then
    vim.notify("sia: provider name required", vim.log.levels.ERROR)
    return
  end

  local provider = SIA_AUTH_PROVIDERS[provider_name]
  if not provider then
    vim.notify(
      string.format(
        "sia: unknown provider '%s'. available: %s",
        provider_name,
        table.concat(vim.tbl_keys(SIA_AUTH_PROVIDERS), ", ")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  provider.authorize()
end, {
  nargs = 1,
  complete = function(arg_lead)
    local completions = {}
    for name, _ in pairs(SIA_AUTH_PROVIDERS) do
      if vim.startswith(name, arg_lead) then
        table.insert(completions, name)
      end
    end
    return completions
  end,
})
