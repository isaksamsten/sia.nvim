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

--- @class sia.ApprovalNotifierOpts
--- @field level sia.RiskLevel
--- @field name string
--- @field message string
--- @field total integer?

--- @class sia.ApprovalNotifier
--- @field show fun(args:sia.ApprovalNotifierOpts) Show/update the notification. Called whenever the message changes.
--- @field clear fun() Clear/dismiss the notification

--- Global state for managing pending approvals
--- @class sia.PendingApproval
--- @field conversation sia.Conversation
--- @field prompt string
--- @field level sia.RiskLevel
--- @field on_ready fun(idx: integer, choice:"accept"|"decline"|"prompt"|"preview")
--- @field clear_preview fun()?

--- @type sia.PendingApproval[]
local pending_approvals = {}

--- Default notifier using floating window
--- @return sia.ApprovalNotifier
function M.floating_notifier()
  local notification_win = nil
  local notification_buf = nil
  local resize_autocmd = nil

  --- @type sia.ApprovalNotifier
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

--- @return sia.ApprovalNotifier
function M.winbar_notifier()
  local notification_win = nil
  local old_winbar = nil

  --- @type sia.ApprovalNotifier
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

--- Show a pending approval notification to the user
--- @param conversation sia.Conversation The conversation requesting approval
--- @param prompt string The prompt to show to the user
--- @param opts { level: sia.RiskLevel, on_accept: fun(), on_cancel: fun(), on_prompt:fun(), on_preview: (fun():fun())? }
function M.show(conversation, prompt, opts)
  local approval_config = require("sia.config").options.defaults.ui.approval
  local notifier = (approval_config.async and approval_config.async.notifier)
    or default_notifier

  local approval = {
    conversation = conversation,
    prompt = prompt,
    level = opts.level,
  }

  approval.on_ready = function(idx, choice)
    if choice ~= "preview" then
      table.remove(pending_approvals, idx)
      if #pending_approvals > 0 then
        local next_approval = pending_approvals[1]
        notifier.show({
          level = next_approval.level,
          name = next_approval.conversation.name,
          message = next_approval.prompt,
          total = #pending_approvals,
        })
      else
        notifier.clear()
      end
    end

    if approval.clear_preview then
      approval.clear_preview()
    end

    if choice == "accept" then
      opts.on_accept()
    elseif choice == "prompt" then
      opts.on_prompt()
    elseif choice == "preview" and opts.on_preview then
      approval.clear_preview = opts.on_preview()
    else
      opts.on_cancel()
    end
  end

  table.insert(pending_approvals, approval)
  local first_approval = pending_approvals[1]
  notifier.show({
    level = first_approval.level,
    name = first_approval.conversation.name,
    message = first_approval.prompt,
    total = #pending_approvals,
  })
end

--- @param idx integer
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_approval(idx, choice)
  if #pending_approvals == 0 or not pending_approvals[idx] then
    return
  end

  pending_approvals[idx].on_ready(idx, choice)
end

--- Internal helper to trigger an approval with a specific choice
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_pending_approval(choice)
  if #pending_approvals == 1 then
    trigger_approval(1, choice)
  else
    local items = {}
    for _, approval in ipairs(pending_approvals) do
      table.insert(
        items,
        string.format("[%s] %s", approval.conversation.name, approval.prompt)
      )
    end

    vim.ui.select(items, {
      prompt = "Select approval:",
    }, function(_, idx)
      if idx then
        trigger_approval(idx, choice)
      end
    end)
  end
end

--- Show the approval prompt to the user
function M.prompt(opts)
  opts = opts or {}
  if opts.first then
    trigger_approval(1, "prompt")
  else
    trigger_pending_approval("prompt")
  end
end

--- Accept the pending approval
function M.accept(opts)
  opts = opts or {}
  if opts.first then
    trigger_approval(1, "accept")
  else
    trigger_pending_approval("accept")
  end
end

--- Decline the pending approval
function M.decline(opts)
  opts = opts or {}
  if opts.first then
    trigger_approval(1, "decline")
  else
    trigger_pending_approval("decline")
  end
end

--- Show preview for the pending approval
function M.preview(opts)
  opts = opts or {}
  if opts.first then
    trigger_approval(1, "preview")
  else
    trigger_pending_approval("preview")
  end
end

--- Get the count of pending approvals
--- @return integer
function M.count()
  return #pending_approvals
end

return M
