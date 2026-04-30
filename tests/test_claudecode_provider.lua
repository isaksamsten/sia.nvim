local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.provider.claudecode"] = MiniTest.new_set()

local function reload_provider()
  package.loaded["sia.provider.claudecode"] = nil
  return require("sia.provider.claudecode")
end

T["sia.provider.claudecode"]["prepare_messages prefixes system and tool names"] = function()
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
  provider.spec.implementations.default.prepare_messages(data, "claude-4.5-sonnet", messages)

  eq(true, vim.startswith(data.system[1].text, "x-anthropic-billing-header:"))
  eq("You are Claude Code, Anthropic's official CLI for Claude.", data.system[2].text)
  eq("Claude Code should help.\n\nfirst", data.messages[1].content[1].text)
  eq("mcp_View", data.messages[2].content[1].name)
end

T["sia.provider.claudecode"]["stream strips tool prefix"] = function()
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

T["sia.provider.claudecode"]["parse auth code supports state suffix"] = function()
  local provider = reload_provider()
  local code, state = provider._test.parse_auth_code("abc#xyz")
  eq("abc", code)
  eq("xyz", state)
end

T["sia.provider.claudecode"]["billing header matches known vector"] = function()
  local provider = reload_provider()
  local header = provider._test.build_billing_header({
    { role = "user", content = "hey" },
  })
  eq(
    "x-anthropic-billing-header: cc_version=2.1.90.b39; cc_entrypoint=cli; cch=fa690;",
    header
  )
end

T["sia.provider.claudecode"]["tool names use Claude Code casing"] = function()
  local provider = reload_provider()
  eq("mcp_Bash", provider._test.prefix_tool_name("bash"))
  eq("bash", provider._test.unprefix_tool_name("mcp_Bash"))
end

T["sia.provider.claudecode"]["rewrite text matches Claude renaming"] = function()
  local provider = reload_provider()
  eq(
    "Claude Code and Claude should help Claude Code users.",
    provider._test.rewrite_text("OpenCode and opencode should help Sia users.")
  )
end

T["sia.provider.claudecode"]["round-trips thinking blocks before tool_use"] = function()
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

return T
