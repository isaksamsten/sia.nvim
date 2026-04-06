local M = {}

--- @class sia.Model
--- @field name string
--- @field api_name string
--- @field provider_name string
--- @field context_window integer?
--- @field response_format table?
--- @field pricing {input: number, output: number}?
--- @field cache_multiplier {read: number, write: number}?
--- @field options table<string, any>
--- @field support sia.config.Support
--- @field provider sia.Provider

--- @param model_config table|string|nil Normalized model config or string name
--- @return sia.Model
function M.resolve(model_config)
  local config = require("sia.config")

  if not model_config then
    model_config = config.options.settings.model
  end

  if type(model_config) == "string" then
    model_config = { name = model_config }
  end

  local provider = require("sia.provider")
  if not model_config or not model_config.name then
    error("Model config must have a 'name' field")
  end

  local name = model_config.name

  local lc = config.get_local_config()
  local aliases = lc and lc.aliases or nil
  local alias_params = nil

  if aliases and aliases[name] then
    local alias = aliases[name]
    alias_params = alias
    name = alias.name
  end

  local resolved = provider.resolve_model(name)

  if lc and lc.models then
    local local_ov = lc.models[resolved.provider_name]
      and lc.models[resolved.provider_name][resolved.short_name]
    if local_ov then
      resolved.options = vim.tbl_extend("force", resolved.options or {}, local_ov)
    end
  end

  --- @type sia.Model
  local obj = {
    name = model_config.name,
    provider_name = resolved.provider_name,
    api_name = resolved.api_name,
    provider = resolved.provider,
    support = setmetatable({}, {
      __index = function(_, key)
        return resolved.support ~= nil and resolved.support[key] or false
      end,
    }),
    context_window = resolved.context_window,
    response_format = resolved.response_format,
    pricing = resolved.pricing,
    cache_multiplier = resolved.cache_multiplier,
    options = resolved.options or {},
  }

  if alias_params and alias_params.options then
    obj.options = vim.tbl_extend("force", obj.options, alias_params.options)
  end
  obj.options = vim.tbl_extend("force", obj.options, model_config.options or {})

  return obj
end

return M
