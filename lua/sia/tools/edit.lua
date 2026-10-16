local tool_utils = require("sia.tools.utils")

return tool_utils.configured_tool(function(settings)
  if settings.hashline then
    return require("sia.tools.edit.hashline")
  end
  return require("sia.tools.edit.replace")
end)
