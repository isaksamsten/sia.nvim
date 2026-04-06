local M = {}

local highlight_groups = {
  SiaConfirm = { link = "NormalFloat" },
  SiaConfirmItem = { link = "NonText" },
  SiaConfirmSelectedItem = { link = "Normal" },
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
  SiaStatusActive = { link = "DiagnosticHint" },
  SiaStatusDone = { link = "DiagnosticOk" },
  SiaStatusFailed = { link = "DiagnosticError" },
  SiaStatusTag = { link = "Type" },
  SiaStatusMuted = { link = "NonText" },
  SiaStatusLabel = { link = "Identifier" },
  SiaStatusValue = { link = "Normal" },
  SiaStatusPath = { link = "Directory" },
  SiaStatusCode = { link = "String" },
  SiaMode = { link = "DiagnosticInfo" },
}

local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

M.confirm = {
  prompt = require("sia.ui.confirm").prompt,
  accept = require("sia.ui.confirm").accept,
  always = require("sia.ui.confirm").always,
  decline = require("sia.ui.confirm").decline,
  preview = require("sia.ui.confirm").preview,
  expand = require("sia.ui.confirm").expand,
}

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
      vim.api.nvim_echo({ { "sia: no changes to accept", "WarningMsg" } }, false, {})
    end
  end,

  --- @param opts { buf: integer? }?
  reject_all = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    if not require("sia.diff").reject_diff(buf) then
      vim.api.nvim_echo({ { "sia: no changes to reject", "WarningMsg" } }, false, {})
    end
  end,

  --- @param opts { buf: integer? }?
  show = function(opts)
    opts = opts or {}
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local diff = require("sia.diff")

    if not diff.show_diff_for_buffer(buf) then
      vim.api.nvim_echo({ { "sia: no changes to show", "WarningMsg" } }, false, {})
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
      return
    end

    vim.fn.setqflist(quickfix_items, "r")
    vim.cmd("copen")
  end,
}

M.ui = {
  --- Manage todos window for the current chat
  --- @param action? string "open" | "close" | "toggle" (default: "toggle")
  todos = function(action)
    require("sia.ui.todos").toggle(action)
  end,

  --- @param action ("open"|"close"|"toggle")?
  status = function(action)
    require("sia.ui.status").toggle(action)
  end,

  --- Show contexts in quickfix list
  contexts = function()
    local chat = require("sia.strategy").get_chat()
    if not chat then
      return
    end

    local contexts = chat.conversation:get_regions()
    if #contexts == 0 then
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
  end,

  --- @param opts table?
  messages = function(opts)
    opts = opts or {}
    local chat = require("sia.strategy").get_chat()
    if chat then
      local entries = chat.conversation.entries
      if #entries == 0 then
        return
      end
      --- @param entry sia.Entry
      local function description(entry)
        local parts = {}

        -- Role label
        local role = entry.role
        if role == "tool" then
          if entry.tool_call.type == "function" then
            role = "tool(" .. entry.tool_call.name .. ")"
          elseif entry.tool_call.type == "custom" then
            role = "tool(" .. entry.tool_call.name .. ")"
          else
            role = "tool"
          end
        end
        table.insert(parts, role)

        -- Status flags
        if entry.dropped then
          table.insert(parts, "[dropped]")
        elseif entry.region and chat.conversation:is_stale(entry.region) then
          table.insert(parts, "[stale]")
        end
        if entry.hide then
          table.insert(parts, "[hidden]")
        end

        -- Content preview
        local preview
        local content = entry.content
        if type(content) == "string" then
          preview = content
        elseif type(content) == "table" then
          for _, part in ipairs(content) do
            if part.type == "text" then
              preview = part.text
              break
            elseif part.type == "file" then
              preview = "📎 " .. part.file.filename
              break
            elseif part.type == "image" then
              preview = "🖼️ image"
              break
            end
          end
        end

        if preview then
          preview = preview:gsub("%s+", " "):sub(1, 80)
          if #preview == 80 then
            preview = preview .. "…"
          end
          table.insert(parts, ": " .. preview)
        end

        return table.concat(parts, " ")
      end

      --- @param entry sia.Entry
      --- @return string?
      local function format_content(entry)
        local parts = {}

        if entry.role == "tool" then
          table.insert(parts, "## Tool Call")
          table.insert(parts, "")
          table.insert(
            parts,
            string.format("**%s** (id: %s)", entry.tool_call.name, entry.tool_call.id)
          )
          if entry.tool_call.type == "function" then
            table.insert(parts, "")
            table.insert(parts, "**Arguments:**")
            table.insert(parts, "```json")
            table.insert(parts, vim.json.encode(entry.tool_call.arguments))
            table.insert(parts, "```")
          end
          table.insert(parts, "")
          table.insert(parts, "## Tool Result")
          table.insert(parts, "")
        end

        if entry.role == "assistant" and entry.reasoning then
          table.insert(parts, "## Reasoning")
          table.insert(parts, "")
          table.insert(parts, entry.reasoning.text or "")
          table.insert(parts, "")
          if entry.content then
            table.insert(parts, "## Response")
            table.insert(parts, "")
          end
        end

        local content = entry.content
        if not content then
          return #parts > 0 and table.concat(parts, "\n") or nil
        end

        if type(content) == "string" then
          table.insert(parts, content)
        elseif type(content) == "table" then
          for _, part in ipairs(content) do
            if part.type == "text" then
              table.insert(parts, part.text)
            elseif part.type == "file" then
              table.insert(
                parts,
                string.format("📎 File: **%s**", part.file.filename)
              )
            elseif part.type == "image" then
              table.insert(parts, string.format("🖼️ Image: %s", part.image.url))
            end
          end
        end

        return #parts > 0 and table.concat(parts, "\n") or nil
      end

      vim.ui.select(entries, {
        prompt = "Show message",
        format_item = description,
        --- @param item sia.Entry?
      }, function(item, _)
        if item then
          local content = format_content(item)

          if content then
            local buf_name = chat.conversation.name .. " " .. description(item)
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
  end,
}

M.chat = {
  toggle = function()
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
  end,

  reply = function()
    local buf = vim.api.nvim_get_current_buf()
    local chat = require("sia.strategy").get_chat()
    if chat then
      vim.cmd("new")
      buf = vim.api.nvim_get_current_buf()
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
      vim.bo[buf].ft = "markdown"
      vim.api.nvim_buf_set_name(buf, "*sia reply*" .. chat.conversation.name)
      vim.api.nvim_win_set_height(win, 10)

      vim.keymap.set("n", "<CR>", function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        chat:submit({ content = table.concat(lines, "\n") })
        vim.api.nvim_buf_delete(buf, { force = true })
      end, { buffer = buf })
      vim.keymap.set("n", "q", function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end, { buffer = buf })
    end
  end,

  --- Open a floating compose window to start a new conversation
  compose = function()
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
          local registry = require("sia.provider")
          if registry.has_model(input) then
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
        return
      end

      local model_name = vim.b[buf].sia_prompt_model
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

      --- @type sia.config.ChatAction?
      local action = config.options.settings.actions.chat
      if not action then
        error("chat action is not defined!")
      end
      local conversation =
        require("sia.conversation").from_action(action, context, { model = model_name })
      conversation:add_user_message(prompt)
      local strategy =
        require("sia.strategy").from_action(action, context, conversation)
      require("sia.assistant").execute_strategy(strategy)
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
  end,
}

_G.sia_model_complete = function(arg_lead, cmd_line, cursor_pos)
  local registry = require("sia.provider")
  local available_models = registry.list()

  -- Also include aliases from local config
  local config = require("sia.config")
  local lc = config.get_local_config()
  if lc and lc.aliases then
    for alias_name, _ in pairs(lc.aliases) do
      table.insert(available_models, alias_name)
    end
  end

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

  require("sia.ui").setup({ icons = config.options.settings.icons })
  require("sia.mappings").setup()

  if config.options.settings.ui.diff.enable then
    require("sia.diff").setup()
  end
  if config.options.settings.history.enable then
    require("sia.history").setup()
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

return M
