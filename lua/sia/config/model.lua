local M = {}

---@alias sia.ModelTier "mini"|"default"|"pro"
---@alias sia.ModelConfig string|{name: string, options: table?}
---@alias sia.ModelRoles table<string, sia.ModelConfig|table<sia.ModelTier, sia.ModelConfig>>
---@alias sia.ModelSelection string|{role: string?, tier: sia.ModelTier?}

M.tiers = { mini = true, default = true, pro = true }

local function concrete(value)
  return type(value) == "string"
    or (type(value) == "table" and type(value.name) == "string")
end

local function normalize_concrete(value, path, check_name)
  if not concrete(value) then
    error(path .. " must be a model name or a table with a 'name' field", 0)
  end
  local result = type(value) == "string" and { name = value } or vim.deepcopy(value)
  if result.name == "" then
    error(path .. " must have a non-empty model name", 0)
  end
  for key in pairs(result) do
    if key ~= "name" and key ~= "options" then
      error(path .. "." .. tostring(key) .. " is not supported", 0)
    end
  end
  if result.options ~= nil and type(result.options) ~= "table" then
    error(path .. ".options must be a table", 0)
  end
  if check_name and not check_name(result.name) then
    error(
      path
        .. " must be one of the allowed models or aliases, got '"
        .. result.name
        .. "'",
      0
    )
  end
  return result
end

--- Expand shorthands without filling missing tiers (fallback happens at selection).
---@param value sia.ModelConfig|sia.ModelRoles|nil
---@param check_name (fun(name: string): boolean)?
---@return table<string, table<sia.ModelTier, {name: string, options: table?}>>
function M.normalize(value, check_name)
  if value == nil then
    return {}
  end
  if concrete(value) then
    value = { default = value }
  elseif type(value) ~= "table" then
    error("model must be a model name or a table of roles", 0)
  end
  local result = {}
  for role, tiers in pairs(value) do
    if type(role) ~= "string" or role == "" then
      error("model role names must be non-empty strings", 0)
    end
    local path = "model." .. role
    result[role] = {}
    if concrete(tiers) then
      local model = normalize_concrete(tiers, path, check_name)
      for tier in pairs(M.tiers) do
        result[role][tier] = vim.deepcopy(model)
      end
    elseif type(tiers) == "table" then
      for tier, model in pairs(tiers) do
        if not M.tiers[tier] then
          error(
            path
              .. "."
              .. tostring(tier)
              .. " is not a valid tier (use mini, default, or pro)",
            0
          )
        end
        result[role][tier] = normalize_concrete(model, path .. "." .. tier, check_name)
      end
    else
      error(path .. " must be a model name or a table of tiers", 0)
    end
  end
  return result
end

--- Replace model leaves rather than merging parameters from different models.
function M.merge(base, overrides)
  local result = vim.deepcopy(base)
  for role, tiers in pairs(overrides) do
    result[role] = result[role] or {}
    for tier, model in pairs(tiers) do
      result[role][tier] = vim.deepcopy(model)
    end
  end
  return result
end

function M.validate_selection(selection, path)
  path = path or "model"
  if type(selection) == "string" then
    selection = { role = selection, tier = "default" }
  end
  if type(selection) ~= "table" then
    error(path .. " must be a role name or a table with role and tier", 0)
  end
  for key in pairs(selection) do
    if key ~= "role" and key ~= "tier" then
      error(path .. "." .. tostring(key) .. " is not supported", 0)
    end
  end
  if
    selection.role ~= nil and (type(selection.role) ~= "string" or selection.role == "")
  then
    error(path .. ".role must be a non-empty string", 0)
  end
  if selection.tier ~= nil and not M.tiers[selection.tier] then
    error(path .. ".tier must be mini, default, or pro", 0)
  end
  return selection
end

--- Strings always select role.default; omissions use the caller's default tier.
---@param selection sia.ModelSelection|nil
---@param default_tier sia.ModelTier
---@param path string?
---@return {role: string, tier: sia.ModelTier}
function M.normalize_selection(selection, default_tier, path)
  local value = M.validate_selection(selection == nil and {} or selection, path)
  return { role = value.role or "default", tier = value.tier or default_tier }
end

return M
