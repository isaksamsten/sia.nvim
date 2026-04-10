--- @class sia.process.Output
--- @field stdout string
--- @field stderr string

--- @class sia.process.RunningProcess
--- @field id integer
--- @field kind "running"
--- @field command string
--- @field description string?

--- @class sia.process.FinishedProcess
--- @field id integer
--- @field kind "finished"
--- @field outcome "completed"|"failed"|"timed_out"|"interrupted"
--- @field command string
--- @field description string?
--- @field code integer
--- @field duration integer
--- @field file {stderr: string?, stdout: string?}

--- @alias sia.process.Process sia.process.RunningProcess|sia.process.FinishedProcess

--- @param content string?
--- @param conversation_id integer
--- @param proc_id integer
--- @param stream "stdout"|"stderr"
--- @return string? path the temp file path, or nil if content is empty
local function write_output(content, conversation_id, proc_id, stream)
  if not content or content == "" then
    return nil
  end

  local dir = require("sia.utils").dirs.bash(conversation_id)
  vim.fn.mkdir(dir, "p")

  local path = vim.fs.joinpath(dir, string.format("process_%d_%s", proc_id, stream))
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

--- @param path string?
--- @return string
local function read_output_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- @param proc sia.process.ProcessRecord
--- @param conversation_id integer
--- @param result sia.ShellResult
local function finalize(proc, conversation_id, result)
  proc.completed_at = vim.uv.hrtime() / 1e9
  proc.code = result.code or 0

  if result.interrupted then
    proc.status = "interrupted"
  elseif result.code == 143 then
    proc.status = "timed_out"
  else
    proc.status = "completed"
  end

  proc.stdout_file = write_output(result.stdout, conversation_id, proc.id, "stdout")
  proc.stderr_file = write_output(result.stderr, conversation_id, proc.id, "stderr")
end

--- @param status string
--- @return "completed"|"failed"|"timed_out"|"interrupted"
local function to_process_outcome(status)
  if
    status == "completed"
    or status == "failed"
    or status == "timed_out"
    or status == "interrupted"
  then
    return status
  end

  error("Cannot convert running process record into a finished process")
end

--- @param proc sia.process.ProcessRecord
--- @return sia.process.Process
local function to_process(proc)
  if proc.status == "running" then
    --- @type sia.process.RunningProcess
    return {
      id = proc.id,
      kind = "running",
      command = proc.command,
      description = proc.description,
    }
  end

  --- @type sia.process.FinishedProcess
  return {
    id = proc.id,
    kind = "finished",
    outcome = to_process_outcome(proc.status),
    command = proc.command,
    description = proc.description,
    code = proc.code or -1,
    duration = proc.completed_at - proc.started_at,
    file = { stderr = proc.stderr_file, stdout = proc.stdout_file },
  }
end

--- @class sia.process.ProcessRecord
--- @field id integer
--- @field command string
--- @field description string?
--- @field status "running"|"completed"|"failed"|"timed_out"|"interrupted"
--- @field code integer?
--- @field stdout_file string?
--- @field stderr_file string?
--- @field started_at number
--- @field completed_at number?
--- @field cancellable sia.Cancellable
--- @field async_process sia.shell.AsyncProcess?
--- @field sync_process sia.shell.SyncProcess?
local ProcessRecord = {}
ProcessRecord.__index = ProcessRecord

--- @return sia.process.Output
function ProcessRecord:get_live_output()
  if self.async_process then
    return self.async_process.get_output()
  end

  if self.sync_process and self.sync_process.is_active() then
    return self.sync_process.get_output()
  end

  return { stdout = "", stderr = "" }
end

--- @return sia.process.Output
function ProcessRecord:get_persisted_output()
  return {
    stdout = read_output_file(self.stdout_file),
    stderr = read_output_file(self.stderr_file),
  }
end

--- @return sia.process.Output
function ProcessRecord:get_output()
  if self.status == "running" then
    return self:get_live_output()
  end

  return self:get_persisted_output()
end

--- @param proc sia.process.ProcessRecord
--- @param conversation_id integer
--- @param captured sia.process.Output
local function persist_output(proc, conversation_id, captured)
  proc.stdout_file = write_output(captured.stdout, conversation_id, proc.id, "stdout")
  proc.stderr_file = write_output(captured.stderr, conversation_id, proc.id, "stderr")
end

--- @class sia.process.ExecOpts
--- @field description string?
--- @field timeout number?
--- @field is_cancelled fun():boolean
--- @field on_complete fun(proc: sia.process.Process)?

--- @alias sia.process.StopResult "stop_requested"|"stopped"|"already_finished"|"not_found"

--- @class sia.process.Runtime
--- @field private shell sia.Shell?
--- @field private items sia.process.ProcessRecord[]
--- @field private conversation_id integer
--- @field private shell_config { project_root: string, shell_opts: sia.config.Shell? }
local Runtime = {}
Runtime.__index = Runtime

--- @private
--- @return sia.Shell
function Runtime:_ensure_shell()
  if not self.shell then
    self.shell = require("sia.process.shell").new(
      self.shell_config.project_root,
      self.shell_config.shell_opts
    )
  end
  return self.shell
end

--- @private
--- @param id integer
--- @return sia.process.ProcessRecord?
function Runtime:get_record(id)
  return self.items[id]
end

--- @param proc_id integer
--- @param command string
--- @param description string?
--- @return sia.process.ProcessRecord
local function create_record(proc_id, command, description)
  local proc = setmetatable({
    id = proc_id,
    command = command,
    description = description,
    status = "running",
    started_at = vim.uv.hrtime() / 1e9,
    cancellable = { is_cancelled = false },
  }, ProcessRecord)
  return proc
end

--- @param command string
--- @param opts sia.process.ExecOpts
--- @return sia.process.Process
function Runtime:exec(command, opts)
  local shell = self:_ensure_shell()
  local proc_id = #self.items + 1
  local proc = create_record(proc_id, command, opts.description)

  proc.sync_process = shell:exec(command, opts.timeout or 120000, function()
    return opts.is_cancelled() or proc.cancellable.is_cancelled
  end, function(result)
    proc.sync_process = nil
    finalize(proc, self.conversation_id, result)
    if opts.on_complete then
      opts.on_complete(to_process(proc))
    end
  end)

  table.insert(self.items, proc)
  return to_process(proc)
end

--- @param command string
--- @param opts sia.process.ExecOpts
--- @return sia.process.Process
function Runtime:exec_async(command, opts)
  local shell = self:_ensure_shell()
  local proc_id = #self.items + 1
  local proc = create_record(proc_id, command, opts.description)

  proc.async_process = shell:spawn_detached(
    command,
    opts.timeout,
    opts.is_cancelled,
    function(result)
      if proc.status ~= "running" then
        return
      end

      proc.async_process = nil
      finalize(proc, self.conversation_id, result)
      if opts.on_complete then
        opts.on_complete(to_process(proc))
      end
    end
  )

  table.insert(self.items, proc)
  return to_process(proc)
end

--- @return string
function Runtime:pwd()
  local shell = self:_ensure_shell()
  return shell:pwd()
end

--- @param id integer
--- @return sia.process.Output? output
function Runtime:get_output(id)
  local proc = self:get_record(id)
  if not proc then
    return nil
  end

  return proc:get_output()
end

--- @param id integer
--- @return sia.process.Process?
function Runtime:get(id)
  local proc = self:get_record(id)
  return proc and to_process(proc) or nil
end

--- @return sia.process.Process[]
function Runtime:list()
  return vim.iter(self.items):map(to_process):totable()
end

--- @param id integer
--- @return sia.process.StopResult
function Runtime:stop(id)
  local proc = self:get_record(id)
  if not proc then
    return "not_found"
  end

  if proc.status ~= "running" then
    return "already_finished"
  end

  if not proc.async_process then
    proc.cancellable.is_cancelled = true
    return "stop_requested"
  end

  local output = proc.async_process.get_output()
  proc.async_process.kill()
  proc.async_process = nil
  proc.completed_at = vim.uv.hrtime() / 1e9
  proc.status = "interrupted"
  proc.code = 143
  persist_output(proc, self.conversation_id, output)

  return "stopped"
end

function Runtime:destroy()
  for _, proc in ipairs(self.items) do
    if proc.status == "running" and proc.async_process then
      proc.async_process.kill()
    end
  end

  if self.shell then
    self.shell:close()
    self.shell = nil
  end

  self.items = {}
end

return {
  --- @param conversation_id integer
  --- @param shell_config { project_root: string, shell_opts: sia.config.Shell? }
  --- @return sia.process.Runtime
  new_runtime = function(conversation_id, shell_config)
    return setmetatable({
      shell = nil,
      items = {},
      conversation_id = conversation_id,
      shell_config = shell_config,
    }, Runtime)
  end,
}
