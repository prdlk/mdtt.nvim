--- mdtt.nvim: a native port of mdtt (https://github.com/szktkfm/mdtt).
--- `edit()` opens the pipe table under the cursor in a float laid over it
--- (mdtt.editor); off a table, it picks one of the buffer's tables or a new
--- one, mdtt's multi-table selection.
---
--- Tables are located with the markdown tree-sitter parser bundled with
--- Neovim, so tables in fenced code are skipped and tables in list items or
--- blockquotes work: the text before the table's column on its first line,
--- and on its delimiter line for the rest, is kept as each line's prefix.
--- `q` in the editor writes the table back as one undo step.
--- @module mdtt

local Model = require "mdtt.model"
local Editor = require "mdtt.editor"

local M = {}

---@class mdtt.Range
---@field first integer 0-based first line
---@field last integer 0-based, end-exclusive
---@field col integer byte column the table starts at

local query ---@type vim.treesitter.Query?

--- Every pipe table in `buf`, in buffer order.
--- @param buf integer
--- @return mdtt.Range[]
local function locate(buf)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local tree = parser:parse()[1]
  query = query or vim.treesitter.query.parse("markdown", "(pipe_table) @table")
  local out = {}
  for _, node in query:iter_captures(tree:root(), buf) do
    local sr, sc, er, ec = node:range()
    out[#out + 1] = { first = sr, last = ec == 0 and er or er + 1, col = sc }
  end
  return out
end

--- Replace lines `first`..`last` (0-based, end-exclusive) with `lines` and put
--- the cursor on line `first + offset`, unless the buffer changed meanwhile.
--- @param buf integer
--- @param win integer
--- @param tick integer changedtick when the editor opened
--- @param first integer
--- @param last integer
--- @param lines string[]
--- @param cursor integer[] (1,0)-indexed cursor after the write
local function apply(buf, win, tick, first, last, lines, cursor)
  if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then
    vim.fn.setreg('"', lines, "l")
    vim.notify("Buffer changed while the table was open; the table is in the unnamed register", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(buf, first, last, true, lines)
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    vim.api.nvim_win_set_cursor(win, cursor)
  end
end

--- @param lines string[]
--- @param first string prefix of the first line
--- @param rest string prefix of every other line
local function prefixed(lines, first, rest)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = (i == 1 and first or rest) .. line
  end
  return out
end

--- @param buf integer
--- @param win integer
--- @param range mdtt.Range
local function edit_table(buf, win, range)
  local lines = vim.api.nvim_buf_get_lines(buf, range.first, range.last, true)
  local first, rest = lines[1]:sub(1, range.col), (lines[2] or ""):sub(1, range.col)
  local content = vim.tbl_map(function(line) return line:sub(range.col + 1) end, lines)
  local t, err = Model.parse(content)
  if not t then
    vim.notify("Not a table: " .. err, vim.log.levels.WARN)
    return
  end

  -- the editor opens over the table: its text sits where the table's does
  vim.api.nvim_win_set_cursor(win, { range.first + 1, range.col })
  local tick = vim.b[buf].changedtick
  Editor.open(t, {
    title = ("Table, line %d"):format(range.first + 1),
    win = { relative = "cursor", row = -1, col = -1 },
    on_write = function(result)
      local out = Model.render(result)
      if vim.deep_equal(out, content) then return end
      apply(buf, win, tick, range.first, range.last, prefixed(out, first, rest), { range.first + 1, range.col })
    end,
  })
end

--- Start mdtt's empty table, inserted below the cursor line on `q` with the
--- line's indentation and blank lines around it so it parses as its own block.
--- @param buf integer
--- @param win integer
local function new_table(buf, win)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
  local indent = line:match "^%s*"
  vim.api.nvim_win_set_cursor(win, { row + 1, #indent })
  local tick = vim.b[buf].changedtick
  Editor.open(Model.new(), {
    title = "New table",
    win = { relative = "cursor", row = 1, col = -1 },
    on_write = function(t)
      local out = prefixed(Model.render(t), indent, indent)
      local below = vim.api.nvim_buf_get_lines(buf, row + 1, row + 2, false)[1]
      local gap = line:find "%S" and 1 or 0
      if gap == 1 then table.insert(out, 1, "") end
      if below and below:find "%S" then table.insert(out, "") end
      apply(buf, win, tick, row + 1, row + 1, out, { row + 2 + gap, #indent })
    end,
  })
end

--- Pick one of `ranges`, or a new table below the cursor.
--- @param buf integer
--- @param win integer
--- @param ranges mdtt.Range[]
local function pick(buf, win, ranges)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local items = { { text = "New table", label = "below line " .. row, buf = buf, pos = { row, 0 } } }
  for _, range in ipairs(ranges) do
    local header = vim.api.nvim_buf_get_lines(buf, range.first, range.first + 1, true)[1]
    items[#items + 1] = {
      text = vim.trim(header:sub(range.col + 1)),
      label = "line " .. (range.first + 1),
      buf = buf,
      pos = { range.first + 1, range.col },
      end_pos = { range.last, 0 },
      range = range,
    }
  end
  require("snacks").picker.pick {
    title = "Select a table",
    items = items,
    preview = "file",
    format = function(item) return { { item.text }, { "  " .. item.label, "SnacksPickerComment" } } end,
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      vim.schedule(function()
        if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then return end
        vim.api.nvim_set_current_win(win)
        if item.range then
          edit_table(buf, win, item.range)
        else
          new_table(buf, win)
        end
      end)
    end,
  }
end

--- Edit the table under the cursor; elsewhere pick a table or a new one.
function M.edit()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not vim.bo[buf].modifiable then
    vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local ranges = locate(buf)
  for _, range in ipairs(ranges) do
    if row >= range.first and row < range.last then return edit_table(buf, win, range) end
  end
  if #ranges == 0 then return new_table(buf, win) end
  pick(buf, win, ranges)
end

return M
