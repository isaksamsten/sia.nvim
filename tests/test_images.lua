---@diagnostic disable: undefined-global
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local original
local buf
local calls
local deleted
local images
local original_system
local original_executable
local jpeg_path

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original = vim.ui.img
      original_system = vim.system
      original_executable = vim.fn.executable
      jpeg_path = vim.fn.tempname() .. ".jpg"
      vim.fn.writefile({ "fake jpeg bytes" }, jpeg_path)
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
      vim.system = original_system
      vim.fn.executable = original_executable
      vim.fn.delete(jpeg_path)
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

T["converts non-PNG bytes asynchronously without passing a filename"] = function()
  local args, opts
  vim.fn.executable = function(name)
    return name == "magick" and 1 or 0
  end
  vim.system = function(argv, options, callback)
    args, opts = argv, options
    callback({ code = 0, stdout = vim.fn.readblob("assets/logo.png") })
  end
  images.add(buf, 1, jpeg_path)
  eq(#calls, 0)
  vim.wait(1000, function()
    return #calls > 0
  end)
  eq(#calls, 1)
  eq(args[1], "magick")
  eq(vim.tbl_contains(args, "jpeg:-[0]"), true)
  eq(vim.tbl_contains(args, "jpeg:size=1024x1024"), true)
  eq(args[#args], "png:-")
  eq(opts.stdin, vim.fn.readblob(jpeg_path))
  eq(opts.timeout, 10000)
end

T["missing ImageMagick leaves the text-only preview"] = function()
  vim.fn.executable = function()
    return 0
  end
  vim.system = function()
    error("must not start conversion")
  end
  images.add(buf, 1, jpeg_path)
  images.refresh()
  eq(#calls, 0)
end

T["conversion failures and stale callbacks cannot render images"] = function()
  local complete
  vim.fn.executable = function()
    return 1
  end
  vim.system = function(_, _, callback)
    complete = callback
  end
  images.add(buf, 1, jpeg_path)
  complete({ code = 1, stderr = "invalid image" })
  vim.wait(20)
  eq(#calls, 0)
  images.clear(buf)
  images.add(buf, 1, jpeg_path)
  images.clear(buf)
  complete({ code = 0, stdout = vim.fn.readblob("assets/logo.png") })
  vim.wait(20)
  eq(#calls, 0)
end

T["ImageMagick integration converts JPEG to PNG"] = function()
  local command = vim.fn.executable("magick") == 1 and "magick" or "convert"
  if vim.fn.executable(command) ~= 1 then
    MiniTest.skip("ImageMagick is not installed")
  end
  local result = vim.system({ command, "assets/logo.png", "jpeg:" .. jpeg_path }):wait()
  eq(result.code, 0)
  images.add(buf, 1, jpeg_path)
  vim.wait(5000, function()
    return #calls > 0
  end)
  eq(#calls, 1)
  eq(calls[1].data:sub(1, 8), "\137PNG\r\n\26\n")
end

T["large JPEG is downsampled before allocating the full pixel cache"] = function()
  local command = vim.fn.executable("magick") == 1 and "magick" or "convert"
  if vim.fn.executable(command) ~= 1 then
    MiniTest.skip("ImageMagick is not installed")
  end
  local result = vim.system({ command, "-size", "6000x4000", "xc:navy", "jpeg:" .. jpeg_path }):wait()
  eq(result.code, 0)

  -- The previous command fails on this fixture before it reaches -thumbnail.
  local old = vim.system({
    command,
    "-limit", "memory", "64MiB",
    "-limit", "map", "128MiB",
    "-limit", "disk", "0",
    "jpeg:-[0]", "-thumbnail", "1024x1024>", "png:-",
  }, { stdin = vim.fn.readblob(jpeg_path), timeout = 10000 }):wait()
  eq(old.code ~= 0, true)
  eq(old.stderr:find("cache resources exhausted", 1, true) ~= nil, true)

  images.add(buf, 1, jpeg_path)
  vim.wait(10000, function()
    return #calls > 0
  end)
  eq(#calls, 1)
  eq(calls[1].data:sub(1, 8), "\137PNG\r\n\26\n")
end

return T
