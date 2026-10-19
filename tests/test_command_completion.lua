local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
      child.lua([[
        package.loaded["sia.config"] = {
          options = {
            actions = {
              doc = { mode = "insert" },
              discuss = { mode = "chat", modes = { plan = {} } },
              disabled = { enabled = function() return false end },
              selection = { range = true },
            },
            settings = { actions = { chat = { modes = { explore = {} } } } },
          },
        }
        package.loaded["sia.provider"] = { list = function() return { "test/model" } end }
        package.loaded["sia.skills.registry"] = { list_skill_names = function() return { "test-skill" } end }
        package.loaded["sia.strategy"] = { get_chat = function() return _G.test_chat end }
        local create = vim.api.nvim_create_user_command
        vim.api.nvim_create_user_command = function(name, callback, opts)
          if name == "Sia" then _G.complete_sia = opts.complete end
        end
        dofile("plugin/sia.lua")
        vim.api.nvim_create_user_command = create
        function _G.complete(line)
          local lead = line:match("%S+$") or ""
          local result = _G.complete_sia(lead, line, #line)
          table.sort(result)
          return result
        end
      ]])
    end,
    pre_case = function()
      child.lua("_G.test_chat = nil; vim.bo.filetype = ''")
    end,
    post_once = function()
      child.stop()
    end,
  },
})
local eq = MiniTest.expect.equality
local function complete(line)
  return child.lua_get("_G.complete(...)", { line })
end

T["actions complete at the start and after flags"] = function()
  eq(complete("Sia /"), { "/discuss", "/doc" })
  eq(complete("Sia /do"), { "/doc" })
  eq(complete("Sia -m test/model /do"), { "/doc" })
  eq(complete("Sia -s test-skill /do"), { "/doc" })
end

T["modes come from the selected action"] = function()
  eq(complete("Sia @"), { "@default", "@explore" })
  eq(complete("Sia /discuss @"), { "@default", "@plan" })
  eq(complete("Sia! /discuss @p"), { "@plan" })
  eq(complete("Sia /doc @"), {})
  eq(complete("Sia /unknown @"), {})
  eq(complete("Sia! @"), {})
end

T["existing chats complete prefixed modes without hiding explicit actions"] = function()
  child.lua("_G.test_chat = { conversation = { modes = { current = {} } } }")
  eq(complete("Sia @c"), { "@current" })
  eq(complete("Sia /do"), { "/doc" })
  eq(complete("Sia /discuss @p"), { "@plan" })
end

T["action and mode completion stops after input or an existing mode"] = function()
  eq(complete("Sia input /do"), {})
  eq(complete("Sia input @"), {})
  eq(complete("Sia /discuss /do"), {})
  eq(complete("Sia @explore @"), {})
  eq(complete("Sia /discuss @plan @"), {})
end

T["flag value completion is preserved"] = function()
  eq(complete("Sia -m test/"), { "test/model" })
  eq(complete("Sia -s test-"), { "test-skill" })
  eq(complete("Sia -m @"), {})
  eq(complete("Sia -s @"), {})
  eq(complete("Sia -m test/model @e"), { "@explore" })
end

return T

