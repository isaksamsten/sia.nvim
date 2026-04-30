local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.provider.claude"] = MiniTest.new_set()

local function reload_provider()
  package.loaded["sia.provider.claude"] = nil
  return require("sia.provider.claude")
end

local function with_stubbed_oauth(fn)
  local original_system = vim.system
  local original_readfile = vim.fn.readfile
  local original_filereadable = vim.fn.filereadable

  local token_data = {
    access = "access-token",
    refresh = "refresh-token",
    expires = (os.time() + 3600) * 1000,
  }

  vim.fn.filereadable = function(path)
    if path:match("claudecode_oauth%.json$") then
      return 1
    end
    return original_filereadable(path)
  end

  vim.fn.readfile = function(path)
    if path:match("claudecode_oauth%.json$") then
      return { vim.json.encode(token_data) }
    end
    return original_readfile(path)
  end

  local ok, err = pcall(fn, function(mock)
    vim.system = mock
  end)

  vim.system = original_system
  vim.fn.readfile = original_readfile
  vim.fn.filereadable = original_filereadable
  package.loaded["sia.provider.claude"] = nil

  if not ok then
    error(err)
  end
end

T["sia.provider.claude"]["prepare_messages prefixes system and tool names"] = function()
  local provider = reload_provider()
  local data = {}
  local messages = {
    { role = "system", content = "OpenCode should help." },
    { role = "user", content = "first" },
    {
      role = "assistant",
      tool_call = {
        id = "toolu_1",
        type = "function",
        name = "view",
        arguments = '{"path":"foo.lua"}',
      },
    },
  }

  --- @diagnostic disable-next-line:param-type-mismatch
  provider.spec.implementations.default.prepare_messages(
    data,
    "claude-4.5-sonnet",
    messages
  )

  eq(true, vim.startswith(data.system[1].text, "x-anthropic-billing-header:"))
  eq("You are Claude Code, Anthropic's official CLI for Claude.", data.system[2].text)
  eq("Claude Code should help.\n\nfirst", data.messages[1].content[1].text)
  eq("mcp_View", data.messages[2].content[1].name)
end

T["sia.provider.claude"]["stream strips tool prefix"] = function()
  local provider = reload_provider()
  local seen_name
  local strategy = {
    on_tools = function()
      return true
    end,
    on_stream = function()
      return true
    end,
  }

  local stream = provider.spec.implementations.default.new_stream(strategy)
  stream:process_stream_chunk({
    type = "content_block_start",
    content_block = {
      type = "tool_use",
      id = "toolu_1",
      name = "mcp_view",
    },
  })

  seen_name = stream.pending_tool_calls[1].name
  eq("view", seen_name)
end

T["sia.provider.claude"]["parse auth code supports state suffix"] = function()
  local provider = reload_provider()
  local code, state = provider._test.parse_auth_code("abc#xyz")
  eq("abc", code)
  eq("xyz", state)
end

T["sia.provider.claude"]["billing header matches known vector"] = function()
  local provider = reload_provider()
  local header = provider._test.build_billing_header({
    { role = "user", content = "hey" },
  })
  eq(
    "x-anthropic-billing-header: cc_version=2.1.90.b39; cc_entrypoint=cli; cch=fa690;",
    header
  )
end

T["sia.provider.claude"]["tool names use Claude Code casing"] = function()
  local provider = reload_provider()
  eq("mcp_Bash", provider._test.prefix_tool_name("bash"))
  eq("bash", provider._test.unprefix_tool_name("mcp_Bash"))
end

T["sia.provider.claude"]["round-trips thinking blocks before tool_use"] = function()
  local provider = reload_provider()
  local data = {}
  local messages = {
    { role = "user", content = "first" },
    {
      role = "assistant",
      reasoning = {
        text = "thinking",
        opaque = {
          blocks = {
            { type = "thinking", thinking = "thinking", signature = "sig" },
          },
        },
      },
      tool_call = {
        id = "toolu_1",
        type = "function",
        name = "view",
        arguments = '{"path":"foo.lua"}',
      },
    },
  }

  --- @diagnostic disable-next-line:param-type-mismatch
  provider.spec.implementations.default.prepare_messages(
    data,
    "claude-4.5-sonnet",
    messages
  )

  -- last message should be the assistant turn with thinking before tool_use.
  local assistant = data.messages[#data.messages]
  eq("assistant", assistant.role)
  eq("thinking", assistant.content[1].type)
  eq("sig", assistant.content[1].signature)
  eq("tool_use", assistant.content[2].type)
  eq("mcp_View", assistant.content[2].name)
end

T["sia.provider.claude"]["parses discovered models with short names and capabilities"] = function()
  with_stubbed_oauth(function(set_system)
    set_system(function(cmd, opts, on_exit)
      eq(opts.text, true)
      eq(cmd[1], "curl")
      eq(cmd[2], "--silent")
      eq(cmd[#cmd], "https://api.anthropic.com/v1/models")

      local joined = table.concat(cmd, "\n")
      eq(joined:match("authorization: Bearer access%-token") ~= nil, true)

      on_exit({
        code = 0,
        stdout = vim.json.encode({
          data = {
            {
              id = "claude-opus-4-7",
              max_input_tokens = 1000000,
              capabilities = {
                image_input = { supported = true },
                pdf_input = { supported = true },
                thinking = {
                  supported = true,
                  types = {
                    adaptive = { supported = true },
                  },
                },
              },
            },
            {
              id = "claude-haiku-4-5-20251001",
              capabilities = {
                thinking = {
                  supported = true,
                  types = {
                    adaptive = { supported = false },
                  },
                },
              },
            },
          },
        }),
      })
    end)

    local provider = reload_provider()
    provider.spec.discover(function(entries, err)
      eq(err, nil)
      eq(entries["opus-4-7"].api_name, "claude-opus-4-7")
      eq(entries["opus-4-7"].context_window, 1000000)
      eq(entries["opus-4-7"].support.image, true)
      eq(entries["opus-4-7"].support.document, true)
      eq(entries["opus-4-7"].support.reasoning, true)
      eq(entries["opus-4-7"].support.adaptive_thinking, true)
      eq(entries["haiku-4-5-20251001"].support.reasoning, true)
      eq(entries["haiku-4-5-20251001"].support.adaptive_thinking, nil)
      eq(entries["claude-opus-4-7"], nil)
    end)
  end)
end

return T
