local M = {}

---@class sia.Shell
---@field private process vim.SystemObj? vim.system process handle
---@field private cwd string current working directory
---@field private project_root string project root directory (security boundary)
---@field private command_queue sia.ShellCommand[] queued commands
---@field private is_executing boolean whether a command is currently executing
---@field private is_alive boolean whether the shell process is alive
---@field private temp_files table<string, string> temporary files for IPC
---@field private shell_path string path to shell executable
local Shell = {}
Shell.__index = Shell

---@class sia.ShellCommand
---@field command string the command to execute
---@field timeout number? timeout in milliseconds
---@field callback function callback to call with result
---@field cancellable sia.Cancellable? cancellation token
---@field cancel_timer userdata? timer for polling cancellation status

---@class sia.ShellResult
---@field stdout string command output
---@field stderr string command errors
---@field code number exit code
---@field interrupted boolean whether command was interrupted

local DEFAULT_TIMEOUT = 30000 -- 30 seconds
local MAX_TIMEOUT = 300000 -- 5 minutes
local TEMP_PREFIX = vim.fn.tempname() .. "-sia-shell-"

---Create a new shell instance
---@param project_root string the project root directory (security boundary)
---@return sia.Shell
function M.new(project_root)
  local self = setmetatable({}, Shell)

  self.project_root = vim.fn.resolve(project_root)
  self.cwd = self.project_root
  self.command_queue = {}
  self.is_executing = false
  self.is_alive = false
  self.shell_path = vim.env.SHELL or "/bin/bash"

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

---@private
function Shell:_start_shell()
  if self.is_alive then
    return
  end

  for _, file in pairs(self.temp_files) do
    vim.fn.writefile({}, file)
  end

  vim.fn.writefile({ self.project_root }, self.temp_files.cwd)

  local safe_env = {
    PATH = vim.env.PATH,
    HOME = vim.env.HOME,
    USER = vim.env.USER,
    SHELL = vim.env.SHELL,
    TERM = vim.env.TERM,
    PWD = self.project_root,
    LANG = vim.env.LANG,
    LC_ALL = vim.env.LC_ALL,
    GIT_EDITOR = "true",
  }

  self.process = vim.system({
    self.shell_path,
  }, {
    cwd = self.project_root,
    env = safe_env,
    stdin = true,
    stdout = false,
    stderr = false,
    text = true,
  }, function(result)
    self.is_alive = false
    self:_cleanup_temp_files()

    if result.code ~= 0 then
      vim.notify(string.format("Sia: shell exited with code %d", result.code), vim.log.levels.WARN)
    end
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
---@param cancellable sia.Cancellable? cancellation token
---@param callback function callback to call with result
function Shell:exec(command, timeout, cancellable, callback)
  timeout = math.min(timeout or DEFAULT_TIMEOUT, MAX_TIMEOUT)

  table.insert(self.command_queue, {
    command = command,
    timeout = timeout,
    callback = callback,
    cancellable = cancellable,
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
  local cmd = table.remove(self.command_queue, 1)

  local cancelled = false
  if cmd.cancellable then
    -- Check cancellation status periodically
    cmd.cancel_timer = vim.uv.new_timer()
    cmd.cancel_timer:start(0, 100, function() -- Check every 100ms
      if cmd.cancellable.is_cancelled then
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
        result.stderr = (result.stderr or "") .. "\nWarning: Shell directory was reset to project root"
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
  for _, file in pairs({ self.temp_files.stdout, self.temp_files.stderr, self.temp_files.status }) do
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
          result.stdout = table.concat(vim.fn.readfile(self.temp_files.stdout), "\n")
        end

        if vim.fn.filereadable(self.temp_files.stderr) == 1 then
          result.stderr = table.concat(vim.fn.readfile(self.temp_files.stderr), "\n")
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
          result.stderr = (result.stderr ~= "" and result.stderr .. "\n" or "") .. "Command execution timed out"
        end

        local max_output = 8000
        if #result.stdout > max_output then
          result.stdout = result.stdout:sub(1, max_output) .. "\n... (output truncated)"
        end
        if #result.stderr > max_output then
          result.stderr = result.stderr:sub(1, max_output) .. "\n... (error output truncated)"
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
    vim.system({ "pkill", "-TERM", "-P", tostring(pid) }, { text = true }, function()
      -- killed
    end)
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
    if vim.fn.filereadable(file) == 1 then
      vim.fn.delete(file)
    end
  end
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
