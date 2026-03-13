local M = {}

local RISK_ORDER = {
  safe = 1,
  info = 2,
  warn = 3,
}

local next_confirm_id = 0
local detail_win = nil
local detail_buf = nil
local detail_help_win = nil
local detail_help_buf = nil
local detail_resize_autocmd = nil
local detail_help_autocmd = nil
local detail_ns = vim.api.nvim_create_namespace("sia_confirm_detail")
local detail_selection = {
  group = 1,
  item = 1,
}

local DETAIL_HELP_LINES = {
  "Confirm mappings",
  "",
  "h/l   move between groups",
  "j/k   move between items",
  "a/d   accept or decline item",
  "A/D   accept or decline group",
  "p     open prompt",
  "v     preview item",
  "<CR>  open prompt",
  "q     close approvals",
}

--- @param level sia.RiskLevel
--- @return string
local function get_highlight(level)
  if level == "warn" then
    return "SiaApproveWarn"
  elseif level == "safe" then
    return "SiaApproveSafe"
  end
  return "SiaApproveInfo"
end

--- @param level1 sia.RiskLevel
--- @param level2 sia.RiskLevel
--- @return sia.RiskLevel
local function max_level(level1, level2)
  if RISK_ORDER[level1] >= RISK_ORDER[level2] then
    return level1
  end
  return level2
end

--- @param value integer
--- @param minimum integer
--- @param maximum integer
--- @return integer
local function clamp(value, minimum, maximum)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

--- @class sia.ConfirmNotifierOpts
--- @field level sia.RiskLevel
--- @field name string
--- @field message string
--- @field total integer?
--- @field groups integer?

--- @class sia.ConfirmNotifier
--- @field show fun(args:sia.ConfirmNotifierOpts) Show/update the notification. Called whenever the message changes.
--- @field clear fun() Clear/dismiss the notification

--- @class sia.PendingConfirmItem
--- @field id integer
--- @field prompt string
--- @field level sia.RiskLevel

--- @class sia.PendingConfirmGroup
--- @field key string
--- @field conversation sia.Conversation
--- @field tool_name string
--- @field kind "input"|"choice"
--- @field level sia.RiskLevel
--- @field batchable boolean
--- @field items sia.PendingConfirmItem[]

--- @class sia.PendingConfirmSection
--- @field conversation sia.Conversation
--- @field groups sia.PendingConfirmGroup[]
--- @field grouped table<string, sia.PendingConfirmGroup>

--- Global state for managing pending confirmations
--- @class sia.PendingConfirm
--- @field id integer
--- @field conversation sia.Conversation
--- @field prompt string
--- @field tool_name string
--- @field kind "input"|"choice"
--- @field level sia.RiskLevel
--- @field on_ready fun(idx: integer, choice:"accept"|"decline"|"prompt"|"preview")
--- @field clear_preview fun()?

--- @type sia.PendingConfirm[]
local pending_confirms = {}

--- Default notifier using floating window
--- @return sia.ConfirmNotifier
function M.floating_notifier()
  local notification_win = nil
  local notification_buf = nil
  local resize_autocmd = nil

  --- @type sia.ConfirmNotifier
  return {
    show = function(args)
      if not notification_buf or not vim.api.nvim_buf_is_valid(notification_buf) then
        notification_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[notification_buf].bufhidden = "wipe"
      end

      local content = string.format("[%s] %s", args.name, args.message)
      if args.total and args.total > 1 then
        content = string.format("%s (+%d more)", content, args.total - 1)
      end
      vim.api.nvim_buf_set_lines(notification_buf, 0, -1, false, { content })

      if not notification_win or not vim.api.nvim_win_is_valid(notification_win) then
        notification_win = vim.api.nvim_open_win(notification_buf, false, {
          relative = "editor",
          width = vim.o.columns,
          height = 1,
          row = 0,
          col = 0,
          style = "minimal",
          focusable = false,
          noautocmd = true,
          zindex = 50,
        })

        if not resize_autocmd then
          resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
            callback = function()
              if notification_win and vim.api.nvim_win_is_valid(notification_win) then
                vim.api.nvim_win_set_config(notification_win, {
                  width = vim.o.columns,
                })
              end
            end,
          })
        end
      end

      vim.wo[notification_win].winhighlight = "Normal:" .. get_highlight(args.level)
    end,

    clear = function()
      if notification_win and vim.api.nvim_win_is_valid(notification_win) then
        vim.api.nvim_win_close(notification_win, true)
        notification_win = nil
      end

      if resize_autocmd then
        pcall(vim.api.nvim_del_autocmd, resize_autocmd)
        resize_autocmd = nil
      end
    end,
  }
end

--- @return sia.ConfirmNotifier
function M.winbar_notifier()
  local notification_win = nil
  local old_winbar = nil

  --- @type sia.ConfirmNotifier
  return {
    show = function(args)
      if not notification_win or not vim.api.nvim_win_is_valid(notification_win) then
        notification_win = vim.api.nvim_get_current_win()
        old_winbar = vim.wo[notification_win].winbar
      end
      local width = vim.fn.winwidth(notification_win)
      local message = string.format("[%s] %s", args.name, args.message)
      if args.total and args.total > 1 then
        message = string.format("%s (+%d more)", message, args.total - 1)
      end
      if #message > width then
        message = message:sub(1, width - 3) .. "..."
      end
      vim.wo[notification_win].winbar = message
    end,

    clear = function()
      if notification_win and vim.api.nvim_win_is_valid(notification_win) then
        vim.wo[notification_win].winbar = old_winbar or ""
        notification_win = nil
        old_winbar = nil
      end
    end,
  }
end

local default_notifier = M.floating_notifier()

--- @return sia.ConfirmNotifier
local function get_notifier()
  local confirm_config = require("sia.config").options.settings.ui.confirm
  return (confirm_config.async and confirm_config.async.notifier) or default_notifier
end

--- @param confirm sia.PendingConfirm
--- @return string
local function group_key(confirm)
  return string.format(
    "%s:%s:%s",
    tostring(confirm.conversation.id),
    confirm.tool_name or "tool",
    confirm.kind or "input"
  )
end

--- @return sia.PendingConfirmSection[]
local function get_sections()
  --- @type table<string, sia.PendingConfirmSection>
  local sections = {}
  --- @type sia.PendingConfirmSection[]
  local ordered_sections = {}

  for _, confirm in ipairs(pending_confirms) do
    local conversation_key = tostring(confirm.conversation.id)
    local section = sections[conversation_key]
    if not section then
      section = {
        conversation = confirm.conversation,
        groups = {},
        grouped = {},
      }
      sections[conversation_key] = section
      table.insert(ordered_sections, section)
    end

    local key = group_key(confirm)
    local group = section.grouped[key]
    if not group then
      group = {
        key = key,
        conversation = confirm.conversation,
        tool_name = confirm.tool_name,
        kind = confirm.kind,
        level = confirm.level,
        batchable = confirm.kind == "input",
        items = {},
      }
      section.grouped[key] = group
      table.insert(section.groups, group)
    else
      group.level = max_level(group.level, confirm.level)
      group.batchable = group.batchable and confirm.kind == "input"
    end

    table.insert(group.items, {
      id = confirm.id,
      prompt = confirm.prompt,
      level = confirm.level,
    })
  end

  return ordered_sections
end

--- @return sia.PendingConfirmGroup[]
local function get_groups()
  local ordered_sections = get_sections()
  local ordered = {}
  for _, section in ipairs(ordered_sections) do
    for _, group in ipairs(section.groups) do
      table.insert(ordered, group)
    end
  end

  return ordered
end

--- @param group sia.PendingConfirmGroup
--- @return string
local function group_heading(group)
  if #group.items == 1 then
    return group.tool_name
  end
  return string.format("%s (%d)", group.tool_name, #group.items)
end

--- @return sia.RiskLevel?
local function pending_level()
  if #pending_confirms == 0 then
    return nil
  end

  local level = "safe"
  for _, confirm in ipairs(pending_confirms) do
    level = max_level(level, confirm.level)
  end
  return level
end

--- @return sia.ConfirmNotifierOpts?
local function build_notifier_state()
  if #pending_confirms == 0 then
    return nil
  end

  local groups = get_groups()
  local confirm = pending_confirms[1]

  return {
    level = confirm.level,
    name = confirm.conversation.name,
    message = confirm.prompt,
    total = #pending_confirms,
    groups = #groups,
  }
end

local refresh_notifier
local refresh_ui
local refresh_detail_window
local clear_detail_window
local trigger_confirm
local ensure_selection
local select_group
local select_item
local apply_group_choice
local apply_selected_item_choice
local warn_group_action
local close_detail_help
local show_detail_help

--- @param id integer
--- @return integer?
local function find_confirm_index(id)
  for idx, confirm in ipairs(pending_confirms) do
    if confirm.id == id then
      return idx
    end
  end
end

local function ensure_detail_buffer()
  if detail_buf and vim.api.nvim_buf_is_valid(detail_buf) then
    return detail_buf
  end

  detail_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[detail_buf].buftype = "nofile"
  vim.bo[detail_buf].bufhidden = "wipe"
  vim.bo[detail_buf].swapfile = false
  vim.bo[detail_buf].modifiable = false
  vim.bo[detail_buf].readonly = true
  vim.bo[detail_buf].buflisted = false
  vim.bo[detail_buf].filetype = "sia-confirm"

  vim.keymap.set("n", "q", function()
    clear_detail_window()
  end, { buffer = detail_buf, silent = true, desc = "Close approvals" })
  vim.keymap.set("n", "<Esc>", function()
    clear_detail_window()
  end, { buffer = detail_buf, silent = true, desc = "Close approvals" })
  vim.keymap.set("n", "h", function()
    select_group(-1)
  end, { buffer = detail_buf, silent = true, desc = "Previous group" })
  vim.keymap.set("n", "l", function()
    select_group(1)
  end, { buffer = detail_buf, silent = true, desc = "Next group" })
  vim.keymap.set("n", "j", function()
    select_item(1)
  end, { buffer = detail_buf, silent = true, desc = "Next item" })
  vim.keymap.set("n", "k", function()
    select_item(-1)
  end, { buffer = detail_buf, silent = true, desc = "Previous item" })
  vim.keymap.set("n", "a", function()
    apply_selected_item_choice("accept")
  end, { buffer = detail_buf, silent = true, desc = "Accept item" })
  vim.keymap.set("n", "d", function()
    apply_selected_item_choice("decline")
  end, { buffer = detail_buf, silent = true, desc = "Decline item" })
  vim.keymap.set("n", "p", function()
    apply_selected_item_choice("prompt")
  end, { buffer = detail_buf, silent = true, desc = "Prompt item" })
  vim.keymap.set("n", "v", function()
    apply_selected_item_choice("preview")
  end, { buffer = detail_buf, silent = true, desc = "Preview item" })
  vim.keymap.set("n", "<CR>", function()
    apply_selected_item_choice("prompt")
  end, { buffer = detail_buf, silent = true, desc = "Prompt item" })
  vim.keymap.set("n", "A", function()
    apply_group_choice("accept")
  end, { buffer = detail_buf, silent = true, desc = "Accept group" })
  vim.keymap.set("n", "D", function()
    apply_group_choice("decline")
  end, { buffer = detail_buf, silent = true, desc = "Decline group" })
  vim.keymap.set("n", "g?", function()
    show_detail_help()
  end, { buffer = detail_buf, silent = true, desc = "Show approval mappings" })

  return detail_buf
end

local function ensure_detail_help_buffer()
  if detail_help_buf and vim.api.nvim_buf_is_valid(detail_help_buf) then
    return detail_help_buf
  end

  detail_help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(detail_help_buf, 0, -1, false, DETAIL_HELP_LINES)
  vim.bo[detail_help_buf].buftype = "nofile"
  vim.bo[detail_help_buf].bufhidden = "wipe"
  vim.bo[detail_help_buf].swapfile = false
  vim.bo[detail_help_buf].readonly = true
  vim.bo[detail_help_buf].buflisted = false
  vim.bo[detail_help_buf].filetype = "sia-confirm-help"
  vim.bo[detail_help_buf].modifiable = false
  return detail_help_buf
end

close_detail_help = function()
  if detail_help_win and vim.api.nvim_win_is_valid(detail_help_win) then
    vim.api.nvim_win_close(detail_help_win, true)
  end
  detail_help_win = nil

  if detail_help_autocmd then
    pcall(vim.api.nvim_del_autocmd, detail_help_autocmd)
    detail_help_autocmd = nil
  end
end

show_detail_help = function()
  if not detail_win or not vim.api.nvim_win_is_valid(detail_win) then
    return
  end

  if detail_help_win and vim.api.nvim_win_is_valid(detail_help_win) then
    close_detail_help()
    return
  end

  local buf = ensure_detail_help_buffer()
  local width = 0
  for _, line in ipairs(DETAIL_HELP_LINES) do
    width = math.max(width, #line)
  end

  detail_help_win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    width = width,
    height = #DETAIL_HELP_LINES,
    row = 1,
    col = 2,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 52,
  })
  vim.wo[detail_help_win].winhighlight = "NormalFloat:SiaConfirm,FloatBorder:SiaConfirm"

  detail_help_autocmd = vim.api.nvim_create_autocmd({
    "CursorMoved",
    "BufLeave",
    "WinLeave",
  }, {
    buffer = detail_buf,
    once = true,
    callback = function()
      close_detail_help()
    end,
  })
end

--- @return sia.PendingConfirmGroup[]
local function get_selected_groups()
  local groups = get_groups()
  ensure_selection(groups)
  return groups
end

ensure_selection = function(groups)
  if #groups == 0 then
    detail_selection.group = 1
    detail_selection.item = 1
    return
  end

  detail_selection.group = clamp(detail_selection.group, 1, #groups)
  local selected_group = groups[detail_selection.group]
  detail_selection.item = clamp(detail_selection.item, 1, #selected_group.items)
end

--- @return sia.PendingConfirmGroup?
local function current_group()
  local groups = get_selected_groups()
  return groups[detail_selection.group]
end

--- @return sia.PendingConfirmItem?
local function current_item()
  local group = current_group()
  if not group then
    return nil
  end
  return group.items[detail_selection.item]
end

warn_group_action = function(group)
  vim.notify(
    string.format("sia: %s groups require item-level actions", group.tool_name),
    vim.log.levels.WARN
  )
end

trigger_confirm = function(idx, choice)
  if #pending_confirms == 0 or not pending_confirms[idx] then
    return
  end

  pending_confirms[idx].on_ready(idx, choice)
end

--- @param group sia.PendingConfirmGroup
--- @param choice "accept"|"decline"
local function trigger_group(group, choice)
  local ids = vim
    .iter(group.items)
    :map(function(item)
      return item.id
    end)
    :totable()

  for _, id in ipairs(ids) do
    local pending_idx = find_confirm_index(id)
    if pending_idx then
      trigger_confirm(pending_idx, choice)
    end
  end
end

apply_group_choice = function(choice)
  local group = current_group()
  if not group then
    return
  end

  if not group.batchable and #group.items > 1 then
    warn_group_action(group)
    return
  end

  if #group.items == 1 then
    detail_selection.item = 1
    apply_selected_item_choice(choice)
    return
  end

  if choice == "accept" then
    trigger_group(group, "accept")
  else
    trigger_group(group, "decline")
  end
end

apply_selected_item_choice = function(choice)
  local item = current_item()
  if not item then
    return
  end

  local pending_idx = find_confirm_index(item.id)
  if pending_idx then
    trigger_confirm(pending_idx, choice)
  end
end

select_group = function(delta)
  local groups = get_groups()
  if #groups == 0 then
    return
  end

  ensure_selection(groups)
  detail_selection.group = ((detail_selection.group - 1 + delta) % #groups) + 1
  local group = groups[detail_selection.group]
  detail_selection.item = clamp(detail_selection.item, 1, #group.items)
  refresh_detail_window()
end

select_item = function(delta)
  local groups = get_groups()
  if #groups == 0 then
    return
  end

  ensure_selection(groups)
  local group = groups[detail_selection.group]
  detail_selection.item = ((detail_selection.item - 1 + delta) % #group.items) + 1
  refresh_detail_window()
end

--- @param width integer
--- @param sections sia.PendingConfirmSection[]
--- @return string[], table[]
local function build_group_lines(width, sections)
  local lines = {}
  local spans = {}
  local section_gap = 3
  local group_index = 0
  local blocks = {}

  for _, section in ipairs(sections) do
    local header = string.format("[%s]", section.conversation.name)
    local token_lines = { "" }
    local header_span = {
      line = 1,
      start_col = 0,
      end_col = #header,
      highlight = "SiaConfirmItem",
    }
    local block_spans = {}
    local line = 1
    local col = 0

    for _, group in ipairs(section.groups) do
      group_index = group_index + 1
      local token = string.format("[%s]", group_heading(group))
      local token_len = #token
      local separator = col == 0 and "" or " "
      local max_token_width = math.max(width - #header - section_gap, 20)

      if col > 0 and col + 1 + token_len > max_token_width then
        table.insert(token_lines, "")
        line = #token_lines
        col = 0
        separator = ""
      end

      local start_col = col + #separator
      token_lines[line] = token_lines[line] .. separator .. token
      table.insert(block_spans, {
        group = group_index,
        line = line + 1,
        start_col = start_col,
        end_col = start_col + token_len,
        highlight = group_index == detail_selection.group and get_highlight(
          group.level
        ) or "SiaConfirmItem",
      })
      if detail_selection.group == group_index then
        header_span.highlight = "SiaConfirmSelectedItem"
      end
      col = start_col + token_len
    end

    local block_width = #header
    for _, token_line in ipairs(token_lines) do
      block_width = math.max(block_width, #token_line)
    end
    table.insert(block_spans, header_span)
    table.insert(blocks, {
      width = block_width,
      header = header,
      token_lines = token_lines,
      spans = block_spans,
    })
  end

  local row_height = 0
  local row_col = 0
  local row_start = 1
  for idx, block in ipairs(blocks) do
    local total_width = row_col == 0 and block.width
      or row_col + section_gap + block.width
    if row_col > 0 and total_width > width then
      row_height = math.max(row_height, 2)
      for _ = 1, row_height do
        table.insert(lines, "")
      end
      row_start = #lines + 1
      row_col = 0
      row_height = 0
    end

    local block_col = row_col == 0 and 0 or row_col + section_gap
    local block_height = #block.token_lines + 1
    row_height = math.max(row_height, block_height)

    for offset = 0, block_height - 1 do
      local line_idx = row_start + offset
      lines[line_idx] = lines[line_idx] or ""
      local target_col = block_col
      if #lines[line_idx] < target_col then
        lines[line_idx] = lines[line_idx]
          .. string.rep(" ", target_col - #lines[line_idx])
      end

      local text = offset == 0 and block.header or block.token_lines[offset]
      lines[line_idx] = lines[line_idx] .. text
    end

    for _, span in ipairs(block.spans) do
      table.insert(spans, {
        group = span.group,
        line = row_start + span.line - 1,
        start_col = block_col + span.start_col,
        end_col = block_col + span.end_col,
        highlight = span.highlight,
      })
    end

    row_col = block_col + block.width
    if idx == #blocks then
      for _ = #lines + 1, row_start + row_height - 1 do
        table.insert(lines, "")
      end
    end
  end

  return lines, spans
end

--- @return string[], table[], sia.RiskLevel, [integer,integer]
local function build_detail_lines()
  local groups = get_selected_groups()
  local sections = get_sections()
  local selected_group = groups[detail_selection.group]
  local level = pending_level() or "info"

  local lines = {}
  local group_lines, group_highlights =
    build_group_lines(math.max(vim.o.columns - 2, 20), sections)
  for _, line in ipairs(group_lines) do
    table.insert(lines, line)
  end
  local highlights = {}
  for _, hl in ipairs(group_highlights) do
    table.insert(highlights, {
      line = hl.line,
      start_col = hl.start_col,
      end_col = hl.end_col,
      highlight = hl.highlight,
    })
  end

  local cursor
  for idx, item in ipairs(selected_group.items) do
    local prefix = idx == detail_selection.item and ">" or " "
    local line = string.format("%s %d. %s", prefix, idx, item.prompt)
    table.insert(lines, line)
    table.insert(highlights, {
      line = #lines,
      start_col = 0,
      end_col = #line,
      highlight = idx == detail_selection.item and get_highlight(item.level)
        or "SiaConfirmItem",
    })
    if idx == detail_selection.item then
      cursor = { #lines, 0 }
    end
  end
  return lines, highlights, level, cursor
end

clear_detail_window = function()
  close_detail_help()

  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_win_close(detail_win, true)
  end
  detail_win = nil

  if detail_resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, detail_resize_autocmd)
    detail_resize_autocmd = nil
  end

  refresh_notifier()
end

refresh_detail_window = function()
  if not detail_win or not vim.api.nvim_win_is_valid(detail_win) then
    return
  end

  close_detail_help()

  if #pending_confirms == 0 then
    clear_detail_window()
    return
  end

  local buf = ensure_detail_buffer()
  local lines, highlights, _, cursor = build_detail_lines()

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, detail_ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, detail_ns, hl.line - 1, hl.start_col, {
      end_col = hl.end_col,
      hl_group = hl.highlight,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  local height = #lines
  vim.api.nvim_win_set_config(detail_win, {
    relative = "editor",
    fixed = true,
    width = vim.o.columns,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = true,
    zindex = 51,
  })
  local target_cursor = cursor or { 1, 0 }
  vim.api.nvim_win_set_cursor(detail_win, target_cursor)
  vim.api.nvim_win_call(detail_win, function()
    vim.fn.winrestview({
      lnum = target_cursor[1],
      col = target_cursor[2],
      topline = target_cursor[1],
      leftcol = 0,
    })
  end)
  vim.wo[detail_win].winhighlight = "SiaConfirm:SiaConfirm"
  vim.wo[detail_win].wrap = false
  vim.wo[detail_win].cursorline = false
end

refresh_notifier = function()
  local notifier = get_notifier()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    notifier.clear()
    return
  end

  local state = build_notifier_state()
  if state then
    notifier.show(state)
  else
    notifier.clear()
  end
end

refresh_ui = function()
  refresh_notifier()
  refresh_detail_window()
end

--- Show a pending confirmation notification to the user
--- @param conversation sia.Conversation The conversation requesting confirmation
--- @param prompt string The prompt to show to the user
--- @param opts { level: sia.RiskLevel, on_accept: fun(), on_cancel: fun(), on_prompt:fun(), on_preview: (fun():fun())?, tool_name:string?, kind:("input"|"choice")? }
function M.show(conversation, prompt, opts)
  next_confirm_id = next_confirm_id + 1

  local confirm = {
    id = next_confirm_id,
    conversation = conversation,
    prompt = prompt,
    tool_name = opts.tool_name or "tool",
    kind = opts.kind or "input",
    level = opts.level,
  }

  confirm.on_ready = function(idx, choice)
    if choice ~= "preview" then
      table.remove(pending_confirms, idx)
    end

    if confirm.clear_preview then
      confirm.clear_preview()
    end

    refresh_ui()

    if choice == "accept" then
      opts.on_accept()
    elseif choice == "prompt" then
      opts.on_prompt()
    elseif choice == "preview" and opts.on_preview then
      confirm.clear_preview = opts.on_preview()
    else
      opts.on_cancel()
    end
  end

  table.insert(pending_confirms, confirm)
  refresh_ui()
end

--- @param group sia.PendingConfirmGroup
--- @return string
local function group_picker_label(group)
  local mode = group.batchable and "batch" or "item"
  return string.format(
    "[%s] %s (%s, %s)",
    group.conversation.name,
    group_heading(group),
    group.level,
    mode
  )
end

--- @param group sia.PendingConfirmGroup
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function pick_item(group, choice)
  local items = {}
  for _, item in ipairs(group.items) do
    table.insert(items, item.prompt)
  end

  vim.ui.select(items, {
    prompt = string.format("Select %s request:", group.tool_name),
  }, function(_, idx)
    if not idx then
      return
    end

    detail_selection.group = clamp(detail_selection.group, 1, #get_groups())
    detail_selection.item = idx
    local pending_idx = find_confirm_index(group.items[idx].id)
    if pending_idx then
      trigger_confirm(pending_idx, choice)
    end
  end)
end

--- @param group sia.PendingConfirmGroup
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function apply_choice(group, choice)
  if #group.items == 1 then
    local pending_idx = find_confirm_index(group.items[1].id)
    if pending_idx then
      trigger_confirm(pending_idx, choice)
    end
    return
  end

  if choice == "accept" or choice == "decline" then
    if group.batchable then
      if choice == "accept" then
        trigger_group(group, "accept")
      else
        trigger_group(group, "decline")
      end
    else
      pick_item(group, choice)
    end
    return
  end

  pick_item(group, choice)
end

--- Internal helper to trigger a confirmation with a specific choice
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_pending_confirm(choice)
  local groups = get_groups()
  if #groups == 0 then
    return
  end

  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    if choice == "accept" or choice == "decline" then
      apply_group_choice(choice)
    else
      apply_selected_item_choice(choice)
    end
    return
  end

  if #pending_confirms == 1 then
    trigger_confirm(1, choice)
    return
  end

  if #groups == 1 then
    apply_choice(groups[1], choice)
    return
  end

  local labels = {}
  for _, group in ipairs(groups) do
    table.insert(labels, group_picker_label(group))
  end

  vim.ui.select(labels, {
    prompt = "Select approval group:",
  }, function(_, idx)
    if idx then
      apply_choice(groups[idx], choice)
    end
  end)
end

--- Show the confirmation prompt to the user
function M.prompt(opts)
  opts = opts or {}
  if opts.first then
    trigger_confirm(1, "prompt")
  else
    trigger_pending_confirm("prompt")
  end
end

--- Accept the pending confirmation
function M.accept(opts)
  opts = opts or {}
  if opts.first then
    trigger_confirm(1, "accept")
  else
    trigger_pending_confirm("accept")
  end
end

--- Decline the pending confirmation
function M.decline(opts)
  opts = opts or {}
  if opts.first then
    trigger_confirm(1, "decline")
  else
    trigger_pending_confirm("decline")
  end
end

--- Show preview for the pending confirmation
function M.preview(opts)
  opts = opts or {}
  if opts.first then
    trigger_confirm(1, "preview")
  else
    trigger_pending_confirm("preview")
  end
end

--- Show grouped approval details in a focusable top window.
function M.expand()
  if #pending_confirms == 0 then
    clear_detail_window()
    return
  end

  local buf = ensure_detail_buffer()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_set_current_win(detail_win)
    refresh_detail_window()
    return
  end

  detail_win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    fixed = true,
    width = vim.o.columns,
    height = 1,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = true,
    noautocmd = true,
    zindex = 51,
  })

  if not detail_resize_autocmd then
    detail_resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        refresh_detail_window()
      end,
    })
  end

  refresh_ui()
end

--- Get the count of pending confirmations
--- @return integer
function M.count()
  return #pending_confirms
end

return M
