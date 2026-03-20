--- @type table<string, sia.config.Mode>
local Modes = {}

--- @type sia.config.Mode
Modes.plan = {
  description = "Create a structured plan before implementing",
  truncate = true,
  permissions = {
    deny = { "apply_diff", "bash", "agent" },
    allow = {
      view = true,
      grep = true,
      glob = true,
      diagnostics = true,
      memory = true,
      webfetch = true,
      websearch = true,
      edit = { arguments = { path = { "(^|/)PLAN_" } } },
      insert = { arguments = { path = { "(^|/)PLAN_" } } },
      write = { arguments = { path = { "(^|/)PLAN_" } } },
    },
  },
  init_state = function()
    return {
      plan_file = "PLAN_" .. os.date("%Y%m%d_%H%M%S") .. ".md",
    }
  end,
  enter_prompt = function(state)
    return table.concat({
      "Your goal is to analyze the codebase and produce a structured, actionable plan.",
      "Write the plan to `" .. state.plan_file .. "` using the `write` tool.",
      "",
      "Guidelines:",
      "- Explore the codebase with `view`, `grep`, and `glob` to understand the problem",
      "- Identify affected files, dependencies, and potential risks",
      "- Break the work into clear, ordered implementation steps",
      "- Do NOT make any code changes -- only produce the plan document",
      "",
    }, "\n")
  end,
  exit_prompt = function(state)
    local stat = vim.uv.fs_stat(state.plan_file)
    if stat then
      return table.concat({
        "Plan mode has ended.",
        "The plan is in `" .. state.plan_file .. "`.",
        "You may now proceed with implementation.",
        "Follow the plan steps in order.",
      }, "\n")
    else
      return "Plan mode has ended without a plan"
    end
  end,
}

return Modes
