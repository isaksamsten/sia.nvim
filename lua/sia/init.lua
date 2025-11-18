local M = {}

local highlight_groups = {
  SiaInsert = { link = "DiffAdd" },
  SiaInsertPostProcess = { link = "DiffChange" },
  SiaReplace = { link = "DiffChange" },
  SiaProgress = { link = "NonText" },
  SiaModel = {},
  SiaUsage = {},
  SiaAssistant = { link = "DiffAdd" },
  SiaUser = { link = "DiffChange" },
  SiaApproveInfo = { link = "StatusLine" },
  SiaApproveSafe = { link = "StatusLine" },
  SiaApproveWarn = { link = "StatusLine" },
  SiaToolResult = { link = "DiffChange" },
  SiaDiffDelete = { link = "DiffDelete" },
  SiaDiffChange = { link = "DiffChange" },
  SiaDiffAdd = { link = "DiffAdd" },
  SiaDiffInlineChange = { link = "GitSignsChangeInline" },
  SiaDiffInlineAdd = { link = "GitSignsAddInline" },
  SiaDiffAddSign = { link = "GitSignsAdd" },
  SiaDiffChangeSign = { link = "GitSignsChange" },
  SiaTodoActive = { link = "DiagnosticWarn" },
  SiaTodoPending = { link = "Comment" },
  SiaTodoDone = { link = "DiagnosticOk" },
  SiaTodoSkipped = { link = "NonText" },
}

local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

function M.reject_edit(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local win = vim.fn.bufwinid(buf)
  local line = opts.line or vim.api.nvim_win_get_cursor(win)[1]

  local hunk_idx = require("sia.diff").get_hunk_at_line(buf, line)
  if hunk_idx then
    require("sia.diff").reject_single_hunk(buf, hunk_idx)
  end
end

function M.accept_edit(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local win = vim.fn.bufwinid(buf)
  local line = opts.line or vim.api.nvim_win_get_cursor(win)[1]

  local hunk_idx = require("sia.diff").get_hunk_at_line(buf, line)
  if hunk_idx then
    require("sia.diff").accept_single_hunk(buf, hunk_idx)
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
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { hunk_info.line, 0 })
      local total_hunks = diff.get_hunk_count(buf)
      vim.api.nvim_echo(
        { { string.format("Edit %d of %d", hunk_info.index, total_hunks), "None" } },
        false,
        {}
      )
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
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { hunk_info.line, 0 })
      local total_hunks = diff.get_hunk_count(buf)
      vim.api.nvim_echo(
        { { string.format("Edit %d of %d", hunk_info.index, total_hunks), "None" } },
        false,
        {}
      )
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

--- @param opts table?
function M.show_messages(opts)
  opts = opts or {}
  local chat = require("sia.strategy").ChatStrategy.by_buf()
  if chat then
    local messages = chat.conversation:get_messages()
    if #messages == 0 then
      vim.notify("Sia: No messages in the current conversation.")
      return
    end
    vim.ui.select(messages, {
      prompt = "Show message",
      --- @param message sia.PreparedMessage
      format_item = function(message)
        local outdated = message.outdated
        local description = message.description
        local empty = message.content
        if outdated then
          return "[outdated] " .. description
        elseif empty == nil and message.role == "user" then
          return "[empty] " .. description
        else
          return description
        end
      end,
      --- @param item sia.PreparedMessage?
    }, function(item, _)
      if item then
        local content
        if item.tool_calls then
          content = vim.inspect(item.tool_calls)
        else
          content = item.content
        end

        if content then
          local buf_name = chat.conversation.name .. " " .. item.description
          local buf = vim.fn.bufnr(buf_name)
          if buf == -1 then
            buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].ft = "markdown"
            vim.api.nvim_buf_set_name(buf, buf_name)
          end
          vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            vim.split(content, "\n", { trimempty = true })
          )
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
          end
        end
      end
    end)
  end
end

function M.toggle()
  local last = require("sia.strategy").ChatStrategy.last()
  if last and vim.api.nvim_buf_is_valid(last.buf) then
    local win = vim.fn.bufwinid(last.buf)
    if
      win ~= -1
      and vim.api.nvim_win_is_valid(win)
      and #vim.api.nvim_list_wins() > 1
    then
      vim.api.nvim_win_close(win, true)
    else
      vim.cmd(last.options.cmd)
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, last.buf)
    end
  end
end

--- @type table<integer, integer>
M._todos_windows = {}

--- Manage todos window for the current chat
--- @param action? string "open" | "close" | "toggle" (default: "toggle")
function M.todos(action)
  action = action or "toggle"

  local buf = vim.api.nvim_get_current_buf()
  local chat = require("sia.strategy").ChatStrategy.by_buf(buf)

  if not chat then
    return
  end

  local todos_buf = chat.conversation.todos and chat.conversation.todos.buf
  local existing_win = M._todos_windows[chat.buf]
  local is_open = existing_win and vim.api.nvim_win_is_valid(existing_win)

  if action == "close" then
    if is_open then
      vim.api.nvim_win_close(existing_win, true)
      M._todos_windows[chat.buf] = nil
    end
    return
  end

  if action == "toggle" then
    if is_open then
      vim.api.nvim_win_close(existing_win, true)
      M._todos_windows[chat.buf] = nil
      return
    end
  end

  if not todos_buf or not vim.api.nvim_buf_is_valid(todos_buf) then
    if action == "open" then
      if not chat.conversation.todos or #chat.conversation.todos.items == 0 then
        return
      end
    end
    return
  end

  local chat_win = vim.fn.bufwinid(chat.buf)
  if chat_win == -1 then
    return
  end

  local chat_width = vim.api.nvim_win_get_width(chat_win)
  local screen_width = vim.o.columns
  local is_full_width = chat_width >= (screen_width - 2)

  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(chat_win)

  local todos_win
  if is_full_width then
    vim.cmd("vertical topleft split")
    if is_open then
      todos_win = existing_win
    else
      todos_win = vim.api.nvim_get_current_win()
    end
    local width = math.floor(screen_width * 0.2)
    vim.api.nvim_win_set_width(todos_win, width)
  else
    if is_open then
      todos_win = existing_win
    else
      vim.cmd("belowright split")
      todos_win = vim.api.nvim_get_current_win()
    end
    local max_height = math.floor(vim.o.lines * 0.2)
    vim.api.nvim_win_set_height(
      todos_win,
      math.min(vim.api.nvim_buf_line_count(todos_buf), max_height)
    )
  end

  vim.api.nvim_win_set_buf(todos_win, todos_buf)

  vim.wo[todos_win].wrap = true
  vim.wo[todos_win].number = false
  vim.wo[todos_win].relativenumber = false
  vim.wo[todos_win].signcolumn = "no"

  M._todos_windows[chat.buf] = todos_win

  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  vim.api.nvim_create_autocmd(
    { "BufDelete", "BufWipeout", "WinClosed", "BufWinLeave" },
    {
      buffer = chat.buf,
      callback = function(ev)
        local win = M._todos_windows[chat.buf]
        if ev.event == "WinClosed" then
          local closed_win = tonumber(ev.match)
          if closed_win == chat_win then
            if win and vim.api.nvim_win_is_valid(M._todos_windows[chat.buf]) then
              vim.api.nvim_win_close(win, true)
            end
            M._todos_windows[chat.buf] = nil
          end
        else
          if win and vim.api.nvim_win_is_valid(M._todos_windows[chat.buf]) then
            vim.api.nvim_win_close(win, true)
          end
          M._todos_windows[chat.buf] = nil
        end
      end,
    }
  )
end

--- Show contexts in quickfix list
function M.show_contexts()
  local chat = require("sia.strategy").ChatStrategy.by_buf()
  if not chat then
    return
  end

  local contexts = chat.conversation:get_contexts()
  if #contexts == 0 then
    vim.notify("No contexts available", vim.log.levels.INFO)
    return
  end

  local qf_items = {}
  for _, ctx in ipairs(contexts) do
    table.insert(qf_items, {
      bufnr = ctx.buf,
      lnum = ctx.pos and ctx.pos[1] or 1,
      end_lnum = ctx.pos and ctx.pos[2] or nil,
      col = 1,
      type = "I",
    })
  end

  vim.fn.setqflist(qf_items, "r")
  vim.cmd("copen")
end

function M.open_reply()
  local buf = vim.api.nvim_get_current_buf()
  local current = require("sia.strategy").ChatStrategy.by_buf(buf)
  if current then
    vim.cmd("new")
    buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].ft = "markdown"
    vim.api.nvim_buf_set_name(buf, "*sia reply*" .. current.conversation.name)
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

--- Compact a conversation by summarizing previous messages
--- @param conversation sia.Conversation The conversation object to compact
--- @param reason string? Optional reason for compacting (used in summary message)
--- @param callback function? Optional callback to execute after compacting
M.compact_conversation = function(conversation, reason, callback)
  local Message = require("sia.conversation").Message
  local messages = {
    Message:from_table({
      role = "system",
      content = [[You are tasked with compacting a conversation by creating a
comprehensive summary that preserves all essential information for
continuing the conversation.

CRITICAL REQUIREMENTS:
1. Preserve ALL technical details: file paths, function names, class names,
   variable names, configuration settings
2. Maintain the chronological order of decisions and changes made
3. Include specific code snippets or patterns that were discussed or implemented
4. Preserve any architectural decisions, design patterns, or coding standards established
5. Keep track of any bugs identified, solutions attempted, and their outcomes
6. Maintain context about the codebase structure and relationships between components

SUMMARY STRUCTURE:
- **Project Context**: Brief description of the project and its purpose
- **Files Modified**: List all files that were created, modified, or discussed
  with specific changes
- **Key Decisions**: Important architectural, design, or implementation
  decisions made
- **Code Changes**: Specific functions, classes, or code blocks that were added/modified
- **Outstanding Issues**: Any unresolved problems, TODOs, or areas needing attention
- **Technical Details**: Configuration changes, dependencies, or environment setup

OUTPUT FORMAT:
Write a clear, structured summary using markdown formatting. Be concise but
comprehensive - the summary should allow someone to understand the full context
and continue working on the project without losing important details.

The summary will replace the conversation history, so ensure no critical
information is lost.]],
    }),
  }

  for _, message in ipairs(conversation:get_messages()) do
    table.insert(messages, message)
  end

  require("sia.assistant").execute_query(messages, {
    model = require("sia.config").get_default_model("fast_model"),
    callback = function(content)
      if content then
        conversation:clear_user_instructions()

        local summary_content
        if reason then
          summary_content = string.format(
            "This is a summary of a previous conversation (%s):\n\n%s",
            reason,
            content
          )
        else
          summary_content = string.format(
            "This is a summary of the conversation which has been removed:\n %s",
            content
          )
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
    end,
  })
end

function M.setup(options)
  local config = require("sia.config")
  config.setup(options)
  require("sia.mappings").setup()

  if config.options.defaults.ui.diff.enable then
    require("sia.diff").setup()
  end

  set_highlight_groups()

  vim.treesitter.language.register("markdown", "sia")

  local augroup = vim.api.nvim_create_augroup("SiaGroup", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaError",
    callback = function(args)
      local data = args.data
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
end

--- @param action sia.config.Action
--- @param opts {context: sia.ActionContext, model: string?, named_prompt: boolean?}
function M.execute_action(action, opts)
  local config = require("sia.config")
  local context = opts.context
  if vim.api.nvim_buf_is_loaded(context.buf) then
    local strategy
    if not opts.named_prompt and (vim.bo[context.buf].filetype == "sia") then
      strategy = require("sia.strategy").ChatStrategy.by_buf(context.buf)

      if strategy and not strategy.is_busy then
        local last_instruction = action.instructions[#action.instructions] --[[@as sia.config.Instruction ]]
        strategy.conversation:add_instruction(last_instruction, nil)

        -- The user might have explicitly changed the model with -m
        if opts.model then
          local Model = require("sia.model")
          strategy.conversation.model = Model.resolve(opts.model)
        end
      else
        vim.notify("Sia: conversation is busy")
      end
    else
      if opts.model then
        action.model = opts.model
      end
      local conversation = require("sia.conversation").Conversation:new(action, context)
      if conversation.mode == "diff" then
        local options =
          vim.tbl_deep_extend("force", config.options.defaults.diff, action.diff or {})
        strategy = require("sia.strategy").DiffStrategy:new(conversation, options)
      elseif conversation.mode == "insert" then
        local options = vim.tbl_deep_extend(
          "force",
          config.options.defaults.insert,
          action.insert or {}
        )
        strategy = require("sia.strategy").InsertStrategy:new(conversation, options)
      elseif conversation.mode == "hidden" then
        local options = vim.tbl_deep_extend(
          "force",
          config.options.defaults.hidden,
          action.hidden or {}
        )
        if not options.callback then
          vim.notify(
            "Sia: Hidden strategy requires a callback function",
            vim.log.levels.ERROR
          )
          return
        end
        strategy = require("sia.strategy").HiddenStrategy:new(conversation, options)
      else
        local options =
          vim.tbl_deep_extend("force", config.options.defaults.chat, action.chat or {})
        strategy = require("sia.strategy").ChatStrategy:new(conversation, options)
      end
    end

    --- @cast strategy sia.Strategy
    require("sia.assistant").execute_strategy(strategy)
  end
end

return M
