local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy
local Canvas = require("sia.canvas").Canvas

local DIFF_NS = vim.api.nvim_create_namespace("SiaDiffStrategy")

--- @class sia.DiffStrategy : sia.Strategy
--- @field buf number
--- @field win number
--- @field pos [integer,integer]
--- @field target_buf number
--- @field target_win number
--- @field options sia.config.Diff
--- @field private writer sia.StreamRenderer?
local DiffStrategy = setmetatable({}, { __index = Strategy })
DiffStrategy.__index = DiffStrategy

--- @param buf number
--- @param win number
--- @param pos [integer,integer]
--- @param conversation sia.Conversation
--- @param options sia.config.Diff
function DiffStrategy:new(buf, win, pos, conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  vim.cmd(options.cmd)
  obj.target_win = vim.api.nvim_get_current_win()
  obj.target_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(obj.target_win, obj.target_buf)
  obj.buf = buf
  obj.win = win
  obj.options = options
  obj.pos = pos or { 1, vim.api.nvim_buf_line_count(buf) }
  return obj
end

--- @private
function DiffStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
    and vim.api.nvim_buf_is_loaded(self.target_buf)
end

function DiffStrategy:on_request_start()
  if not self:buf_is_loaded() then
    return false
  end
  vim.bo[self.buf].modifiable = false
  vim.bo[self.target_buf].modifiable = true
  vim.bo[self.target_buf].buftype = "nofile"
  vim.bo[self.target_buf].ft = vim.bo[self.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.target_win][wo] = vim.wo[self.win][wo]
  end

  if self.pos[1] > 1 then
    local before = vim.api.nvim_buf_get_lines(self.buf, 0, self.pos[1] - 1, true)
    vim.api.nvim_buf_set_lines(self.target_buf, 0, 0, false, before)
  end

  vim.api.nvim_buf_set_extmark(self.buf, DIFF_NS, self.pos[1] - 1, 0, {
    virt_lines = {
      { { "🤖 ", "Normal" }, { "Analyzing changes...", "SiaProgress" } },
    },
    virt_lines_above = self.pos[1] - 1 > 0,
    hl_group = "SiaReplace",
    end_line = self.pos[2],
  })
  self.writer = StreamRenderer:new({
    canvas = Canvas:new(self.target_buf, { temporary_text_hl = "SiaInsert" }),
    line = vim.api.nvim_buf_line_count(self.target_buf) - 1,
    temporary = true,
  })
  self:set_abort_keymap(self.target_buf)
  return true
end

function DiffStrategy:on_error()
  if self:buf_is_loaded() then
    vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
    self.writer.canvas:clear_temporary_text()
  end
end

function DiffStrategy:on_cancel()
  self:on_error()
end

function DiffStrategy:on_stream_start()
  return self:buf_is_loaded()
end

function DiffStrategy:on_content(input)
  if self:buf_is_loaded() then
    if input.content then
      self.writer:append(input.content)
    end
    if input.tool_calls then
      self.pending_tools = input.tool_calls
    end
    return true
  end
  return false
end

function DiffStrategy:on_complete(control)
  self:execute_tools({
    turn_id = control.turn_id,
    handle_tools_completion = function(opts)
      if opts.results then
        for _, tool_result in ipairs(opts.results) do
          self.conversation:add_instruction({
            { role = "assistant", tool_calls = { tool_result.tool } },
            {
              role = "tool",
              content = tool_result.result.content,
              _tool_call = tool_result.tool,
              kind = tool_result.result.kind,
              ephemeral = tool_result.result.kind == "failed"
                or tool_result.result.ephemeral,
            },
          }, tool_result.result.context, { turn_id = control.turn_id })

          if tool_result.result.display_content then
            self.writer:append(tool_result.result.display_content)
          end
        end

        self.conversation:add_instruction({
          role = "user",
          content = "If you're ready to replace the selected text now, output ONLY the replacement text - no explanations, no 'Here's the updated code:', no 'I've made these changes:', nothing else. Your entire next response will be used verbatim as the replacement.",
        }, nil, { turn_id = control.turn_id })
      end
      self.writer:append_newline()

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
      local content = control.content
      local buf_loaded = vim.api.nvim_buf_is_loaded(self.target_buf)
      local diff_win_valid = vim.api.nvim_win_is_valid(self.target_win)
      local curr_win_valid = vim.api.nvim_win_is_valid(self.win)
      if not (buf_loaded and diff_win_valid and curr_win_valid and content) then
        control.finish()
        self.conversation:untrack_messages()
        return
      end

      self:del_abort_keymap(self.target_buf)
      self.writer.canvas:clear_temporary_text()
      vim.api.nvim_buf_set_lines(
        self.target_buf,
        self.pos[1] - 1,
        self.pos[2] - 1,
        false,
        content
      )
      if self.pos[2] < vim.api.nvim_buf_line_count(self.buf) then
        local after = vim.api.nvim_buf_get_lines(self.buf, self.pos[2], -1, true)
        vim.api.nvim_buf_set_lines(
          self.target_buf,
          #content + self.pos[2] - 1,
          -1,
          false,
          after
        )
      end
      vim.api.nvim_set_current_win(self.target_win)
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(self.win)
      vim.cmd("diffthis")
      vim.bo[self.target_buf].modifiable = false
      vim.bo[self.buf].modifiable = true
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

return DiffStrategy
