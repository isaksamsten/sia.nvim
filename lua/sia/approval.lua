--- Module for handling async approval requests
--- This module manages pending approval prompts that can be shown asynchronously
local M = {}

--- Global state for managing pending approvals
--- @class sia.PendingApproval
--- @field conversation sia.Conversation
--- @field prompt string
--- @field on_ready fun(choice:"accept"|"decline"|"prompt"|"preview")
--- @field clear_preview fun()?

--- @type sia.PendingApproval[]
local pending_approvals = {}

--- Get the appropriate message based on pending approvals
--- @return string[]?
local function get_notification_message()
  if #pending_approvals == 0 then
    return nil
  elseif #pending_approvals == 1 then
    local approval = pending_approvals[1]
    return vim.split(
      string.format("󱇥 [%s] %s", approval.conversation.name, approval.prompt),
      "\n"
    )
  else
    local conversations = {}
    for _, approval in ipairs(pending_approvals) do
      conversations[approval.conversation.name] = true
    end
    local conv_count = vim.tbl_count(conversations)

    return {
      string.format(
        "󱇥 %d approval%s pending from %d conversation%s",
        #pending_approvals,
        #pending_approvals > 1 and "s" or "",
        conv_count,
        conv_count > 1 and "s" or ""
      ),
    }
  end
end

--- Default notifier using floating window
--- @return sia.ApprovalNotifier
function M.floating_notifier()
  local notification_win = nil
  local notification_buf = nil
  local resize_autocmd = nil

  --- @type sia.ApprovalNotifier
  return {
    show = function(msg)
      if not notification_buf or not vim.api.nvim_buf_is_valid(notification_buf) then
        notification_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[notification_buf].bufhidden = "wipe"
      end

      vim.api.nvim_buf_set_lines(notification_buf, 0, -1, false, msg)

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

        vim.wo[notification_win].winhighlight = "Normal:SiaApproval"

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
    show = function(msg)
      if not notification_win or not vim.api.nvim_win_is_valid(notification_win) then
        notification_win = vim.api.nvim_get_current_win()
        old_winbar = vim.wo[notification_win].winbar
      end
      vim.wo[notification_win].winbar = msg[1]
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
--- @param opts { on_accept: fun(), on_cancel: fun(), on_prompt:fun(), on_preview: fun():fun() }
function M.show(conversation, prompt, opts)
  local approval_config = require("sia.config").options.defaults.ui.approval
  local notifier = (approval_config.async and approval_config.async.notifier)
    or default_notifier

  local approval = {
    conversation = conversation,
    prompt = prompt,
  }

  approval.on_ready = function(choice)
    if choice ~= "preview" then
      for i, a in ipairs(pending_approvals) do
        if a == approval then
          table.remove(pending_approvals, i)
          break
        end
      end

      local msg = get_notification_message()
      if msg then
        notifier.show(msg)
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
    elseif choice == "preview" then
      approval.clear_preview = opts.on_preview()
    else
      opts.on_cancel()
    end
  end

  table.insert(pending_approvals, approval)

  local msg = get_notification_message()
  if msg then
    notifier.show(msg)
  end
end

--- Internal helper to trigger an approval with a specific choice
--- @param choice "accept"|"decline"|"prompt"|"preview"
local function trigger_pending_approval(choice)
  if #pending_approvals == 0 then
    vim.notify("Sia: No pending approvals", vim.log.levels.INFO)
    return
  end

  local function trigger_approval(idx)
    if pending_approvals[idx] and pending_approvals[idx].on_ready then
      pending_approvals[idx].on_ready(choice)
    end
  end

  if #pending_approvals == 1 then
    trigger_approval(1)
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
        trigger_approval(idx)
      end
    end)
  end
end

--- Show the approval prompt to the user
function M.prompt()
  trigger_pending_approval("prompt")
end

--- Accept the pending approval
function M.accept()
  trigger_pending_approval("accept")
end

--- Decline the pending approval
function M.decline()
  trigger_pending_approval("decline")
end

--- Show preview for the pending approval
function M.preview()
  trigger_pending_approval("preview")
end

--- Get the count of pending approvals
--- @return integer
function M.count()
  return #pending_approvals
end

return M
