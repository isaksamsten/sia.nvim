return {

  check = function()
    vim.health.start("Sia")
    vim.health.info("Validating agent definitions")
    require("sia.agent.registry").scan()
    local errors = require("sia.agent.registry").errors()
    if vim.tbl_count(errors) > 0 then
      for name, error in pairs(errors) do
        vim.health.error(
          string.format(
            "Error parsing agent '%s' in  %s: %s",
            name,
            error.path,
            error.message
          )
        )
      end
    else
      vim.health.ok("Agents are fine")
    end
    vim.health.info("Validating skill definitions")
    require("sia.skills.registry").scan()
    errors = require("sia.skills.registry").errors()
    if vim.tbl_count(errors) > 0 then
      for name, error in pairs(errors) do
        vim.health.error(
          string.format(
            "Error parsing skill '%s' in  %s: %s",
            name,
            error.path,
            error.message
          )
        )
      end
    else
      vim.health.ok("Skills are fine")
    end
  end,
}
