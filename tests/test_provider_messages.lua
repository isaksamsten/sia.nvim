local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["provider.prepare_messages"] = MiniTest.new_set()

T["provider.prepare_messages"]["openai completion only merges adjacent user messages"] = function()
  local openai = require("sia.provider.openai")
  --- @type sia.Message[]
  local messages = {
    { role = "user", content = "first" },
    {
      role = "user",
      content = {
        { type = "text", text = "second" },
        { type = "image", image = { url = "https://example.com/cat.png" } },
      },
    },
    {
      role = "assistant",
      reasoning = { text = "thinking", opaque = "opaque-reasoning" },
    },
    { role = "assistant", content = "final answer" },
    {
      role = "assistant",
      tool_call = {
        id = "call_1",
        type = "function",
        name = "view",
        arguments = '{"path":"foo.lua"}',
      },
    },
  }

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  openai.completion.prepare_messages(data, {}, messages)

  eq(3, #data.messages)
  eq("user", data.messages[1].role)
  eq("text", data.messages[1].content[1].type)
  eq("first", data.messages[1].content[1].text)
  eq("second", data.messages[1].content[2].text)
  eq("image_url", data.messages[1].content[3].type)
  eq("https://example.com/cat.png", data.messages[1].content[3].image_url.url)

  eq("assistant", data.messages[2].role)
  eq("thinking", data.messages[2].reasoning_text)
  eq("opaque-reasoning", data.messages[2].reasoning_opaque)

  eq("assistant", data.messages[3].role)
  eq("final answer", data.messages[3].content)
  eq("view", data.messages[3].tool_calls[1]["function"].name)
end

T["provider.prepare_messages"]["deepseek completion renames reasoning_text to reasoning_content"] =
  function()
    local deepseek = require("sia.provider.deepseek")
    --- @type sia.Message[]
    local messages = {
      { role = "user", content = "first" },
      { role = "assistant", reasoning = { text = "thinking" } },
      { role = "assistant", content = "final answer" },
    }

    local data = {}
    deepseek.spec.implementations.default.prepare_messages(data, {}, messages)

    eq("assistant", data.messages[2].role)
    eq("thinking", data.messages[2].reasoning_content)
    eq(nil, data.messages[2].reasoning_text)
  end

T["provider.prepare_messages"]["deepseek completion enables thinking for reasoning models"] =
  function()
    local deepseek = require("sia.provider.deepseek")

    local data = {}
    deepseek.spec.implementations.default.prepare_parameters(data, {
      support = { reasoning = true },
      options = { reasoning_effort = "high" },
    })

    eq("high", data.reasoning_effort)
    eq("enabled", data.thinking.type)
  end

T["provider.prepare_messages"]["deepseek completion groups adjacent tool calls into one assistant turn"] =
  function()
    local deepseek = require("sia.provider.deepseek")
    --- @type sia.Message[]
    local messages = {
      { role = "user", content = "first" },
      {
        role = "assistant",
        content = "",
        reasoning = { text = "thinking" },
        tool_call = {
          id = "call_1",
          type = "function",
          name = "view",
          arguments = '{"path":"foo.lua"}',
        },
      },
      {
        role = "tool",
        tool_call = { id = "call_1", type = "function", name = "view" },
        content = "file content",
      },
      {
        role = "assistant",
        tool_call = {
          id = "call_2",
          type = "function",
          name = "grep",
          arguments = '{"pattern":"bar"}',
        },
      },
      {
        role = "tool",
        tool_call = { id = "call_2", type = "function", name = "grep" },
        content = "match found",
      },
    }

    local data = {}
    deepseek.spec.implementations.default.prepare_messages(data, {}, messages)

    eq(4, #data.messages)
    eq("assistant", data.messages[2].role)
    eq("thinking", data.messages[2].reasoning_content)
    eq(2, #data.messages[2].tool_calls)
    eq("view", data.messages[2].tool_calls[1]["function"].name)
    eq("grep", data.messages[2].tool_calls[2]["function"].name)
  end

T["provider.prepare_messages"]["deepseek completion moves user messages after tool chain continuations"] =
  function()
    local deepseek = require("sia.provider.deepseek")
  local messages = {
    { role = "user", content = "first" },
    {
      role = "assistant",
      reasoning = { text = "thinking" },
    },
    {
      role = "assistant",
      tool_call = {
        id = "call_1",
        type = "function",
        name = "view",
        arguments = '{"path":"foo.lua"}',
      },
    },
    {
      role = "tool",
      tool_call = { id = "call_1", type = "function", name = "view" },
      content = "file content",
    },
    { role = "user", content = "interruption" },
    {
      role = "assistant",
      tool_call = {
        id = "call_2",
        type = "function",
        name = "grep",
        arguments = '{"pattern":"bar"}',
      },
    },
    {
      role = "tool",
      tool_call = { id = "call_2", type = "function", name = "grep" },
      content = "match found",
    },
  }

  local data = {}
  deepseek.spec.implementations.default.prepare_messages(data, {}, messages)

  eq(5, #data.messages)
  eq("assistant", data.messages[2].role)
  eq(2, #data.messages[2].tool_calls)
  eq("tool", data.messages[3].role)
  eq("tool", data.messages[4].role)
  eq("user", data.messages[5].role)
  eq("interruption", data.messages[5].content)
end

T["provider.prepare_messages"]["openai responses keeps assistant items separate"] = function()
  local openai = require("sia.provider.openai")
  --- @type any[]
  local messages = {
    { role = "system", hide = false, content = "system prompt" },
    {
      role = "user",
      content = {
        { type = "text", text = "first" },
        {
          type = "image",
          image = { url = "https://example.com/dog.png", detail = "low" },
        },
      },
    },
    {
      role = "user",
      content = {
        {
          type = "file",
          file = {
            file_data = "data:text/plain;base64,Zm9v",
            filename = "note.txt",
            detail = "auto",
          },
        },
        { type = "text", text = "second" },
      },
      meta = {},
    },
    { role = "assistant", content = "assistant one" },
    { role = "assistant", content = "assistant two" },
  }

  local data = {}
  openai.responses.prepare_messages(data, {}, messages)

  eq("system prompt", data.instructions)
  eq(3, #data.input)
  eq("user", data.input[1].role)
  eq("input_text", data.input[1].content[1].type)
  eq("first", data.input[1].content[1].text)
  eq("input_image", data.input[1].content[2].type)
  eq("https://example.com/dog.png", data.input[1].content[2].image_url)
  eq("input_file", data.input[1].content[3].type)
  eq("note.txt", data.input[1].content[3].filename)
  eq("input_text", data.input[1].content[4].type)
  eq("second", data.input[1].content[4].text)
  eq("assistant", data.input[2].role)
  eq("assistant one", data.input[2].content)
  eq("assistant", data.input[3].role)
  eq("assistant two", data.input[3].content)
end

T["provider.prepare_messages"]["anthropic merges adjacent assistant turns after translation"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  --- @type sia.Message[]
  local messages = {
    { role = "assistant", hide = false, content = "first", meta = {} },
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

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  anthropic.prepare_messages(data, {}, messages)

  eq(1, #data.messages)
  eq("assistant", data.messages[1].role)
  eq("text", data.messages[1].content[1].type)
  eq("first", data.messages[1].content[1].text)
  eq("tool_use", data.messages[1].content[2].type)
  eq("view", data.messages[1].content[2].name)
end

T["provider.prepare_messages"]["anthropic round-trips thinking blocks before tool_use"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  --- @type sia.Message[]
  local messages = {
    { role = "user", content = "hi" },
    {
      role = "assistant",
      reasoning = {
        text = "let me think",
        opaque = {
          blocks = {
            {
              type = "thinking",
              thinking = "let me think",
              signature = "sig-abc",
            },
            { type = "redacted_thinking", data = "encrypted-blob" },
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

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  anthropic.prepare_messages(data, {}, messages)

  eq(2, #data.messages)
  local assistant = data.messages[2]
  eq("assistant", assistant.role)
  eq(3, #assistant.content)
  eq("thinking", assistant.content[1].type)
  eq("let me think", assistant.content[1].thinking)
  eq("sig-abc", assistant.content[1].signature)
  eq("redacted_thinking", assistant.content[2].type)
  eq("encrypted-blob", assistant.content[2].data)
  eq("tool_use", assistant.content[3].type)
  eq("view", assistant.content[3].name)
end

T["provider.prepare_messages"]["anthropic round-trips thinking blocks for content-only assistant"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  --- @type sia.Message[]
  local messages = {
    { role = "user", content = "hi" },
    {
      role = "assistant",
      content = "final answer",
      reasoning = {
        text = "thinking text",
        opaque = {
          blocks = {
            {
              type = "thinking",
              thinking = "thinking text",
              signature = "sig-1",
            },
          },
        },
      },
    },
  }

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  anthropic.prepare_messages(data, {}, messages)

  eq(2, #data.messages)
  local assistant = data.messages[2]
  eq("assistant", assistant.role)
  eq(2, #assistant.content)
  eq("thinking", assistant.content[1].type)
  eq("sig-1", assistant.content[1].signature)
  eq("text", assistant.content[2].type)
  eq("final answer", assistant.content[2].text)
end

T["provider.prepare_messages"]["anthropic translates PDF and image content blocks"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  --- @type sia.Message[]
  local messages = {
    {
      role = "user",
      content = {
        {
          type = "file",
          file = {
            filename = "report.pdf",
            file_data = "data:application/pdf;base64,JVBERi0x",
          },
        },
        {
          type = "image",
          image = {
            url = "data:image/png;base64,iVBORw0KGgo=",
          },
        },
        { type = "text", text = "Summarize this." },
      },
    },
  }

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  anthropic.prepare_messages(data, {}, messages)

  eq("user", data.messages[1].role)
  eq("document", data.messages[1].content[1].type)
  eq("base64", data.messages[1].content[1].source.type)
  eq("application/pdf", data.messages[1].content[1].source.media_type)
  eq("report.pdf", data.messages[1].content[1].title)
  eq("image", data.messages[1].content[2].type)
  eq("base64", data.messages[1].content[2].source.type)
  eq("image/png", data.messages[1].content[2].source.media_type)
  eq("text", data.messages[1].content[3].type)
  eq("Summarize this.", data.messages[1].content[3].text)
end

T["provider.prepare_messages"]["anthropic translates tool result PDF content blocks"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  --- @type sia.Message[]
  local messages = {
    {
      role = "tool",
      tool_call = { id = "toolu_1", type = "function", name = "view_document" },
      content = {
        { type = "text", text = "Document attached" },
        {
          type = "file",
          file = {
            filename = "report.pdf",
            file_data = "https://example.com/report.pdf",
          },
        },
      },
    },
  }

  local data = {}
  --- @diagnostic disable-next-line:param-type-mismatch
  anthropic.prepare_messages(data, {}, messages)

  eq("user", data.messages[1].role)
  eq("tool_result", data.messages[1].content[1].type)
  eq("text", data.messages[1].content[1].content[1].type)
  eq("document", data.messages[1].content[1].content[2].type)
  eq("url", data.messages[1].content[1].content[2].source.type)
  eq("https://example.com/report.pdf", data.messages[1].content[1].content[2].source.url)
end

T["provider.prepare_messages"]["anthropic enables thinking when model supports reasoning"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  local data = {}
  anthropic.prepare_parameters(data, {
    options = {},
    support = { reasoning = true },
  })

  eq("enabled", data.thinking.type)
  eq(4096, data.thinking.budget_tokens)
  eq(true, data.max_tokens > data.thinking.budget_tokens)
end

T["provider.prepare_messages"]["anthropic respects explicit thinking option"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  local data = {}
  anthropic.prepare_parameters(data, {
    options = {
      thinking = { type = "adaptive" },
      max_tokens = 16000,
    },
  })

  eq("adaptive", data.thinking.type)
  eq(16000, data.max_tokens)
end

T["provider.prepare_messages"]["anthropic disables thinking when type is disabled"] = function()
  local anthropic = require("sia.provider.anthropic").messages
  local data = {}
  anthropic.prepare_parameters(data, {
    options = { thinking = { type = "disabled" } },
    support = { reasoning = true },
  })

  eq(nil, data.thinking)
end

T["sia.provider.anthropic stream"] = MiniTest.new_set()

T["sia.provider.anthropic stream"]["captures thinking and signature"] = function()
  local anthropic = require("sia.provider.anthropic")
  local reasoning_chunks = {}
  local strategy = {
    on_tools = function()
      return true
    end,
    on_stream = function(_, delta)
      if delta.reasoning then
        table.insert(reasoning_chunks, delta.reasoning.content)
      end
      return true
    end,
  }

  local stream = anthropic.messages.new_stream(strategy)
  stream:process_stream_chunk({
    type = "content_block_start",
    index = 0,
    content_block = { type = "thinking", thinking = "" },
  })
  stream:process_stream_chunk({
    type = "content_block_delta",
    index = 0,
    delta = { type = "thinking_delta", thinking = "let me " },
  })
  stream:process_stream_chunk({
    type = "content_block_delta",
    index = 0,
    delta = { type = "thinking_delta", thinking = "think" },
  })
  stream:process_stream_chunk({
    type = "content_block_delta",
    index = 0,
    delta = { type = "signature_delta", signature = "abc" },
  })
  stream:process_stream_chunk({ type = "content_block_stop", index = 0 })
  stream:process_stream_chunk({
    type = "content_block_start",
    index = 1,
    content_block = { type = "text" },
  })
  stream:process_stream_chunk({
    type = "content_block_delta",
    index = 1,
    delta = { type = "text_delta", text = "answer" },
  })

  local result = stream:finalize()
  eq("answer", result.content)
  eq("let me think", result.reasoning.text)
  eq("let me think", result.reasoning.opaque.blocks[1].thinking)
  eq("abc", result.reasoning.opaque.blocks[1].signature)
  eq({ "let me ", "think" }, reasoning_chunks)
end

T["sia.provider.anthropic stream"]["captures redacted thinking"] = function()
  local anthropic = require("sia.provider.anthropic")
  local strategy = {
    on_tools = function()
      return true
    end,
    on_stream = function()
      return true
    end,
  }

  local stream = anthropic.messages.new_stream(strategy)
  stream:process_stream_chunk({
    type = "content_block_start",
    index = 0,
    content_block = { type = "redacted_thinking", data = "OPAQUE" },
  })
  stream:process_stream_chunk({ type = "content_block_stop", index = 0 })

  local result = stream:finalize()
  eq("redacted_thinking", result.reasoning.opaque.blocks[1].type)
  eq("OPAQUE", result.reasoning.opaque.blocks[1].data)
end

return T
