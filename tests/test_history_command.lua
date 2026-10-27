local eq = MiniTest.expect.equality
local persistence = require("sia.persistence")
local command = require("sia.history_command")
local chat = require("sia.strategy.chat")
local root, stdpath, select_ui, notify, cwd, notices
local original_tab, buffers

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      root = vim.fn.tempname()
      stdpath, select_ui, notify = vim.fn.stdpath, vim.ui.select, vim.notify
      cwd = vim.fn.getcwd()
      original_tab = vim.api.nvim_get_current_tabpage()
      buffers = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        buffers[buf] = true
      end
      vim.cmd("tabnew")
      notices = {}
      vim.fn.stdpath = function(kind)
        return kind == "data" and root or stdpath(kind)
      end
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
    end,
    post_case = function()
      for _, item in ipairs(chat.all()) do
        chat.remove(item.buf, true)
        if vim.api.nvim_buf_is_valid(item.buf) then
          vim.api.nvim_buf_delete(item.buf, { force = true })
        end
      end
      vim.cmd("tabclose!")
      vim.api.nvim_set_current_tabpage(original_tab)
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if not buffers[buf] then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      vim.fn.stdpath, vim.ui.select, vim.notify = stdpath, select_ui, notify
      vim.cmd("cd " .. vim.fn.fnameescape(cwd))
      vim.fn.delete(root, "rf")
    end,
  },
})

local function save(workspace)
  local conv = require("sia.conversation").new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
    workspace = workspace or cwd,
  })
  conv.name = "Saved conversation"
  conv:add_system_message("Original system prompt")
  conv:add_user_message("Hello")
  conv:add_assistant_message("turn", "Answer")
  assert(persistence.save(conv))
  local id = conv.uuid
  conv:destroy()
  return id
end

T["picker uses vim.ui.select and supports cancellation"] = function()
  local id = save()
  local called = false
  vim.ui.select = function(items, opts, callback)
    called = true
    eq(#items, 1)
    eq(items[1].id, id)
    local label = opts.format_item(items[1])
    eq(label:find("Saved conversation", 1, true) ~= nil, true)
    eq(label:find(cwd, 1, true) ~= nil, true)
    callback(nil)
  end
  command.run({ args = "" })
  eq(called, true)
  eq(chat.count(), 0)
end

T["picker filters workspace unless bang is given"] = function()
  local local_id = save(cwd .. "/.")
  local other_id = save(root .. "/another-project")
  vim.ui.select = function(items, _, callback)
    eq(#items, 1)
    eq(items[1].id, local_id)
    callback(nil)
  end
  command.run({ args = "" })
  vim.ui.select = function(items, _, callback)
    eq(#items, 2)
    local ids = { items[1].id, items[2].id }
    eq(vim.tbl_contains(ids, local_id), true)
    eq(vim.tbl_contains(ids, other_id), true)
    callback(nil)
  end
  command.run({ args = "", bang = true })
  eq(vim.tbl_contains(command.complete(other_id:sub(1, 8)), other_id), true)
end

T["explicit UUID bypasses workspace filtering"] = function()
  local id = save(root .. "/missing-project")
  local called = false
  vim.ui.select = function(items, opts, callback)
    called = true
    eq(items, { "Cancel", "Use current directory" })
    eq(opts.prompt:find("missing-project", 1, true) ~= nil, true)
    callback(nil)
  end
  command.run({ args = id })
  eq(called, true)
end

T["selection restores with current tools and does not send a request"] = function()
  local id = save()
  local assistant = require("sia.assistant")
  local execute = assistant.execute_strategy
  assistant.execute_strategy = function()
    error("Must not start a request")
  end
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  local ok, err = pcall(command.run, { args = "" })
  assistant.execute_strategy = execute
  assert(ok, err)
  eq(notices, {})
  eq(chat.count(), 1)
  local strategy = chat.last()
  eq(strategy.conversation.uuid, id)
  eq(strategy.conversation.name, "Saved conversation")
  eq(strategy.conversation.entries[1].content, "Original system prompt")
  eq(#strategy.conversation.tool_definitions > 0, true)
  eq(strategy.conversation.project_mcp, true)
  eq(strategy.is_busy == true, false)
  eq(vim.fn.getcwd(), cwd)
end

T["direct resume focuses an existing visible or hidden chat"] = function()
  local id = save()
  command.run({ args = id })
  eq(notices, {})
  local strategy = chat.last()
  local buf = strategy.buf
  vim.cmd("new")
  command.resume(id)
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(chat.count(), 1)
  vim.cmd("enew")
  eq(vim.fn.bufwinid(buf), -1)
  command.resume(id)
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(chat.count(), 1)
end

T["missing workspace asks before falling back to the current directory"] = function()
  local id = save(root .. "/missing")
  vim.ui.select = function(items, opts, callback)
    eq(items, { "Cancel", "Use current directory" })
    eq(opts.prompt:find("missing", 1, true) ~= nil, true)
    callback("Cancel")
  end
  command.resume(id)
  eq(chat.count(), 0)
  vim.ui.select = function(_, _, callback)
    callback("Use current directory")
  end
  command.resume(id)
  eq(notices, {})
  eq(chat.last().conversation.workspace, cwd)
end

T["missing model falls back with a notification"] = function()
  local id = save()
  local path = vim.fs.joinpath(root, "sia", "conversations", id .. ".json")
  local snapshot = assert(persistence.load(id))
  snapshot.model = "nonexistent/no-model"
  vim.fn.writefile({ vim.json.encode(snapshot) }, path)
  command.resume(id)
  eq(chat.count(), 1)
  eq(#notices, 1)
  eq(notices[1]:find("Saved model is unavailable", 1, true) ~= nil, true)
end

T["completion offers matching IDs and empty history is reported"] = function()
  command.run({ args = "" })
  eq(chat.count(), 0)
  eq(#notices, 1)
  local id = save()
  eq(command.complete(id:sub(1, 8)), { id })
  eq(command.complete("not-an-id"), {})
end

T["invalid IDs report an error without opening a chat"] = function()
  command.run({ args = "../escape" })
  eq(chat.count(), 0)
  eq(#notices, 1)
end

T["SiaHistory is registered with optional UUID argument"] = function()
  dofile("plugin/sia.lua")
  local commands = vim.api.nvim_get_commands({})
  eq(commands.SiaHistory.nargs, "?")
  local id = save()
  vim.cmd("SiaHistory " .. id)
  eq(chat.last().conversation.uuid, id)
end

T["saved workspace supplies configuration and window-local cwd"] = function()
  local workspace = root .. "/project"
  vim.fn.mkdir(workspace .. "/.sia", "p")
  vim.fn.writefile({ "{}" }, workspace .. "/.sia/config.json")
  local id = save(workspace)
  local original_window = vim.api.nvim_get_current_win()
  local action = require("sia.config")._raw_options.settings.actions.chat
  local tools, resolved_path = action.tools
  action.tools = function(model)
    resolved_path = require("sia.config").get_local_config_path()
    return tools(model)
  end
  local ok, err = pcall(command.resume, id)
  action.tools = tools
  assert(ok, err)
  eq(notices, {})
  eq(resolved_path, workspace .. "/.sia/config.json")
  eq(chat.last().conversation.workspace, workspace)
  eq(vim.fn.getcwd(), workspace)
  eq(vim.fn.getcwd(vim.fn.win_id2win(original_window)), cwd)
end

return T
