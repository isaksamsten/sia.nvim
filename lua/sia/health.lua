local function check_executable(name, description, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(string.format("%s is available", name))
    return
  end

  local message = string.format("%s is %s", name, description)
  if required then
    vim.health.error(message)
  else
    vim.health.warn(message)
  end
end

local function check_puppeteer_on_arm()
  local machine = (vim.uv.os_uname().machine or ""):lower()
  if not machine:match("arm") and not machine:match("aarch64") then
    return
  end

  local browsers = { "chromium", "chromium-browser", "google-chrome", "google-chrome-stable" }
  local browser
  for _, name in ipairs(browsers) do
    if vim.fn.executable(name) == 1 then
      browser = vim.fn.exepath(name)
      break
    end
  end

  local executable_path = vim.env.PUPPETEER_EXECUTABLE_PATH
  if executable_path and executable_path ~= "" then
    vim.health.ok("PUPPETEER_EXECUTABLE_PATH is configured for webfetch")
    return
  end

  local path_hint = browser or "the path returned by `which chromium` (or `which chromium-browser`)"
  vim.health.warn(
    "Puppeteer may not provide a compatible browser for ARM systems. "
      .. "Install Chromium, set PUPPETEER_SKIP_DOWNLOAD=true "
      .. "(PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true for older Puppeteer releases), and set "
      .. "PUPPETEER_EXECUTABLE_PATH="
      .. path_hint
  )
end

return {
  check = function()
    vim.health.start("Sia")

    vim.health.info("Checking required external dependencies")
    check_executable("curl", "required to communicate with providers", true)

    vim.health.info("Checking optional external dependencies")
    local optional = {
      { "rg", "required by the grep tool" },
      { "fd", "required by the glob tool" },
      { "git", "required by the git_worktree tool and Git-aware actions" },
      { "/bin/bash", "the default shell used by the bash tool" },
      { "node", "required by the webfetch tool" },
      { "npm", "required to install dependencies for the webfetch tool" },
      {
        "openssl",
        "required for OAuth authentication with the Codex and Claude providers",
      },
    }
    for _, dependency in ipairs(optional) do
      check_executable(dependency[1], dependency[2], false)
    end
    check_puppeteer_on_arm()

    local browser_openers = vim.fn.has("win32") == 1 and { "start" }
      or vim.fn.has("mac") == 1 and { "open" }
      or { "xdg-open" }
    local opener_available = false
    for _, name in ipairs(browser_openers) do
      if vim.fn.executable(name) == 1 then
        opener_available = true
        vim.health.ok(string.format("%s is available", name))
        break
      end
    end
    if not opener_available then
      vim.health.warn(
        string.format(
          "%s is optional for opening provider OAuth URLs in a browser",
          table.concat(browser_openers, " or ")
        )
      )
    end

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
