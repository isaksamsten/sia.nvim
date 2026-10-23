local M = {}

local context_paths = {
  ["context.tools.max_calls"] = "number",
  ["context.tools.keep_last"] = "number",
  ["context.tools.strip_inputs"] = "boolean",
  ["context.tokens.prune.at_fraction"] = "number",
  ["context.tokens.prune.to_fraction"] = "number",
  ["context.tokens.compact.oldest_fraction"] = "number",
}

local function path_parts(path)
  local parts = vim.split(path, ".", { plain = true })
  for _, part in ipairs(parts) do
    if part == "" then
      error("empty configuration path component", 0)
    end
  end
  if context_paths[path] then
    return parts, context_paths[path]
  end
  if path == "action.chat" then
    return parts, "string"
  end
  if parts[1] ~= "model" then
    error("unsupported configuration path: " .. path, 0)
  end
  if #parts == 1 then
    return parts, "string"
  end
  if #parts < 3 or not require("sia.config.model").tiers[parts[3]] then
    error("use model.<role>.<mini|default|pro>[.name|.options.<path>]", 0)
  end
  if #parts == 3 or (#parts == 4 and parts[4] == "name") then
    return parts, "string"
  end
  if #parts == 4 and parts[4] == "options" then
    return parts, "read_only"
  end
  if #parts >= 5 and parts[4] == "options" then
    return parts, "scalar"
  end
  error("unsupported model path", 0)
end

function M.run(args)
  local ok, err = pcall(function()
    local path, text = args.args:match("^(%S+)%s+(.+)$")
    path = path or args.args
    if path == "" then
      vim.notify(vim.inspect({
        model = require("sia.config").options.settings.model,
        context = require("sia.config").options.settings.context,
      }))
      return
    end
    if path == "skill" or path == "agent" then
      local key = path == "skill" and "skills" or "agents"
      local current = require("sia.config").options.settings[key] or {}
      if not text and not args.bang then
        vim.notify(path .. " = " .. vim.inspect(current))
        return
      end
      local operation, name
      if args.bang then
        if text then
          error("use :SiaConfig! " .. path .. " to remove generated entries", 0)
        end
      else
        operation, name = text:match("^([+-])(%S+)$")
        if not name then
          error("use " .. path .. " +<name> or -<name>", 0)
        end
        if operation == "+" and vim.tbl_contains(current, name) then
          return
        end
      end
      local updated, result = require("sia.config.local").update_auto_config(
        function(json)
          if args.bang then
            json[key] = nil
            return
          end
          local values = json[key] or {}
          if operation == "+" then
            if not vim.tbl_contains(values, name) then
              values[#values + 1] = name
            end
          else
            values = vim.tbl_filter(function(entry)
              return entry ~= name
            end, values)
          end
          json[key] = #values > 0 and values or nil
        end
      )
      if not updated then
        error(result, 0)
      end
      vim.notify("sia: " .. path .. " saved")
      return
    end
    local parts, expected = path_parts(path)
    if not text and not args.bang then
      local value = require("sia.config").options.settings
      if parts[1] == "action" then
        value = require("sia.config").get_local_config() or {}
      end
      for _, part in ipairs(parts) do
        value = type(value) == "table" and value[part] or nil
      end
      vim.notify(path .. " = " .. vim.inspect(value))
      return
    end
    if expected == "read_only" and not args.bang then
      error("options can only be inspected or unset. Use an options.<path> to edit", 0)
    end
    if args.bang and text then
      error("use :SiaConfig! <path> to remove a generated setting", 0)
    end
    local value
    if not args.bang then
      local decoded, parsed = pcall(vim.json.decode, text)
      if decoded then
        value = parsed
      else
        value = text
      end
      if expected == "string" then
        if type(value) ~= "string" then
          error("expected a string", 0)
        end
      elseif expected == "scalar" then
        if
          type(value) ~= "string"
          and type(value) ~= "number"
          and type(value) ~= "boolean"
        then
          error("expected a string, number, or boolean", 0)
        end
      elseif type(value) ~= expected then
        error("expected " .. expected, 0)
      end
    end
    local updated, result = require("sia.config.local").update_auto_config(
      function(json)
        if #parts == 1 then
          if args.bang then
            json.model = nil
          else
            json.model = require("sia.config.model").normalize(value)
          end
          return
        end
        local node = json
        local parents = {}
        for i = 1, #parts - 1 do
          local key = parts[i]
          if type(node[key]) == "string" and parts[1] == "model" then
            node[key] = { name = node[key] }
          end
          if node[key] == nil then
            if args.bang then
              return
            end
            node[key] = {}
          end
          if type(node[key]) ~= "table" then
            error("path crosses a scalar value", 0)
          end
          parents[#parents + 1] = { node = node, key = key }
          node = node[key]
        end
        local key = parts[#parts]
        if
          parts[1] == "model"
          and #parts == 4
          and key == "name"
          and not args.bang
          and node.name ~= nil
          and node.name ~= value
        then
          node.options = nil
        end
        if parts[1] == "model" and #parts == 3 and not args.bang then
          node[key] = { name = value }
        else
          node[key] = value
        end
        if args.bang then
          for i = #parents, 1, -1 do
            local parent = parents[i]
            if
              type(parent.node[parent.key]) == "table"
              and next(parent.node[parent.key]) == nil
            then
              parent.node[parent.key] = nil
            end
          end
        end
      end
    )
    if not updated then
      error(result, 0)
    end
    vim.notify("sia: " .. path .. (args.bang and " removed" or " saved"))
  end)
  if not ok then
    vim.notify("sia: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.complete(lead, line, cursor)
  local before = line and line:sub(1, cursor or #line) or ""
  if before:match("SiaConfig!?%s+action%.chat%s+[^%s]*$") then
    local registry = require("sia.agent.registry")
    registry.scan()
    local names = {}
    for name in pairs(require("sia.config").options.actions) do
      names[name] = true
    end
    for _, agent in
      ipairs(registry.filter(function()
        return true
      end))
    do
      names[agent.name] = true
    end
    local candidates = {}
    for name in pairs(names) do
      if vim.startswith(name, lead) then
        candidates[#candidates + 1] = name
      end
    end
    table.sort(candidates)
    return candidates
  end
  local kind = before:match("SiaConfig!?%s+(skill)%s+[^%s]*$")
    or before:match("SiaConfig!?%s+(agent)%s+[^%s]*$")
  if kind then
    local names = {}
    if kind == "skill" then
      names = require("sia.skills.registry").list_skill_names()
    else
      for _, agent in
        ipairs(require("sia.agent.registry").filter(function()
          return true
        end))
      do
        names[#names + 1] = agent.name
      end
    end
    local candidates = {}
    local sign = lead:sub(1, 1) == "-" and "-" or "+"
    for _, name in ipairs(names) do
      local candidate = sign .. name
      if vim.startswith(candidate, lead) then
        candidates[#candidates + 1] = candidate
      end
    end
    table.sort(candidates)
    return candidates
  end
  local paths = { "model", "skill", "agent", "action.chat" }
  for path in pairs(context_paths) do
    paths[#paths + 1] = path
  end
  local roles = require("sia.config").options.settings.model
  for role in pairs(roles) do
    for tier in pairs(require("sia.config.model").tiers) do
      local prefix = "model." .. role .. "." .. tier
      paths[#paths + 1] = prefix
      paths[#paths + 1] = prefix .. ".name"
      paths[#paths + 1] = prefix .. ".options."
    end
  end
  table.sort(paths)
  return vim.tbl_filter(function(path)
    return vim.startswith(path, lead)
  end, paths)
end

return M
