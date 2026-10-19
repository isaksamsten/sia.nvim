local eq = MiniTest.expect.equality
local grep = require("sia.tools.grep")
local hashline = require("sia.hashline")
local system = vim.system
local dir, conversation
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      conversation = require("sia.conversation").new({
        workspace = dir,
        temporary = true,
        model = require("sia.model").resolve("openai/gpt-4.1"),
        approved_tools = { grep = true },
        tools = { grep },
      })
    end,
    post_case = function()
      vim.system = system
      conversation.tracker:destroy()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf):sub(1, #dir) == dir then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      vim.fn.delete(dir, "rf")
    end,
  },
})
local function file(name, lines)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end
local function run(args)
  local result
  grep.implementation.execute(args, function(res)
    result = res
  end, { conversation = conversation })
  vim.wait(5000, function()
    return result ~= nil
  end)
  assert(result, "grep did not finish")
  if not result.ephemeral then
    eq(
      string.format("Searched for `%s` in `%s`", args.pattern, args.path or "."),
      result.summary
    )
  end
  return result
end
local function snapshot(result)
  return result.content:match("#(%x+)%]")
end
local function mock_match(name, row, text)
  vim.system = function(_, _, callback)
    callback({
      code = 0,
      stdout = vim.json.encode({
        type = "match",
        data = {
          path = { text = name },
          line_number = row,
          lines = { text = text .. "\n" },
        },
      }) .. "\n",
    })
  end
end
T["search context is directly editable and omitted lines remain unseen"] = function()
  local lines = {}
  for i = 1, 15 do
    lines[i] = "line " .. i
  end
  lines[5] = "needle"
  local path = file("source.lua", lines)
  local result = run({ pattern = "needle", path = "." })
  eq(type(snapshot(result)), "string")
  eq(true, result.content:find("4:line 4\n5:needle\n6:line 6", 1, true) ~= nil)
  local changed, err =
    hashline.apply(conversation, path, lines, snapshot(result), "PUT 5.=5:\n+updated")
  assert(changed, err)
  eq(changed[5], "updated")
  eq(hashline.apply(conversation, path, lines, snapshot(result), "CUT 10.=10"), nil)
end
T["unopened search results do not create buffers or trigger file autocommands"] = function()
  local path = file("unopened.lua", { "needle", "tail" })
  local events = {}
  local autocmd = vim.api.nvim_create_autocmd(
    { "BufReadPost", "BufEnter", "FileType" },
    {
      callback = function(event)
        events[#events + 1] = event.event
      end,
    }
  )
  local ok, result = pcall(run, { pattern = "needle", path = "unopened.lua" })
  vim.api.nvim_del_autocmd(autocmd)
  assert(ok, result)
  eq(type(snapshot(result)), "string")
  eq(vim.fn.bufnr(path), -1)
  eq(events, {})
end
T["DOS disk snapshots match buffer text when opened for editing"] = function()
  local path = file("dos.lua", { "needle\r", "tail\r" })
  local result = run({ pattern = "needle", path = "dos.lua" })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local changed, err =
    hashline.apply(conversation, path, lines, snapshot(result), "CUT 1.=1")
  assert(changed, err)
  eq(changed, { "tail" })
end
T["unsaved buffers supply context without being reloaded"] = function()
  local path = file("source.lua", { "disk before", "needle", "disk after" })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved before" })
  local result = run({ pattern = "needle", path = "source.lua" })
  eq(true, result.content:find("1:unsaved before", 1, true) ~= nil)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { "unsaved before" })
  eq(vim.bo[buf].modified, true)
  eq(vim.fn.readfile(path)[1], "disk before")
end
T["disk matches that moved in an unsaved buffer are omitted"] = function()
  local path = file("source.lua", { "needle", "tail" })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
  local result = run({ pattern = "needle", path = "source.lua" })
  eq(snapshot(result), nil)
  eq(true, result.content:find("buffer differs", 1, true) ~= nil)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "inserted", "needle", "tail" })
end
T["unmodified buffers refresh before emitting tagged context"] = function()
  local path = file("source.lua", { "old" })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  vim.bo[buf].autoread = false
  vim.fn.writefile({ "new needle content", "new tail" }, path)
  local result = run({ pattern = "needle", path = "source.lua" })
  eq(type(snapshot(result)), "string")
  eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    { "new needle content", "new tail" }
  )
  eq(vim.bo[buf].autoread, false)
end
T["changes between rg and buffer loading are not marked seen"] = function()
  file("source.lua", { "different current text" })
  mock_match("source.lua", 1, "old needle")
  local result = run({ pattern = "needle" })
  eq(snapshot(result), nil)
  eq(true, result.content:find("Omitted 1", 1, true) ~= nil)
end
T["search results stay in history while edits against changed buffers are rejected"] = function()
  local path = file("first.lua", { "needle one" })
  file("second.lua", { "needle two" })
  local result = run({ pattern = "needle", path = "." })
  eq(result.region, nil)
  conversation:add_tool_message("search-turn", {
    key = "search",
    id = "search",
    call_id = "search",
    type = "function",
    name = "grep",
    arguments = "{}",
  }, result.content, { region = result.region })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user change" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(hashline.apply(conversation, path, lines, snapshot(result), "CUT 1.=1"), nil)
  local messages = conversation:serialize()
  eq(messages[#messages].content, result.content)
end
T["truncated buffer rows cannot be edited"] = function()
  local lines = { "needle " .. string.rep("x", 300) }
  local path = file("source.lua", lines)
  local result = run({ pattern = "needle", path = "source.lua" })
  eq(true, result.content:find("[TRUNCATED]", 1, true) ~= nil)
  eq(hashline.apply(conversation, path, lines, snapshot(result), "CUT 1.=1"), nil)
end
T["JSON search handles colon paths and multiline matches"] = function()
  local path = file("with:colon.lua", { "start", "needle", "end" })
  local result =
    run({ pattern = "start\nneedle", path = "with:colon.lua", multiline = true })
  local changed, err = hashline.apply(
    conversation,
    path,
    vim.fn.readfile(path),
    snapshot(result),
    "PUT 1.=2:\n+replacement"
  )
  assert(changed, err)
  eq(changed, { "replacement", "end" })
end
T["no matches have no preview"] = function()
  file("source.lua", { "other" })
  for _, mode in ipairs({ "content", "files_with_matches", "count" }) do
    local result = run({ pattern = "needle", path = ".", output_mode = mode })
    eq(result.preview, nil)
  end
end
T["rg errors are reported rather than mistaken for no matches"] = function()
  local result = run({ pattern = "needle", path = "missing" })
  eq(result.ephemeral, true)
  eq(true, result.content:find("Search failed", 1, true) ~= nil)
end
T["file and count modes remain display only"] = function()
  file("source.lua", { "needle", "needle" })
  local result =
    run({ pattern = "needle", path = ".", output_mode = "files_with_matches" })
  eq(true, result.content:find("source.lua", 1, true) ~= nil)
  eq(result.region, nil)
  vim.system = function(_, _, callback)
    callback({ code = 0, stdout = "source.lua:2\n" })
  end
  result = run({ pattern = "needle", output_mode = "count" })
  eq(true, result.content:find("total: 2 matches in 1 files", 1, true) ~= nil)
  eq(result.region, nil)
end
T["single-file count mode resolves paths inside the conversation workspace"] = function()
  file("source.lua", { "needle", "needle" })
  local result = run({ pattern = "needle", path = "source.lua", output_mode = "count" })
  eq(true, result.content:find("source.lua: 2", 1, true) ~= nil)
end
T["changed context outside the disk match comes from the buffer"] = function()
  local path = file("source.lua", { "before", "needle", "after" })
  local buf = require("sia.utils").ensure_file_is_loaded(path)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "unsaved after" })
  local result = run({ pattern = "needle", path = "source.lua" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local changed, err = hashline.apply(
    conversation,
    path,
    lines,
    snapshot(result),
    "PUT 3.=3:\n+edited context"
  )
  assert(changed, err)
  eq(changed[3], "edited context")
end
T["context caps leave undisplayed rows unseen"] = function()
  local lines = {}
  for i = 1, 300 do
    lines[i] = "needle " .. i
  end
  local path = file("source.lua", lines)
  local result = run({ pattern = "needle", path = "source.lua" })
  eq(true, result.content:find("Results limited", 1, true) ~= nil)
  eq(hashline.apply(conversation, path, lines, snapshot(result), "CUT 300.=300"), nil)
end
return T
