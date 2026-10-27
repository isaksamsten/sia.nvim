local M = {}

local function notify(message, level)
  vim.notify("sia: " .. message, level or vim.log.levels.WARN)
end

local function focus_open(id)
  local chat = require("sia.strategy.chat")
  for _, item in ipairs(chat.all()) do
    local strategy = chat.by_buf(item.buf)
    if strategy.conversation.uuid == id then
      local windows = vim.fn.win_findbuf(item.buf)
      if #windows > 0 then
        vim.api.nvim_set_current_win(windows[1])
      else
        vim.cmd("sbuffer " .. item.buf)
      end
      return true
    end
  end
  return false
end

local function open(id, workspace)
  if focus_open(id) then
    return
  end
  local conversation
  local context = vim.api.nvim_create_buf(false, true)
  vim.bo[context].buftype = ""
  vim.api.nvim_buf_set_name(
    context,
    vim.fs.joinpath(workspace, ".sia-history-" .. context)
  )
  local ok, err = pcall(function()
    local options
    vim.api.nvim_buf_call(context, function()
      local config = require("sia.config")
      local snapshot, load_err = require("sia.persistence").load(id)
      assert(snapshot, load_err)
      local models = require("sia.model")
      local resolved, model = pcall(models.resolve, snapshot.model)
      if not resolved then
        model = models.resolve()
        notify("Saved model is unavailable. Using " .. model.name)
      end
      local action = config.options.settings.actions.chat
      local tools, approved
      if action.tools then
        tools, approved = action.tools(model)
      end
      local restore_err
      conversation, restore_err = require("sia.persistence").restore(id, {
        workspace = workspace,
        model = model,
        tools = tools,
        approved_tools = approved,
        modes = action.modes,
      })
      assert(conversation, restore_err)
      conversation.project_mcp = true
      options = vim.tbl_deep_extend(
        "force",
        config.options.settings.chat or {},
        action.chat or {}
      )
    end)
    local strategy =
      require("sia.strategy.chat").new(conversation, options, { render_all = true })
    vim.api.nvim_win_call(strategy:get_win(), function()
      vim.cmd("lcd " .. vim.fn.fnameescape(workspace))
    end)
  end)
  vim.api.nvim_buf_delete(context, { force = true })
  if not ok then
    if conversation then
      local chat = require("sia.strategy.chat")
      for _, item in ipairs(chat.all()) do
        if chat.by_buf(item.buf).conversation == conversation then
          chat.remove(item.buf, false)
        end
      end
      conversation:destroy()
    end
    notify("Unable to restore conversation: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- @param id string
function M.resume(id)
  if focus_open(id) then
    return
  end
  local snapshot, err = require("sia.persistence").load(id)
  if not snapshot then
    notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(snapshot.workspace) == 1 then
    open(id, snapshot.workspace)
    return
  end
  local cwd = vim.fn.getcwd()
  vim.ui.select({ "Cancel", "Use current directory" }, {
    prompt = "Saved workspace is missing: "
      .. snapshot.workspace
      .. ". Use "
      .. cwd
      .. "?",
  }, function(choice)
    if choice == "Use current directory" then
      open(id, cwd)
    end
  end)
end

--- @param args {args:string, bang:boolean?}
function M.run(args)
  if args.args ~= "" then
    M.resume(args.args)
    return
  end
  local history = require("sia.persistence").list()
  if not args.bang then
    local function normalized(path)
      return vim.fs.normalize(
        vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
      )
    end
    local workspace = normalized(vim.fn.getcwd())
    history = vim.tbl_filter(function(item)
      return normalized(item.workspace) == workspace
    end, history)
  end
  if #history == 0 then
    notify("No saved conversations", vim.log.levels.INFO)
    return
  end
  vim.ui.select(history, {
    prompt = "Conversation history",
    format_item = function(item)
      return string.format(
        "%s | %s | %s",
        item.title,
        os.date("%Y-%m-%d %H:%M", item.updated_at),
        item.workspace
      )
    end,
  }, function(item)
    if item then
      M.resume(item.id)
    end
  end)
end

--- @param lead string
--- @return string[]
function M.complete(lead)
  local ids = {}
  for _, item in ipairs(require("sia.persistence").list()) do
    if vim.startswith(item.id, lead) then
      ids[#ids + 1] = item.id
    end
  end
  return ids
end

return M
