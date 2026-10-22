local M = {}
M.MAX_FRAME = 1024 * 1024

function M.start(config, on_message, on_exit)
  local self = { buffer = "", stderr = "", closed = false }
  local job
  local function fail(reason)
    if self.closed then
      return
    end
    self.closed = true
    if job then
      pcall(vim.fn.jobstop, job)
    end
    on_exit(reason)
  end
  local launched
  launched, job = pcall(vim.fn.jobstart, config.command, {
    cwd = config.cwd,
    env = config.env,
    on_stdout = function(_, data)
      if self.closed then
        return
      end
      for i, part in ipairs(data) do
        if i > 1 then
          local frame = self.buffer
          self.buffer = ""
          if frame ~= "" then
            local ok, message = pcall(vim.json.decode, frame)
            if not ok or type(message) ~= "table" then
              fail(
                "Invalid MCP stdout: expected newline-delimited JSON (server logs must use stderr)"
              )
              return
            end
            on_message(message)
            if self.closed then
              return
            end
          end
        end
        if #self.buffer + #part > M.MAX_FRAME then
          fail("MCP stdout frame exceeds 1 MiB")
          return
        end
        self.buffer = self.buffer .. part
      end
    end,
    on_stderr = function(_, data)
      self.stderr = (self.stderr .. table.concat(data, "\n")):sub(-8192)
    end,
    on_exit = function(_, code)
      if not self.closed then
        self.closed = true
        on_exit("MCP process exited (code " .. code .. ")")
      end
    end,
  })
  if not launched or job <= 0 then
    return nil, "Unable to launch MCP executable"
  end
  function self:send(message)
    if self.closed then
      return false
    end
    local ok = pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
    if not ok then
      fail("MCP stdin write failed")
    end
    return ok
  end
  function self:stop()
    if self.closed then
      return
    end
    self.closed = true
    pcall(vim.fn.chanclose, job, "stdin")
    vim.defer_fn(function()
      pcall(vim.fn.jobstop, job)
    end, 200)
  end
  return self
end
return M
