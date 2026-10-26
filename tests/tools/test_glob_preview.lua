local eq = MiniTest.expect.equality
local glob = require("sia.tools.glob")
local utils = require("sia.utils")
local output = require("sia.tool_output")
local system, limit_files = vim.system, utils.limit_files

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.system, utils.limit_files = system, limit_files
    end,
  },
})

local function run(files, args, failure)
  vim.system = function(command, _, callback)
    eq("fd", command[1])
    callback({
      code = failure and 2 or 0,
      stdout = table.concat(files, "\0"),
      stderr = failure,
    })
  end
  -- Preserve a known newest-first selection independently of preview sorting.
  utils.limit_files = function(items, opts)
    return vim.list_slice(items, 1, opts.max_count), #items
  end
  local result
  glob.implementation.execute(args or {}, function(res)
    result = res
  end, {
    conversation = { approved_tools = { glob = true } },
  })
  assert(result, "glob did not finish")
  return result
end

T["preview groups and sorts directories and names without reordering model output"] = function()
  local files = { "src/z.lua", "tests/b.lua", "root.lua", "src/a.lua" }
  local result = run(files, { pattern = "*.lua" })
  eq(
    { text = "./\n  root.lua\n\nsrc/\n  a.lua\n  z.lua\n\ntests/\n  b.lua", ft = "text" },
    result.preview
  )
  eq(
    "Files matching pattern `*.lua` (max 100, newest first):\n"
      .. table.concat(files, "\n"),
    result.content
  )
  output.complete(result)
  eq("text", result.summary.detail.ft)
end

T["directory entries retain their trailing slash"] = function()
  local result = run({ "src/", "src/nested/", "src/nested/file.lua" })
  eq("./\n  src/\n\nsrc/\n  nested/\n\nsrc/nested/\n  file.lua", result.preview.text)
end

T["no matches reports model content without a summary or preview"] = function()
  local result = run({}, { pattern = "*.missing" })
  output.complete(result)
  eq(nil, result.summary)
  eq("No files found matching pattern: *.missing", result.content)
  eq(nil, result.preview)
end

T["limited preview omits explanatory and more-files lines"] = function()
  local files = {}
  for i = 1, 101 do
    files[i] = string.format("src/%03d.lua", i)
  end
  local result = run(files)
  eq(101, #vim.split(result.preview.text, "\n")) -- Heading plus 100 selected files.
  eq(nil, result.preview.text:find("more files", 1, true))
  eq(nil, result.preview.text:find("Showing", 1, true))
  eq(nil, result.preview.text:find("101.lua", 1, true))
  eq(true, result.content:find("Showing 100 of 101 files", 1, true) ~= nil)
end

T["nonzero exit is a failure with its actual error"] = function()
  local result = run({}, { path = "missing" }, "fd: missing: No such directory\n")
  eq(nil, result.summary)
  eq(true, result.ephemeral)
  eq("Error: fd: missing: No such directory", result.content)
  eq(nil, result.content:find("No files found", 1, true))
  output.complete(result)
  eq(nil, result.summary)
  eq(nil, result.preview)
end

T["missing executable is reported rather than thrown"] = function()
  vim.system = function()
    error("fd: executable not found")
  end
  local result
  glob.implementation.execute({}, function(res)
    result = res
  end, {
    conversation = { approved_tools = { glob = true } },
  })
  eq(nil, result.summary)
  eq(true, result.ephemeral)
  eq(true, result.content:find("executable not found", 1, true) ~= nil)
end

return T
