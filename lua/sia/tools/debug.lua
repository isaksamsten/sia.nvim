local tool_utils = require("sia.tools.utils")

local CONTROL = {
  continue = "continue",
  step_over = "next",
  step_into = "stepIn",
  step_out = "stepOut",
  pause = "pause",
}
local INSPECT = { threads = true, stack_trace = true, scopes = true, variables = true }
local sequence = 0
local generations = setmetatable({}, { __mode = "k" })
local tracked = setmetatable({}, { __mode = "k" })
-- A grant belongs to one conversation and one concrete DAP session, never an ID.
local approvals = setmetatable({}, { __mode = "k" })
local ended = setmetatable({}, { __mode = "k" })
local outputs = setmetatable({}, { __mode = "k" })
-- Retain logs, not debugger objects, for conversations that approved a session.
local output_archives = setmetatable({}, { __mode = "k" })
local OUTPUT_ARCHIVES = 8
local OUTPUT_BYTES, OUTPUT_EVENTS = 65536, 256

local function output_log(session)
  if not outputs[session] then
    outputs[session] = { events = {}, bytes = 0, sequence = 0, dropped = 0 }
  end
  return outputs[session]
end

local expire_session
local function retain_output(conversation, session)
  local log = output_log(session)
  local archive = output_archives[conversation] or {}
  output_archives[conversation] = archive
  for _, entry in ipairs(archive) do
    if entry.log == log then
      return
    end
  end
  archive[#archive + 1] = {
    id = session.id,
    configuration = session.config.name,
    log = log,
  }
  if #archive > OUTPUT_ARCHIVES then
    table.remove(archive, 1)
  end
  if session.on_close then
    session.on_close["sia.debug.output"] = function()
      expire_session(session)
    end
  end
end

expire_session = function(session)
  ended[session] = true
  for _, grants in pairs(approvals) do
    grants[session] = nil
  end
  for _, archive in pairs(output_archives) do
    for _, entry in ipairs(archive) do
      if entry.log == outputs[session] then
        entry.terminated = true
      end
    end
  end
end

local function capture_output(session, body)
  local category = body.category or "console"
  if category ~= "stdout" and category ~= "stderr" and category ~= "console" then
    return
  end
  if type(body.output) ~= "string" or body.output == "" then
    return
  end
  local log = output_log(session)
  -- Keep stream formatting intact; only byte clipping counts as truncation.
  local limit = 16384
  if #body.output > limit then
    while limit > 0 do
      local byte = body.output:byte(limit + 1)
      if byte < 128 or byte >= 192 then
        break
      end
      limit = limit - 1
    end
  end
  local text = body.output:sub(1, limit)
  log.sequence = log.sequence + 1
  log.events[#log.events + 1] = {
    id = log.sequence,
    category = category,
    text = text,
    truncated = #text < #body.output or nil,
  }
  log.bytes = log.bytes + #text
  while log.bytes > OUTPUT_BYTES or #log.events > OUTPUT_EVENTS do
    local removed = table.remove(log.events, 1)
    log.bytes = log.bytes - #removed.text
    log.dropped = removed.id
  end
end

local function output_page(session, args, retained_log)
  local log = retained_log
    or outputs[session]
    or { events = {}, sequence = 0, dropped = 0 }
  local events = vim.tbl_filter(function(event)
    return (not args.after or event.id > args.after)
      and (
        not args.category
        or args.category == "all"
        or event.category == args.category
      )
  end, log.events)
  local count = args.count or 20
  local first = args.after and 1 or math.max(1, #events - count + 1)
  local page, bytes = {}, 0
  for index = first, math.min(#events, first + count - 1) do
    local event = events[index]
    if bytes + #event.text > 24000 then
      break
    end
    page[#page + 1], bytes = event, bytes + #event.text
  end
  return {
    session_id = session.id,
    events = page,
    next_after = page[#page] and page[#page].id or log.sequence,
    has_more = first + #page <= #events,
    dropped_through = log.dropped > 0 and log.dropped or nil,
    first_available = log.events[1] and log.events[1].id or log.sequence + 1,
    history_lost = args.after ~= nil and args.after < log.dropped or nil,
    message = #page == 0 and "No captured output." or nil,
  }
end

-- Keep transition tracking alive even after a tool wait is cancelled/times out.
local function track(dap)
  if tracked[dap] then
    return
  end
  tracked[dap] = true
  dap.listeners.after.event_output["sia.debug.output"] = capture_output
  for _, event in ipairs({
    "event_stopped",
    "event_continued",
    "event_terminated",
    "event_exited",
  }) do
    dap.listeners.after[event]["sia.debug.transitions"] = function(session)
      generations[session] = (generations[session] or 0) + 1
      if event == "event_terminated" or event == "event_exited" then
        expire_session(session)
      end
    end
  end
  dap.listeners.after.disconnect["sia.debug.approvals"] = function(session)
    expire_session(session)
  end
end

local function sessions(dap)
  local result, seen = {}, {}
  local function visit(items)
    for _, session in pairs(items) do
      if not seen[session] and not session.closed then
        seen[session] = true
        result[#result + 1] = session
        visit(session.children or {})
      end
    end
  end
  visit(dap.sessions())
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

-- stopped_thread_id is the UI selection, not the only stopped thread (e.g. pause).
local function stopped_thread(session, id)
  if id then
    local thread = session.threads[id]
    return (thread and thread.stopped or session.stopped_thread_id == id) and id or nil
  end
  if session.stopped_thread_id then
    return session.stopped_thread_id
  end
  local found
  for thread_id, thread in pairs(session.threads) do
    if thread.stopped then
      if found then
        return nil
      end -- Require explicit selection if ambiguous.
      found = thread_id
    end
  end
  return found
end

local function snapshot(session)
  local frame = session.current_frame
  return {
    session_id = session.id,
    configuration = session.config.name,
    state = session.closed and "terminated"
      or (
        stopped_thread(session) and "stopped"
        or (session.initialized and "running" or "initializing")
      ),
    thread_id = stopped_thread(session),
    frame = frame and {
      id = frame.id,
      name = frame.name,
      path = frame.source and frame.source.path,
      line = frame.line,
    } or nil,
  }
end

local function frame_info(frame)
  if not frame then
    return nil
  end
  return {
    id = frame.id,
    name = frame.name,
    path = frame.source and frame.source.path,
    line = frame.line,
    column = frame.column,
  }
end

local function scope_info(scope)
  return {
    name = scope.name,
    reference = scope.variablesReference,
    expensive = scope.expensive or nil,
    named = scope.namedVariables,
    indexed = scope.indexedVariables,
  }
end

local function variable_page(session, body, args)
  local variables = body and body.variables or {}
  local start = session.capabilities.supportsVariablePaging and 0 or (args.start or 0)
  local page = vim.list_slice(variables, start + 1, start + (args.count or 20))
  local value_limit = math.min(1000, math.floor(16000 / math.max(#page, 1)))
  return {
    variables = vim.tbl_map(function(variable)
      local value = variable.value or ""
      local clipped = #value > value_limit
      if clipped then
        value = require("sia.tool_output").limit(value, value_limit, 20)
      end
      return {
        name = variable.name,
        value = value,
        type = variable.type ~= "" and variable.type or nil,
        reference = (variable.variablesReference or 0) > 0
            and variable.variablesReference
          or nil,
        truncated = clipped or nil,
      }
    end, page),
    next_start = (args.start or 0) + #page,
    may_have_more = #page == (args.count or 20),
  }
end

local function render(value)
  local text = vim.inspect(value)
  if #text > 30000 then
    text = text:sub(1, 30000) .. "\n[truncated; request a smaller page]"
  end
  return text
end

-- Do not trust current_frame: nvim-dap may still be refreshing it after a stop.
local function read_frame(session, thread, callback)
  session:request(
    "stackTrace",
    { threadId = thread, startFrame = 0, levels = 1 },
    function(err, body)
      callback(err, body and body.stackFrames and body.stackFrames[1])
    end
  )
end

-- Every asynchronous operation owns its timer/listeners and completes exactly once.
local function operation(dap, args, opts, callback, on_timeout)
  sequence = sequence + 1
  local key = "sia.debug." .. sequence
  local timer = assert(vim.uv.new_timer())
  local deadline = vim.uv.now() + (args.timeout or 60) * 1000
  local done, listeners = false, {}
  local function stop()
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    for _, event in ipairs(listeners) do
      dap.listeners.after[event][key] = nil
    end
  end
  local function finish(value, err)
    if done then
      return
    end
    stop()
    callback({
      summary = err and "Debug operation failed" or false,
      content = err and ("ERROR: " .. err) or render(value),
      ephemeral = err ~= nil,
      kind = value and value.state == "cancelled" and "cancelled" or nil,
    })
  end
  local function listen(event, fn)
    listeners[#listeners + 1] = event
    dap.listeners.after[event][key] = function(...)
      if not done then
        fn(...)
      end
    end
  end
  local poll
  timer:start(
    0,
    50,
    vim.schedule_wrap(function()
      if done then
        return
      end
      if opts.cancellable and opts.cancellable.is_cancelled then
        finish({
          state = "cancelled",
          message = "Stopped waiting. Cancelled.",
        })
      elseif vim.uv.now() >= deadline then
        finish(on_timeout and on_timeout() or {
          state = "timeout",
          message = "Timed out. Use sessions to check its state.",
        })
      elseif poll then
        poll()
      end
    end)
  )
  return finish,
    listen,
    function(fn)
      poll = fn
    end,
    stop,
    function()
      return not done
    end
end

return tool_utils.new_tool({
  definition = {
    name = "debug",
    description = [[Inspect and control nvim-dap sessions; the USER launches/attaches and terminates the debugger.

<workflow>
Set breakpoints before launch → ask the USER to start debugging → `wait_for_start` → `wait_for_stop` → inspect/step.
`inspect` returns the top frame, scopes, and a bounded page of non-expensive locals in one call.
`continue`, `step_over`, `step_into`, `step_out`, and `pause` return the fresh top frame and new output at the next stop/termination.
Use `variables(reference)` to expand a returned scope or variable; use `stack_trace` for callers.
`output` reads captured stdout/stderr/console events; use `next_after` as `after` for new output.
</workflow>

<rules>
- Use returned IDs, never invent them. Select `session_id` when ambiguous; omit irrelevant arguments.
- Refresh frame IDs and variable references after execution resumes. Inspect only needed variable pages.
- Timeout/cancellation stops waiting, NOT execution. Use `wait_for_stop` to keep waiting or `pause` to interrupt.
- Breakpoints are shared with the USER; saved breakpoints are pending until adapter verification.
- Access is approved once per conversation/session, including runtime values and execution control. New session, new approval. Values may contain secrets.
</rules>]],
    type = "function",
    parameters = {
      action = {
        type = "string",
        description = "The action",
        enum = {
          "sessions",
          "set_breakpoint",
          "remove_breakpoint",
          "breakpoints",
          "wait_for_start",
          "wait_for_stop",
          "continue",
          "step_over",
          "step_into",
          "step_out",
          "pause",
          "threads",
          "stack_trace",
          "scopes",
          "inspect",
          "variables",
          "output",
        },
      },
      session_id = {
        type = "integer",
        description = "Session ID from sessions. Required if multiple sessions match.",
      },
      configuration = {
        type = "string",
        description = "Exact debug configuration name to select or wait for.",
      },
      path = {
        type = "string",
        description = "Source file, relative to the conversation workspace or absolute.",
      },
      line = { type = "integer", description = "1-based source line for a breakpoint." },
      condition = {
        type = "string",
        description = "Optional breakpoint expression; may execute code in the target.",
      },
      thread_id = {
        type = "integer",
        description = "Thread to inspect/control; defaults to the stopped thread.",
      },
      frame_id = {
        type = "integer",
        description = "Frame ID from stack_trace, for scopes.",
      },
      reference = {
        type = "integer",
        description = "variablesReference from scopes or variables.",
      },
      category = {
        type = "string",
        enum = { "all", "stdout", "stderr", "console" },
        description = "Output stream filter (default all).",
      },
      after = {
        type = "integer",
        description = "Output event cursor from next_after. Omit for latest events; 0 reads from oldest retained event.",
      },
      start = {
        type = "integer",
        description = "Zero-based stack/variable offset (default 0).",
      },
      count = {
        type = "integer",
        description = "Maximum stack frames, variables, or output events (default 20, max 100).",
      },
      timeout = {
        type = "integer",
        description = "Wait/request timeout in seconds (default 60, max 300). Timing out never stops the target.",
      },
    },
    required = { "action" },
  },
  is_supported = function()
    return pcall(require, "dap")
  end,
  is_approved = function()
    return false -- Session grants are deliberately separate from tool-wide approval.
  end,
  summary = function(args)
    return "Debug: " .. args.action
  end,
}, function(args, conversation, callback, opts)
  local ok, dap = pcall(require, "dap")
  local function fail(message)
    callback({
      summary = "Debug operation failed",
      content = "ERROR: " .. message,
      ephemeral = true,
    })
  end
  if not ok then
    return fail("nvim-dap is not installed")
  end
  -- Some providers populate omitted optional strings with "". In Lua those
  -- strings are truthy, so an empty configuration would filter out every session.
  args = vim.tbl_extend("force", {}, args)
  for _, name in ipairs({ "configuration", "condition", "category" }) do
    if type(args[name]) == "string" and args[name]:match("^%s*$") then
      args[name] = nil
    end
  end
  -- Providers may emit placeholders for every schema property. Ignore fields
  -- that this action does not consume rather than rejecting an unrelated value.
  local used = { action = true }
  local fields = {
    sessions = { "session_id", "configuration" },
    breakpoints = {},
    set_breakpoint = { "path", "line", "condition", "timeout" },
    remove_breakpoint = { "path", "line", "timeout" },
    wait_for_start = { "session_id", "configuration", "timeout" },
    wait_for_stop = { "session_id", "configuration", "thread_id", "timeout" },
    threads = { "session_id", "configuration", "timeout" },
    inspect = {
      "session_id",
      "configuration",
      "thread_id",
      "start",
      "count",
      "timeout",
    },
    stack_trace = {
      "session_id",
      "configuration",
      "thread_id",
      "start",
      "count",
      "timeout",
    },
    scopes = { "session_id", "configuration", "thread_id", "frame_id", "timeout" },
    variables = {
      "session_id",
      "configuration",
      "thread_id",
      "reference",
      "start",
      "count",
      "timeout",
    },
    output = { "session_id", "configuration", "category", "after", "count" },
  }
  local control_fields = { "session_id", "configuration", "thread_id", "timeout" }
  local relevant = CONTROL[args.action] and control_fields or fields[args.action]
  if not relevant then
    return fail("Unknown debug action: " .. tostring(args.action))
  end
  for _, name in ipairs(relevant) do
    used[name] = true
  end
  for name in pairs(args) do
    if not used[name] then
      args[name] = nil
    end
  end
  for _, name in ipairs({ "session_id", "thread_id" }) do
    if args[name] == 0 then
      args[name] = nil
    end
  end
  for name, bounds in pairs({
    timeout = { 1, 300 },
    count = { 1, 100 },
    start = { 0, math.huge },
    line = { 1, math.huge },
    session_id = { 1, math.huge },
    thread_id = { 1, math.huge },
    frame_id = { 0, math.huge },
    reference = { 1, math.huge },
    after = { 0, math.huge },
  }) do
    local value = args[name]
    if
      value ~= nil
      and (
        type(value) ~= "number"
        or value ~= math.floor(value)
        or value < bounds[1]
        or value > bounds[2]
      )
    then
      return fail("Invalid " .. name)
    end
  end
  local function matches(session)
    return (not args.session_id or session.id == args.session_id)
      and (not args.configuration or session.config.name == args.configuration)
  end
  local function matching()
    return vim.tbl_filter(matches, sessions(dap))
  end
  local function reply(value)
    callback({ summary = false, content = render(value) })
  end
  if
    args.action == "output"
    and args.category
    and not vim.tbl_contains({ "all", "stdout", "stderr", "console" }, args.category)
  then
    return fail("Unknown output category: " .. tostring(args.category))
  end
  track(dap)
  local function authorize(session, run)
    if session.closed or ended[session] then
      return fail("Debug session has ended")
    end
    if opts.cancellable and opts.cancellable.is_cancelled then
      return fail("Cancelled")
    end
    local grants = approvals[conversation]
    if not grants then
      grants = setmetatable({}, { __mode = "k" })
      approvals[conversation] = grants
    end
    if grants[session] then
      retain_output(conversation, session)
      return run()
    end

    -- Session approval deliberately bypasses tool-wide grants and verifiers.
    -- No operation timer/listeners are active while this prompt is pending.
    local prompt = string.format(
      "Debug access to session %d (%s)",
      session.id,
      session.config.name or "unnamed"
    )
    local answered = false
    local function answer(accepted)
      if answered then
        return
      end
      answered = true
      if opts.cancellable and opts.cancellable.is_cancelled then
        return fail("Cancelled")
      end
      if session.closed or ended[session] then
        return fail("Debug session ended while awaiting approval")
      end
      if not accepted then
        return callback({
          summary = false,
          content = "Debug session access declined.",
          kind = "cancelled",
        })
      end
      grants[session] = true
      retain_output(conversation, session)
      run()
    end
    local function prompt_user()
      vim.ui.input({ prompt = prompt .. " (y/N): " }, function(response)
        answer(
          type(response) == "string" and response:lower():match("^%s*y%s*$") ~= nil
        )
      end)
    end
    local confirm = require("sia.config").options.settings.ui.confirm
    if confirm.async and confirm.async.enable then
      require("sia.ui.confirm").show(conversation, prompt, {
        level = "warn",
        tool_name = "debug",
        kind = "input",
        on_accept = function()
          answer(true)
        end,
        on_cancel = function()
          answer(false)
        end,
        on_prompt = prompt_user,
      })
    else
      prompt_user()
    end
  end
  if args.action == "sessions" then
    return reply(vim.tbl_map(snapshot, matching()))
  end

  if
    args.action == "breakpoints"
    or args.action == "set_breakpoint"
    or args.action == "remove_breakpoint"
  then
    local bp = require("dap.breakpoints")
    if args.action == "breakpoints" then
      local result = {}
      for buf, items in pairs(bp.get()) do
        for _, item in ipairs(items) do
          result[#result + 1] = {
            path = vim.api.nvim_buf_get_name(buf),
            line = item.line,
            condition = item.condition,
            state = item.state or "pending",
          }
        end
      end
      return reply(result)
    end
    if type(args.path) ~= "string" or args.path == "" or not args.line then
      return fail("path and line are required")
    end
    local path = vim.fs.abspath(vim.fs.joinpath(conversation.workspace, args.path))
    if args.path:sub(1, 1) == "/" then
      path = vim.fs.normalize(args.path)
    end
    if vim.fn.filereadable(path) ~= 1 then
      return fail("Source file does not exist: " .. path)
    end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    if args.line > vim.api.nvim_buf_line_count(buf) then
      return fail("Breakpoint line is past the end of the file")
    end
    local active = sessions(dap)
    local function change()
      for _, s in ipairs(active) do
        if
          s.closed
          or ended[s]
          or not (approvals[conversation] and approvals[conversation][s])
        then
          return fail("Debug session ended before breakpoint changes were applied")
        end
      end
      if opts.cancellable and opts.cancellable.is_cancelled then
        return fail("Cancelled")
      end
      if args.action == "set_breakpoint" then
        bp.set({ condition = args.condition }, buf, args.line)
      else
        bp.remove(buf, args.line)
      end
      local source_breakpoints = {}
      for _, item in ipairs(bp.get(buf)[buf] or {}) do
        source_breakpoints[#source_breakpoints + 1] = {
          line = item.line,
          condition = item.condition,
          hitCondition = item.hitCondition,
          logMessage = item.logMessage,
        }
      end
      -- Only synchronize sessions explicitly authorized above.
      if #active == 0 then
        return reply({
          path = path,
          line = args.line,
          state = "pending",
          message = "Saved locally. Ask the user to start the debugger.",
        })
      end
      local finish, _, set_poll = operation(dap, args, opts, callback)
      local sent, completed, results = {}, {}, {}
      set_poll(function()
        for _, s in ipairs(active) do
          if
            s.closed
            or ended[s]
            or not (approvals[conversation] and approvals[conversation][s])
          then
            completed[s] = true
            results[s.id] = results[s.id]
              or {
                state = "ended",
                message = "Not synchronized: session access expired",
              }
          elseif s.initialized and not sent[s] then
            sent[s] = true
            s:request("setBreakpoints", {
              source = { name = vim.fs.basename(path), path = path },
              breakpoints = source_breakpoints,
              sourceModified = false,
            }, function(err, body)
              completed[s] = true
              results[s.id] = err and { error = vim.inspect(err) } or body
              if not err and body and bp.set_state then
                for _, state in ipairs(not ended[s] and body.breakpoints or {}) do
                  if state.line then
                    bp.set_state(buf, state)
                  end
                end
              end
            end)
          end
        end
        for _, s in ipairs(active) do
          if not completed[s] then
            return
          end
        end
        finish({
          path = path,
          local_breakpoints = source_breakpoints,
          sessions = results,
        })
      end)
    end
    local function approve_next(index)
      local s = active[index]
      if not s then
        return change()
      end
      authorize(s, function()
        approve_next(index + 1)
      end)
    end
    return approve_next(1)
  end

  local selected = matching()
  if #selected > 1 then
    return fail(
      "Multiple sessions match; specify session_id (use sessions to list them)"
    )
  end
  local session = selected[1]
  if args.action == "wait_for_start" or args.action == "wait_for_stop" then
    local function wait_for(predicate, ready)
      local finish, listen, set_poll, stop = operation(dap, args, opts, callback)
      local function terminated(s)
        if s == session or (not session and matches(s)) then
          finish({ session_id = s.id, state = "terminated" })
        end
      end
      listen("event_terminated", terminated)
      listen("event_exited", terminated)
      listen("disconnect", terminated)
      listen("event_initialized", function(s)
        if not session and matches(s) then
          session = s
        end
      end)
      listen("event_stopped", function(s)
        if not session and matches(s) then
          session = s
        end
      end)
      local function check()
        local candidates = matching()
        if #candidates > 1 then
          return finish(nil, "Multiple sessions match; specify session_id")
        end
        session = session or candidates[1]
        if not session then
          return
        end
        if session.closed or ended[session] then
          return terminated(session)
        end
        if predicate() then
          stop()
          ready()
        end
      end
      set_poll(check)
      check()
    end
    return wait_for(function()
      return session.initialized
    end, function()
      authorize(session, function()
        if args.action == "wait_for_start" then
          return reply(snapshot(session))
        end
        wait_for(function()
          return stopped_thread(session, args.thread_id)
        end, function()
          reply(snapshot(session))
        end)
      end)
    end)
  end
  -- Archived logs remain readable only by conversations that approved that run.
  -- Always prefer a live match so reused IDs cannot inherit live access.
  if args.action == "output" and (not session or session.closed or ended[session]) then
    local archive = output_archives[conversation] or {}
    local candidates = {}
    for _, entry in ipairs(archive) do
      if
        entry.terminated
        and (not args.session_id or entry.id == args.session_id)
        and (not args.configuration or entry.configuration == args.configuration)
      then
        candidates[#candidates + 1] = entry
      end
    end
    if #candidates > 1 then
      return fail(
        "Multiple archived sessions match; specify session_id and configuration"
      )
    end
    if candidates[1] then
      local entry = candidates[1]
      local result = output_page(entry, args, entry.log)
      result.state, result.configuration = "terminated", entry.configuration
      return reply(result)
    end
  end
  if not session then
    return fail(
      "No matching session. Ask the user to start debugging, then use wait_for_start."
    )
  end
  if not session.initialized then
    return fail("Session is still initializing; use wait_for_start")
  end

  if args.action == "output" then
    return authorize(session, function()
      reply(output_page(session, args))
    end)
  end

  local function execute_session()
    if session.closed or ended[session] then
      return fail("Debug session has ended")
    end
    if args.action == "inspect" then
      local thread = stopped_thread(session, args.thread_id)
      if not thread then
        return fail("Session is running; use wait_for_stop or pause")
      end
      local finish, _, _, _, active = operation(dap, args, opts, callback)
      local generation = generations[session]
      local result = { session_id = session.id, thread_id = thread, state = "stopped" }
      local function request(method, params, next_step)
        if not active() then
          return
        end
        session:request(method, params, function(err, body)
          if not active() then
            return
          end
          if session.closed or ended[session] or generations[session] ~= generation then
            return finish(
              nil,
              "Execution changed during inspection; inspect again at the next stop"
            )
          end
          if err then
            return finish(nil, vim.inspect(err))
          end
          next_step(body or {})
        end)
      end
      request(
        "stackTrace",
        { threadId = thread, startFrame = 0, levels = 1 },
        function(body)
          local frame = body.stackFrames and body.stackFrames[1]
          result.frame = frame_info(frame)
          if not frame then
            return finish(result)
          end
          request("scopes", { frameId = frame.id }, function(scopes_body)
            result.scopes = vim.tbl_map(scope_info, scopes_body.scopes or {})
            local locals
            for _, scope in ipairs(scopes_body.scopes or {}) do
              if
                not scope.expensive
                and (scope.variablesReference or 0) > 0
                and (
                  scope.presentationHint == "locals" or scope.name:lower() == "locals"
                )
              then
                locals = scope
                break
              end
            end
            if not locals then
              return finish(result)
            end
            local params = { variablesReference = locals.variablesReference }
            if session.capabilities.supportsVariablePaging then
              params.start, params.count = args.start or 0, args.count or 20
            end
            request("variables", params, function(variables_body)
              result.locals = variable_page(session, variables_body, args)
              result.locals.reference = locals.variablesReference
              finish(result)
            end)
          end)
        end
      )
      return
    end
    if INSPECT[args.action] then
      if args.action ~= "threads" and not stopped_thread(session, args.thread_id) then
        return fail("Session is running; use wait_for_stop or pause")
      end
      local method, params
      if args.action == "threads" then
        method, params = "threads", {}
      elseif args.action == "stack_trace" then
        local thread = stopped_thread(session, args.thread_id)
        method, params =
          "stackTrace",
          { threadId = thread, startFrame = args.start or 0, levels = args.count or 20 }
      elseif args.action == "scopes" then
        if not args.frame_id then
          return fail("frame_id is required (use stack_trace)")
        end
        method, params = "scopes", { frameId = args.frame_id }
      else
        if not args.reference then
          return fail("reference is required (use scopes or variables)")
        end
        method, params = "variables", { variablesReference = args.reference }
        if session.capabilities.supportsVariablePaging then
          params.start, params.count = args.start or 0, args.count or 20
        end
      end
      local finish = operation(dap, args, opts, callback)
      session:request(method, params, function(err, body)
        if err then
          return finish(nil, vim.inspect(err))
        end
        if args.action == "variables" then
          body = variable_page(session, body, args)
        elseif args.action == "stack_trace" and body then
          body = {
            frames = vim.tbl_map(frame_info, body.stackFrames or {}),
            total = body.totalFrames,
          }
        elseif args.action == "scopes" and body then
          body = { scopes = vim.tbl_map(scope_info, body.scopes or {}) }
        end
        finish(vim.tbl_extend("force", { session_id = session.id }, body or {}))
      end)
      return
    end

    local command = CONTROL[args.action]
    if not command then
      return fail("Unknown debug action: " .. tostring(args.action))
    end
    local function control()
      -- Recheck after approval: the user may have changed sessions or resumed execution.
      if session.closed then
        return fail("Session has closed")
      end
      local thread = args.thread_id or stopped_thread(session)
      if not thread then
        return fail(
          "thread_id is required when there is no stopped thread (use threads)"
        )
      end
      if args.action ~= "pause" and not stopped_thread(session, thread) then
        return fail("Session is already running")
      end
      if opts.cancellable and opts.cancellable.is_cancelled then
        return fail("Cancelled")
      end
      local output_after = output_log(session).sequence
      local finish, listen, set_poll, _, active = operation(
        dap,
        args,
        opts,
        callback,
        function()
          return {
            session = snapshot(session),
            state = "timeout",
            output = output_page(session, { after = output_after }),
            message = stopped_thread(session) and "Timed out waiting for a stop event."
              or "Target is still running; use wait_for_stop or pause.",
          }
        end
      )
      local stop_event, hydrating
      local function complete(result)
        result.output = output_page(session, { after = output_after })
        finish(result)
      end
      local function ready()
        if
          not stop_event
          or hydrating
          or not stopped_thread(session, stop_event.threadId)
        then
          return
        end
        hydrating = true
        vim.schedule(function()
          if not active() then
            return
          end
          local generation = generations[session]
          local stopped = stop_event
          read_frame(
            session,
            stopped.threadId or stopped_thread(session),
            function(err, frame)
              if not active() then
                return
              end
              if session.closed or ended[session] then
                return complete({ session_id = session.id, state = "terminated" })
              end
              if generations[session] ~= generation then
                local changed = snapshot(session)
                changed.frame = nil
                changed.message =
                  "Execution changed while fetching the frame; inspect again."
                return complete(changed)
              end
              complete({
                session_id = session.id,
                state = "stopped",
                reason = stopped.reason,
                thread_id = stopped.threadId,
                frame = frame_info(frame),
                frame_error = err and vim.inspect(err) or nil,
              })
            end
          )
        end)
      end
      listen("event_stopped", function(s, body)
        if s == session then
          stop_event = body
          ready()
        end
      end)
      listen("event_terminated", function(s)
        if s == session then
          complete({ session_id = s.id, state = "terminated" })
        end
      end)
      set_poll(function()
        if session.closed or ended[session] then
          complete({ session_id = session.id, state = "terminated" })
        else
          ready()
        end
      end)
      -- Clear the old stop before sending, just as Session:_step does.
      track(dap)
      generations[session] = (generations[session] or 0) + 1
      local generation = generations[session]
      local old_thread, old_frame = session.stopped_thread_id, session.current_frame
      local was_stopped = session.threads[thread] and session.threads[thread].stopped
      if command ~= "pause" then
        session:event_continued({ threadId = thread, allThreadsContinued = false })
      end
      session:request(command, { threadId = thread }, function(err, body)
        local unchanged = not session.closed and generations[session] == generation
        if err then
          if unchanged and command ~= "pause" then
            session.stopped_thread_id, session.current_frame = old_thread, old_frame
            if session.threads[thread] then
              session.threads[thread].stopped = was_stopped
            end
          end
          return finish(nil, vim.inspect(err))
        elseif
          unchanged
          and command == "continue"
          and body
          and body.allThreadsContinued ~= false
        then
          session:event_continued({ threadId = thread, allThreadsContinued = true })
        end
      end)
    end
    control()
  end
  authorize(session, execute_session)
end)
