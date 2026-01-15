local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local FAILED_TO_EXECUTE = "❌ Failed to execute command"

return tool_utils.new_tool({
  name = "bash",
  message = function(args)
    if args.description then
      return string.format("%s...", args.description)
    end
    return string.format("Running command...")
  end,
  description = "Execute bash commands safely within the project directory",
  system_prompt = string.format(
    [[Executes a given bash command in a persistent shell session
with optional timeout, ensuring proper handling and security measures.

Before executing the command, please follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use the
     glob tool to verify the parent directory exists and is the correct
     location
   - For example, before running "mkdir foo/bar", first use glob to check
     that "foo" exists and is the intended parent directory

2. Security Check:
   - For security and to limit the threat of a prompt injection attack, some
     commands are limited or banned. If you use a disallowed command, you will
     receive an error message explaining the restriction. Explain the error to
     the User.
   - Verify that the command is not one of the banned commands: %s.

3. Command Execution:
   - After ensuring proper quoting, execute the command.
   - Capture the output of the command.
;
4. Output Processing:
   - If the output exceeds 8000 characters, output will be truncated before
     being returned to you.
   - Prepare the output for display to the user.

5. Return Result:
   - Provide the processed output of the command.
   - If any errors occurred during execution, include those in the output.

Usage notes:
  - The command argument is required.
  - You can specify an optional timeout in milliseconds (up to 300000ms / 5 minutes). If
    not specified, commands will timeout after 30 seconds.
  - VERY IMPORTANT: You MUST avoid using search commands like `find` and
    `grep`. Instead use grep, glob, or task to search. You MUST avoid
    read tools like `cat`, `head`, `tail`, and `ls`, and use read and
    workspace to read files.
  - When issuing multiple commands, use the ';' or '&&' operator to separate
    them. DO NOT use newlines (newlines are ok in quoted strings).
  - VERY IMPORTANT: You should use separate tool calls rather than chaining
    with `&&` when one of the commands changes the environment. The changes are
    persisted between calls!
  - VERY IMPORTANT: All commands share the same persistent shell session. This means:
    * Environment variables remain set between commands
    * Directory changes with `cd` persist
    * Shell settings like `ulimit` persist
  - Try to maintain your current working directory throughout the session by
    using absolute paths and avoiding usage of `cd`. You may use `cd` if the
    User explicitly requests it.

  <good-example>
  pytest /foo/bar/tests
  </good-example>
  <bad-example>
  cd /foo/bar && pytest tests
  </bad-example>

# Committing changes with git

When the user asks you to create a new git commit, follow these steps carefully:

1. Start with a single message that contains exactly three tool_use blocks that
   do the following (it is VERY IMPORTANT that you send these tool_use blocks
   in a single message, otherwise it will feel slow to the user!):
   - Run a git status command to see all untracked files.
   - Run a git diff command to see both staged and unstaged changes that will be committed.
   - Run a git log command to see recent commit messages, so that you can follow this repository's commit message style.

2. Analyze all the changes; if there are multiple unrelated changes ask the
   user what changes to commit and add.
3. Analyze all staged changes (both previously staged and newly added) and draft a commit message.

4. Create the commit and in order to ensure good formatting, ALWAYS pass the
   commit message via a HEREDOC, a la this example:
<example>
git commit -m "$(cat <<'EOF'
   Commit message here.

   )"
</example>

5. If the commit fails due to pre-commit hook changes, retry the commit ONCE to include these automated changes. If it fails again, it usually means a pre-commit hook is preventing the commit. If the commit succeeds but you notice that files were modified by the pre-commit hook, you MUST amend your commit to include them.

6. Finally, run git status to make sure the commit succeeded.]],
    table.concat(utils.BANNED_COMMANDS, ", ")
  ),

  parameters = {
    command = {
      type = "string",
      description = "The bash command to execute",
    },
    description = {
      type = "string",
      description = "Clear, consice description of what the command does in 3-10 words.Example:\nInput: ls\nOutput: Lists files in current directory",
    },
    timeout = {
      type = "number",
      description = "Optional timeout in milliseconds (default 30000, max 300000)",
    },
  },
  required = { "command" },
}, function(args, conversation, callback, opts)
  if not args.command or args.command:match("^%s*$") then
    callback({
      content = { "Error: No command specified" },
      display_content = { FAILED_TO_EXECUTE },
      kind = "failed",
    })
    return
  end

  local timeout = args.timeout or 30000
  if timeout > 300000 then
    timeout = 300000
  end

  local project_root = vim.fn.getcwd()

  local banned, reason = utils.is_command_banned(args.command)
  if banned then
    callback({
      content = { string.format("Error: %s", reason) },
      display_content = { FAILED_TO_EXECUTE },
      kind = "failed",
    })
    return
  end
  local is_dangerous = utils.detect_dangerous_command_patterns(args.command)
  local prompt = string.format("Execute: %s", args.command)

  opts.user_input(prompt, {
    level = is_dangerous and "warn" or "info",
    preview = function(preview_buf)
      local lines = vim.split(args.command, "\n")
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
      vim.bo[preview_buf].ft = "sh"
      return #lines
    end,
    on_accept = function()
      if not conversation.shell then
        local Shell = require("sia.shell")
        local config = require("sia.config")
        conversation.shell = Shell.new(project_root, config.options.defaults.shell)
      end

      conversation.shell:exec(
        args.command,
        timeout,
        opts and opts.cancellable,
        function(result)
          local stdout = result.stdout or ""
          local stderr = result.stderr or ""
          local code = result.code or 0

          local content = {}

          local cwd = conversation.shell:pwd()
          local relative_cwd = vim.fn.fnamemodify(cwd, ":~:.")
          if relative_cwd == "" or relative_cwd == "." then
            relative_cwd = "."
          end
          table.insert(content, string.format("Working directory: %s", relative_cwd))

          if stdout and stdout ~= "" then
            table.insert(content, "")
            table.insert(content, stdout)
          end
          if stderr and stderr ~= "" then
            if stdout and stdout ~= "" then
              table.insert(content, "")
            elseif #content > 1 then
              table.insert(content, "")
            end
            table.insert(content, "stderr:")
            table.insert(content, stderr)
          end
          if code ~= 0 then
            table.insert(content, string.format("Exit code: %d", code))
          end
          if result.interrupted then
            table.insert(content, "Command was interrupted")
          end

          if #content == 1 then
            table.insert(content, "")
            table.insert(content, "Command completed successfully (no output)")
          end

          local display_msg
          if code == 0 then
            if args.description then
              display_msg =
                string.format("⚡ %s: `%s`", args.description, args.command)
            else
              display_msg = string.format("⚡ Executed `%s`", args.command)
            end
          elseif result.interrupted then
            if args.description then
              display_msg =
                string.format("⚡ Stopped %s: `%s`", args.description, args.command)
            else
              display_msg = string.format("⚡ Stopped `%s`", args.command)
            end
          else
            if args.description then
              display_msg = string.format(
                "⚡ %s: `%s` (exit code %d)",
                args.description,
                args.command,
                code
              )
            else
              display_msg =
                string.format("⚡ Executed `%s` (exit code %d)", args.command, code)
            end
          end

          callback({
            content = content,
            display_content = vim.split(
              display_msg,
              "\n",
              { trimempty = true, plain = true }
            ),
          })
        end
      )
    end,
  })
end)
