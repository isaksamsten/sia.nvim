local M = {}

--- @class sia.Model
--- @field config table The normalized model config with name and optional overrides
--- @field spec table The model specification from M.options.models
local Model = {}
Model.__index = Model

--- Create a new Model instance
--- @param model_config table Normalized model config with at least {name:string}
--- @return sia.Model
function Model:new(model_config)
  local config = require("sia.config")

  if not model_config or not model_config.name then
    error("Model config must have a 'name' field")
  end

  local model_spec = config.options.models[model_config.name]
  if not model_spec then
    error(string.format("Unknown model: %s", model_config.name))
  end

  local obj = setmetatable({}, self)
  obj.config = model_config
  obj.spec = model_spec
  return obj
end

--- Resolve a model config (string or table) to a Model instance
--- @param model_config table|string|nil Normalized model config or string name
--- @return sia.Model
function M.resolve(model_config)
  local config = require("sia.config")

  -- If nil, use default model
  if not model_config then
    model_config = config.get_default_model()
  end

  -- If string, normalize it
  if type(model_config) == "string" then
    model_config = { name = model_config }
  end

  return Model:new(config.resolve_model_config(model_config))
end

--- Get the model name (e.g., "openai/gpt-4.1")
--- @return string
function Model:name()
  return self.config.name
end

--- Get the provider name (e.g., "openai")
--- @return string
function Model:provider_name()
  return self.spec[1]
end

--- Get the API model name (e.g., "gpt-4.1")
--- @return string
function Model:api_name()
  return self.spec[2]
end

--- Get the provider instance
--- @return sia.config.Provider
function Model:get_provider()
  local config = require("sia.config")
  local provider = config.options.providers[self:provider_name()]
  if not provider then
    provider = require("sia.provider.defaults")[self:provider_name()]
  end
  return provider
end

--- Get a parameter value, checking config overrides first, then model spec
--- @param key string Parameter name (e.g., "temperature", "pricing", "reasoning_effort")
--- @param default any? Default value if not found
--- @return any
function Model:get_param(key, default)
  -- Check config overrides first
  if self.config[key] ~= nil then
    return self.config[key]
  end

  -- Then check model spec
  if self.spec[key] ~= nil then
    return self.spec[key]
  end

  return default
end

--- Get all parameters from both config and spec, with config taking precedence
--- @return table
function Model:get_all_params()
  local params = vim.tbl_extend("force", {}, self.spec)
  params = vim.tbl_extend("force", params, self.config)
  return params
end

--- Get the full model spec (provider name, api name, and all params)
--- Useful for provider.prepare_parameters
--- @return table
function Model:get_spec()
  return self.spec
end

return M
