local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local FAILED_TO_EXECUTE = "❌ Failed to execute command"

local START_REPLY = [[
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
    conversation.shell = Shell.new(project_root, config.options.defaults.shell)
  end
  return conversation.shell
end

--- Write full output to a persistent temp file
--- @param content string
--- @return string? path the temp file path, or nil if content is empty
local function write_temp_output(content)
  if not content or content == "" then
    return nil
  end
  local path = vim.fn.tempname()
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

--- Build a display message for the bash process
--- @param proc sia.conversation.BashProcess
--- @return string
local function build_display_message(proc)
  local desc = proc.description or proc.command
  if proc.status == "completed" then
    if proc.code == 0 then
      return string.format("⚡ %s: `%s`", desc, proc.command)
    else
      return string.format(
        "⚡ %s: `%s` (exit code %d)",
        desc,
        proc.command,
        proc.code or -1
      )
    end
  elseif proc.status == "timed_out" or proc.interrupted then
    return string.format("⚡ Stopped %s: `%s`", desc, proc.command)
  else
    return string.format("⚡ %s: `%s` (failed)", desc, proc.command)
  end
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
    [[Executes bash commands asynchronously in a persistent shell session with
optional timeout, ensuring proper handling and security measures.

Commands run in the background and you can continue working while they execute.

## Commands

- **start**: Launch a new bash command. Returns a process ID immediately.
- **status**: Check if a running process has completed (non-blocking).
- **wait**: Block until a process completes and return its result.

## Workflow

1. Use `start` to launch a command. You'll get a process ID back immediately.
2. Continue doing other work (editing files, reading, etc.) while the command runs.
3. Use `status` to check if the process has finished without blocking.
4. Use `wait` when you need the result and have nothing else to do.

For quick commands that you need results from immediately, you can call `start`
followed by `wait` with the returned process ID.

## Large Output

When output exceeds the inline limit, `wait` returns truncated output along with
the temp file path containing the full output (e.g. `/tmp/nvimXXXXXX`). You can
use the `read` or `grep` tool on that path to inspect the full output.

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
- You can specify an optional timeout in milliseconds (up to 300000ms / 5 minutes).
  If not specified, commands will timeout after 30 seconds.
- VERY IMPORTANT: You MUST avoid using search commands like `find` and
  `grep`. Instead use grep, glob, or task to search. You MUST avoid
  read tools like `cat`, `head`, `tail`, and `ls`, and use read and
  workspace to read files.
- When issuing multiple commands, use the ';' or '&&' operator to separate
  them. DO NOT use newlines (newlines are ok in quoted strings).
- All commands share the same persistent shell session. This means:
  * Environment variables remain set between commands
  * Directory changes with `cd` persist
  * Shell settings like `ulimit` persist
- Try to maintain your current working directory throughout the session by
  using absolute paths and avoiding usage of `cd`.
- Launch multiple independent commands concurrently with separate `start` calls
  to maximize performance!

<good-example>
bash(command="start", bash_command="pytest /foo/bar/tests", description="Run tests")
// continue working...
bash(command="wait", id=1)
</good-example>

<good-example>
// Launch two independent commands concurrently:
bash(command="start", bash_command="make lint", description="Run linter")
bash(command="start", bash_command="make test", description="Run tests")
// Do other work...
bash(command="wait", id=1)
bash(command="wait", id=2)
</good-example>

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
    table.concat(utils.BANNED_COMMANDS, ", ")
  ),

  parameters = {
    command = {
      type = "string",
      enum = { "start", "status", "wait" },
      description = "The command to execute: start (launch new process), status (check process status), wait (wait for process completion)",
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
      description = "Optional timeout in milliseconds (default 30000, max 300000, only for 'start')",
    },
    id = {
      type = "integer",
      description = "The process ID (required for 'status' and 'wait')",
    },
  },
  required = { "command" },
}, function(args, conversation, callback, opts)
  if not args.command then
    callback({
      content = { "Error: 'command' parameter is required" },
      display_content = { FAILED_TO_EXECUTE },
      kind = "failed",
    })
    return
  end

  if args.command == "start" then
    if not args.bash_command or args.bash_command:match("^%s*$") then
      callback({
        content = { "Error: 'bash_command' parameter is required for 'start'" },
        display_content = { FAILED_TO_EXECUTE },
        kind = "failed",
      })
      return
    end

    local timeout = args.timeout or 30000
    if timeout > 300000 then
      timeout = 300000
    end

    local banned, reason = utils.is_command_banned(args.bash_command)
    if banned then
      callback({
        content = { string.format("Error: %s", reason) },
        display_content = { FAILED_TO_EXECUTE },
        kind = "failed",
      })
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
        local proc =
          conversation:new_bash_process(args.bash_command, args.description)

        shell:exec(
          args.bash_command,
          timeout,
          opts and opts.cancellable,
          function(result)
            proc.stdout_file = write_temp_output(result.stdout)
            proc.stderr_file = write_temp_output(result.stderr)

            proc.status = result.interrupted and "timed_out" or "completed"
            if result.code ~= 0 and not result.interrupted then
              proc.status = (result.code == 143) and "timed_out" or "completed"
            end
            proc.code = result.code or 0
            proc.interrupted = result.interrupted
            proc.completed_at = vim.uv.hrtime() / 1e9
          end
        )

        callback({
          content = vim.split(string.format(START_REPLY, proc.id), "\n"),
          display_content = {
            string.format(
              "🚀 Started `%s` (process %d)",
              args.description or args.bash_command,
              proc.id
            ),
          },
        })
      end,
    })
  elseif args.command == "status" then
    if not args.id then
      callback({
        content = { "Error: 'id' parameter is required for 'status'" },
        display_content = { "❌ Missing id parameter" },
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

    local content = {
      string.format("Process ID: %d", proc.id),
      string.format("Command: %s", proc.command),
      string.format("Status: %s", proc.status),
    }

    if proc.status ~= "running" then
      table.insert(content, string.format("Exit code: %d", proc.code or -1))
      if proc.interrupted then
        table.insert(content, "Interrupted: yes")
      end
      if proc.stdout_file then
        table.insert(content, string.format("Full stdout: %s", proc.stdout_file))
      end
      if proc.stderr_file then
        table.insert(content, string.format("Full stderr: %s", proc.stderr_file))
      end
    else
      local elapsed = (vim.uv.hrtime() / 1e9) - proc.started_at
      table.insert(content, string.format("Running for: %.1fs", elapsed))
    end

    callback({ content = content })
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

    -- Helper to return result for a completed process
    local function return_completed_result(completed_proc)
      local shell = ensure_shell(conversation)
      local cwd = shell:pwd()

      -- Read result from temp files
      local stdout = ""
      local stderr = ""

      if completed_proc.stdout_file and vim.fn.filereadable(completed_proc.stdout_file) == 1 then
        stdout = table.concat(vim.fn.readfile(completed_proc.stdout_file), "\n")
      end
      if completed_proc.stderr_file and vim.fn.filereadable(completed_proc.stderr_file) == 1 then
        stderr = table.concat(vim.fn.readfile(completed_proc.stderr_file), "\n")
      end

      local result = {
        stdout = stdout,
        stderr = stderr,
        code = completed_proc.code or 0,
        interrupted = completed_proc.interrupted or false,
      }

      local content = build_result_summary(completed_proc, result, cwd)
      callback({
        content = content,
        display_content = vim.split(
          build_display_message(completed_proc),
          "\n",
          { trimempty = true, plain = true }
        ),
      })
    end

    -- If already completed, return result immediately
    if proc.status ~= "running" then
      return_completed_result(proc)
      return
    end

    -- Poll until complete
    local function poll()
      local current_proc = conversation:get_bash_process(args.id)
      if not current_proc then
        callback({
          content = { "Error: Process instance was removed" },
        })
        return
      end

      if current_proc.status ~= "running" then
        return_completed_result(current_proc)
      else
        vim.defer_fn(poll, 500)
      end
    end

    poll()
  else
    callback({
      content = { string.format("Error: Unknown command '%s'", args.command) },
    })
  end
end)
