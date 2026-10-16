local hashline = require("sia.hashline")
local eq = MiniTest.expect.equality
local path, buf, conversation, tag, runner, destination_path, destination_buf
local next_id = 0
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      destination_path, destination_buf = nil, nil
      next_id = next_id + 1
      conversation = {
        id = "clipboard-tool-test-" .. next_id,
        approved_tools = { edit = true },
        tracker = {
          suppress = function(_, _, fn)
            fn()
          end,
        },
      }
      path = vim.fn.tempname()
      vim.fn.writefile({ "one", "two", "three" }, path)
      buf = require("sia.utils").ensure_file_is_loaded(path, { listed = true })
      tag = hashline
        .view(conversation, path, { "one", "two", "three" }, 1, 3)[1]
        :match("#(%x+)%]")
      local tool_utils = require("sia.tools.utils")
      local original = tool_utils.new_tool
      tool_utils.new_tool = function(_, execute)
        return execute
      end
      local ok, result = pcall(dofile, "lua/sia/tools/edit/hashline.lua")
      tool_utils.new_tool = original
      assert(ok, result)
      runner = result
    end,
    post_case = function()
      hashline.clear_clipboard(conversation.id)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.fn.delete(path)
      if destination_buf and vim.api.nvim_buf_is_valid(destination_buf) then
        vim.api.nvim_buf_delete(destination_buf, { force = true })
      end
      if destination_path then
        vim.fn.delete(destination_path)
      end
    end,
  },
})
local function stage()
  local pending, result
  runner(
    { target_file = path, tag = tag, edits = "CUT 2.=2 @part" },
    conversation,
    function(res)
      result = res
    end,
    {
      user_input = function(_, opts)
        pending = opts
      end,
    }
  )
  return pending, function()
    return result
  end
end
local function paste()
  local lines = { "destination" }
  local snapshot =
    hashline.view(conversation, "/destination", lines, 1, 1)[1]:match("#(%x+)%]")
  return hashline.apply(conversation, "/destination", lines, snapshot, "PUT >$ @part")
end
T["register is published only after successful approval and save"] = function()
  local pending, result = stage()
  eq(paste(), nil)
  pending.on_accept()
  eq(result().ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "three" })
  eq(paste(), { "destination", "two" })
end
T["stale approval never publishes captured text"] = function()
  local pending, result = stage()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user change" })
  pending.on_accept()
  eq(result().ephemeral, true)
  eq(paste(), nil)
end
T["failed save never publishes captured text"] = function()
  local pending, result = stage()
  vim.bo[buf].buftype = "nofile"
  pending.on_accept()
  eq(result().ephemeral, true)
  eq(paste(), nil)
  eq(vim.fn.readfile(path), { "one", "two", "three" })
end
T["denied edits never publish captured text"] = function()
  conversation.active_mode = require("sia.permissions").create_active_mode("plan", {
    permissions = { deny = { "edit" } },
  })
  local result
  require("sia.tools.edit.hashline").implementation.execute(
    { target_file = path, tag = tag, edits = "CUT 2.=2 @part" },
    function(res)
      result = res
    end,
    { conversation = conversation }
  )
  eq(type(result.content), "table")
  eq(paste(), nil)
  eq(vim.fn.readfile(path), { "one", "two", "three" })
end
T["two edit calls move captured lines across files"] = function()
  local pending = stage()
  pending.on_accept()
  destination_path = vim.fn.tempname()
  vim.fn.writefile({ "destination" }, destination_path)
  destination_buf =
    require("sia.utils").ensure_file_is_loaded(destination_path, { listed = true })
  local owner = { id = conversation.id, tracker = conversation.tracker }
  local snapshot =
    hashline.view(owner, destination_path, { "destination" }, 1, 1)[1]:match("#(%x+)%]")
  local result
  runner(
    { target_file = destination_path, tag = snapshot, edits = "PUT >$ @part" },
    owner,
    function(res)
      result = res
    end,
    {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    }
  )
  eq(result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "three" })
  eq(vim.fn.readfile(destination_path), { "destination", "two" })
end
T["edit response supports another edit without viewing again"] = function()
  local pending, result = stage()
  pending.on_accept()
  local content = result().content
  local fresh_tag = content:match("#(%x+)%]")
  eq(type(fresh_tag), "string")
  eq(content:find("2:three", 1, true) ~= nil, true)
  local next_result
  runner(
    { target_file = path, tag = fresh_tag, edits = "PUT <2:\n+inserted" },
    conversation,
    function(res)
      next_result = res
    end,
    {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    }
  )
  eq(next_result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "inserted", "three" })
  eq(next_result.content:find("2:inserted", 1, true) ~= nil, true)
end
return T
