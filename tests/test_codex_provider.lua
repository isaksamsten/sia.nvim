local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.provider.codex"] = MiniTest.new_set()

local function reload_codex()
  package.loaded["sia.provider.codex"] = nil
  return require("sia.provider.codex")
end

local function with_stubbed_auth(fn)
  local original_notify = vim.notify
  local original_system = vim.system
  local original_uv = vim.uv.os_uname
  local notify_calls = {}

  vim.notify = function(msg, level)
    table.insert(notify_calls, { msg = msg, level = level })
  end

  vim.uv.os_uname = function()
    return { sysname = "Darwin", release = "25.4.0", machine = "arm64" }
  end

  local ok, err = pcall(fn, notify_calls, function(mock)
    vim.system = mock
  end)

  vim.notify = original_notify
  vim.system = original_system
  vim.uv.os_uname = original_uv
  package.loaded["sia.provider.codex"] = nil

  if not ok then
    error(err)
  end
end

local function stub_missing_token()
  local original_readfile = vim.fn.readfile
  local original_filereadable = vim.fn.filereadable

  vim.fn.filereadable = function(path)
    if path:match("codex_token%.json$") then
      return 0
    end
    return original_filereadable(path)
  end

  return function()
    vim.fn.readfile = original_readfile
    vim.fn.filereadable = original_filereadable
  end
end

T["sia.provider.codex"]["returns error when codex is not authorized"] = function()
  with_stubbed_auth(function(notify_calls)
    local restore_token_fs = stub_missing_token()
    local codex = reload_codex()
    codex.spec.discover(function(entries, err)
      eq(entries, nil)
      eq(err, "Codex is not authorized")
    end)
    restore_token_fs()

    eq(#notify_calls, 1)
    eq(notify_calls[1].msg, "sia: run :SiaAuth codex to authorize")
    eq(notify_calls[1].level, vim.log.levels.WARN)
  end)
end

T["sia.provider.codex"]["parses discovered models from codex api"] = function()
  with_stubbed_auth(function(_, set_system)
    local token_data = {
      access_token = "access-token",
      refresh_token = "refresh-token",
      expires_at = os.time() + 3600,
      account_id = "acct_123",
    }

    local original_readfile = vim.fn.readfile
    local original_filereadable = vim.fn.filereadable

    vim.fn.filereadable = function(path)
      if path:match("codex_token%.json$") then
        return 1
      end
      return original_filereadable(path)
    end

    vim.fn.readfile = function(path)
      if path:match("codex_token%.json$") then
        return { vim.json.encode(token_data) }
      end
      return original_readfile(path)
    end

    set_system(function(cmd, opts, on_exit)
      eq(opts.text, true)
      eq(cmd[1], "curl")
      eq(cmd[2], "--silent")
      eq(cmd[#cmd], "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")

      local joined = table.concat(cmd, "\n")
      eq(joined:match("Authorization: Bearer access%-token") ~= nil, true)
      eq(joined:match("ChatGPT%-Account%-Id: acct_123") ~= nil, true)
      eq(joined:match("originator: sia") ~= nil, true)
      eq(joined:match("User%-Agent: sia%.nvim %(Darwin 25%.4%.0; arm64%)") ~= nil, true)

      on_exit({
        code = 0,
        stdout = vim.json.encode({
          models = {
            {
              id = "gpt-5.3-codex",
              input_modalities = { "text", "image" },
              supported_reasoning_levels = {
                { effort = "low" },
                { effort = "medium" },
              },
              supports_parallel_tool_calls = true,
              context_window = 272000,
              max_context_window = 400000,
              default_reasoning_level = "medium",
              default_reasoning_summary = "none",
              default_verbosity = "low",
            },
            {
              id = "gpt-5.4",
              input_modalities = { "text" },
              context_window = 272000,
              default_verbosity = "medium",
            },
            { no_id = true },
          },
        }),
      })
    end)

    local codex = reload_codex()
    codex.spec.discover(function(entries, err)
      eq(err, nil)
      eq(entries["gpt-5.3-codex"].context_window, 400000)
      eq(entries["gpt-5.3-codex"].support.image, true)
      eq(entries["gpt-5.3-codex"].support.document, true)
      eq(entries["gpt-5.3-codex"].support.reasoning, true)
      eq(entries["gpt-5.3-codex"].support.tool_calls, true)
      eq(entries["gpt-5.3-codex"].options.reasoning_effort, "medium")
      eq(entries["gpt-5.3-codex"].options.reasoning_summary, "none")
      eq(entries["gpt-5.3-codex"].options.text_verbosity, "low")

      eq(entries["gpt-5.4"].context_window, 272000)
      eq(entries["gpt-5.4"].support.image, nil)
      eq(entries["gpt-5.4"].support.document, true)
      eq(entries["gpt-5.4"].options.text_verbosity, "medium")
      eq(entries["missing"], nil)
    end)

    vim.fn.readfile = original_readfile
    vim.fn.filereadable = original_filereadable
  end)
end

return T

