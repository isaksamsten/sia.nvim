local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["deletion preview includes removed contents before the file is deleted"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "first", "second" }, path)
  local result
  local ok, err = pcall(function()
    require("sia.tools.apply_diff").implementation.execute(
      "*** Begin Patch\n*** Delete File: " .. path .. "\n*** End Patch",
      function(res) result = res end,
      { conversation = { approved_tools = { apply_diff = true } } }
    )
    assert(result, "patch did not finish")
    require("sia.tool_output").complete(result)
    eq("Deleted " .. vim.fn.fnamemodify(path, ":."), result.summary.header)
    eq("diff", result.summary.detail.ft)
    eq(true, result.summary.detail.text:find("-first\n-second", 1, true) ~= nil)
    eq(true, result.summary.detail.text:find("+0,0", 1, true) ~= nil)
    eq(0, vim.fn.filereadable(path))
  end)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  vim.fn.delete(path)
  assert(ok, err)
end

return T
