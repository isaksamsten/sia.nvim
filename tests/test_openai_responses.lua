local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local first = "**Inferring intent**\n\nFirst paragraph."
local second = "**Refreshing context**\n\nSecond paragraph."
local expected = first .. "\n\n" .. second

local function reasoning_item(id, texts)
  local summary = {}
  for _, text in ipairs(texts) do
    table.insert(summary, { type = "summary_text", text = text })
  end
  return { type = "reasoning", id = id, encrypted_content = "opaque", summary = summary }
end

local function new_stream(provider)
  local deltas = {}
  local stream = provider.new_stream({
    on_stream = function(_, delta)
      table.insert(deltas, delta.reasoning.content)
      return true
    end,
  })
  return stream, deltas
end

local function emit_parts(stream)
  for index, text in ipairs({ first, second }) do
    stream:process_stream_chunk({
      type = "response.reasoning_summary_text.done",
      item_id = "rs_1",
      summary_index = index - 1,
      text = text,
    })
  end
end

for name, provider in pairs({
  openai = require("sia.provider.openai").responses,
  codex = require("sia.provider.codex").spec.implementations.default,
}) do
  T[name .. " separates summary parts while streaming and persisting"] = function()
    local stream, deltas = new_stream(provider)
    emit_parts(stream)
    local item = reasoning_item("rs_1", { first, second })
    stream:process_stream_chunk({ type = "response.output_item.done", item = item })
    -- The completion repeats output items; it must not repeat their summaries.
    stream:process_stream_chunk({
      type = "response.completed",
      response = { output = { item } },
    })
    eq(expected, table.concat(deltas))
    eq(expected, stream:finalize().reasoning.text)
    eq(
      { id = "rs_1", encrypted_content = "opaque" },
      stream:finalize().reasoning.opaque
    )
    eq({ first, "\n\n", second }, deltas)
  end
end

T["completion fallback uses the same separators"] = function()
  local stream, deltas = new_stream(require("sia.provider.openai").responses)
  emit_parts(stream)
  stream:process_stream_chunk({
    type = "response.completed",
    response = { output = { reasoning_item("rs_1", { first, second }) } },
  })
  eq(table.concat(deltas), stream:finalize().reasoning.text)
end

T["empty summary parts do not introduce extra separators"] = function()
  local stream, deltas = new_stream(require("sia.provider.openai").responses)
  for _, text in ipairs({ "", first, "", second, "" }) do
    stream:process_stream_chunk({
      type = "response.reasoning_summary_text.done",
      text = text,
    })
  end
  stream:process_stream_chunk({ type = "response.reasoning_summary_text.done" })
  stream:process_stream_chunk({
    type = "response.output_item.done",
    item = reasoning_item("rs_1", { "", first, "", second }),
  })
  eq(expected, table.concat(deltas))
  eq(expected, stream:finalize().reasoning.text)
end

T["missing summaries remain opaque and do not crash"] = function()
  local stream = new_stream(require("sia.provider.openai").responses)
  stream:process_stream_chunk({
    type = "response.output_item.done",
    item = { type = "reasoning", id = "rs_1" },
  })
  eq(nil, stream:finalize().reasoning)
end

T["cancellation at a summary boundary stops before the next part"] = function()
  local deltas = {}
  local stream = require("sia.provider.openai").responses.new_stream({
    on_stream = function(_, delta)
      table.insert(deltas, delta.reasoning.content)
      return delta.reasoning.content ~= "\n\n"
    end,
  })
  stream:process_stream_chunk({
    type = "response.reasoning_summary_text.done",
    text = first,
  })
  eq(
    true,
    stream:process_stream_chunk({
      type = "response.reasoning_summary_text.done",
      text = second,
    })
  )
  eq({ first, "\n\n" }, deltas)
end

return T
