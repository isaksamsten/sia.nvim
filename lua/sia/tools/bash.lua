local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local ASYNC_START_REPLY = [[
Async bash process launched successfully.
processId: %d (This is an internal ID for your use, do not mention it to the user.)
The command is currently running in the background. If you have other tasks you should
continue working on them now. Wait to call bash(command="wait") until either:
- You want to check on the process status - call bash(command="status") to get an
  immediate status update
- You run out of things to do and the process is still running - call
  bash(command="wait") to idle and wait for the result (do not use
  "wait" unless you completely run out of things to do as it will waste time).
]]

--- Ensure the shell is initialized for the conversation
--- @param conversation sia.Conversation
--- @return sia.Shell
local function ensure_shell(conversation)
  if not conversation.shell then
    local Shell = require("sia.shell")
    local config = require("sia.config")
    local project_root = vim.fn.getcwd()
    conversation.shell = Shell.new(project_root, config.options.settings.shell)
  end
  return conversation.shell
end

--- Write full output to a persistent temp file in a named directory
--- @param content string
--- @param conversation_id integer
--- @param proc_id integer
--- @param stream string "stdout" or "stderr"
--- @return string? path the temp file path, or nil if content is empty
local function write_temp_output(content, conversation_id, proc_id, stream)
  if not content or content == "" then
    return nil
  end
  local dir = require("sia.utils").dirs.bash(conversation_id)
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, string.format("process_%d_%s", proc_id, stream))
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

--- Build a summary of the bash process result (for returning to the AI)
--- @param proc sia.conversation.BashProcess
--- @param result sia.ShellResult
--- @param cwd string
--- @return string[] content
local function build_result_summary(proc, result, cwd)
  local content = {}
  local stdout = result.stdout or ""
  local stderr = result.stderr or ""
  local code = result.code or 0

  local relative_cwd = vim.fn.fnamemodify(cwd, ":~:.")
  if relative_cwd == "" or relative_cwd == "." then
    relative_cwd = "."
  end
  table.insert(content, string.format("Process %d completed.", proc.id))
  table.insert(content, string.format("Command: %s", proc.command))
  table.insert(content, string.format("Working directory: %s", relative_cwd))
  table.insert(content, string.format("Exit code: %d", code))

  if result.interrupted then
    table.insert(content, "Status: interrupted")
  end

  local max_inline = 8000
  if stdout ~= "" then
    table.insert(content, "")
    if #stdout > max_inline then
      table.insert(
        content,
        string.format(
          "stdout: (truncated, %d chars total - full output: %s)",
          #stdout,
          proc.stdout_file
        )
      )
      table.insert(content, stdout:sub(1, max_inline))
      table.insert(content, "... (truncated)")
    else
      table.insert(content, "stdout:")
      table.insert(content, stdout)
    end
  end

  if stderr ~= "" then
    table.insert(content, "")
    if #stderr > max_inline then
      table.insert(
        content,
        string.format(
          "stderr: (truncated, %d chars total - full output: %s)",
          #stderr,
          proc.stderr_file
        )
      )
      table.insert(content, stderr:sub(1, max_inline))
      table.insert(content, "... (truncated)")
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
--- @param proc sia.conversation.BashProcess
--- @return string
local function build_display_message(proc)
  local desc = proc.description or proc.command
  local icon = icons.bash_exec
  local cmd = format_command(proc.command)
  if proc.status == "completed" then
    if proc.code == 0 then
      return string.format("%s %s: %s", icon, desc, cmd)
    else
      return string.format("%s %s: %s (exit code %d)", icon, desc, cmd, proc.code or -1)
    end
  elseif proc.status == "timed_out" or proc.interrupted then
    return string.format("%s Stopped %s: %s", icon, desc, cmd)
  else
    return string.format("%s %s: %s (failed)", icon, desc, cmd)
  end
end

--- Helper to finalize a completed process and call the callback
--- @param proc sia.conversation.BashProcess
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function return_completed_result(proc, conversation, callback)
  local shell = ensure_shell(conversation)
  local cwd = shell:pwd()

  -- Read result from temp files
  local stdout = ""
  local stderr = ""

  if proc.stdout_file and vim.fn.filereadable(proc.stdout_file) == 1 then
    stdout = table.concat(vim.fn.readfile(proc.stdout_file), "\n")
  end
  if proc.stderr_file and vim.fn.filereadable(proc.stderr_file) == 1 then
    stderr = table.concat(vim.fn.readfile(proc.stderr_file), "\n")
  end

  local result = {
    stdout = stdout,
    stderr = stderr,
    code = proc.code or 0,
    interrupted = proc.interrupted or false,
  }

  local content = build_result_summary(proc, result, cwd)
  callback({
    content = content,
    display_content = build_display_message(proc),
  })
end

--- Handle completion of a shell command, updating the process record
--- @param proc sia.conversation.BashProcess
--- @param result sia.ShellResult
--- @param conversation sia.Conversation
--- @param on_completed (fun(proc: sia.conversation.BashProcess))?
local function handle_completion(proc, result, conversation, on_completed)
  proc.stdout_file =
    write_temp_output(result.stdout, conversation.id, proc.id, "stdout")
  proc.stderr_file =
    write_temp_output(result.stderr, conversation.id, proc.id, "stderr")

  proc.status = result.interrupted and "timed_out" or "completed"
  if result.code ~= 0 and not result.interrupted then
    proc.status = (result.code == 143) and "timed_out" or "completed"
  end
  proc.code = result.code or 0
  proc.interrupted = result.interrupted
  proc.completed_at = vim.uv.hrtime() / 1e9

  if on_completed then
    on_completed(proc)
  end
end

--- Launch a command via shell and track it as a bash process.
--- Async commands are spawned as independent processes (via spawn_detached)
--- that do not block the main shell queue.
--- Sync commands run through the main shell's serial queue.
--- @param args table tool arguments
--- @param conversation sia.Conversation
--- @param opts sia.NewToolExecuteOpts
--- @param on_started fun(proc: sia.conversation.BashProcess?, err: string?) called immediately after launch
--- @param on_completed (fun(proc: sia.conversation.BashProcess))? called when process finishes
local function launch_command(args, conversation, opts, on_started, on_completed)
  local banned, reason = utils.is_command_banned(args.bash_command)
  if banned then
    on_started(nil, string.format("Error: %s", reason))
    return
  end

  local is_dangerous = utils.detect_dangerous_command_patterns(args.bash_command)
  local prompt = string.format("Execute: %s", args.bash_command)

  opts.user_input(prompt, {
    level = is_dangerous and "warn" or "info",
    preview = function(preview_buf)
      local lines = vim.split(args.bash_command, "\n")
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
      vim.bo[preview_buf].ft = "sh"
      return #lines
    end,
    on_accept = function()
      local shell = ensure_shell(conversation)
      local proc = conversation:new_bash_process(args.bash_command, args.description)

      if args.async then
        local handle = shell:spawn_detached(
          args.bash_command,
          nil, -- no timeout for async; use kill command or :SiaShell stop
          opts and opts.cancellable,
          function(result)
            proc.detached_handle = nil
            handle_completion(proc, result, conversation, on_completed)
          end
        )
        proc.detached_handle = handle
      else
        shell:exec(
          args.bash_command,
          args.timeout or 120000,
          opts and opts.cancellable,
          function(result)
            handle_completion(proc, result, conversation, on_completed)
          end
        )
      end

      on_started(proc)
    end,
  })
end

return tool_utils.new_tool({
  name = "bash",
  message = function(args)
    if args.command == "start" then
      if args.description then
        return string.format("Starting: %s...", args.description)
      end
      return "Starting command..."
    elseif args.command == "status" then
      return string.format("Checking process %d...", args.id or 0)
    elseif args.command == "wait" then
      return string.format("Waiting for process %d...", args.id or 0)
    end
    return "Running command..."
  end,
  description = "Execute bash commands safely within the project directory",
  system_prompt = string.format(
    [[Executes bash commands in a persistent shell session with optional timeout,
ensuring proper handling and security measures.

## Commands

- **start**: Execute a bash command. By default, blocks until the command completes
  and returns the result directly. Set `async=true` to launch in the background.
- **status**: Check if an async process has completed (non-blocking). For running
  processes, includes the last 20 lines of stdout/stderr so you can monitor progress.
- **wait**: Block until an async process completes and return its result. Use
  `wait_timeout` to limit how long to wait — if the process hasn't finished, you
  get partial output and the process keeps running.

## Default Workflow (synchronous)

For most commands, simply use `start` — it runs the command and returns the result
in a single call:

<good-example>
bash(command="start", bash_command="pytest /foo/bar/tests", description="Run tests")
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

<good-example>
// Launch two independent commands concurrently:
bash(command="start", bash_command="make lint", description="Run linter", async=true)
bash(command="start", bash_command="make test", description="Run tests", async=true)
// Do other work...
bash(command="wait", id=1)
bash(command="wait", id=2)
</good-example>

<good-example>
// For very long-running tasks, use wait_timeout to check progress periodically:
bash(command="start", bash_command="make integration-test", description="Run integration tests", async=true)
// Do other work...
bash(command="wait", id=1, wait_timeout=10000)
// If still running, you get partial output and can continue working
bash(command="status", id=1)
// When ready, wait for the final result:
bash(command="wait", id=1)
</good-example>

<good-example>
// Kill a long-running process that is no longer needed:
bash(command="start", bash_command="tail -f /var/log/app.log", description="Watch logs", async=true)
// After getting enough information:
bash(command="kill", id=1)
</good-example>

## Large Output

When output exceeds the inline limit, the result includes truncated output along with
the file path containing the full output. Output files are stored at predictable
paths like `<tmpdir>/sia/bash/<id>/process_<n>_stdout`. You can use the `%s` or
`grep` tool on that path to inspect the full output.

## Security

Before executing a command, follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use the
     glob tool to verify the parent directory exists and is the correct location

2. Security Check:
   - Some commands are limited or banned to prevent prompt injection attacks.
   - Banned commands: %s.

## Usage Notes

- The `bash_command` and `description` parameters are required for `start`.
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
    table.concat(utils.BANNED_COMMANDS, ", "),
    tool_names.view
  ),

  parameters = {
    command = {
      type = "string",
      enum = { "start", "status", "wait", "kill" },
      description = "The command to execute: start (launch new process), status (check process status + partial output if async), wait (wait for process completion), kill (terminate a running process)",
    },
    bash_command = {
      type = "string",
      description = "The bash command to execute (required for 'start')",
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
      description = "The process ID (required for 'status', 'wait', and 'kill')",
    },
    async = {
      type = "boolean",
      description = "If true, launch the command in the background and return a process ID immediately. Use 'status' or 'wait' to get the result later. Default is false (synchronous).",
    },
    wait_timeout = {
      type = "number",
      description = "Optional timeout in milliseconds for 'wait'. If the process hasn't completed within this time, returns partial output and the process keeps running. Omit to wait indefinitely.",
    },
  },
  required = { "command" },
}, function(args, conversation, callback, opts)
  if not args.command then
    callback({
      content = { "Error: 'command' parameter is required" },
      display_content = icons.error .. " Failed to execute command",
      kind = "failed",
    })
    return
  end

  if args.command == "start" then
    if not args.bash_command or args.bash_command:match("^%s*$") then
      callback({
        content = { "Error: 'bash_command' parameter is required for 'start'" },
        display_content = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    if args.async then
      launch_command(args, conversation, opts, function(proc, err)
        if err then
          callback({
            content = { err },
            display_content = icons.error .. " Failed to execute command",
            kind = "failed",
          })
          return
        end
        callback({
          content = vim.split(string.format(ASYNC_START_REPLY, proc.id), "\n"),
          display_content = string.format(
            "%s Started %s (process %d)",
            icons.started,
            format_command(args.description or args.bash_command),
            proc.id
          ),
        })
      end, nil)
    else
      launch_command(args, conversation, opts, function(_, err)
        if err then
          callback({
            content = { err },
            display_content = icons.error .. " Failed to execute command",
            kind = "failed",
          })
        end
      end, function(proc)
        vim.schedule(function()
          return_completed_result(proc, conversation, callback)
        end)
      end)
    end
  elseif args.command == "status" then
    if not args.id then
      callback({
        content = { "Error: 'id' parameter is required for 'status'" },
        display_content = icons.error .. " Missing id parameter",
      })
      return
    end

    local proc = conversation:get_bash_process(args.id)
    if not proc then
      callback({
        content = {
          string.format(
            "Error: Process with ID %d not found in this conversation",
            args.id
          ),
        },
      })
      return
    end

    callback({ content = proc:get_preview() })
  elseif args.command == "wait" then
    if not args.id then
      callback({
        content = { "Error: 'id' parameter is required for 'wait'" },
      })
      return
    end

    local proc = conversation:get_bash_process(args.id)
    if not proc then
      callback({
        content = {
          string.format(
            "Error: Process with ID %d not found in this conversation",
            args.id
          ),
        },
      })
      return
    end

    if proc.status ~= "running" then
      return_completed_result(proc, conversation, callback)
      return
    end

    local wait_timeout = args.wait_timeout
    local start_time = vim.uv.hrtime() / 1e6

    local function poll()
      local current_proc = conversation:get_bash_process(args.id)
      if not current_proc then
        callback({
          content = { "Error: Process instance was removed" },
        })
        return
      end

      if current_proc.status ~= "running" then
        return_completed_result(current_proc, conversation, callback)
        return
      end

      if wait_timeout then
        local elapsed = (vim.uv.hrtime() / 1e6) - start_time
        if elapsed >= wait_timeout then
          local content = {
            string.format("Process %d is still running.", current_proc.id),
            string.format("Command: %s", current_proc.command),
            string.format(
              "Running for: %.1fs",
              (vim.uv.hrtime() / 1e9) - current_proc.started_at
            ),
            string.format(
              "Wait timed out after %.1fs. Use status to check progress or wait again.",
              wait_timeout / 1000
            ),
          }
          local preview = current_proc:get_preview()
          for i = 5, #preview do
            table.insert(content, preview[i])
          end
          callback({ content = content })
          return
        end
      end

      vim.defer_fn(poll, 500)
    end

    poll()
  elseif args.command == "kill" then
    if not args.id then
      callback({
        content = { "Error: 'id' parameter is required for 'kill'" },
        display_content = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    local proc = conversation:get_bash_process(args.id)
    if not proc then
      callback({
        content = { string.format("Error: No process with ID %d found", args.id) },
        display_content = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    local content, err = proc:stop()
    if err then
      callback({
        content = { err },
        display_content = icons.error .. " Failed to execute command",
        kind = "failed",
      })
      return
    end

    callback({
      content = content or { "Process is not running" },
      display_content = string.format(
        "%s Killed process %d: %s",
        icons.bash_kill,
        args.id,
        format_command(proc.command)
      ),
    })
  else
    callback({
      content = { string.format("Error: Unknown command '%s'", args.command) },
    })
  end
end)
