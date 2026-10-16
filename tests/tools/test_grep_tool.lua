local eq = MiniTest.expect.equality
local grep = require("sia.tools.grep")
local output = require("sia.tool_output")
local system = vim.system

local T = MiniTest.new_set({ hooks = {
  post_case = function() vim.system = system end,
} })

local function run(args, stdout)
  if stdout then
    vim.system = function(command, _, callback)
      eq("rg", command[1])
      callback({ code = stdout == "" and 1 or 0, stdout = stdout })
    end
  end
  local result
  grep.implementation.execute(args, function(res) result = res end, {
    conversation = { approved_tools = { grep = true } },
  })
  vim.wait(2000, function() return result ~= nil end)
  assert(result, "grep did not finish")
  return result
end

T["groups content matches by file and orders lines within each group"] = function()
  local result = run({ pattern = "needle" },
    "a.lua:8:1:last needle\nb.lua:2:4:other needle\na.lua:3:2:first needle\n")
  eq("text", result.preview.ft)
  eq(true, result.preview.text:find("a.lua\n  3: first needle\n  8: last needle", 1, true) ~= nil)
  eq(true, result.preview.text:find("b.lua\n  2: other needle", 1, true) ~= nil)
  local _, occurrences = result.preview.text:gsub("a%.lua", "")
  eq(1, occurrences)
  eq(true, result.summary:find("Found 3 matches in 2 files", 1, true) ~= nil)
  -- The model retains its original header and path:line:column result format.
  eq(true, result.content:find("The following search results were returned (3 matches found)", 1, true) ~= nil)
  eq(true, result.content:find("a.lua:3:2:first needle", 1, true) ~= nil)
  output.complete(result)
  eq("text", result.summary.detail.ft)
end

T["file mode previews only paths"] = function()
  local result = run({ pattern = "needle", output_mode = "files_with_matches" }, "a.lua\nb.lua\n")
  eq("a.lua\nb.lua", result.preview.text)
  eq("Files containing matches for `needle` (2 files):\na.lua\nb.lua", result.content)
end

T["count mode previews only file counts"] = function()
  local result = run({ pattern = "needle", output_mode = "count" }, "b.lua:1\na.lua:3\n")
  eq("a.lua: 3\nb.lua: 1", result.preview.text)
  eq("Match counts for `needle` (total: 4 matches in 2 files):\na.lua: 3\nb.lua: 1", result.content)
end

for _, mode in ipairs({ "content", "files_with_matches", "count" }) do
  T["no matches has no preview in " .. mode .. " mode"] = function()
    local result = run({ pattern = "needle", output_mode = mode }, "")
    eq(nil, result.preview)
    output.complete(result)
    eq("string", type(result.summary))
  end
end

T["single-file output uses the requested path as its heading"] = function()
  local path = "lua/sia/tools/grep.lua"
  local result = run({ pattern = "needle", path = path }, "12:4:some needle\n")
  eq(path .. "\n  12: some needle", result.preview.text)
  eq(true, result.summary:find("Found 1 match in 1 file", 1, true) ~= nil)
end

T["limited results disclose omitted matches"] = function()
  local lines = {}
  for i = 1, 101 do
    lines[i] = string.format("a.lua:%d:1:needle", i)
  end
  local result = run({ pattern = "needle" }, table.concat(lines, "\n"))
  eq(102, #vim.split(result.preview.text, "\n")) -- File, 100 matches, truncation notice.
  eq(true, result.preview.text:find("… 1 more match", 1, true) ~= nil)
  eq(true, result.content:find("showing 100 most recent by file mtime", 1, true) ~= nil)
end

T["real ripgrep result passes through the shared preview pipeline"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "first needle", "unrelated", "second needle" }, path)
  local ok, result = pcall(run, { pattern = "needle", path = path })
  vim.fn.delete(path)
  assert(ok, result)
  output.complete(result)
  eq({ text = path .. "\n  1: first needle\n  3: second needle", ft = "text" }, result.summary.detail)
end

return T
