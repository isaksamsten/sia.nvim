local common = require("sia.strategy.common")

local Writer = common.Writer
local Strategy = common.Strategy
local Canvas = require("sia.canvas").Canvas

local DIFF_NS = vim.api.nvim_create_namespace("SiaDiffStrategy")

--- @class sia.DiffStrategy : sia.Strategy
--- @field buf number
--- @field win number
--- @field options sia.config.Diff
--- @field private _writer sia.Writer?
local DiffStrategy = setmetatable({}, { __index = Strategy })
DiffStrategy.__index = DiffStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Diff
function DiffStrategy:new(conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(win, buf)

  obj.buf = buf
  obj.win = win
  obj.options = options
  return obj
end

function DiffStrategy:on_init()
  local context = self.conversation.context
  if
    not context
    or not vim.api.nvim_buf_is_loaded(context.buf)
    or not vim.api.nvim_buf_is_loaded(self.buf)
  then
    return false
  end
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].ft = vim.bo[self.conversation.context.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.win][wo] = vim.wo[self.conversation.context.win][wo]
  end

  local before = vim.api.nvim_buf_get_lines(context.buf, 0, context.pos[1] - 1, true)
  vim.api.nvim_buf_set_lines(self.buf, 0, 0, false, before)

  vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(context.buf, DIFF_NS, context.pos[1] - 1, 0, {
    virt_lines = {
      { { "🤖 ", "Normal" }, { "Analyzing changes...", "SiaProgress" } },
    },
    virt_lines_above = context.pos[1] - 1 > 0,
    hl_group = "SiaReplace",
    end_line = context.pos[2],
  })
  self._writer = Writer:new({
    canvas = Canvas:new(self.buf, { temporary_text_hl = "SiaInsert" }),
    line = vim.api.nvim_buf_line_count(self.buf) - 1,
  })
  self:set_abort_keymap(self.buf)
  return true
end

function DiffStrategy:on_error()
  vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, DIFF_NS, 0, -1)
  self._writer.canvas:clear_temporary_text()
end

function DiffStrategy:on_cancelled()
  self:on_error()
end

function DiffStrategy:on_start()
  if not vim.api.nvim_buf_is_loaded(self.buf) then
    return false
  end
  return true
end

--- @param content string
function DiffStrategy:on_progress(content)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
    return true
  end
  return false
end

function DiffStrategy:on_complete(control)
  self:execute_tools({
    handle_tools_completion = function(opts)
      self.conversation:add_instruction({
        role = "assistant",
        content = self._writer.cache,
      })
      if opts.results then
        for _, tool_result in ipairs(opts.results) do
          self.conversation:add_instruction({
            { role = "assistant", tool_calls = { tool_result.tool } },
            {
              role = "tool",
              content = tool_result.result.content,
              _tool_call = tool_result.tool,
              kind = tool_result.result.kind,
            },
          }, tool_result.result.context)

          if
            tool_result.result.display_content and tool_result.result.display_content[1]
          then
            self._writer:append(tool_result.result.display_content[1])
          end
        end
        -- Add reminder after tool calls to prevent explanatory text
        self.conversation:add_instruction({
          role = "user",
          content = "If you're ready to replace the selected text now, output ONLY the replacement text - no explanations, no 'Here's the updated code:', no 'I've made these changes:', nothing else. Your entire next response will be used verbatim as the replacement.",
        })
      end
      self._writer:append_newline()
      self._writer:reset_cache()

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      if vim.api.nvim_buf_is_loaded(self.buf) then
        self:del_abort_keymap(self.buf)
        local context = self.conversation.context
        if not context then
          control.finish()
          self.conversation:untrack_messages()
          return
        end
        self._writer.canvas:clear_temporary_text()
        vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, self._writer.cache)
        local after = vim.api.nvim_buf_get_lines(context.buf, context.pos[2], -1, true)
        vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, after)
        if
          vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_is_valid(context.win)
        then
          vim.api.nvim_set_current_win(self.win)
          vim.cmd("diffthis")
          vim.api.nvim_set_current_win(context.win)
          vim.cmd("diffthis")
        end
        vim.bo[self.buf].modifiable = false
      end
      vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, DIFF_NS, 0, -1)
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

return DiffStrategy
