local M = {}

--- Strip ANSI escape sequences (colors, cursor movement, etc.) from a string
--- @param s string
--- @return string
local function strip_ansi(s)
  s = s:gsub("\27%[%d*;?%d*;?%d*[A-Za-z]", "")
  s = s:gsub("\27%[[%d;]*m", "")
  s = s:gsub("\27%][^\a\27]*[\a]", "")
  s = s:gsub("\27%][^\a\27]*\27\\", "")
  s = s:gsub("\27[%(%)][AB012]", "")
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\r", "")
  return s
end

---@class sia.Shell
---@field private process vim.SystemObj? vim.system process handle
---@field private cwd string current working directory
---@field private project_root string project root directory (security boundary)
---@field private command_queue sia.ShellCommand[] queued commands
---@field private is_executing boolean whether a command is currently executing
---@field private is_alive boolean whether the shell process is alive
---@field private temp_files table<string, string> temporary files for IPC
---@field private shell_path string path to shell executable
---@field private shell_args string[] arguments for the shell executable
local Shell = {}
Shell.__index = Shell

---@class sia.ShellCommand
---@field command string the command to execute
---@field timeout number? timeout in milliseconds
---@field callback function callback to call with result
---@field is_cancelled (fun():boolean)?
---@field cancel_timer uv_timer_t?

---@class sia.ShellResult
---@field stdout string command output (may be truncated for large outputs)
---@field stderr string command errors (may be truncated for large outputs)
---@field stdout_file string? persistent temp file with full stdout
---@field stderr_file string? persistent temp file with full stderr
---@field code number exit code
---@field interrupted boolean whether command was interrupted

local DEFAULT_TIMEOUT = 30000 -- 30 seconds
local MAX_TIMEOUT = 300000 -- 5 minutes
local TEMP_PREFIX = vim.fn.tempname() .. "-sia-shell-"

---Create a new shell instance
---@param project_root string the project root directory (security boundary)
---@param shell_opts sia.config.Shell? shell configuration
---@return sia.Shell
function M.new(project_root, shell_opts)
  local self = setmetatable({}, Shell)

  self.project_root = vim.fn.resolve(project_root)
  self.cwd = self.project_root
  self.command_queue = {}
  self.is_executing = false
  self.is_alive = false

  shell_opts = shell_opts or {}
  self.shell_path = shell_opts.command or "/bin/bash"

  local args = shell_opts.args
  if type(args) == "function" then
    args = args()
  end
  self.shell_args = args or { "-s" }

  local id = string.format("%x", math.random(0x10000))
  self.temp_files = {
    status = TEMP_PREFIX .. id .. "-status",
    stdout = TEMP_PREFIX .. id .. "-stdout",
    stderr = TEMP_PREFIX .. id .. "-stderr",
    cwd = TEMP_PREFIX .. id .. "-cwd",
  }

  self:_start_shell()
  return self
end

---Build the safe environment table for shell processes
---@private
---@param cwd string? working directory to set as PWD (defaults to project_root)
---@return table<string, string>
function Shell:_build_env(cwd)
  return {
    PATH = vim.env.PATH,
    HOME = vim.env.HOME,
    USER = vim.env.USER,
    SHELL = vim.env.SHELL,
    TERM = vim.env.TERM,
    PWD = cwd or self.project_root,
    LANG = vim.env.LANG,
    LC_ALL = vim.env.LC_ALL,
    GIT_EDITOR = "true",
  }
end

---@private
function Shell:_start_shell()
  if self.is_alive then
    return
  end

  for _, file in pairs(self.temp_files) do
    vim.fn.writefile({}, file)
  end

  vim.fn.writefile({ self.project_root }, self.temp_files.cwd)

  self.process = vim.system({
    self.shell_path,
    unpack(self.shell_args),
  }, {
    cwd = self.project_root,
    env = self:_build_env(),
    stdin = true,
    stdout = false,
    stderr = false,
    text = true,
  }, function(_)
    self.is_alive = false
    self:_cleanup_temp_files()
  end)

  if self.process then
    self.is_alive = true
  else
    error("Failed to start shell process")
  end
end

---@private
---@param command string
function Shell:_send_to_shell(command)
  if not self.is_alive or not self.process then
    error("Shell is not alive")
  end

  local success, err = pcall(function()
    self.process:write(command .. "\n")
  end)

  if not success then
    error("Failed to write to shell: " .. (err or "unknown error"))
  end
end

---Execute a command and return the result
---@param command string the command to execute
---@param timeout number? timeout in milliseconds
---@param is_cancelled (fun():boolean)?
---@param callback function callback to call with result
function Shell:exec(command, timeout, is_cancelled, callback)
  timeout = math.min(timeout or DEFAULT_TIMEOUT, MAX_TIMEOUT)

  table.insert(self.command_queue, {
    command = command,
    timeout = timeout,
    callback = callback,
    is_cancelled = is_cancelled,
  })

  self:_process_queue()
end

---@private
function Shell:_process_queue()
  if self.is_executing or #self.command_queue == 0 then
    return
  end

  if not self.is_alive then
    -- Try to restart shell
    self:_start_shell()
    if not self.is_alive then
      for _, cmd in ipairs(self.command_queue) do
        cmd.callback({
          stdout = "",
          stderr = "Shell process is not available",
          code = 1,
          interrupted = false,
        })
      end
      self.command_queue = {}
      return
    end
  end

  self.is_executing = true
  --- @type sia.ShellCommand
  local cmd = table.remove(self.command_queue, 1)

  local cancelled = false
  if cmd.is_cancelled then
    cmd.cancel_timer = vim.uv.new_timer()
    cmd.cancel_timer:start(0, 100, function()
      if cmd.is_cancelled() then
        cancelled = true
        self:_kill_children()
        pcall(cmd.cancel_timer.stop, cmd.cancel_timer)
        pcall(cmd.cancel_timer.close, cmd.cancel_timer)
      end
    end)
  end

  vim.schedule(function()
    self:_exec_internal(cmd.command, cmd.timeout, function(result)
      self.is_executing = false

      if cmd.cancel_timer then
        pcall(cmd.cancel_timer.stop, cmd.cancel_timer)
        pcall(cmd.cancel_timer.close, cmd.cancel_timer)
      end

      self:_update_cwd()

      if not self:_is_within_project() then
        self:_update_cwd()
        result.stderr = (result.stderr or "")
          .. "\nWarning: Shell directory was reset to project root"
      end

      if cancelled then
        result.interrupted = true
      end

      cmd.callback(result)

      vim.schedule(function()
        self:_process_queue()
      end)
    end)
  end)
end

---Execute a command internally
---@private
---@param command string
---@param timeout number
---@param callback function
function Shell:_exec_internal(command, timeout, callback)
  for _, file in pairs({
    self.temp_files.stdout,
    self.temp_files.stderr,
    self.temp_files.status,
  }) do
    vim.fn.writefile({}, file)
  end

  local escaped_command = vim.fn.shellescape(command)

  -- 1. Execute the command with redirections
  -- 2. Capture exit code immediately
  -- 3. Update CWD file
  -- 4. Write exit code to status file
  local command_sequence = string.format(
    [[
eval %s < /dev/null > %s 2> %s
EXEC_EXIT_CODE=$?
pwd > %s
echo $EXEC_EXIT_CODE > %s
]],
    escaped_command,
    vim.fn.shellescape(self.temp_files.stdout),
    vim.fn.shellescape(self.temp_files.stderr),
    vim.fn.shellescape(self.temp_files.cwd),
    vim.fn.shellescape(self.temp_files.status)
  )

  self:_send_to_shell(command_sequence)

  local start_time = vim.uv.hrtime()
  local check_timer = vim.uv.new_timer()

  check_timer:start(0, 10, function()
    local elapsed = (vim.uv.hrtime() - start_time) / 1e6

    local status_size = 0
    if vim.fn.filereadable(self.temp_files.status) == 1 then
      status_size = vim.fn.getfsize(self.temp_files.status)
    end

    local completed = status_size > 0
    local timed_out = elapsed > timeout

    if completed or timed_out then
      check_timer:stop()
      check_timer:close()

      vim.schedule(function()
        local result = {
          stdout = "",
          stderr = "",
          code = 0,
          interrupted = false,
        }

        if vim.fn.filereadable(self.temp_files.stdout) == 1 then
          result.stdout =
            strip_ansi(table.concat(vim.fn.readfile(self.temp_files.stdout), "\n"))
        end

        if vim.fn.filereadable(self.temp_files.stderr) == 1 then
          result.stderr =
            strip_ansi(table.concat(vim.fn.readfile(self.temp_files.stderr), "\n"))
        end

        if completed then
          if vim.fn.filereadable(self.temp_files.status) == 1 then
            local status_lines = vim.fn.readfile(self.temp_files.status)
            if #status_lines > 0 then
              result.code = tonumber(status_lines[1]) or 0
            end
          end
        else
          self:_kill_children()
          result.code = 143 -- SIGTERM
          result.stderr = (result.stderr ~= "" and result.stderr .. "\n" or "")
            .. "Command execution timed out"
        end

        callback(result)
      end)
    end
  end)
end

---@private
function Shell:_kill_children()
  if not self.process or not self.is_alive then
    return
  end

  local pid = self.process.pid
  if pid then
    vim.system({
      "sh",
      "-c",
      string.format(
        "ps -A -o pid= -o ppid= | awk '$2 == %d {print $1}' | xargs kill -TERM 2>/dev/null || true",
        pid
      ),
    }, { text = true }, function() end)
  end
end

---@private
function Shell:_update_cwd()
  if vim.fn.filereadable(self.temp_files.cwd) == 1 then
    local cwd_lines = vim.fn.readfile(self.temp_files.cwd)
    if #cwd_lines > 0 then
      local new_cwd = vim.trim(cwd_lines[1])
      if new_cwd ~= "" then
        self.cwd = new_cwd
      end
    end
  end
end

---@private
---@return boolean
function Shell:_is_within_project()
  local resolved_cwd = vim.fn.resolve(self.cwd)
  local resolved_root = vim.fn.resolve(self.project_root)
  return vim.startswith(resolved_cwd, resolved_root)
end

---@return string
function Shell:pwd()
  self:_update_cwd()
  return self.cwd
end

---@private
function Shell:_cleanup_temp_files()
  for _, file in pairs(self.temp_files) do
    vim.uv.fs_unlink(file)
  end
end

---@class sia.DetachedProcess
---@field process vim.SystemObj
---@field kill fun()
---@field is_done fun(): boolean
---@field get_output fun(): {stdout: string, stderr: string}

---Spawn an independent process that does not block the main shell queue.
---Inherits the current working directory but not shell-specific state (exports, aliases).
---The returned handle can be killed or polled for completion.
---@param command string the command to execute
---@param timeout number? timeout in milliseconds (nil = no timeout, capped at MAX_TIMEOUT if set)
---@param is_cancelled (fun():boolean)?
---@param callback fun(result: sia.ShellResult) called when the process finishes
---@return sia.DetachedProcess
function Shell:spawn_detached(command, timeout, is_cancelled, callback)
  local cwd = self:pwd()
  -- Security: ensure cwd is within project root
  local resolved_cwd = vim.fn.resolve(cwd)
  local resolved_root = vim.fn.resolve(self.project_root)
  if not vim.startswith(resolved_cwd, resolved_root) then
    cwd = self.project_root
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false
  local timed_out = false

  local proc = vim.system({
    self.shell_path,
    "-c",
    command,
  }, {
    cwd = cwd,
    env = self:_build_env(cwd),
    stdin = false,
    stdout = function(_, data)
      if data then
        table.insert(stdout_chunks, data)
      end
    end,
    stderr = function(_, data)
      if data then
        table.insert(stderr_chunks, data)
      end
    end,
    text = true,
  }, function(obj)
    done = true
    local stdout = strip_ansi(table.concat(stdout_chunks))
    local stderr = strip_ansi(table.concat(stderr_chunks))

    if timed_out then
      stderr = (stderr ~= "" and stderr .. "\n" or "") .. "Command execution timed out"
    end

    vim.schedule(function()
      callback({
        stdout = stdout,
        stderr = stderr,
        code = timed_out and 143 or (obj.code or 0),
        interrupted = timed_out,
      })
    end)
  end)

  -- Timeout timer (only if timeout is specified)
  local timeout_timer
  if timeout then
    timeout_timer = vim.uv.new_timer()
    timeout_timer:start(timeout, 0, function()
      if not done then
        timed_out = true
        proc:kill(15) -- SIGTERM
      end
      pcall(timeout_timer.stop, timeout_timer)
      pcall(timeout_timer.close, timeout_timer)
    end)
  end

  -- Cancellation polling
  local cancel_timer
  if is_cancelled then
    cancel_timer = vim.uv.new_timer()
    cancel_timer:start(0, 100, function()
      if is_cancelled() and not done then
        timed_out = true
        proc:kill(15)
        pcall(cancel_timer.stop, cancel_timer)
        pcall(cancel_timer.close, cancel_timer)
      elseif done then
        pcall(cancel_timer.stop, cancel_timer)
        pcall(cancel_timer.close, cancel_timer)
      end
    end)
  end

  return {
    process = proc,
    kill = function()
      if not done then
        timed_out = true
        proc:kill(15)
      end
    end,
    is_done = function()
      return done
    end,
    get_output = function()
      -- Pump pending I/O so libuv delivers any buffered stdout/stderr
      -- data to our callbacks before we read the chunks
      vim.uv.run("nowait")
      return {
        stdout = strip_ansi(table.concat(stdout_chunks)),
        stderr = strip_ansi(table.concat(stderr_chunks)),
      }
    end,
  }
end

---Close the shell
function Shell:close()
  if self.process and self.is_alive then
    self:_kill_children()
    self.process:kill(15) -- SIGTERM
    self.is_alive = false
  end

  self:_cleanup_temp_files()

  for _, cmd in ipairs(self.command_queue) do
    cmd.callback({
      stdout = "",
      stderr = "Shell was closed",
      code = 1,
      interrupted = true,
    })
  end
  self.command_queue = {}
end

---@return boolean
function Shell:is_running()
  return self.is_alive
end

return M
