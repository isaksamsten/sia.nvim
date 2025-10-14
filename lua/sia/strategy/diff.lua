local common = require("sia.strategy.common")

local Writer = common.Writer
local Strategy = common.Strategy
local Canvas = require("sia.canvas").Canvas

local DIFF_NS = vim.api.nvim_create_namespace("SiaDiffStrategy")

--- @class sia.DiffStrategy : sia.Strategy
--- @field target_buf number
--- @field target_win number
--- @field options sia.config.Diff
--- @field private context sia.Context
--- @field private writer sia.Writer?
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

  if not conversation.context then
    error("Can't initialize DiffStrategy")
  end
  obj.context = conversation.context
  obj.target_buf = buf
  obj.target_win = win
  obj.options = options
  return obj
end

--- @private
function DiffStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.context.buf)
    and vim.api.nvim_buf_is_loaded(self.target_buf)
end

function DiffStrategy:on_request_start()
  if not self:buf_is_loaded() then
    return false
  end
  local context = self.context
  vim.bo[context.buf].modifiable = false
  vim.bo[self.target_buf].modifiable = true
  vim.bo[self.target_buf].buftype = "nofile"
  vim.bo[self.target_buf].ft = vim.bo[context.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.target_win][wo] = vim.wo[context.win][wo]
  end

  local before = vim.api.nvim_buf_get_lines(context.buf, 0, context.pos[1] - 1, true)
  vim.api.nvim_buf_set_lines(self.target_buf, 0, 0, false, before)

  vim.api.nvim_buf_set_extmark(context.buf, DIFF_NS, context.pos[1] - 1, 0, {
    virt_lines = {
      { { "🤖 ", "Normal" }, { "Analyzing changes...", "SiaProgress" } },
    },
    virt_lines_above = context.pos[1] - 1 > 0,
    hl_group = "SiaReplace",
    end_line = context.pos[2],
  })
  self.writer = Writer:new({
    canvas = Canvas:new(self.target_buf, { temporary_text_hl = "SiaInsert" }),
    line = vim.api.nvim_buf_line_count(self.target_buf) - 1,
  })
  self:set_abort_keymap(self.target_buf)
  return true
end

function DiffStrategy:on_error()
  if self:buf_is_loaded() then
    vim.api.nvim_buf_clear_namespace(self.target_buf, DIFF_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.context.buf, DIFF_NS, 0, -1)
    self.writer.canvas:clear_temporary_text()
  end
end

function DiffStrategy:on_cancelled()
  self:on_error()
end

function DiffStrategy:on_stream_started()
  return self:buf_is_loaded()
end

--- @param content string
function DiffStrategy:on_content_received(content)
  if self:buf_is_loaded() then
    self.writer:append(content)
    return true
  end
  return false
end

function DiffStrategy:on_completed(control)
  self:execute_tools({
    handle_tools_completion = function(opts)
      self.conversation:add_instruction({
        role = "assistant",
        content = self.writer.cache,
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

          if tool_result.result.display_content then
            for _, display in ipairs(tool_result.result.display_content) do
              self.writer:append(display)
            end
          end
        end

        self.conversation:add_instruction({
          role = "user",
          content = "If you're ready to replace the selected text now, output ONLY the replacement text - no explanations, no 'Here's the updated code:', no 'I've made these changes:', nothing else. Your entire next response will be used verbatim as the replacement.",
        })
      end
      self.writer:append_newline()
      self.writer:reset_cache()

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      local context = self.context
      local buf_loaded = vim.api.nvim_buf_is_loaded(self.target_buf)
      local diff_win_valid = vim.api.nvim_win_is_valid(self.target_win)
      local curr_win_valid = context and vim.api.nvim_win_is_valid(context.win)
      if not (buf_loaded and diff_win_valid and curr_win_valid) then
        control.finish()
        self.conversation:untrack_messages()
        return
      end

      self:del_abort_keymap(self.target_buf)
      self.writer.canvas:clear_temporary_text()
      vim.api.nvim_buf_set_lines(self.target_buf, -1, -1, false, self.writer.cache)
      local after = vim.api.nvim_buf_get_lines(context.buf, context.pos[2], -1, true)
      vim.api.nvim_buf_set_lines(self.target_buf, -1, -1, false, after)
      vim.api.nvim_set_current_win(self.target_win)
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(context.win)
      vim.cmd("diffthis")
      vim.bo[self.target_buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(self.context.buf, DIFF_NS, 0, -1)
      vim.bo[context.buf].modifiable = true
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

return DiffStrategy
