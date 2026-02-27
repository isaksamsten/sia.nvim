local M = {}

--- @param level sia.RiskLevel
--- @return string
local function get_icon(level)
  if level == "safe" then
    return ""
  elseif level == "warn" then
    return ""
  else
    return ""
  end
end

--- @class sia.ConfirmNotifierOpts
--- @field level sia.RiskLevel
--- @field name string
--- @field message string
--- @field total integer?

--- @class sia.ConfirmNotifier
--- @field show fun(args:sia.ConfirmNotifierOpts) Show/update the notification. Called whenever the message changes.
--- @field clear fun() Clear/dismiss the notification

--- Global state for managing pending confirmations
--- @class sia.PendingConfirm
--- @field conversation sia.Conversation
--- @field prompt string
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

      local icon = get_icon(args.level)
      local content = string.format("%s [%s] %s", icon, args.name, args.message)
      if args.total > 1 then
        content = string.format("%s (+%d more)", content, args.total)
      end
      local split = vim.split(content, "\n")

      vim.api.nvim_buf_set_lines(notification_buf, 0, -1, false, { split[1] })

      if not notification_win or not vim.api.nvim_win_is_valid(notification_win) then
        local width = vim.o.columns
        local height = 1

        notification_win = vim.api.nvim_open_win(notification_buf, false, {
          relative = "editor",
          width = width,
          height = height,
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

      if args.level == "warn" then
        vim.wo[notification_win].winhighlight = "Normal:SiaApproveWarn"
      elseif args.level == "safe" then
        vim.wo[notification_win].winhighlight = "Normal:SiaApproveSafe"
      else
        vim.wo[notification_win].winhighlight = "Normal:SiaApproveInfo"
      end
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
      local message = args.message
      if #message > width then
        message = message:sub(1, width - 1) .. "…"
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

--- Show a pending confirmation notification to the user
--- @param conversation sia.Conversation The conversation requesting confirmation
--- @param prompt string The prompt to show to the user
--- @param opts { level: sia.RiskLevel, on_accept: fun(), on_cancel: fun(), on_prompt:fun(), on_preview: (fun():fun())? }
function M.show(conversation, prompt, opts)
  local confirm_config = require("sia.config").options.settings.ui.confirm
  local notifier = (confirm_config.async and confirm_config.async.notifier)
    or default_notifier

  local confirm = {
    conversation = conversation,
    prompt = prompt,
    level = opts.level,
  }

  confirm.on_ready = function(idx, choice)
    if choice ~= "preview" then
      table.remove(pending_confirms, idx)
      if #pending_confirms > 0 then
        local next_confirm = pending_confirms[1]
        notifier.show({
          level = next_confirm.level,
          name = next_confirm.conversation.name,
          message = next_confirm.prompt,
          total = #pending_confirms,
        })
      else
        notifier.clear()
      end
    end

    if confirm.clear_preview then
      confirm.clear_preview()
    end

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
  local first_confirm = pending_confirms[1]
  notifier.show({
    level = first_confirm.level,
    name = first_confirm.conversation.name,
    message = first_confirm.prompt,
    total = #pending_confirms,
  })
end

--- @param idx integer
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_confirm(idx, choice)
  if #pending_confirms == 0 or not pending_confirms[idx] then
    return
  end

  pending_confirms[idx].on_ready(idx, choice)
end

--- Internal helper to trigger a confirmation with a specific choice
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_pending_confirm(choice)
  if #pending_confirms == 1 then
    trigger_confirm(1, choice)
  else
    local items = {}
    for _, confirm in ipairs(pending_confirms) do
      table.insert(
        items,
        string.format("[%s] %s", confirm.conversation.name, confirm.prompt)
      )
    end

    vim.ui.select(items, {
      prompt = "Select confirmation:",
    }, function(_, idx)
      if idx then
        trigger_confirm(idx, choice)
      end
    end)
  end
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

--- Get the count of pending confirmations
--- @return integer
function M.count()
  return #pending_confirms
end

return M
