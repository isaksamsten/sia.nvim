local M = {}

local NS = vim.api.nvim_create_namespace("sia_chat_images")
local entries = {}
local placements = {}
local backend
local checked = false
local pending = false
local attached = false

-- Capability probing is optional: custom backends only need set/get/del.
function M.available()
  if not checked then
    checked = true
    local ok, img = pcall(function()
      return vim.ui.img
    end)
    if ok and img and type(img.set) == "function" and type(img.del) == "function" then
      local supported = true
      if img._supported then
        local success, result = pcall(img._supported, { timeout = 100 })
        supported = success and result
      end
      if supported then
        backend = img
      end
    end
  end
  return backend ~= nil
end

M.height = 12

local function remove(key)
  pcall(backend.del, placements[key].id)
  placements[key] = nil
end

-- The API is screen-relative, so only place images whose entire reserved area
-- is visible and unfolded. Never let terminal graphics spill outside the chat.
function M.refresh()
  if not backend then
    return
  end
  local visible = {}
  for buf, marks in pairs(entries) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
          for id, entry in pairs(marks) do
            local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, {})
            if #mark > 0 then
              local first = mark[1] + 1
              local last = first + M.height - 1
              local unfolded = vim.api.nvim_win_call(win, function()
                for row = first, last do
                  if vim.fn.foldclosed(row) ~= -1 then
                    return false
                  end
                end
                return true
              end)
              local top = vim.fn.screenpos(win, first, 1)
              local bottom = vim.fn.screenpos(win, last, 1)
              if unfolded and top.row > 0 and bottom.row - top.row == M.height - 1 then
                local key = string.format("%d:%d:%d", buf, win, id)
                local width = math.min(40, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
                if width > 0 then
                  -- Approximate terminal cells as twice as tall as they are wide.
                  local height = math.max(1, math.min(M.height, math.floor(width / entry.aspect / 2)))
                  width = math.max(1, math.min(width, math.floor(height * entry.aspect * 2)))
                  local opts = { row = top.row, col = top.col, width = width, height = height, zindex = 1 }
                  local placement = placements[key]
                  local ok, image_id = true, placement and placement.id
                  if not placement or not vim.deep_equal(placement.opts, opts) then
                    ok, image_id = pcall(backend.set, image_id or entry.data, opts)
                  end
                  if ok then
                    placements[key] = { id = image_id, buf = buf, mark = id, opts = opts }
                    visible[key] = true
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  for key in pairs(placements) do
    if not visible[key] then
      remove(key)
    end
  end
end

local function schedule_refresh()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.refresh()
  end)
end

function M.add(buf, row, path)
  if not M.available() then
    return
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > 20 * 1024 * 1024 then
    return
  end
  local ok, data = pcall(vim.fn.readblob, path)
  if not ok or #data < 24 or data:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return
  end
  local function uint32(offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local width, height = uint32(17), uint32(21)
  if width == 0 or height == 0 then
    return
  end
  if not attached then
    attached = true
    vim.api.nvim_create_autocmd({
      "WinScrolled", "WinResized", "VimResized", "BufWinEnter", "BufWinLeave",
      "TabEnter", "TabLeave", "WinClosed", "CursorMoved", "TextChanged", "ModeChanged",
    }, { callback = schedule_refresh })
    -- Fold commands need not move the cursor or scroll the window.
    vim.api.nvim_create_autocmd("SafeState", { callback = M.refresh })
    vim.api.nvim_create_autocmd("BufWipeout", {
      callback = function(ev)
        M.clear(ev.buf)
      end,
    })
  end
  local id = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { right_gravity = false })
  entries[buf] = entries[buf] or {}
  entries[buf][id] = { data = data, aspect = width / height }
  schedule_refresh()
end

function M.clear(buf, first, last)
  for id in pairs(entries[buf] or {}) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, {})
    if #mark == 0 or (mark[1] >= (first or 0) and (not last or last == -1 or mark[1] < last)) then
      for key, placement in pairs(placements) do
        if placement.buf == buf and placement.mark == id then
          remove(key)
        end
      end
      if #mark > 0 then
        vim.api.nvim_buf_del_extmark(buf, NS, id)
      end
      entries[buf][id] = nil
    end
  end
  if entries[buf] and not next(entries[buf]) then
    entries[buf] = nil
  end
end

return M

