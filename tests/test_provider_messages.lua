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

return T
