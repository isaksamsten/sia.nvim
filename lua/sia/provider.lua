local M = {}

local function copilot_api_key()
  local token = nil
  local oauth = nil

  local function find_config()
    local config = vim.fn.expand("$XDG_CONFIG_HOME")
    if config and vim.fn.isdirectory(config) > 0 then
      return config
    elseif vim.fn.has("win32") > 0 then
      config = vim.fn.expand("~/AppData/Local")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    else
      config = vim.fn.expand("~/.config")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    end
  end

  local function get_oauth_token()
    if oauth then
      return oauth
    end
    local config_home = find_config()
    if not config_home then
      return nil
    end
    local apps = config_home .. "/github-copilot/apps.json"
    if vim.fn.filereadable(apps) == 1 then
      local data = vim.json.decode(table.concat(vim.fn.readfile(apps), " "))
      for key, value in pairs(data) do
        if string.find(key, "github.com") then
          return value.oauth_token
        end
      end
    end
    return nil
  end

  return function()
    if token and token.expires_at > os.time() then
      return token.token
    end

    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Can't find Copilot auth token")
    end

    local cmd = table.concat({
      "curl",
      "--silent",
      '--header "Authorization: Bearer ' .. oauth .. '"',
      '--header "Content-Type: application/json"',
      '--header "Accept: application/json"',
      "https://api.github.com/copilot_internal/v2/token",
    }, " ")
    local response = vim.fn.system(cmd)
    local status, json = pcall(vim.json.decode, response)
    if status then
      token = json
      return token.token
    end
  end
end

--- @type sia.config.Provider
M.copilot = { base_url = "https://api.githubcopilot.com/chat/completions", api_key = copilot_api_key() }

--- @type sia.config.Provider
M.openai = {
  base_url = "https://api.openai.com/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENAI_API_KEY")
  end,
}

return M