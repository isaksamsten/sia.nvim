local M = {}

--- @type sia.config.Tool
M.add_file = {
  name = "add_file",
  description = "Add files to the list of files to be included in the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be added." } },
  required = { "glob_pattern" },
  execute = function(args, split, callback)
    --- @cast split sia.SplitStrategy
    if args.glob_pattern then
      local files = require("sia.utils").glob_pattern_to_files(args.glob_pattern)
      if #files > 3 then
        callback({ "The glob pattern is too broad. Please narrow it down." })
        return
      end

      local missing_files = {}
      local existing_files = {}
      for _, file in ipairs(files) do
        if vim.fn.filereadable(file) == 0 then
          table.insert(missing_files, file)
        else
          table.insert(existing_files, file)
          split:add_file(file)
        end
      end
      local message = {}
      if #existing_files > 0 and #missing_files > 0 then
        message[#message + 1] = "I've added the files:"
        for _, file in ipairs(existing_files) do
          table.insert(message, " - " .. file)
        end
        message[#message + 1] = ""
        message[#message + 1] = "I can't seem to find the files:"
        for _, file in ipairs(missing_files) do
          table.insert(message, " - " .. file)
        end
      elseif #existing_files > 0 then
        message[#message + 1] = "I've added the files:"
        for _, file in ipairs(existing_files) do
          table.insert(message, " - " .. file)
        end
      else
        message[#message + 1] = "I can't seem to find the files:"
        for _, file in ipairs(missing_files) do
          table.insert(message, " - " .. file)
        end
      end
      callback(message)
    else
      callback({ "The glob pattern is missing" })
    end
  end,
}

--- @type sia.config.Tool
M.remove_file = {
  name = "remove_file",
  description = "Remove files from the list of files to be processed",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be deleted." } },
  required = { "glob_pattern" },
  execute = function(args, split, callback)
    if args.glob_pattern then
      --- @cast split sia.SplitStrategy
      split:remove_files({ args.glob_pattern })
      callback({ "I've removed the files matching " .. args.glob_pattern .. " from the conversation." })
    else
      callback({ "The glob pattern is missing" })
    end
  end,
}

return M
