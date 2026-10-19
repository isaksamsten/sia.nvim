local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local output = require("sia.tool_output")

T["captures approval content without a window and releases the buffer"] = function()
  local captured_buf
  local win_count = #vim.api.nvim_list_wins()
  local preview = output.capture(function(buf)
    captured_buf = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@@ -1 +1 @@", "-old", "+new" })
    vim.bo[buf].filetype = "diff"
    return 3
  end)
  eq({ text = "@@ -1 +1 @@\n-old\n+new", ft = "diff" }, preview)
  eq(false, vim.api.nvim_buf_is_valid(captured_buf))
  eq(win_count, #vim.api.nvim_list_wins())
end

T["broken preview releases its buffer and does not throw"] = function()
  local captured_buf
  eq(
    nil,
    output.capture(function(buf)
      captured_buf = buf
      error("bad preview")
    end)
  )
  eq(false, vim.api.nvim_buf_is_valid(captured_buf))
end

T["completion prefers explicit details then accepted diff then result text"] = function()
  local result = {
    content = "Applied successfully",
    summary = "Edited file",
    preview = { text = "-old\n+new", ft = "diff" },
  }
  output.complete(result)
  eq(
    { header = "Edited file", detail = { text = "-old\n+new", ft = "diff" } },
    result.summary
  )
  eq(nil, result.preview)
  result.summary = { header = "Edited file", detail = { text = "Explicit output" } }
  result.preview = { text = "ignored", ft = "diff" }
  output.complete(result)
  eq("Explicit output", result.summary.detail.text)
  result.summary = "Read file"
  output.complete(result)
  eq("Read file", result.summary)
end

T["failures show actual error rather than proposed edits"] = function()
  local result = {
    summary = "Failed to edit",
    content = "File changed since approval",
    preview = { text = "+unapplied", ft = "diff" },
  }
  output.complete(result)
  eq("File changed since approval", result.summary.detail.text)
  eq("text", result.summary.detail.ft)
end

T["multipart previews include text and leave image data alone"] = function()
  local result = {
    summary = "Viewed image",
    content = {
      { type = "text", text = "Image dimensions: 10x10" },
      { type = "image", data = "secret" },
    },
  }
  result.preview = output.from_content(result.content)
  output.complete(result)
  eq("Image dimensions: 10x10", result.summary.detail.text)
  eq("secret", result.content[2].data)
end

T["shared limits remove terminal escapes and bound output"] = function()
  eq("red\nnext", output.limit("\27[31mred\27[0m\r\nnext\n"))
  local text = table.concat(vim.fn["repeat"]({ "line" }, 210), "\n")
  local limited = output.limit(text)
  eq(201, #vim.split(limited, "\n"))
  eq(true, limited:find("preview truncated", 1, true) ~= nil)
  eq(true, #output.limit(string.rep("a", 100000)) < 1100)
end

T["automatic approval captures diff before mutation"] = function()
  local value = "old"
  local tool = require("sia.tools.utils").new_tool({
    definition = { name = "preview_test", type = "function" },
    preview = true,
  }, function(_, _, callback, opts)
    opts.user_input("Edit file", {
      preview = function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-" .. value, "+new" })
        vim.bo[buf].filetype = "diff"
        return 2
      end,
      on_accept = function()
        value = "new"
        callback({ summary = "Edited file", content = "Done" })
      end,
    })
  end)
  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, {
    conversation = { approved_tools = { preview_test = true } },
  })
  eq("new", value)
  eq("-old\n+new", result.preview.text)
  output.complete(result)
  eq("-old\n+new", result.summary.detail.text)
end

T["engine delivers normalized previews in final results and statuses"] = function()
  local entries, statuses
  require("sia.engine").execute_tools({
    { key = "call", type = "function", name = "read", arguments = "{}" },
  }, {
    tool_implementation = { read = {
      summary = function()
        return "Reading file"
      end,
    } },
    execute_tool = function(_, _, _, opts)
      opts.callback({
        summary = "Read file",
        content = "file contents",
        preview = output.from_content("file contents"),
      })
    end,
  }, {
    turn_id = "turn",
    on_complete = function(results, final_statuses)
      entries, statuses = results, final_statuses
    end,
  })
  vim.wait(1000, function()
    return entries ~= nil
  end)
  eq(
    { header = "Read file", detail = { text = "file contents", ft = "text" } },
    entries[1].result.summary
  )
  eq(entries[1].result.summary, statuses[1].summary)
end

T["long Unicode lines remain valid after truncation"] = function()
  local limited = output.limit(string.rep("猫", 20000))
  eq(true, #limited < 1100)
  eq(true, vim.fn.strchars(limited) > 300)
  eq(nil, limited:find("\239\191\189", 1, true))
end

T["tools without preview opt-in keep summary only"] = function()
  local tool = require("sia.tools.utils").new_tool({
    definition = { name = "preview_test", type = "function" },
  }, function(_, _, callback)
    callback({ summary = "Viewed file", content = "Large file contents" })
  end)
  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, {
    conversation = { approved_tools = { preview_test = true } },
  })
  output.complete(result)
  eq("Viewed file", result.summary)
  eq(nil, result.preview)
end

T["custom tool preview function opts in without a built-in tool name"] = function()
  local tool = require("sia.tools.utils").new_tool({
    definition = { name = "custom_preview", type = "function" },
    preview = function(args, result)
      return { text = args.label .. "\n" .. result.content, ft = "lua" }
    end,
  }, function(_, _, callback)
    callback({ summary = "Computed result", content = "return 42" })
  end)
  local result
  tool.implementation.execute({ label = "-- answer" }, function(res)
    result = res
  end, {
    conversation = { approved_tools = { custom_preview = true } },
  })
  output.complete(result)
  eq(
    {
      header = "Computed result",
      detail = { text = "-- answer\nreturn 42", ft = "lua" },
    },
    result.summary
  )
end

T["view errors hide summaries without hiding model errors"] = function()
  local view = require("sia.tools.view")
  local result
  view.implementation.execute({ path = "missing-sia-preview-test-file" }, function(res)
    result = res
  end, { conversation = { approved_tools = { view = true } } })
  output.ensure_summary(result, "view")
  output.complete(result)
  eq(false, result.summary)
  eq("Error: File cannot be found", result.content)
  eq(nil, result.preview)
end

T["search errors hide summaries without hiding model errors"] = function()
  for _, args in ipairs({ {}, { pattern = "[" } }) do
    local result
    require("sia.tools.grep").implementation.execute(args, function(res)
      result = res
    end, { conversation = { approved_tools = { grep = true } } })
    vim.wait(1000, function()
      return result ~= nil
    end)
    output.ensure_summary(result, "grep")
    output.complete(result)
    eq(false, result.summary)
    eq("string", type(result.content))
    eq(true, #result.content > 0)
    eq(nil, result.preview)
  end
end

T["explicit omission clears previews without exposing model instructions"] = function()
  local result = {
    summary = false,
    content = "Use process 7 to poll",
    preview = { text = "private" },
  }
  output.ensure_summary(result, "bash")
  output.complete(result)
  eq(false, result.summary)
  eq(nil, result.preview)
  eq("Use process 7 to poll", result.content)
end

T["missing summaries remain visible without enabling previews"] = function()
  for _, case in ipairs({
    {
      content = "Error: process not found",
      expected = "Failed bash: process not found",
    },
    { content = "No references found.", expected = "No references found." },
    { content = "model-only result", expected = "Completed bash" },
  }) do
    local result = { content = case.content }
    output.ensure_summary(result, "bash")
    output.complete(result)
    eq(case.expected, result.summary)
    eq(case.content, result.content)
    eq(nil, result.preview)
  end
end

T["empty details do not create a details row"] = function()
  local result = {
    summary = { header = "Ran command", detail = { text = "\n\n" } },
    content = "done",
  }
  output.complete(result)
  eq(nil, result.summary.detail)
end

T["cancelled tools retain model instructions without showing them in details"] = function()
  local tool = require("sia.tools.utils").new_tool({
    definition = { name = "cancel_test", type = "function" },
    preview = true,
  }, function(_, _, callback)
    callback({
      summary = "Cancelled editing file",
      kind = "cancelled",
      content = "IMPORTANT: model instructions",
    })
  end)
  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, {
    conversation = { approved_tools = { cancel_test = true } },
  })
  output.complete(result)
  eq("Cancelled editing file", result.summary)
  eq("IMPORTANT: model instructions", result.content)
  eq(nil, result.preview)
end

T["hidden results still have visible transient summaries while awaiting approval"] = function()
  for _, case in ipairs({
    { name = "agent", args = { command = "send", id = 1, message = "Continue" } },
    { name = "bash", args = { action = "kill", id = 1 } },
  }) do
    local finish, confirmation, running, results
    local implementation = require("sia.tools." .. case.name).implementation
    require("sia.engine").execute_tools({
      {
        key = "pending",
        type = "function",
        name = case.name,
        arguments = vim.json.encode(case.args),
      },
    }, {
      tool_implementation = { [case.name] = implementation },
      approved_tools = { [case.name] = true },
      execute_tool = function(_, _, _, opts)
        -- Hold the result until the pending approval is resolved.
        finish = opts.callback
        confirmation = opts.on_confirmation
      end,
    }, {
      turn_id = "turn",
      on_status = function(statuses)
        if statuses[1].status == "running" then
          running = statuses[1].summary
        end
      end,
      on_complete = function(entries)
        results = entries
      end,
    })
    vim.wait(1000, function()
      return finish ~= nil
    end)
    eq(false, running)
    confirmation(true)
    eq("string", type(running))
    eq(nil, results)
    confirmation(false)
    eq(false, running)
    finish({ summary = false, content = "model-only result" })
    vim.wait(1000, function()
      return results ~= nil
    end)
    eq(false, results[1].result.summary)
    eq("model-only result", results[1].result.content)
  end
end

return T
