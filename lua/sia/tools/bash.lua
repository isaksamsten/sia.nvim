local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local INLINE_OUTPUT_LIMIT = 8000
local PREVIEW_TAIL_LINES = 20
local VIEW_OUTPUT_LIMIT = 2000
local ACTIONS = {
  start = true,
  status = true,
  wait = true,
  view = true,
  kill = true,
}

local ASYNC_START_REPLY = [[
Async bash process launched successfully.
processId: %d (This is an internal ID for your use, do not mention it to the user.)
The command is currently running in the background. If you have other tasks you should
continue working on them now. Wait to call bash(action="wait") until either:
- You want to check on the process status - call bash(action="status") to get an
  immediate status update
- You run out of things to do and the process is still running - call
  bash(action="wait") to idle and wait for the result (do not use
  "wait" unless you completely run out of things to do as it will waste time).
If the user sends a message while you are waiting, the wait may yield early with a
status update. You will then see the user's message in the conversation and should
respond before calling wait or status again.
]]

local SUSPICIOUS_PATTERNS = {
  "rm",
  "rmdir",
  "&&",
  "||",
  ";",
  "|",
  "%$%(",
  "`",
  "%$%{",
  "bash %-c",
  "sh %-c",
  "zsh %-c",
  "python %-c",
  "node %-e",
  "perl %-e",
  "eval",
  "exec",
  "source",
  "%<%(",
  "<<",
  "%$[A-Za-z_]",
  "alias ",
  "function ",
  "curl",
  "wget",
  "nc",
  "netcat",
  "\\r",
  "\\m",
  "\\s",
  '"r"',
  "'s'",
  '"s"',
  "'r'",
}
--- @param command string
--- @return boolean is_dangerous
local function is_suspicious(command)
  for _, pattern in ipairs(SUSPICIOUS_PATTERNS) do
    if command:find(pattern) then
      return true
    end
  end

  return false
end
--- @param output sia.process.Output?
--- @return sia.process.Output
local function normalize_output(output)
  return {
    stdout = output and output.stdout or "",
    stderr = output and output.stderr or "",
  }
end

--- @param text string
--- @param limit integer
--- @return string[]
local function tail_lines(text, limit)
  if text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= limit then
    return lines
  end

  return vim.list_slice(lines, #lines - limit + 1, #lines)
end

--- @param lines string[]
--- @param header string
--- @param values string[]
local function append_block(lines, header, values)
  table.insert(lines, header)
  for _, value in ipairs(values) do
    table.insert(lines, value)
  end
end

--- @param lines string[]
--- @param output sia.process.Output
local function append_preview_output(lines, output)
  local stdout_tail = tail_lines(output.stdout, PREVIEW_TAIL_LINES)
  local stderr_tail = tail_lines(output.stderr, PREVIEW_TAIL_LINES)

  if #stdout_tail > 0 then
    append_block(
      lines,
      string.format(
        "stdout (last %d lines):",
        math.min(#stdout_tail, PREVIEW_TAIL_LINES)
      ),
      stdout_tail
    )
  end

  if #stderr_tail > 0 then
    append_block(
      lines,
      string.format(
        "stderr (last %d lines):",
        math.min(#stderr_tail, PREVIEW_TAIL_LINES)
      ),
      stderr_tail
    )
  end

  if #stdout_tail == 0 and #stderr_tail == 0 then
    table.insert(lines, "No output captured.")
  end
end

--- @param value any
--- @return boolean
local function is_action(value)
  return type(value) == "string" and ACTIONS[value] == true
end

--- @param args table
--- @return table
local function normalize_args(args)
  local normalized = vim.deepcopy(args or {})
  local action = normalized.action
  if not is_action(action) then
    action = "start"
  end

  normalized.action = action
  normalized.command = normalized.command
  return normalized
end

--- @param proc_id integer
--- @return string
local function bash_view_hint(proc_id)
  return string.format(
    'Use bash(action="view", id=%d) to inspect the full output',
    proc_id
  )
end

--- @param proc sia.process.Process
--- @return string
local function process_status(proc)
  if proc.kind == "running" then
    return "running"
  end

  return proc.outcome
end

--- @param proc sia.process.Process
--- @param runtime sia.process.Runtime
--- @return string
local function build_process_preview(proc, runtime)
  local output = normalize_output(runtime:get_output(proc.id))
  local lines = {
    string.format("Process ID: %d", proc.id),
    string.format("Command: %s", proc.command),
    string.format("Status: %s", process_status(proc)),
  }

  if proc.description and proc.description ~= proc.command then
    table.insert(lines, string.format("Description: %s", proc.description))
  end

  if proc.kind == "finished" then
    table.insert(lines, string.format("Exit code: %d", proc.code))
    if proc.file.stdout then
      table.insert(lines, string.format("stdout file: %s", proc.file.stdout))
    end
    if proc.file.stderr then
      table.insert(lines, string.format("stderr file: %s", proc.file.stderr))
    end
  end

  append_preview_output(lines, output)
  return table.concat(lines, "\n")
end

--- @param proc sia.process.Process
--- @param runtime sia.process.Runtime
--- @return string
local function waiting_yield_message(proc, runtime)
  return string.format(
    "Process %d is still running. Yielding to process user input.\n\n%s",
    proc.id,
    build_process_preview(proc, runtime)
  )
end

--- Build a summary of the bash process result
--- @param proc sia.process.FinishedProcess
--- @param output sia.process.Output
--- @param cwd string
--- @return string[] content
local function build_result_summary(proc, output, cwd)
  local content = {}
  local stdout = output.stdout
  local stderr = output.stderr
  local code = proc.kind == "finished" and proc.code or 0

  local relative_cwd = vim.fn.fnamemodify(cwd, ":~:.")
  if relative_cwd == "" or relative_cwd == "." then
    relative_cwd = "."
  end
  table.insert(content, string.format("Process %d completed.", proc.id))
  table.insert(content, string.format("Command: %s", proc.command))
  table.insert(content, string.format("Working directory: %s", relative_cwd))
  table.insert(content, string.format("Exit code: %d", code))

  if stdout ~= "" then
    table.insert(content, "")
    if #stdout > INLINE_OUTPUT_LIMIT then
      local path = proc.file.stdout
      table.insert(
        content,
        string.format(
          path and "stdout: (truncated, %d chars total - full output: %s)"
            or "stdout: (truncated, %d chars total)",
          #stdout,
          path
        )
      )
      table.insert(content, stdout:sub(1, INLINE_OUTPUT_LIMIT))
      table.insert(content, "... (truncated)")
      table.insert(content, bash_view_hint(proc.id))
      if path then
        table.insert(content, string.format("stdout file: %s", path))
      end
    else
      table.insert(content, "stdout:")
      table.insert(content, stdout)
    end
  end

  if stderr ~= "" then
    table.insert(content, "")
    if #stderr > INLINE_OUTPUT_LIMIT then
      local path = proc.file.stderr
      table.insert(
        content,
        string.format(
          path and "stderr: (truncated, %d chars total - full output: %s)"
            or "stderr: (truncated, %d chars total)",
          #stderr,
          path
        )
      )
      table.insert(content, stderr:sub(1, INLINE_OUTPUT_LIMIT))
      table.insert(content, "... (truncated)")
      table.insert(content, bash_view_hint(proc.id))
      if path then
        table.insert(content, string.format("stderr file: %s", path))
      end
    else
      table.insert(content, "stderr:")
      table.insert(content, stderr)
    end
  end

  if stdout == "" and stderr == "" and code == 0 then
    table.insert(content, "")
    table.insert(content, "Command completed successfully (no output)")
  end

  return content
end

--- @param text string
--- @return string[]
local function output_lines(text)
  if text == "" then
    return {}
  end

  return vim.split(text, "\n", { plain = true })
end

--- @param lines string[]
--- @param offset integer
--- @param limit integer
--- @return { total: integer, start_line: integer?, end_line: integer?, content: string[] }
local function paginate_output(lines, offset, limit)
  if #lines == 0 then
    return {
      total = 0,
      content = {},
    }
  end

  local start_line = math.max(1, offset)
  if start_line > #lines then
    start_line = #lines
  end

  local end_line = math.min(#lines, start_line + limit - 1)
  return {
    total = #lines,
    start_line = start_line,
    end_line = end_line,
    content = lines,
  }
end

--- @param content string[]
--- @param label string
--- @param text string
--- @param offset integer
--- @param limit integer
--- @param path string?
local function append_output_view(content, label, text, offset, limit, path)
  local paged = paginate_output(output_lines(text), offset, limit)
  table.insert(content, label .. ":")

  if path then
    table.insert(content, string.format("file: %s", path))
  end

  if paged.total == 0 or not paged.start_line or not paged.end_line then
    table.insert(content, "No output captured.")
    return
  end

  table.insert(
    content,
    string.format("lines %d-%d of %d", paged.start_line, paged.end_line, paged.total)
  )
  vim.list_extend(content, paged.content)

  if paged.end_line < paged.total then
    table.insert(
      content,
      string.format("Use offset=%d to continue.", paged.end_line + 1)
    )
  end
end

--- @param proc sia.process.Process
--- @param runtime sia.process.Runtime
--- @param offset integer
--- @param limit integer
--- @param stream string
--- @return string
local function build_process_output_view(proc, runtime, offset, limit, stream)
  local output = normalize_output(runtime:get_output(proc.id))
  local content = {
    string.format("Process ID: %d", proc.id),
    string.format("Command: %s", proc.command),
    string.format("Status: %s", process_status(proc)),
  }

  if proc.description and proc.description ~= proc.command then
    table.insert(content, string.format("Description: %s", proc.description))
  end

  if proc.kind == "finished" then
    table.insert(content, string.format("Exit code: %d", proc.code))
  end

  table.insert(content, "")
  if proc.kind == "finished" then
    if stream == "stdout" or stream == "both" then
      append_output_view(
        content,
        "stdout",
        output.stdout,
        offset,
        limit,
        proc.file.stdout
      )
    end
    if stream == "both" then
      table.insert(content, "")
    end
    if stream == "stderr" or stream == "both" then
      append_output_view(
        content,
        "stderr",
        output.stderr,
        offset,
        limit,
        proc.file.stderr
      )
    end
  end

  return table.concat(content, "\n")
end

--- Format a command for display: inline backticks for single-line,
--- fenced code block for multi-line commands.
--- @param command string
--- @return string
local function format_command(command)
  if command:find("\n") then
    return "\n```sh\n" .. command .. "\n```"
  end
  return "`" .. command .. "`"
end

--- Build a display message for the bash process
--- @param proc sia.process.Process
--- @return string
local function build_display_message(proc)
  local desc = proc.description or proc.command
  local icon = icons.bash_exec
  local cmd = format_command(proc.command)
  if proc.kind == "running" then
    return string.format("%s %s: %s", icon, desc, cmd)
  end

  if proc.outcome == "completed" then
    if proc.code == 0 then
      return string.format("%s %s: %s", icon, desc, cmd)
    else
      return string.format("%s %s: %s (exit code %d)", icon, desc, cmd, proc.code)
    end
  elseif proc.outcome == "timed_out" or proc.outcome == "interrupted" then
    return string.format("%s Stopped %s: %s", icon, desc, cmd)
  else
    return string.format("%s %s: %s (failed)", icon, desc, cmd)
  end
end

--- Helper to finalize a completed process and call the callback
--- @param proc sia.process.FinishedProcess
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function return_completed_result(proc, conversation, callback)
  local cwd = conversation.process_runtime:pwd()
  local output = normalize_output(conversation.process_runtime:get_output(proc.id))
  local content = build_result_summary(proc, output, cwd)
  callback({
    content = table.concat(content, "\n"),
    summary = build_display_message(proc),
  })
end

--- Wait for a tracked bash process to finish, optionally yielding early when the user
--- has queued follow-up input or when a wait timeout elapses.
--- @param proc_id integer
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
--- @param wait_timeout number?
local function wait_for_process(proc_id, conversation, callback, wait_timeout)
  local proc = conversation.process_runtime:get(proc_id)
  if not proc then
    callback({
      content = string.format(
        "Error: Process with ID %d not found in this conversation",
        proc_id
      ),
    })
    return
  end

  if proc.kind ~= "running" then
    return_completed_result(proc, conversation, callback)
    return
  end

  local timeout_message = wait_timeout
      and string.format(
        "Wait timed out after %.1fs. Use status to check progress or wait again.",
        wait_timeout / 1000
      )
    or nil

  local function poll()
    local current_proc = conversation.process_runtime:get(proc_id)
    if not current_proc then
      callback({
        content = "Error: Process instance was removed",
      })
      return
    end

    if current_proc.kind ~= "running" then
      return_completed_result(current_proc, conversation, callback)
      return
    end

    if conversation:has_pending_user_messages() then
      local desc = current_proc.description or current_proc.command
      local cmd = format_command(current_proc.command)
      callback({
        summary = string.format("%s Paused %s: %s", icons.bash_exec, desc, cmd),
        content = waiting_yield_message(current_proc, conversation.process_runtime),
      })
      return
    end

    if wait_timeout then
      wait_timeout = wait_timeout - 500
      if wait_timeout <= 0 then
        callback({
          content = table.concat({
            string.format("Process %d is still running.", current_proc.id),
            string.format("Command: %s", current_proc.command),
            timeout_message,
            "",
            build_process_preview(current_proc, conversation.process_runtime),
          }, "\n"),
        })
        return
      end
    end

    vim.defer_fn(poll, 500)
  end

  poll()
end

--- Launch a command via shell and track it as a bash process.
--- Async commands are spawned as independent processes (via spawn_detached)
--- that do not block the main shell queue.
--- Sync commands run through the main shell's serial queue.
--- @param args table tool arguments
--- @param conversation sia.Conversation
--- @param opts sia.NewToolExecuteOpts
--- @param on_started fun(proc: sia.process.Process?, err: string?) called immediately after launch
local function launch_command(args, conversation, opts, on_started)
  local is_dangerous = is_suspicious(args.command)
  local prompt = string.format("Execute: %s", args.command)

  local runtime = conversation.process_runtime

  opts.user_input(prompt, {
    level = is_dangerous and "warn" or "info",
    preview = function(preview_buf)
      local lines = vim.split(args.command, "\n")
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
      vim.bo[preview_buf].ft = "sh"
      return #lines
    end,
    on_accept = function()
      local is_cancelled = function()
        return opts.cancellable ~= nil and opts.cancellable.is_cancelled
      end
      local proc
      if args.async then
        proc = runtime:exec_async(args.command, {
          description = args.description,
          timeout = args.timeout,
          is_cancelled = is_cancelled,
        })
      else
        proc = runtime:exec(args.command, {
          description = args.description,
          timeout = args.timeout or 120000,
          is_cancelled = is_cancelled,
        })
      end
      on_started(proc)
    end,
  })
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "bash",
    description = "Execute bash commands safely within the project directory",
    parameters = {
      action = {
        type = "string",
        enum = { "start", "status", "wait", "view", "kill" },
        description = "The action to execute: start (launch new process), status (check process status + partial output if async), wait (wait for process completion), view (read stdout/stderr with offset and limit), kill (terminate a running process). Defaults to 'start'.",
      },
      command = {
        type = "string",
        description = "The shell command to execute (required for 'start')",
      },
      description = {
        type = "string",
        description = "Clear, concise description of what the command does in 3-10 words (required for 'start')",
      },
      timeout = {
        type = "number",
        description = "Optional timeout in milliseconds (default 120000, only for 'start')",
      },
      id = {
        type = "integer",
        description = "The process ID (required for 'status', 'wait', 'view', and 'kill')",
      },
      async = {
        type = "boolean",
        description = "If true, launch the command in the background and return a process ID immediately. Use 'status' or 'wait' to get the result later. Default is false (synchronous).",
      },
      wait_timeout = {
        type = "number",
        description = "Optional timeout in milliseconds for 'wait'. If the process hasn't completed within this time, returns partial output and the process keeps running. Omit to wait indefinitely.",
      },
      offset = {
        type = "integer",
        description = "Line offset to start reading process output from (1-based, only for 'view')",
      },
      limit = {
        type = "integer",
        description = "Maximum number of output lines to read per stream (default: 2000, only for 'view')",
      },
      stream = {
        type = "string",
        enum = { "stdout", "stderr", "both" },
        description = "The output stream (only for 'view')",
      },
    },
    required = {},
  },
  summary = function(args)
    local normalized = normalize_args(args)
    if normalized.action == "start" then
      if normalized.description then
        return string.format("Starting: %s...", args.description)
      end
      return "Starting command..."
    elseif normalized.action == "status" then
      return string.format("Checking process %d...", normalized.id or 0)
    elseif normalized.action == "wait" then
      return string.format("Waiting for process %d...", normalized.id or 0)
    elseif normalized.action == "view" then
      return string.format("Viewing process %d output...", normalized.id or 0)
    end
    return "Running command..."
  end,
  instructions = string.format(
    [[Executes bash commands in a persistent shell session with optional timeout,
ensuring proper handling and security measures.

## Commands

- **start**: Execute a bash command. By default, blocks until the command completes
  and returns the result directly. If the user sends a follow-up message while you are
  waiting, it may yield early with a status update while the command keeps running.
  Set `async=true` to launch in the background immediately.
- **status**: Check if an async process has completed (non-blocking). For running
  processes, includes the last 20 lines of stdout/stderr so you can monitor progress.
- **wait**: Block until an async process completes and return its result. Use
  `wait_timeout` to limit how long to wait — if the process hasn't finished, you
  get partial output and the process keeps running.
- **view**: Read the full stdout/stderr captured for a process. Use `offset` and
  `limit` to page through large outputs without going through the separate `%s` tool.

## Default Workflow (synchronous)

	For most commands, simply call `bash` with a shell `command` — it defaults to
	`action="start"` and returns the result in a single call:

<good-example>
	bash(command="pytest /foo/bar/tests", description="Run tests")
// Result is returned immediately — no need for a separate wait call
</good-example>

## Async Workflow

For long-running commands or when you want to run multiple commands concurrently,
use `async=true`:

1. Use `start` with `async=true` to launch a command. You'll get a process ID back.
2. Continue doing other work (editing files, reading, etc.) while the command runs.
3. Use `status` to check progress — shows whether it's done plus recent output.
4. Use `wait` when you need the result and have nothing else to do.
5. Use `wait` with `wait_timeout` to peek at partial output without blocking forever.
6. Use `kill` to terminate a running process that is no longer needed.
	7. If the user sends a message while you are waiting on `bash(action="wait")` or a
	   blocking `bash(action="start", async=false, command="...")`, the call may yield early with a
   status update. Respond to the user first, then call `wait` or `status` again when
   you are ready.

<good-example>
// Launch two independent commands concurrently:
	bash(action="start", command="make lint", description="Run linter", async=true)
	bash(action="start", command="make test", description="Run tests", async=true)
// Do other work...
	bash(action="wait", id=1)
	bash(action="wait", id=2)
</good-example>

<good-example>
// For very long-running tasks, use wait_timeout to check progress periodically:
	bash(action="start", command="make integration-test", description="Run integration tests", async=true)
// Do other work...
	bash(action="wait", id=1, wait_timeout=10000)
// If still running, you get partial output and can continue working
	bash(action="status", id=1)
// When ready, wait for the final result:
	bash(action="wait", id=1)
</good-example>

<good-example>
// Kill a long-running process that is no longer needed:
	bash(action="start", command="tail -f /var/log/app.log", description="Watch logs", async=true)
// After getting enough information:
	bash(action="kill", id=1)
</good-example>

## Large Output

When output exceeds the inline limit, the result includes truncated output. Use
	`bash(action="view", id=<process_id>)` to inspect the full stdout/stderr, and add
`offset`/`limit` to page through it. Output files are still stored at predictable
paths like `<tmpdir>/sia/bash/<id>/process_<n>_stdout` when you need the raw files.

## Security

Before executing a command, follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use the
     glob tool to verify the parent directory exists and is the correct location

## Usage Notes

	- The `command` and `description` parameters are required for `start`.
	- `action` defaults to `start`.
- You can specify an optional timeout in milliseconds.
  If not specified, commands will timeout after 120 seconds.
- VERY IMPORTANT: You MUST avoid using search commands like `find` and
  `grep`. Instead use grep, glob, or task to search. You MUST avoid
  read tools like `cat`, `head`, `tail`, and `ls`, and use %s and
  workspace to view files.
- When issuing multiple commands, use the ';' or '&&' operator to separate
  them. DO NOT use newlines (newlines are ok in quoted strings).
- All commands share the same persistent shell session. This means:
  * Environment variables remain set between commands
  * Directory changes with `cd` persist
  * Shell settings like `ulimit` persist
- Try to maintain your current working directory throughout the session by
  using absolute paths and avoiding usage of `cd`.
- For independent commands, use `async=true` and launch them concurrently
  to maximize performance!

<bad-example>
cd /foo/bar && pytest tests
</bad-example>

# Committing changes with git

When the user asks you to create a new git commit, follow these steps carefully:

1. Start with a single message that contains three tool_use blocks that do the following:
   - Run a git status command to see all untracked files.
   - Run a git diff command to see both staged and unstaged changes.
   - Run a git log command to see recent commit messages for style reference.

2. Analyze all changes; if there are multiple unrelated changes ask the user what to commit.
3. Draft a commit message based on the changes.
4. Create the commit using a HEREDOC for proper formatting:
<example>
git commit -m "$(cat <<'EOF'
   Commit message here.
   )"
</example>

5. If the commit fails due to pre-commit hook changes, retry once. If it fails again,
   it usually means a pre-commit hook is preventing the commit.

6. Finally, run git status to make sure the commit succeeded.]],
    tool_names.view,
    tool_names.view
  ),
}, function(args, conversation, callback, opts)
  args = normalize_args(args)
  if args.action == "start" then
    if not args.command or args.command:match("^%s*$") then
      callback({
        content = "Error: 'command' parameter is required for 'start'",
        summary = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    if args.async then
      launch_command(args, conversation, opts, function(proc, err)
        if err then
          callback({
            content = err,
            summary = icons.error .. " Failed to execute command",
            kind = "failed",
          })
          return
        end
        callback({
          content = string.format(ASYNC_START_REPLY, proc.id),
          summary = string.format(
            "%s Started %s (process %d)",
            icons.started,
            format_command(args.description or args.command),
            proc.id
          ),
        })
      end)
    else
      launch_command(args, conversation, opts, function(proc, err)
        if err then
          callback({
            content = err,
            summary = icons.error .. " Failed to execute command",
            kind = "failed",
          })
          return
        end
        wait_for_process(proc.id, conversation, callback, nil)
      end)
    end
  elseif args.action == "status" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'status'",
        summary = icons.error .. " Missing id parameter",
      })
      return
    end

    local proc = conversation.process_runtime:get(args.id)
    if not proc then
      callback({
        content = string.format(
          "Error: Process with ID %d not found in this conversation",
          args.id
        ),
      })
      return
    end

    callback({
      content = build_process_preview(proc, conversation.process_runtime),
    })
  elseif args.action == "wait" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'wait'",
      })
      return
    end

    wait_for_process(args.id, conversation, callback, args.wait_timeout)
  elseif args.action == "view" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'view'",
        summary = icons.error .. " Missing id parameter",
      })
      return
    end

    local proc = conversation.process_runtime:get(args.id)
    if not proc then
      callback({
        content = string.format(
          "Error: Process with ID %d not found in this conversation",
          args.id
        ),
        summary = icons.error .. " Failed to view process output",
      })
      return
    end

    local offset = math.max(1, tonumber(args.offset) or 1)
    local limit = math.max(1, tonumber(args.limit) or VIEW_OUTPUT_LIMIT)
    callback({
      content = build_process_output_view(
        proc,
        conversation.process_runtime,
        offset,
        limit,
        args.stream
      ),
      summary = string.format("%s Viewed process %d output", icons.view_bash, args.id),
    })
  elseif args.action == "kill" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'kill'",
        summary = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    local stop_result = conversation.process_runtime:stop(args.id)
    if stop_result == "not_found" then
      callback({
        content = string.format(
          "Error: Process with ID %d not found in this conversation",
          args.id
        ),
        summary = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    local proc = conversation.process_runtime:get(args.id)
    local content
    if stop_result == "already_finished" then
      content = proc and build_process_preview(proc, conversation.process_runtime)
        or "Process already finished."
    elseif stop_result == "stop_requested" then
      content = proc
          and table.concat({
            string.format("Stop requested for process %d.", args.id),
            "",
            build_process_preview(proc, conversation.process_runtime),
          }, "\n")
        or string.format("Stop requested for process %d.", args.id)
    else
      content = proc
          and table.concat({
            string.format("Process %d stopped.", args.id),
            "",
            build_process_preview(proc, conversation.process_runtime),
          }, "\n")
        or string.format("Process %d stopped.", args.id)
    end

    callback({
      content = content,
      summary = string.format(
        "%s Stopped process %d: %s",
        stop_result == "stop_requested" and icons.bash_exec or icons.bash_kill,
        args.id,
        format_command(proc and proc.command or "unknown")
      ),
    })
  else
    callback({
      content = string.format("Error: Unknown action '%s'", tostring(args.action)),
    })
  end
end)
