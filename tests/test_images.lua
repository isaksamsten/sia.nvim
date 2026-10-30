---@diagnostic disable: undefined-global
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local original
local buf
local calls
local deleted
local images

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original = vim.ui.img
      calls, deleted = {}, {}
      vim.ui.img = {
        set = function(data, opts)
          calls[#calls + 1] = { data = data, opts = opts }
          return type(data) == "number" and data or #calls
        end,
        del = function(id)
          deleted[#deleted + 1] = id
        end,
      }
      package.loaded["sia.ui.images"] = nil
      images = require("sia.ui.images")
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "" }, 40))
      vim.wo.foldenable = false
      vim.wo.wrap = false
    end,
    post_case = function()
      images.clear(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.ui.img = original
    end,
  },
})

T["missing API gracefully falls back"] = function()
  vim.ui.img = nil
  eq(images.available(), false)
end

T["unsupported terminal gracefully falls back"] = function()
  vim.ui.img._supported = function()
    return false
  end
  eq(images.available(), false)
end

T["places PNG below preview and removes it on clear"] = function()
  images.add(buf, 1, "assets/logo.png")
  images.refresh()
  eq(#calls, 1)
  eq(calls[1].data:sub(1, 8), "\137PNG\r\n\26\n")
  eq(calls[1].opts.row, vim.fn.screenpos(0, 2, 1).row)
  images.clear(buf)
  eq(#deleted, 1)
end

T["hides images after scrolling out of view"] = function()
  images.add(buf, 1, "assets/logo.png")
  images.refresh()
  vim.api.nvim_win_set_cursor(0, { 30, 0 })
  vim.cmd("normal! zt")
  images.refresh()
  eq(#deleted, 1)
end

T["hides folded images"] = function()
  images.add(buf, 1, "assets/logo.png")
  images.refresh()
  vim.wo.foldmethod = "manual"
  vim.wo.foldenable = true
  vim.cmd("2,14fold")
  images.refresh()
  eq(#deleted, 1)
end

T["normalization retains image metadata"] = function()
  local result = {
    summary = "Viewed image",
    preview = { text = "Image: logo.png", ft = "text", image = "/tmp/logo.png" },
  }
  require("sia.tool_output").complete(result)
  eq(result.summary.detail.image, "/tmp/logo.png")
end

T["canvas reserves image rows under the text preview and cleans them up"] = function()
  local canvas = require("sia.canvas").Canvas:new(buf)
  local count = canvas:update_tool_block({ 0, 0 }, 0, {
    image = {
      status = "done",
      summary = {
        header = "Viewed image",
        detail = {
          text = "Image: logo.png",
          ft = "text",
          image = "assets/logo.png",
        },
      },
    },
  }, { "image" })
  eq(count, 6 + images.height)
  images.refresh()
  eq(#calls, 1)
  eq(calls[1].opts.row, vim.fn.screenpos(0, 6, 1).row)
  canvas:clear_tool_highlights()
  eq(#deleted, 1)
end

T["view_image returns inline preview metadata after a successful read"] = function()
  local result
  require("sia.tools.view_image").implementation.execute({ path = "assets/logo.png" }, function(value)
    result = value
  end, {
    conversation = { approved_tools = { view_image = true } },
  })
  eq(result.preview.image, vim.fn.fnamemodify("assets/logo.png", ":p"))
  eq(result.preview.ft, "text")
  eq(result.content[1].type, "image")
end

return T
