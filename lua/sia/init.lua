local config = require("sia.config")
local utils = require("sia.utils")
local Conversation = require("sia.conversation").Conversation
local ChatStrategy = require("sia.strategy").ChatStrategy
local DiffStrategy = require("sia.strategy").DiffStrategy
local InsertStrategy = require("sia.strategy").InsertStrategy
local HiddenStrategy = require("sia.strategy").HiddenStrategy

local M = {}

local highlight_groups = {
  SiaChatResponse = { link = "CursorLine" },
  SiaInsert = { link = "DiffAdd" },
  SiaReplace = { link = "DiffChange" },
  SiaProgress = { link = "NonText" },
  SiaModel = { link = "NonText" },
  SiaAssistant = { link = "DiffAdd" },
  SiaUser = { link = "DiffChange" },
}

local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

--- @param opts { buf: integer? }?
function M.accept_edits(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not require("sia.diff").accept_diff(buf) then
    vim.api.nvim_echo({ { "Sia: No changes to accept", "WarningMsg" } }, false, {})
  end
end

--- @param opts { buf: integer? }?
function M.reject_edits(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not require("sia.diff").reject_diff(buf) then
    vim.api.nvim_echo({ { "Sia: No changes to reject", "WarningMsg" } }, false, {})
  end
end

--- @param opts { buf: integer? }?
function M.show_edits_diff(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local diff = require("sia.diff")

  if not diff.show_diff_for_buffer(buf) then
    vim.api.nvim_echo({ { "Sia: No changes to show", "WarningMsg" } }, false, {})
  end
end

--- Navigate to the next diff hunk
--- @param opts { buf: integer? }?
function M.next_edit(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  local diff = require("sia.diff")
  local hunk_info = diff.get_next_hunk(buf, current_line)

  if hunk_info then
    local line_count = vim.api.nvim_buf_line_count(buf)
    if hunk_info.line > 0 and hunk_info.line <= line_count then
      vim.api.nvim_win_set_cursor(0, { hunk_info.line, 0 })
      local total_hunks = diff.get_hunk_count(buf)
      vim.api.nvim_echo({ { string.format("Edit %d of %d", hunk_info.index, total_hunks), "Normal" } }, false, {})
    end
  end
end

--- Navigate to the previous diff hunk
--- @param opts { buf: integer? }?
function M.prev_edit(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  local diff = require("sia.diff")
  local hunk_info = diff.get_prev_hunk(buf, current_line)

  if hunk_info then
    local line_count = vim.api.nvim_buf_line_count(buf)
    if hunk_info.line > 0 and hunk_info.line <= line_count then
      vim.api.nvim_win_set_cursor(0, { hunk_info.line, 0 })
      local total_hunks = diff.get_hunk_count(buf)
      vim.api.nvim_echo({ { string.format("Edit %d of %d", hunk_info.index, total_hunks), "Normal" } }, false, {})
    end
  end
end

--- Populate quickfix list with all diff hunks
--- @param opts { buf: integer? }?
function M.show_edits_qf(opts)
  opts = opts or {}
  local buf = opts.buf
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end

  local diff = require("sia.diff")
  local quickfix_items = diff.get_all_hunks_for_quickfix(buf)

  if #quickfix_items == 0 then
    vim.api.nvim_echo({ { "Sia: No changes to show", "WarningMsg" } }, false, {})
    return
  end

  vim.fn.setqflist(quickfix_items, "r")
  vim.cmd("copen")
end

function M.remove_message()
  local chat = ChatStrategy.by_buf()
  if chat then
    local contexts, mappings = chat.conversation:get_messages({ mapping = true })
    if #contexts == 0 then
      vim.notify("Sia: No messages in current conversation.")
      return
    end
    vim.ui.select(contexts, {
      prompt = "Delete message",
      format_item = function(item)
        return item:get_description()
      end,
      --- @param idx integer?
    }, function(_, idx)
      if idx and mappings then
        chat.conversation:remove_instruction(mappings[idx])
        chat:redraw()
      end
    end)
  end
end

--- @param opts table?
function M.show_messages(opts)
  opts = opts or {}
  local chat = ChatStrategy.by_buf()
  if chat then
    local contexts, mappings = chat.conversation:get_messages({ mapping = true })
    if #contexts == 0 then
      vim.notify("Sia: No messages in the current conversation.")
      return
    end
    vim.ui.select(contexts, {
      prompt = "Show message",
      --- @param message sia.Message
      format_item = function(message)
        local outdated = message:is_outdated()
        local description = message:get_description()
        if outdated then
          return "[outdated] " .. description
        else
          return description
        end
      end,
      --- @param item sia.Message?
      --- @param idx integer
    }, function(item, idx)
      if item and mappings then
        local content
        if item.tool_calls then
          content = vim.inspect(item.tool_calls)
        else
          content = item:get_content()
        end

        if content then
          local buf_name = chat.name .. " " .. item:get_description()
          local buf = vim.fn.bufnr(buf_name)
          if buf == -1 then
            buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].ft = "markdown"
            -- vim.bo[buf].modifiable = false
            vim.api.nvim_buf_set_name(buf, buf_name)
          end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { trimempty = true }))
          local win
          if opts.peek then
            win = vim.api.nvim_open_win(buf, true, {
              relative = "win",
              focusable = true,
              style = "minimal",
              anchor = "SW",
              row = vim.o.lines,
              col = 0,
              width = vim.api.nvim_win_get_width(0) - 1,
              height = math.floor(vim.o.lines * 0.2),
              border = "single",
              title = buf_name,
              title_pos = "center",
            })
            vim.wo[win].wrap = true
            vim.keymap.set("n", opts.close_key or "q", function()
              vim.api.nvim_win_close(win, true)
            end, { buffer = buf })
          else
            vim.bo[buf].buftype = "acwrite"
            vim.bo[buf].modified = false
            vim.api.nvim_win_set_buf(0, buf)
            -- if opts.edit then
            --   vim.bo[buf].modifiable = chat.conversation:is_instruction_editable(mappings[idx])
            --   vim.api.nvim_create_autocmd("BufWriteCmd", {
            --     buffer = buf,
            --     callback = function()
            --       local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            --       local updated = chat.conversation:update_instruction(mappings[idx], lines)
            --       if updated then
            --         vim.api.nvim_echo({ { "Instruction updated...", "Normal" } }, false, {})
            --       end
            --       vim.bo[buf].modified = false
            --       chat:redraw()
            --     end,
            --   })
            -- end
          end
        end
      end
    end)
  end
end

function M.toggle()
  local last = ChatStrategy.last()
  if last and vim.api.nvim_buf_is_valid(last.buf) then
    local win = vim.fn.bufwinid(last.buf)
    if win ~= -1 and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    else
      vim.cmd(last.options.cmd)
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, last.buf)
    end
  end
end

function M.open_reply()
  local buf = vim.api.nvim_get_current_buf()
  local current = ChatStrategy.by_buf(buf)
  if current then
    vim.cmd("new")
    buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].ft = "markdown"
    vim.api.nvim_buf_set_name(buf, "*sia reply*" .. current.name)
    vim.api.nvim_win_set_height(win, 10)

    vim.keymap.set("n", "<CR>", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      --- @type sia.config.Instruction
      local instruction = {
        role = "user",
        content = lines,
      }
      current.conversation:add_instruction(instruction, nil)
      require("sia.assistant").execute_strategy(current)
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf })
    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf })
  end
end

--- @class sia.AddCommand
--- @field completion (fun(s:string):string[])?
--- @field execute_local fun(args: vim.api.keyset.create_user_command.command_args, c: sia.Conversation):nil
--- @field execute_global (fun(args: vim.api.keyset.create_user_command.command_args):nil)?
--- @field require_range boolean
--- @field only_visible boolean?
--- @field non_sia_buf boolean?

--- @type table<string, sia.AddCommand>
local add_commands = {
  file = {
    only_visible = true,
    require_range = false,
    completion = function(lead)
      return vim.fn.getcompletion(lead, "file")
    end,
    execute_global = function(args)
      local fargs = args.fargs
      if args.bang then
        -- Conversation.clear_pending_files()
      end
      local files = utils.glob_pattern_to_files(fargs)
      -- Conversation.add_pending_instruction("current_context", {
    end,
    execute_local = function(args, conversation)
      local fargs = args.fargs
      if args.bang then
        -- conversation.files = {}
      end
      local files = utils.glob_pattern_to_files(fargs)

      -- conversation:add_files(files)
    end,
  },
  context = {
    require_range = true,
    only_visible = true,
    execute_global = function(args)
      local context = utils.create_context(args)
      Conversation.add_pending_instruction("current_context", context)
    end,
    execute_local = function(args, conversation)
      local context = utils.create_context(args)
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
        Conversation.add_pending_tool(tool)
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
          conversation:add_instruction("current_context", { buf = buf, pos = { 0, 0 }, file = true })
        end
      end
    end,
    execute_global = function(args)
      for _, bufname in ipairs(args.fargs) do
        local buf = vim.fn.bufnr(bufname)
        if buf ~= -1 then
          Conversation.add_pending_instruction("current_context", { buf = buf, pos = { 0, 0 }, file = true })
        end
      end
    end,
  },
  symbols = {
    require_range = false,
    non_sia_buf = true,
    execute_global = function(args)
      Conversation.add_pending_instruction("current_document_symbols", utils.create_context(args))
    end,
    execute_local = function(args, conversation)
      conversation:add_instruction("current_document_symbols", utils.create_context(args))
    end,
  },
}

function M.setup(options)
  config.setup(options)
  require("sia.mappings").setup()

  vim.api.nvim_create_user_command("SiaAccept", function()
    M.accept_edits()
  end, {})

  vim.api.nvim_create_user_command("SiaReject", function()
    M.reject_edits()
  end, {})

  vim.api.nvim_create_user_command("SiaDiff", function()
    M.show_edits_diff()
  end, {})

  vim.api.nvim_create_user_command("SiaAdd", function(args)
    local cmd_name = table.remove(args.fargs, 1)
    local command = add_commands[cmd_name]
    if command then
      if command.non_sia_buf and vim.bo.ft == "sia" then
        vim.notify("Sia: Not a valid context")
        return
      end

      utils.with_chat_strategy({
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
      local is_range = utils.is_range_commend(line)
      local complete = {}

      if string.sub(line, 1, pos):match("SiaAdd%s%w*$") then
        for command, command_args in pairs(add_commands) do
          local non_sia_buf = command_args.non_sia_buf == nil or (command_args.non_sia_buf and vim.bo.ft ~= "sia")
          if non_sia_buf and vim.startswith(command, arg_lead) and command_args.require_range == is_range then
            complete[#complete + 1] = command
          end
        end
      else
        local command = add_commands[string.sub(line, 1, pos):match("SiaAdd%s+(%w*)")]
        if command and command.completion then
          for _, subcmd in ipairs(command.completion(arg_lead)) do
            complete[#complete + 1] = subcmd
          end
        end
      end
      return complete
    end,
  })

  vim.api.nvim_create_user_command("SiaRemove", function(args)
    local chat = ChatStrategy.by_buf()
    if chat then
      chat.conversation:remove_files(args.fargs)
    else
      Conversation.remove_global_files(args.fargs)
    end
  end, {
    nargs = "+",
    complete = function(arg_lead)
      local chat = ChatStrategy.by_buf()
      local files = {}
      if chat then
        files = chat.conversation.files
      else
        files = Conversation.pending_files
      end
      local matches = {}
      for _, file in ipairs(files) do
        if vim.fn.match(file.path, "^" .. vim.fn.escape(arg_lead, "\\")) >= 0 then
          table.insert(matches, file)
        end
      end
      return matches
    end,
  })

  local running_jobs = {}

  vim.api.nvim_create_user_command("SiaAbort", function()
    for _, job in ipairs(running_jobs) do
      vim.fn.jobstop(job)
    end
    running_jobs = {}
    vim.api.nvim_echo({ { "Sia: Aborted all running jobs", "Normal" } }, false, {})
  end, {})

  --- Compact a conversation by summarizing previous messages
  --- @param conversation table The conversation object to compact
  --- @param reason string? Optional reason for compacting (used in summary message)
  --- @param callback function? Optional callback to execute after compacting
  M.compact_conversation = function(conversation, reason, callback)
    local prompt = {
      {
        role = "system",
        content = [[You are tasked with compacting a conversation by creating a comprehensive summary that preserves all essential information for continuing the conversation.

CRITICAL REQUIREMENTS:
1. Preserve ALL technical details: file paths, function names, class names, variable names, configuration settings
2. Maintain the chronological order of decisions and changes made
3. Include specific code snippets or patterns that were discussed or implemented
4. Preserve any architectural decisions, design patterns, or coding standards established
5. Keep track of any bugs identified, solutions attempted, and their outcomes
6. Maintain context about the codebase structure and relationships between components

SUMMARY STRUCTURE:
- **Project Context**: Brief description of the project and its purpose
- **Files Modified**: List all files that were created, modified, or discussed with specific changes
- **Key Decisions**: Important architectural, design, or implementation decisions made
- **Code Changes**: Specific functions, classes, or code blocks that were added/modified
- **Outstanding Issues**: Any unresolved problems, TODOs, or areas needing attention
- **Technical Details**: Configuration changes, dependencies, or environment setup

OUTPUT FORMAT:
Write a clear, structured summary using markdown formatting. Be concise but comprehensive - the summary should allow someone to understand the full context and continue working on the project without losing important details.

The summary will replace the conversation history, so ensure no critical information is lost.]],
      },
    }

    for _, message in ipairs(conversation:get_messages({ kind = "user" })) do
      table.insert(prompt, message:to_prompt())
    end

    require("sia.assistant").execute_query({
      prompt = prompt,
    }, function(content)
      if content then
        conversation:clear_user_instructions()

        local summary_content
        if reason then
          summary_content = string.format(
            "This is a summary of the previous conversation which has been compacted due to topic change (%s):\n\n%s",
            reason,
            content
          )
        else
          summary_content = string.format("This is a summary of the conversation which has been removed:\n %s", content)
        end

        conversation:add_instruction({
          role = "user",
          content = summary_content,
        })

        if callback then
          callback(content)
        end
      elseif callback then
        callback(nil)
      end
    end)
  end

  vim.api.nvim_create_user_command("SiaCompact", function()
    local chat = ChatStrategy.by_buf()

    if chat then
      chat.is_busy = true
      chat.canvas:update_progress({ { "Compacting conversation...", "WarningMsg" } })
      M.compact_conversation(chat.conversation, "Requested by user", function(_)
        chat.is_busy = false
        chat:redraw()
      end)
    else
      -- echo that not called from a chat
    end
  end, {})

  vim.treesitter.language.register("markdown", "sia")

  local augroup = vim.api.nvim_create_augroup("SiaGroup", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaError",
    callback = function(args)
      local data = args.data
      print(vim.inspect(data))
      if data.message then
        if type(data.message) == "string" then
          vim.notify("Sia: " .. data.message, vim.log.levels.WARN)
        elseif data.message.error and type(data.message.error) == "string" then
          vim.notify("Sia: " .. data.message.error, vim.log.levels.WARN)
        end
      else
        vim.notify("Sia: unknown error", vim.log.levels.WARN)
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      set_highlight_groups()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "SiaStart",
    callback = function(args)
      table.insert(running_jobs, args.data.job)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "SiaComplete",
    callback = function(args)
      local job = args.data.job
      for i, j in ipairs(running_jobs) do
        if j == job then
          table.remove(running_jobs, i)
          break
        end
      end
    end,
  })

  if config.options.report_usage == true then
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = "SiaUsageReport",
      callback = function(args)
        local data = args.data
        if data and data.usage then
          local usage = data.usage
          local model = data.model
          if not (usage.completion_tokens or usage.prompt_tokens) and usage.total_tokens then
            local prompt = { { "" .. usage.total_tokens, "NonText" } }
            if model then
              table.insert(prompt, 1, { model.name, "Comment" })
            end
            vim.api.nvim_echo(prompt, false, {})
          elseif usage.completion_tokens and usage.prompt_tokens then
            local prompt = {
              { " " .. usage.prompt_tokens, "NonText" },
              { "/", "NonText" },
              { "" .. usage.completion_tokens, "NonText" },
            }
            if model then
              if model.cost then
                local total_cost = usage.completion_tokens * model.cost.completion_tokens
                  + usage.prompt_tokens * model.cost.prompt_tokens
                if total_cost < 0.1 then
                  total_cost = "<0.1"
                else
                  total_cost = string.format("%.2f", total_cost)
                end

                table.insert(prompt, {
                  string.format(" ($%s)", total_cost),
                  "NonText",
                })
              end
              table.insert(prompt, 1, { model.name, "Comment" })
            end
            vim.api.nvim_echo(prompt, false, {})
          end
        end
      end,
    })
  end
end

--- @param action sia.config.Action
--- @param opts sia.ActionContext
--- @param model string?
function M.main(action, opts, model)
  if vim.api.nvim_buf_is_loaded(opts.buf) then
    local strategy
    local visible = ChatStrategy.visible()
    if action.mode == "chat" and (vim.bo[opts.buf].filetype == "sia" or #visible == 1) then
      if #visible == 1 then
        strategy = ChatStrategy.by_buf(visible[1].buf)
      else
        strategy = ChatStrategy.by_buf(opts.buf)
      end

      if strategy and not strategy.is_busy then
        for _, tool in ipairs(action.tools or {}) do
          strategy.conversation:add_tool(tool)
        end

        if vim.bo[opts.buf].filetype ~= "sia" then
          for _, instruction in ipairs(action.instructions or {}) do
            strategy.conversation:add_instruction(instruction, opts)
          end
        else
          local last_instruction = action.instructions[#action.instructions] --[[@as sia.config.Instruction ]]
          strategy.conversation:add_instruction(last_instruction, nil)
        end

        -- The user might have explicitly changed the model with -m
        if model then
          strategy.conversation.model = model
        end
      end
    else
      if model then
        action.model = model
      end
      local conversation = Conversation:new(action, opts)
      if conversation.mode == "diff" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.diff, action.diff or {})
        strategy = DiffStrategy:new(conversation, options)
      elseif conversation.mode == "insert" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.insert, action.insert or {})
        strategy = InsertStrategy:new(conversation, options)
      elseif conversation.mode == "hidden" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.hidden, action.hidden or {})
        if not options.callback then
          vim.notify("Sia: Hidden strategy requires a callback function", vim.log.levels.ERROR)
          return
        end
        strategy = HiddenStrategy:new(conversation, options)
      else
        local options = vim.tbl_deep_extend("force", config.options.defaults.chat, action.chat or {})
        strategy = ChatStrategy:new(conversation, options)
      end
    end

    --- @cast strategy sia.Strategy
    require("sia.assistant").execute_strategy(strategy)
  end
end

return M
