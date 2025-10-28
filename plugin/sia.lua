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
      vim.api.nvim_echo(
        { { "Sia: Unable to capture current context.", "ErrorMsg" } },
        false,
        {}
      )
      return
    end
    context.start_line, context.end_line = capture[1], capture[2]
    context.pos = { capture[1], capture[2] }
    context.mode = "v"
  end

  if action.range == true and context.mode ~= "v" then
    vim.api.nvim_echo({
      {
        "Sia: The action " .. args.fargs[1] .. " must be used with a range",
        "ErrorMsg",
      },
    }, false, {})
    return
  end

  local is_range = context.mode == "v"
  local is_range_valid = action.range == nil or action.range == is_range
  if utils.is_action_disabled(action) or not is_range_valid then
    vim.api.nvim_echo({
      {
        "Sia: The action "
          .. args.fargs[1]
          .. " is not enabled in the current context.",
        "ErrorMsg",
      },
    }, false, {})
    return
  end

  require("sia").execute_action(action, {
    context = context,
    model = model,
    named_prompt = named,
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

    local match = string.match(string.sub(CmdLine, 1, CursorPos), "-m ([%w-_/.]*)$")
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
  if not chat or not chat.conversation or not chat.conversation.prepare_messages then
    vim.notify("SiaDebug: No active Sia chat in this buffer.", vim.log.levels.WARN)
    return
  end
  local ok, result = pcall(chat.conversation.prepare_messages, chat.conversation)
  if not ok then
    vim.notify(
      "SiaDebug: Error generating conversation query: " .. tostring(result),
      vim.log.levels.ERROR
    )
    return
  end

  local provider = require("sia.provider.openai").completion
  local data = {}
  provider.prepare_messages(data, "", result)
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
            tick = require("sia.tracker").ensure_tracked(buf),
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
  tool = {
    require_range = false,
    completion = function(lead)
      local tools = require("sia.config").options.defaults.tools.choices or {}
      local completion = {}
      for name, _ in pairs(tools) do
        if vim.startswith(name, lead) then
          table.insert(completion, name)
        end
      end
      return completion
    end,
    execute_global = function(args)
      for _, tool in ipairs(args.fargs) do
        require("sia.conversation").Conversation.add_pending_tool(tool)
      end
    end,
    execute_local = function(args, conversation)
      for _, tool in ipairs(args.fargs) do
        conversation:add_tool(tool)
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
          conversation:add_instruction(
            "current_context",
            { buf = buf, tick = require("sia.tracker").ensure_tracked(buf), mode = "v" }
          )
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
    require("sia").accept_edits()
  else
    require("sia").accept_edit()
  end
end, { bang = true })

vim.api.nvim_create_user_command("SiaReject", function(args)
  if args.bang then
    require("sia").reject_edits()
  else
    require("sia").reject_edit()
  end
end, { bang = true })

vim.api.nvim_create_user_command("SiaDiff", function()
  require("sia").show_edits_diff()
end, {})

vim.api.nvim_create_user_command("SiaAnswer", function(args)
  local command = args.fargs[1]
  local approval = require("sia.approval")
  if command == "prompt" then
    approval.prompt({ first = args.bang })
  elseif command == "accept" then
    approval.accept({ first = args.bang })
  elseif command == "decline" then
    approval.decline({ first = args.bang })
  elseif command == "preview" then
    approval.preview({ first = args.bang })
  end
end, { nargs = 1, bang = true })

vim.api.nvim_create_user_command("SiaAdd", function(args)
  local cmd_name = table.remove(args.fargs, 1)
  local command = SIA_ADD_CMD[cmd_name]
  if command then
    if command.non_sia_buf and vim.bo.ft == "sia" then
      vim.notify("Sia: Not a valid context")
      return
    end

    require("sia.utils").with_chat_strategy({
      on_select = function(chat)
        command.execute_local(args, chat.conversation)
      end,
      on_none = function()
        if command.execute_global then
          command.execute_global(args)
        else
          vim.notify("No *sia* buffer")
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

vim.api.nvim_create_user_command("SiaCompact", function()
  local chat = require("sia.strategy").ChatStrategy.by_buf()

  if chat then
    chat.is_busy = true
    chat.canvas:update_progress({ { "Compacting conversation...", "WarningMsg" } })
    require("sia").compact_conversation(
      chat.conversation,
      "Requested by user",
      function(_)
        chat.is_busy = false
        chat:redraw()
      end
    )
  end
end, {})
