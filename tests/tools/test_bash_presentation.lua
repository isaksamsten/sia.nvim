local eq = MiniTest.expect.equality
local bash = require("sia.tools.bash")
local output = require("sia.tool_output")
local T = MiniTest.new_set()

local function run(args, options)
  options = options or {}
  local proc = { id = 1, kind = options.finished and "finished" or "running",
    command = "make test", outcome = "completed", code = 0,
    file = { stdout = "", stderr = "" } }
  local conversation = {
    approved_tools = { bash = true },
    has_pending_user_messages = function() return options.pause or false end,
    process_runtime = {
      get = function(_, id) return id == 1 and proc or nil end,
      get_output = function() return { stdout = options.stdout or "", stderr = options.stderr or "" } end,
      pwd = function() return "/tmp" end,
      stop = function(_, id) return id == 1 and (options.stop or "stopped") or "not_found" end,
    },
  }
  local result
  bash.implementation.execute(args, function(res) result = res end, { conversation = conversation })
  assert(result, "bash did not finish")
  output.complete(result)
  return result
end

T["polling and reading output stay hidden while retaining model content"] = function()
  for _, action in ipairs({ "status", "view", "wait" }) do
    local result = run({ action = action, id = 1, wait_timeout = 1 }, { stdout = "hello" })
    eq(false, result.summary)
    eq(nil, result.preview)
    eq(true, result.content:find("hello", 1, true) ~= nil)
  end
end

T["completion without output has no details"] = function()
  local result = run({ action = "wait", id = 1 }, { finished = true })
  eq("Ran `make test`", result.summary.header)
  eq(nil, result.summary.detail)
  eq(true, result.content:find("Command completed successfully", 1, true) ~= nil)
end

T["finished status surfaces the outcome and output"] = function()
  local result = run({ action = "status", id = 1 }, { finished = true, stdout = "done", stderr = "warning" })
  eq("Ran `make test`", result.summary.header)
  eq("done\nwarning", result.summary.detail.text)
end

T["pause and stop details contain only output"] = function()
  for _, case in ipairs({
    { action = "wait", options = { pause = true }, header = "Paused `make test`" },
    { action = "kill", options = { stop = "stop_requested" }, header = "Requested stop for `make test`" },
    { action = "kill", options = { stop = "already_finished" }, header = "Already finished `make test`" },
    { action = "kill", options = {}, header = "Stopped `make test`" },
  }) do
    case.options.stdout = "hello"
    local result = run({ action = case.action, id = 1 }, case.options)
    eq(case.header, result.summary.header)
    eq("hello", result.summary.detail.text)
  end
end

T["invalid process operations remain visible"] = function()
  for _, action in ipairs({ "status", "view", "wait", "kill" }) do
    for _, id in ipairs({ 0, 2 }) do
      local result = run({ action = action, id = id ~= 0 and id or nil })
      eq("table", type(result.summary))
      eq(true, result.summary.header:find("Failed", 1, true) ~= nil)
      eq(true, result.summary.detail.text:find("Error:", 1, true) ~= nil)
    end
  end
end

return T
