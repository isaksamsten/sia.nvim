local eq = MiniTest.expect.equality
local debug_tool = require("sia.tools.debug")
local dap, session, requests, conversation, dir, old_dap, old_breakpoints
local prompts, answer, input, confirm_config
local confirm_show

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      old_dap = package.loaded.dap
      old_breakpoints = package.loaded["dap.breakpoints"]
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "one", "two" }, dir .. "/source.lua")
      requests = {}
      prompts, answer = {}, "y"
      input = vim.ui.input
      confirm_show = require("sia.ui.confirm").show
      confirm_config = vim.deepcopy(require("sia.config").options.settings.ui.confirm)
      local confirm = require("sia.config").options.settings.ui.confirm
      confirm.use_vim_ui, confirm.show_preview = true, false
      confirm.async.enable = false
      vim.ui.input = function(opts, callback)
        prompts[#prompts + 1] = opts.prompt
        if type(answer) == "function" then
          answer(callback)
        else
          callback(answer)
        end
      end
      session = {
        id = 1,
        config = { name = "test", type = "mock" },
        initialized = true,
        capabilities = { supportsVariablePaging = true },
        stopped_thread_id = 7,
        current_frame = {
          id = 42,
          name = "main",
          line = 2,
          source = { path = "source.lua" },
        },
        children = {},
        threads = {},
        on_close = {},
        event_continued = function(self, body)
          for id, thread in pairs(self.threads) do
            if body.allThreadsContinued or id == body.threadId then
              thread.stopped = false
            end
          end
          if body.allThreadsContinued or self.stopped_thread_id == body.threadId then
            self.stopped_thread_id = nil
            self.current_frame = nil
          end
        end,
        request = function(_, command, arguments, callback)
          requests[#requests + 1] = { command = command, arguments = arguments }
          callback(nil, { variables = { { name = "x", value = "1" } } })
        end,
        set_breakpoints = function(_, bps, callback)
          requests[#requests + 1] = { command = "setBreakpoints", arguments = bps }
          callback()
        end,
      }
      dap = {
        listeners = { after = {} },
        sessions = function()
          return { session }
        end,
      }
      for _, name in ipairs({
        "disconnect",
        "event_output",
        "event_stopped",
        "event_continued",
        "event_initialized",
        "event_terminated",
        "event_exited",
      }) do
        dap.listeners.after[name] = {}
      end
      package.loaded.dap = dap
      local breakpoints = {}
      package.loaded["dap.breakpoints"] = {
        set = function(opts, buf, line)
          breakpoints[buf] = { { line = line, condition = opts.condition } }
        end,
        remove = function(buf)
          breakpoints[buf] = nil
        end,
        get = function(buf)
          if buf then
            return { [buf] = breakpoints[buf] }
          end
          return breakpoints
        end,
      }
      conversation = require("sia.conversation").new({
        workspace = dir,
        temporary = true,
        model = require("sia.model").resolve("openai/gpt-4.1"),
        approved_tools = { debug = true },
        tools = { debug_tool },
      })
    end,
    post_case = function()
      vim.ui.input = input
      require("sia.ui.confirm").show = confirm_show
      require("sia.config").options.settings.ui.confirm = confirm_config
      package.loaded.dap = old_dap
      package.loaded["dap.breakpoints"] = old_breakpoints
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

local function start(args, cancellable)
  local result, calls = nil, 0
  debug_tool.implementation.execute(args, function(res)
    result = res
    calls = calls + 1
  end, {
    conversation = conversation,
    cancellable = cancellable,
  })
  return function()
    return result
  end, function()
    return calls
  end
end

local function await(get)
  assert(
    vim.wait(2000, function()
      return get() ~= nil
    end),
    "debug did not finish"
  )
  return get()
end

local function event(name, body)
  local listeners = vim.tbl_values(dap.listeners.after[name])
  for _, listener in ipairs(listeners) do
    listener(session, body or {})
  end
end

local function no_wait_listeners()
  for key in pairs(dap.listeners.after.event_stopped) do
    if key ~= "sia.debug.transitions" then
      return false
    end
  end
  return true
end

T["completed output archives are bounded per conversation"] = function()
  for id = 1, 9 do
    session = vim.tbl_extend("force", {}, session, { id = id, on_close = {} })
    await(start({ action = "threads" }))
    event("event_output", { output = "run " .. id })
    event("event_terminated")
  end
  dap.sessions = function()
    return {}
  end
  local oldest = await(start({ action = "output", session_id = 1 }))
  eq(true, oldest.content:find("No matching session", 1, true) ~= nil)
  local newest = await(start({ action = "output", session_id = 9 }))
  eq(true, newest.content:find("run 9", 1, true) ~= nil)
  eq(9, #prompts)
end

T["completed session output includes late events without another approval"] = function()
  await(start({ action = "threads" }))
  event("event_output", { category = "stdout", output = "hello\n" })
  event("event_terminated")
  dap.sessions = function()
    return {}
  end
  event("event_output", { category = "stderr", output = "last message\n" })
  local result = await(start({ action = "output", session_id = 1, after = 1 }))
  eq(true, result.content:find("last message", 1, true) ~= nil)
  eq(true, result.content:find('state = "terminated"', 1, true) ~= nil)
  eq(1, #prompts)
  eq(1, #requests)
  eq(false, result.summary)
  local control = await(start({ action = "continue", session_id = 1 }))
  eq(true, control.content:find("No matching session", 1, true) ~= nil)
end

T["archived output is private to the approving conversation"] = function()
  await(start({ action = "threads" }))
  event("event_output", { output = "private log" })
  event("event_exited")
  dap.sessions = function()
    return {}
  end
  local original = conversation
  conversation = require("sia.conversation").new({
    workspace = dir,
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
    approved_tools = { debug = true },
    tools = { debug_tool },
  })
  local result = await(start({ action = "output", session_id = 1 }))
  conversation.tracker:destroy()
  conversation = original
  eq(nil, result.content:find("private log", 1, true))
  eq(true, result.content:find("No matching session", 1, true) ~= nil)
end

T["reused session id never inherits archived approval or output"] = function()
  await(start({ action = "threads" }))
  event("event_output", { output = "old log" })
  event("event_terminated")
  session = vim.tbl_extend("force", {}, session, { on_close = {} })
  local result = await(start({ action = "output", session_id = 1 }))
  eq(2, #prompts)
  eq(nil, result.content:find("old log", 1, true))
end

T["transport closure also archives output"] = function()
  await(start({ action = "threads" }))
  event("event_output", { output = "transport log" })
  session.closed = true
  for _, close in pairs(session.on_close) do
    close(session)
  end
  dap.sessions = function()
    return {}
  end
  eq(
    true,
    await(start({ action = "output", session_id = 1 })).content:find(
      "transport log",
      1,
      true
    ) ~= nil
  )
end

T["output preserves newlines carriage returns and UTF-8 without false truncation"] = function()
  await(start({ action = "sessions" }))
  local text = "hello\nworld\r\n  progress\r\tåäö\n"
  event("event_output", { category = "stdout", output = text })
  local result = await(start({ action = "output" }))
  eq(true, result.content:find("text = " .. vim.inspect(text), 1, true) ~= nil)
  eq(nil, result.content:find("truncated", 1, true))
end

T["oversized output marks real truncation without splitting UTF-8"] = function()
  await(start({ action = "sessions" }))
  local text = string.rep("a\n", 8191) .. "åäö"
  event("event_output", { category = "stdout", output = text })
  local result = await(start({ action = "output" }))
  eq(true, result.content:find("truncated = true", 1, true) ~= nil)
  eq(
    true,
    result.content:find("text = " .. vim.inspect(text:sub(1, 16384)), 1, true) ~= nil
  )
end

T["output captures stdout and stderr without requiring a stop"] = function()
  await(start({ action = "sessions" }))
  event("event_output", { category = "stdout", output = "hello\n" })
  event("event_output", { category = "stderr", output = "warning\n" })
  session.stopped_thread_id = nil
  local result = await(start({ action = "output" }))
  eq(true, result.content:find("hello", 1, true) ~= nil)
  eq(true, result.content:find("stderr", 1, true) ~= nil)
  eq(true, result.content:find("warning", 1, true) ~= nil)
  eq(false, result.summary)
  eq(0, #requests)
  eq(1, #prompts)
end

T["output filtering and cursors do not consume shared history"] = function()
  await(start({ action = "sessions" }))
  event("event_output", { category = "stdout", output = "first" })
  event("event_output", { category = "stderr", output = "second" })
  event("event_output", { category = "stdout", output = "third" })
  local result =
    await(start({ action = "output", category = "stdout", after = 0, count = 1 }))
  eq(true, result.content:find("first", 1, true) ~= nil)
  eq(true, result.content:find("next_after = 1", 1, true) ~= nil)
  eq(true, result.content:find("has_more = true", 1, true) ~= nil)
  result = await(start({ action = "output", category = "stdout", after = 1 }))
  eq(true, result.content:find("third", 1, true) ~= nil)
  eq(nil, result.content:find("second", 1, true))
  result = await(start({ action = "output", category = "stderr", after = 0 }))
  eq(true, result.content:find("second", 1, true) ~= nil)
end

T["output buffer is bounded and reports lost history"] = function()
  await(start({ action = "sessions" }))
  for i = 1, 257 do
    event("event_output", { output = "entry " .. i })
  end
  local result = await(start({ action = "output", after = 0, count = 1 }))
  eq(true, result.content:find("dropped_through = 1", 1, true) ~= nil)
  eq(true, result.content:find("history_lost = true", 1, true) ~= nil)
  eq(true, result.content:find("first_available = 2", 1, true) ~= nil)
end

T["output requires approval and is isolated between sessions"] = function()
  await(start({ action = "sessions" }))
  event("event_output", { output = "private output" })
  answer = "n"
  eq("cancelled", await(start({ action = "output" })).kind)
  answer = "y"
  session = vim.tbl_extend("force", {}, session, { id = 2 })
  local result = await(start({ action = "output" }))
  eq(nil, result.content:find("private output", 1, true))
end

T["output reports invalid category and never changes program state"] = function()
  local result = await(start({ action = "output", category = "unknown" }))
  eq(true, result.content:find("Unknown output category", 1, true) ~= nil)
  eq(0, #requests)
end

T["inspect returns frame scopes and locals in one call"] = function()
  session.request = function(_, command, arguments, callback)
    requests[#requests + 1] = { command = command, arguments = arguments }
    if command == "stackTrace" then
      callback(
        nil,
        {
          stackFrames = {
            { id = 22, name = "main", line = 9, source = { path = "main.py" } },
          },
        }
      )
    elseif command == "scopes" then
      callback(
        nil,
        {
          scopes = {
            { name = "Locals", presentationHint = "locals", variablesReference = 33 },
            { name = "Globals", variablesReference = 44 },
          },
        }
      )
    else
      callback(
        nil,
        {
          variables = {
            { name = "x", type = "int", value = "42", variablesReference = 0 },
          },
        }
      )
    end
  end
  local result = await(start({ action = "inspect", count = 3 }))
  eq(3, #requests)
  eq("stackTrace", requests[1].command)
  eq(1, requests[1].arguments.levels)
  eq(22, requests[2].arguments.frameId)
  eq(33, requests[3].arguments.variablesReference)
  eq(3, requests[3].arguments.count)
  eq(true, result.content:find('value = "42"', 1, true) ~= nil)
  eq(true, result.content:find("reference = 44", 1, true) ~= nil)
  eq(nil, result.content:find("result =", 1, true))
  eq(1, #prompts)
end

T["inspect applies local pagination when the adapter cannot page variables"] = function()
  session.capabilities.supportsVariablePaging = false
  session.request = function(_, command, arguments, callback)
    requests[#requests + 1] = { command = command, arguments = arguments }
    if command == "stackTrace" then
      callback(nil, { stackFrames = { { id = 22 } } })
    elseif command == "scopes" then
      callback(nil, { scopes = { { name = "Locals", variablesReference = 33 } } })
    else
      callback(
        nil,
        { variables = { { name = "a", value = "1" }, { name = "b", value = "2" } } }
      )
    end
  end
  local result = await(start({ action = "inspect", start = 1, count = 1 }))
  eq(nil, requests[3].arguments.start)
  eq(true, result.content:find('name = "b"', 1, true) ~= nil)
  eq(nil, result.content:find('name = "a"', 1, true))
end

T["inspect rejects mixed state when execution resumes between requests"] = function()
  local respond
  session.request = function(_, command, _, callback)
    requests[#requests + 1] = { command = command }
    respond = callback
  end
  local get = start({ action = "inspect" })
  session:event_continued({ threadId = 7 })
  event("event_continued", { threadId = 7 })
  respond(nil, { stackFrames = { { id = 22 } } })
  eq(true, await(get).content:find("Execution changed", 1, true) ~= nil)
  eq(1, #requests)
end

T["inspect never automatically reads expensive scopes"] = function()
  session.request = function(_, command, _, callback)
    requests[#requests + 1] = { command = command }
    if command == "stackTrace" then
      callback(nil, { stackFrames = { { id = 22 } } })
    else
      callback(
        nil,
        { scopes = { { name = "Locals", variablesReference = 33, expensive = true } } }
      )
    end
  end
  await(start({ action = "inspect" }))
  eq(2, #requests)
end

T["inspect does not continue after cancellation"] = function()
  local respond
  session.request = function(_, command, _, callback)
    requests[#requests + 1] = { command = command }
    respond = callback
  end
  local cancellable = { is_cancelled = false }
  local get, calls = start({ action = "inspect" }, cancellable)
  cancellable.is_cancelled = true
  await(get)
  respond(nil, { stackFrames = { { id = 22 } } })
  eq(1, #requests)
  eq(1, calls())
end

T["inspection results are structured and large values are clipped per variable"] = function()
  session.request = function(_, _, _, callback)
    callback(
      nil,
      {
        variables = {
          { name = "large", value = string.rep("x", 5000), variablesReference = 33 },
        },
      }
    )
  end
  local result = await(start({ action = "variables", reference = 1 }))
  eq(nil, result.content:find("result =", 1, true))
  eq(true, result.content:find("truncated = true", 1, true) ~= nil)
  eq(true, result.content:find("reference = 33", 1, true) ~= nil)
  eq(true, #result.content < 2000)
end

T["step returns a fresh top frame and only new output"] = function()
  await(start({ action = "output" }))
  event("event_output", { category = "stdout", output = "old output" })
  session.current_frame = { id = 99, line = 1 }
  session.request = function(_, command, _, callback)
    requests[#requests + 1] = { command = command }
    if command == "stackTrace" then
      return callback(nil, { stackFrames = { { id = 22, name = "main", line = 9 } } })
    end
    event("event_output", { category = "stdout", output = "new output" })
    session.stopped_thread_id = 7
    event("event_stopped", { reason = "step", threadId = 7 })
    callback(nil, {})
  end
  local result = await(start({ action = "step_over" }))
  eq("next", requests[1].command)
  eq("stackTrace", requests[2].command)
  eq(true, result.content:find("id = 22", 1, true) ~= nil)
  eq(true, result.content:find("line = 9", 1, true) ~= nil)
  eq(true, result.content:find("new output", 1, true) ~= nil)
  eq(nil, result.content:find("old output", 1, true))
end

T["termination returns output without requesting another frame"] = function()
  session.request = function(_, command, _, callback)
    requests[#requests + 1] = { command = command }
    event("event_output", { category = "stderr", output = "final output" })
    event("event_terminated")
    callback(nil, {})
  end
  local result = await(start({ action = "continue" }))
  eq(1, #requests)
  eq(true, result.content:find('state = "terminated"', 1, true) ~= nil)
  eq(true, result.content:find("final output", 1, true) ~= nil)
end

T["one approval covers inspection and control in a session"] = function()
  local result = await(start({ action = "threads" }))
  eq(false, result.summary)
  await(start({ action = "variables", reference = 123 }))
  await(start({ action = "wait_for_start" }))
  local get = start({ action = "step_over" })
  session.stopped_thread_id = 7
  event("event_stopped", { reason = "step", threadId = 7 })
  await(get)
  eq(1, #prompts)
  eq(true, prompts[1]:find("session 1", 1, true) ~= nil)
end

T["a new session object requires approval even with the same id"] = function()
  await(start({ action = "threads" }))
  event("event_terminated")
  session = vim.tbl_extend("force", {}, session)
  await(start({ action = "threads" }))
  eq(2, #prompts)
end

T["approvals are isolated by conversation"] = function()
  await(start({ action = "threads" }))
  local original = conversation
  conversation = require("sia.conversation").new({
    workspace = dir,
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
    approved_tools = { debug = true },
    tools = { debug_tool },
  })
  await(start({ action = "threads" }))
  conversation.tracker:destroy()
  conversation = original
  await(start({ action = "threads" }))
  eq(2, #prompts)
end

T["declining session access sends no adapter request"] = function()
  answer = "n"
  local result = await(start({ action = "variables", reference = 123 }))
  eq("cancelled", result.kind)
  eq(0, #requests)
  answer = "y"
  await(start({ action = "threads" }))
  eq(2, #prompts)
end

T["approval pending when a session closes cannot authorize its replacement"] = function()
  local accept
  answer = function(callback)
    accept = callback
  end
  local get = start({ action = "threads" })
  eq(nil, get())
  session.closed = true
  accept("y")
  eq(true, await(get).content:find("ended", 1, true) ~= nil)
  eq(0, #requests)
  session = vim.tbl_extend("force", {}, session, { closed = false })
  answer = "y"
  await(start({ action = "threads" }))
  eq(2, #prompts)
end

T["async approval uses only session accept or decline"] = function()
  require("sia.config").options.settings.ui.confirm.async.enable = true
  local pending
  require("sia.ui.confirm").show = function(owner, _, opts)
    eq(conversation, owner)
    eq(nil, opts.on_always)
    pending = opts
  end
  local get = start({ action = "wait_for_start" })
  eq(nil, get())
  eq(true, no_wait_listeners())
  pending.on_accept()
  eq(false, await(get).summary)
  await(start({ action = "threads" }))
  eq(1, #requests)
end

T["declining approval during a wait stops its timer and listeners"] = function()
  answer = "n"
  eq("cancelled", await(start({ action = "wait_for_start" })).kind)
  eq(true, no_wait_listeners())
end

T["child sessions do not inherit access"] = function()
  await(start({ action = "threads" }))
  local child = vim.tbl_extend("force", {}, session, { id = 2, children = {} })
  session.children[2] = child
  await(start({ action = "threads", session_id = 2 }))
  eq(2, #prompts)
end

T["disconnect expires approval even if the session object is reused"] = function()
  await(start({ action = "threads" }))
  event("disconnect")
  local result = await(start({ action = "threads" }))
  eq(true, result.content:find("ended", 1, true) ~= nil)
  eq(1, #requests)
end

T["cancelled approval cannot grant access or complete twice"] = function()
  local respond
  answer = function(callback)
    respond = callback
  end
  local cancellable = { is_cancelled = false }
  local get, calls = start({ action = "wait_for_stop" }, cancellable)
  cancellable.is_cancelled = true
  eq(true, no_wait_listeners())
  respond("y")
  eq(true, await(get).content:find("Cancelled", 1, true) ~= nil)
  respond("n")
  eq(1, calls())
  eq(0, #requests)
  answer = "y"
  await(start({ action = "threads" }))
  eq(2, #prompts)
  eq(true, no_wait_listeners())
end

T["wait for stop rechecks readiness after approval"] = function()
  local respond
  answer = function(callback)
    respond = callback
  end
  local get = start({ action = "wait_for_stop" })
  session.stopped_thread_id = nil
  respond("y")
  eq(nil, get())
  session.stopped_thread_id = 7
  await(get)
  eq(1, #prompts)
end

T["expired session blocks changes while another approval is pending"] = function()
  local child = vim.tbl_extend("force", {}, session, { id = 2, children = {} })
  session.children[2] = child
  local respond
  answer = function(callback)
    if #prompts == 1 then
      callback("y")
    else
      respond = callback
    end
  end
  local get = start({ action = "set_breakpoint", path = "source.lua", line = 2 })
  event("event_exited")
  respond("y")
  eq(true, await(get).content:find("ended", 1, true) ~= nil)
  eq(0, #requests)
  eq(nil, next(require("dap.breakpoints").get()))
end

T["ordinary pending breakpoints and discovery require no approval"] = function()
  await(start({ action = "sessions" }))
  dap.sessions = function()
    return {}
  end
  await(start({ action = "set_breakpoint", path = "source.lua", line = 2 }))
  eq(0, #prompts)
end

T["sessions ignores provider-filled blank optional strings"] = function()
  local args = {
    thread_id = 1,
    session_id = 1,
    start = 0,
    condition = "",
    path = "test.py",
    timeout = 5,
    count = 20,
    frame_id = 1,
    reference = 1,
    line = 4,
    configuration = "",
    action = "sessions",
  }
  local result = await(start(args))
  eq(true, result.content:find('configuration = "test"', 1, true) ~= nil)
  eq(true, result.content:find("session_id = 1", 1, true) ~= nil)
  eq("", args.configuration)
  args.configuration = "  \t"
  eq(true, await(start(args)).content:find("session_id = 1", 1, true) ~= nil)
  args.configuration = "other"
  eq("{}", await(start(args)).content)
end

T["sessions ignores unused zero placeholders"] = function()
  local result = await(start({
    action = "sessions",
    count = 20,
    start = 0,
    frame_id = 0,
    line = 4,
    timeout = 60,
    path = "test.py",
    reference = 0,
    configuration = "",
    condition = "",
    thread_id = 0,
    session_id = 0,
  }))
  eq(true, result.content:find("session_id = 1", 1, true) ~= nil)
end

T["inspection ignores irrelevant invalid fields but validates its own"] = function()
  await(start({ action = "threads", reference = 0, line = -1, count = 0 }))
  eq("threads", requests[1].command)
  local result = await(start({ action = "variables", reference = 0 }))
  eq(true, result.content:find("Invalid reference", 1, true) ~= nil)
  eq(1, #requests)
end

T["breakpoints work without a session and do not move the cursor"] = function()
  dap.sessions = function()
    return {}
  end
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local result =
    await(start({ action = "set_breakpoint", path = "source.lua", line = 2 }))
  eq(true, result.content:find("pending", 1, true) ~= nil)
  eq(buf, vim.api.nvim_get_current_buf())
  eq(cursor, vim.api.nvim_win_get_cursor(0))
  eq(0, #requests)
end

T["wait_for_start waits for initialization rather than mere session creation"] = function()
  session.initialized = false
  local get = start({ action = "wait_for_start" })
  eq(nil, get())
  session.initialized = true
  eq(true, await(get).content:find("session_id = 1", 1, true) ~= nil)
end

T["wait_for_stop returns an existing stop immediately"] = function()
  local get = start({ action = "wait_for_stop", session_id = 1 })
  eq(true, get().content:find("stopped", 1, true) ~= nil)
end

T["ambiguous sessions require an explicit id"] = function()
  dap.sessions = function()
    return { session, { id = 2, config = {}, children = {} } }
  end
  local result = await(start({ action = "stack_trace" }))
  eq(true, result.content:find("Multiple", 1, true) ~= nil)
  eq(0, #requests)
end

T["continue observes a stop emitted before the request response"] = function()
  session.request = function(_, command, arguments, callback)
    requests[#requests + 1] = { command = command, arguments = arguments }
    if command == "stackTrace" then
      return callback(nil, { stackFrames = { { id = 22, name = "main", line = 9 } } })
    end
    session.stopped_thread_id = 7
    event("event_stopped", { reason = "breakpoint", threadId = 7 })
    callback(nil, {})
  end
  local result = await(start({ action = "continue", session_id = 1 }))
  eq("continue", requests[1].command)
  eq(7, requests[1].arguments.threadId)
  eq(true, result.content:find("breakpoint", 1, true) ~= nil)
  eq(true, no_wait_listeners())
end

T["step actions map to DAP requests"] = function()
  for action, command in pairs({
    step_over = "next",
    step_into = "stepIn",
    step_out = "stepOut",
  }) do
    session.stopped_thread_id = 7
    local get = start({ action = action })
    eq(command, requests[#requests].command)
    session.stopped_thread_id = 7
    event("event_stopped", { reason = "step" })
    await(get)
  end
end

T["cancelling a wait removes listeners and never resumes the target"] = function()
  session.stopped_thread_id = nil
  local cancellable = { is_cancelled = false }
  local get = start({ action = "wait_for_stop" }, cancellable)
  cancellable.is_cancelled = true
  eq("cancelled", await(get).kind)
  eq(true, no_wait_listeners())
  eq(0, #requests)
end

T["a running target is reported on execution timeout"] = function()
  local result = await(start({ action = "continue", timeout = 1 }))
  eq(true, result.content:find("still running", 1, true) ~= nil)
  eq(true, no_wait_listeners())
end

T["adapter errors are returned and waits are cleaned up"] = function()
  session.request = function(_, _, _, callback)
    callback({ message = "rejected" })
  end
  local result = await(start({ action = "step_over" }))
  eq(true, result.content:find("rejected", 1, true) ~= nil)
  eq(true, no_wait_listeners())
end

T["variables require a stopped session and use the explicit reference"] = function()
  await(start({ action = "variables", reference = 123, count = 3 }))
  eq("variables", requests[1].command)
  eq(123, requests[1].arguments.variablesReference)
  eq(3, requests[1].arguments.count)
  session.stopped_thread_id = nil
  local result = await(start({ action = "variables", reference = 123 }))
  eq(true, result.content:find("Session is running", 1, true) ~= nil)
  eq(1, #requests)
end

T["termination completes a stop wait"] = function()
  session.stopped_thread_id = nil
  local get = start({ action = "wait_for_stop" })
  event("event_terminated")
  eq(true, await(get).content:find("terminated", 1, true) ~= nil)
end

T["execution waits for asynchronous stopped-thread publication"] = function()
  local get = start({ action = "step_into" })
  event("event_stopped", { reason = "step", threadId = 9 })
  eq(nil, get())
  session.threads[9] = { stopped = true }
  eq(true, await(get).content:find("stopped", 1, true) ~= nil)
end

T["rejected execution preserves the previous stop"] = function()
  session.request = function(_, _, _, cb)
    cb({ message = "rejected" })
  end
  await(start({ action = "step_over" }))
  eq(7, session.stopped_thread_id)
  eq(42, session.current_frame.id)
end

T["continue response clears all resumed threads"] = function()
  session.threads[7], session.threads[8] = { stopped = true }, { stopped = true }
  session.request = function(_, _, _, cb)
    cb(nil, { allThreadsContinued = true })
  end
  local cancellable = { is_cancelled = false }
  local get = start({ action = "continue" }, cancellable)
  eq(false, session.threads[7].stopped)
  eq(false, session.threads[8].stopped)
  cancellable.is_cancelled = true
  await(get)
end

T["a paused non-focused thread can be inspected and resumed"] = function()
  session.stopped_thread_id = nil
  session.threads[7] = { id = 7, stopped = true }
  await(start({ action = "stack_trace", thread_id = 7 }))
  eq(7, requests[1].arguments.threadId)
  local get = start({ action = "continue", thread_id = 7 })
  eq("continue", requests[2].command)
  event("event_terminated")
  await(get)
end

T["late execution responses do not erase a newer stop after cancellation"] = function()
  local respond
  session.request = function(_, _, _, callback)
    respond = callback
  end
  local cancellable = { is_cancelled = false }
  local get = start({ action = "continue" }, cancellable)
  eq(nil, session.stopped_thread_id)
  cancellable.is_cancelled = true
  await(get)
  session.stopped_thread_id = 9
  event("event_stopped", { threadId = 9 })
  respond(nil, {})
  eq(9, session.stopped_thread_id)
end

T["breakpoint changes wait for initialization and report adapter rejection"] = function()
  session.initialized = false
  session.request = function(_, command, _, callback)
    eq("setBreakpoints", command)
    callback({ message = "adapter rejected breakpoint" })
  end
  local get = start({ action = "set_breakpoint", path = "source.lua", line = 2 })
  eq(nil, get())
  session.initialized = true
  eq(true, await(get).content:find("adapter rejected breakpoint", 1, true) ~= nil)
end

T["wait catches a short-lived session between polls"] = function()
  dap.sessions = function()
    return {}
  end
  local get = start({ action = "wait_for_start" })
  event("event_terminated")
  eq(true, await(get).content:find("terminated", 1, true) ~= nil)
end

T["missing optional dependency is safely unsupported"] = function()
  local preload = package.preload.dap
  package.loaded.dap = nil
  package.preload.dap = function()
    error("not installed")
  end
  eq(false, debug_tool.implementation.is_supported())
  package.preload.dap = preload
  package.loaded.dap = dap
end

return T
