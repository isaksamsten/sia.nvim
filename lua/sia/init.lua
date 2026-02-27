local M = {}

local highlight_groups = {
  SiaInsert = { link = "DiffAdd" },
  SiaInsertPostProcess = { link = "DiffChange" },
  SiaReplace = { link = "DiffChange" },
  SiaProgress = { link = "NonText" },
  SiaModel = {},
  SiaUsage = {},
  SiaStatus = {},
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
  SiaAgentRunning = { link = "DiagnosticHint" },
  SiaAgentCompleted = { link = "DiagnosticOk" },
  SiaAgentFailed = { link = "DiagnosticError" },
}

local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

M.edit = {
  reject = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local win = vim.fn.bufwinid(buf)
    local line = opts.line or vim.api.nvim_win_get_cursor(win)[1]

    local hunk_idx = require("sia.diff").get_hunk_at_line(buf, line)
    if hunk_idx then
      require("sia.diff").reject_single_hunk(buf, hunk_idx)
    end
  end,

  accept = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local win = vim.fn.bufwinid(buf)
    local line = opts.line or vim.api.nvim_win_get_cursor(win)[1]

    local hunk_idx = require("sia.diff").get_hunk_at_line(buf, line)
    if hunk_idx then
      require("sia.diff").accept_single_hunk(buf, hunk_idx)
    end
  end,

  --- @param opts { buf: integer? }?
  accept_all = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    if not require("sia.diff").accept_diff(buf) then
      vim.api.nvim_echo({ { "Sia: No changes to accept", "WarningMsg" } }, false, {})
    end
  end,

  --- @param opts { buf: integer? }?
  reject_all = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    if not require("sia.diff").reject_diff(buf) then
      vim.api.nvim_echo({ { "Sia: No changes to reject", "WarningMsg" } }, false, {})
    end
  end,

  --- @param opts { buf: integer? }?
  show = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local diff = require("sia.diff")

    if not diff.show_diff_for_buffer(buf) then
      vim.api.nvim_echo({ { "Sia: No changes to show", "WarningMsg" } }, false, {})
    end
  end,

  --- Navigate to the next diff hunk
  --- @param opts { buf: integer? }?
  next = function(opts)
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
  end,

  --- Navigate to the previous diff hunk
  --- @param opts { buf: integer? }?
  prev = function(opts)
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
  end,

  --- Populate quickfix list with all diff hunks
  --- @param opts { buf: integer? }?
  open_qf = function(opts)
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
  end,
}

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

--- Manage todos window for the current chat
--- @param action? string "open" | "close" | "toggle" (default: "toggle")
function M.todos(action)
  require("sia.ui.todos").toggle(action)
end

--- @param action ("open"|"close"|"toggle")?
function M.status(action)
  require("sia.ui.status").toggle(action)
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

function M.reply()
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

--- Open a floating compose window to start a new conversation
function M.compose()
  local config = require("sia.config")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].ft = "markdown"

  vim.b[buf].sia_prompt_model = nil

  local width = vim.o.columns
  local height = math.max(5, math.floor(vim.o.lines * 0.2))
  local row = vim.o.lines - height - 2
  local col = math.floor((vim.o.columns - width) / 2)

  local function update_title(win)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local model = vim.b[buf].sia_prompt_model
    local title = model and string.format(" Sia [%s] ", model) or " Sia "
    vim.api.nvim_win_set_config(win, { title = title, title_pos = "center" })
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    focusable = true,
    style = "minimal",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "single",
    title = " Sia ",
    title_pos = "center",
    footer = " <CR>: Submit | m: Select Model | q: Close ",
    footer_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  vim.keymap.set("n", "m", function()
    vim.ui.input({
      prompt = "Model: ",
      default = vim.b[buf].sia_prompt_model or config.options.settings.model.name,
      completion = "customlist,v:lua.sia_model_complete",
    }, function(input)
      if input and input ~= "" then
        if config.options.models[input] then
          vim.b[buf].sia_prompt_model = input
          update_title(win)
        end
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    end)
  end, { buffer = buf, desc = "Select model for prompt" })

  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local prompt = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")

    if prompt == "" then
      vim.notify("Sia: No prompt provided.", vim.log.levels.WARN)
      return
    end

    local model_name = vim.b[buf].sia_prompt_model
    local action =
      vim.tbl_deep_extend("force", {}, config.options.settings.actions.chat)
    action.instructions = vim.list_extend({}, action.instructions)
    table.insert(action.instructions, {
      role = "user",
      content = prompt,
    })

    if model_name then
      action.model = model_name
    end

    local target_buf = vim.fn.bufnr("#")
    if target_buf == -1 then
      target_buf = vim.api.nvim_get_current_buf()
    end

    local context = {
      buf = target_buf,
      win = vim.fn.bufwinid(target_buf),
      mode = "n",
      bang = false,
    }

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end

    M.execute_action(action, {
      context = context,
      model = model_name,
      named_prompt = false,
    })
  end, { buffer = buf, desc = "Submit prompt" })

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, desc = "Close prompt window" })

  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, desc = "Close prompt window" })

  vim.cmd("startinsert")
end

_G.sia_model_complete = function(arg_lead, cmd_line, cursor_pos)
  local config = require("sia.config")
  local available_models = vim.tbl_keys(config.options.models)
  table.sort(available_models)

  local matches = {}
  for _, model in ipairs(available_models) do
    if vim.startswith(model, arg_lead) then
      table.insert(matches, model)
    end
  end

  return matches
end

function M.setup(options)
  local config = require("sia.config")
  config.setup(options)

  require("sia.icons").setup(config.options.settings.icons or "emoji")
  require("sia.mappings").setup()

  if config.options.settings.ui.diff.enable then
    require("sia.diff").setup()
  end

  set_highlight_groups()

  vim.treesitter.language.register("markdown", "sia")

  local augroup = vim.api.nvim_create_augroup("SiaGroup", { clear = true })

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
    local should_execute = true
    if not opts.named_prompt and (vim.bo[context.buf].filetype == "sia") then
      strategy = require("sia.strategy").ChatStrategy.by_buf(context.buf)

      if strategy then
        local last_instruction = action.instructions[#action.instructions] --[[@as sia.config.Instruction ]]

        if strategy.is_busy then
          strategy:queue_instruction(last_instruction, nil)
          should_execute = false
        else
          strategy.conversation:add_instruction(last_instruction, nil)
        end
      end
    else
      if opts.model then
        action.model = opts.model
      end
      local conversation = require("sia.conversation").Conversation:new(action, context)
      if conversation.mode == "diff" then
        local options =
          vim.tbl_deep_extend("force", config.options.settings.diff, action.diff or {})
        strategy = require("sia.strategy").DiffStrategy:new(conversation, options)
      elseif conversation.mode == "insert" then
        local options = vim.tbl_deep_extend(
          "force",
          config.options.settings.insert,
          action.insert or {}
        )
        strategy = require("sia.strategy").InsertStrategy:new(conversation, options)
      elseif conversation.mode == "hidden" then
        local options = vim.tbl_deep_extend(
          "force",
          config.options.settings.hidden,
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
          vim.tbl_deep_extend("force", config.options.settings.chat, action.chat or {})
        strategy = require("sia.strategy").ChatStrategy:new(conversation, options)
      end
    end

    if strategy and should_execute then
      --- @cast strategy sia.Strategy
      require("sia.assistant").execute_strategy(strategy)
    end
  end
end

return M
