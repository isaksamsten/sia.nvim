local tool_utils = require("sia.tools.utils")

local FAILED_TO_CREATE_QF = "❌ Failed to create quickfix list"

return tool_utils.new_tool({
  name = "show_locations",
  message = "Creating location list...",
  description = "Show multiple locations in a navigable list for easy browsing",
  system_prompt = [[SHOWS MULTIPLE LOCATIONS TO THE USER - creates a navigable quickfix list.

This tool is for presenting multiple locations to the USER, NOT for reading code yourself.
Use the read tool if you need to examine file contents.

Use this for:
- Multiple search results or error locations
- Collections of related code locations
- Any scenario where user benefits from seeing all locations at once

Creates a navigable list that users can browse with :cnext/:cprev or clicking.
Use appropriate 'type' values: E (error), W (warning), I (info), N (note).]],
  parameters = {
    items = {
      type = "array",
      items = {
        type = "object",
        properties = {
          filename = { type = "string", description = "File path" },
          lnum = { type = "integer", description = "Line number (1-based)" },
          col = { type = "integer", description = "Column number (1-based, optional)" },
          text = { type = "string", description = "Description text for the item" },
          type = { type = "string", description = "Item type: E (error), W (warning), I (info), N (note)" },
        },
        required = { "filename", "lnum", "text" },
      },
      description = "List of quickfix items",
    },
    title = { type = "string", description = "Title for the quickfix list" },
  },
  required = { "items" },
}, function(args, _, callback)
  if not args.items or #args.items == 0 then
    callback({
      content = { "Error: No items provided for quickfix list" },
      display_content = { FAILED_TO_CREATE_QF },
      kind = "failed",
    })
    return
  end

  local qf_items = {}
  local valid_types = { E = true, W = true, I = true, N = true }

  for i, item in ipairs(args.items) do
    if not item.filename or not item.lnum or not item.text then
      callback({
        content = { string.format("Error: Item %d missing required fields (filename, lnum, text)", i) },
        display_content = { FAILED_TO_CREATE_QF },
        kind = "failed",
      })
      return
    end

    local qf_item = {
      filename = item.filename,
      lnum = item.lnum,
      col = item.col or 1,
      text = item.text,
    }

    if item.type and valid_types[item.type] then
      qf_item.type = item.type
    end

    table.insert(qf_items, qf_item)
  end

  vim.fn.setqflist(qf_items, "r")

  if args.title then
    vim.fn.setqflist({}, "a", { title = args.title })
  end

  vim.cmd("copen")

  local title = args.title or "Quickfix List"
  callback({
    content = {
      string.format("Created quickfix list `%s` with %d items", title, #qf_items),
      "Use :cnext/:cprev to navigate, or click items in the quickfix window",
    },
    display_content = { string.format("📝 Created quickfix list with %d items", #qf_items) },
  })
end)
