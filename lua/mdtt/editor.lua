--- The table editor window: a port of mdtt's TUI
--- (https://github.com/szktkfm/mdtt) onto snacks.win.
---
--- The table is drawn as a grid in a scratch float. The selected cell is
--- highlighted, and the real cursor sits on it, so mouse clicks and searches
--- select cells as well. mdtt's modes map onto the cursor row: row 0 is the
--- header (mdtt's HEADER mode), 1.. are body rows. Insert mode is real
--- insert mode: a one-line float laid over the cell (anchored with `bufpos`,
--- so it follows horizontal scrolling), whose text is written back into the
--- table on every change. `I` opens the cell in a larger float, one line per
--- `<br>`, in place of mdtt's $EDITOR hand-off.
---
--- `q` hands the table to `on_write`. Closing the window any other way
--- (`:q`, `<C-w>c`) discards it; mdtt has no way to do that.
--- @module mdtt.editor

local Snacks = require "snacks"

local M = {}

local width = vim.api.nvim_strwidth
local ns = vim.api.nvim_create_namespace "mdtt"
local SEP = "│"
local BR = "<[bB][rR]%s*/?>"

--- Default links, re-applied after `:colorscheme` (which clears them).
local function highlights()
  for name, link in pairs {
    MdttHeader = "Title",
    MdttBorder = "FloatBorder",
    MdttCursor = "Visual",
    MdttInsert = "Visual",
    MdttMode = "PmenuSel",
  } do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end
highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("mdtt_highlights", {}),
  callback = highlights,
})

--- mdtt's full help, two columns
local HELP = {
  {
    { "↑/k", "up" },
    { "↓/j", "down" },
    { "←/h", "left" },
    { "→/l", "right" },
    { "b/pgup", "page up" },
    { "f/pgdn", "page down" },
    { "ctrl+u", "½ page up" },
    { "ctrl+d", "½ page down" },
    { "g/home", "go to start" },
    { "G/end", "go to end" },
  },
  {
    { "i", "insert mode" },
    { "I", "edit cell in a float" },
    { "esc/ctrl+c/enter", "normal mode" },
    { "o/vo", "add row/column" },
    { "dd/vd", "delete row/column" },
    { "x", "clear cell" },
    { "yy/vy", "copy row/column" },
    { "y.", "copy cell" },
    { "p", "paste" },
    { "q", "write and close" },
    { "?", "toggle help" },
  },
}

--- @param s string
--- @param n integer display width
local function pad(s, n) return s .. (" "):rep(n - width(s)) end

--- @return string[]
local function help_lines()
  local cols, w1 = {}, 0
  for c, col in ipairs(HELP) do
    local kw = 0
    for _, entry in ipairs(col) do
      kw = math.max(kw, width(entry[1]))
    end
    cols[c] = vim.tbl_map(function(entry) return pad(entry[1], kw) .. "  " .. entry[2] end, col)
  end
  for _, s in ipairs(cols[1]) do
    w1 = math.max(w1, width(s))
  end
  local lines = {}
  for i = 1, math.max(#cols[1], #cols[2]) do
    lines[i] = " " .. pad(cols[1][i] or "", w1) .. "    " .. (cols[2][i] or "")
  end
  return lines
end

---@class mdtt.Editor
---@field t mdtt.Table
---@field x integer column, 1-based
---@field y integer 0 = header, 1.. = body rows
---@field mode "normal"|"insert"|"help"
---@field reg? {kind: "row"|"col"|"cell", cells?: string[], title?: string, align?: string, value?: string}
---@field win snacks.win
---@field input? snacks.win
---@field widths integer[] display width of each column's text
---@field spans table<integer, integer[][]> buffer line -> per-column {start, end} bytes, 0-based, end-exclusive
---@field saved boolean
---@field on_write fun(t: mdtt.Table)
local Editor = {}
Editor.__index = Editor

function Editor:get() return self.y == 0 and self.t.titles[self.x] or self.t.rows[self.y][self.x] end

--- @param value string
function Editor:set(value)
  if self.y == 0 then
    self.t.titles[self.x] = value
  else
    self.t.rows[self.y][self.x] = value
  end
end

--- Buffer line (1-based) of the cursor row.
function Editor:line() return self.y == 0 and 1 or self.y + 2 end

--- Body rows that fit in the window, mdtt's page size.
function Editor:page() return math.max(1, vim.api.nvim_win_get_height(self.win.win) - 2) end

-- Movement, after mdtt: moving up from the first row selects the header;
-- paging and `g` stop at the first row and take one more press to reach it.

--- @param n integer
function Editor:up(n) self.y = self.y <= 1 and 0 or math.max(self.y - n, 1) end

--- @param n integer
function Editor:down(n)
  local last = #self.t.rows
  self.y = self.y == 0 and math.min(1, last) or math.min(self.y + n, last)
end

--- @param n integer
function Editor:right(n) self.x = math.max(1, math.min(self.x + n, #self.t.titles)) end

--- Insert an empty row below the cursor (at the top from the header).
function Editor:add_row()
  local at = self.y + 1
  local row = {}
  for c = 1, #self.t.titles do
    row[c] = ""
  end
  table.insert(self.t.rows, at, row)
  self.y = at
  self:insert()
end

--- Insert a column right of the cursor, optionally filled from a register.
--- @param reg? {title: string, align: string, cells: string[]}
function Editor:add_col(reg)
  local at = self.x + 1
  table.insert(self.t.titles, at, reg and reg.title or "")
  table.insert(self.t.aligns, at, reg and reg.align or "")
  for r, row in ipairs(self.t.rows) do
    table.insert(row, at, reg and reg.cells[r] or "")
  end
  self.x = at
end

--- @return boolean copied false on the header, which is not a row
function Editor:copy_row()
  if self.y == 0 then return false end
  self.reg = { kind = "row", cells = vim.deepcopy(self.t.rows[self.y]) }
  return true
end

function Editor:copy_col()
  local x = self.x
  self.reg = {
    kind = "col",
    title = self.t.titles[x],
    align = self.t.aligns[x],
    cells = vim.tbl_map(function(row) return row[x] end, self.t.rows),
  }
end

function Editor:delete_row()
  if not self:copy_row() then return end
  table.remove(self.t.rows, self.y)
  self.y = math.min(self.y, #self.t.rows)
end

function Editor:delete_col()
  if #self.t.titles == 1 then
    vim.notify("A table needs at least one column", vim.log.levels.WARN)
    return
  end
  self:copy_col()
  table.remove(self.t.titles, self.x)
  table.remove(self.t.aligns, self.x)
  for _, row in ipairs(self.t.rows) do
    table.remove(row, self.x)
  end
  self.x = math.min(self.x, #self.t.titles)
end

function Editor:paste()
  local reg = self.reg
  if not reg then return end
  if reg.kind == "row" then
    table.insert(self.t.rows, self.y + 1, vim.deepcopy(reg.cells))
    self.y = self.y + 1
  elseif reg.kind == "col" then
    self:add_col(reg)
  else
    self:set(reg.value)
  end
end

--- Draw the grid (or the help), then sync window size, footer and cursor.
function Editor:render()
  local buf, win = self.win.buf, self.win.win
  if not (buf and win and vim.api.nvim_win_is_valid(win)) then return end
  local lines, marks = {}, {}
  self.spans = {}

  if self.mode == "help" then
    lines = help_lines()
  else
    local t = self.t
    self.widths = {}
    for c, title in ipairs(t.titles) do
      local w = math.max(width(title), 1)
      for _, row in ipairs(t.rows) do
        w = math.max(w, width(row[c]))
      end
      self.widths[c] = w
    end

    local function add(cells)
      local parts, spans, pos = {}, {}, 0
      for c, w in ipairs(self.widths) do
        if c > 1 then
          parts[#parts + 1] = SEP
          marks[#marks + 1] = { #lines, pos, pos + #SEP, "MdttBorder" }
          pos = pos + #SEP
        end
        local text = " " .. pad(cells[c], w) .. " "
        spans[c] = { pos, pos + #text }
        parts[#parts + 1] = text
        pos = pos + #text
      end
      lines[#lines + 1] = table.concat(parts)
      self.spans[#lines] = spans
    end

    add(t.titles)
    marks[#marks + 1] = { 0, 0, #lines[1], "MdttHeader" }
    local segs = {}
    for c, w in ipairs(self.widths) do
      local a = t.aligns[c]
      local l = (a == "left" or a == "center") and ":" or "─"
      local r = (a == "right" or a == "center") and ":" or "─"
      segs[c] = l .. ("─"):rep(w) .. r
    end
    lines[2] = table.concat(segs, "┼")
    marks[#marks + 1] = { 1, 0, #lines[2], "MdttBorder" }
    for _, row in ipairs(t.rows) do
      add(row)
    end
    local span = self.spans[self:line()][self.x]
    marks[#marks + 1] = { self:line() - 1, span[1], span[2], "MdttCursor" }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = 200 })
  end

  local label = ({ normal = "NORMAL", insert = "INSERT", help = "HELP" })[self.mode]
  if self.y == 0 and self.mode ~= "help" then label = self.mode == "insert" and "HEADER INSERT" or "HEADER" end
  local footer = { { " " .. label .. " ", "MdttMode" }, { " ? help  q write ", "FloatFooter" } }
  local w = width(footer[1][1] .. footer[2][1]) + 2
  for _, line in ipairs(lines) do
    w = math.max(w, width(line))
  end
  self.win.opts.width = math.min(w, vim.o.columns - 2)
  self.win.opts.height = math.min(#lines, vim.o.lines - 4)
  vim.api.nvim_win_set_config(win, {
    width = self.win.opts.width,
    height = self.win.opts.height,
    footer = footer,
    footer_pos = "center",
  })

  local want = self.mode == "help" and { 1, 0 } or { self:line(), self.spans[self:line()][self.x][1] + 1 }
  if not vim.deep_equal(vim.api.nvim_win_get_cursor(win), want) then vim.api.nvim_win_set_cursor(win, want) end
end

--- Select the cell under the cursor after a move that was not one of ours
--- (mouse, search, `w`), then snap the cursor back onto it.
function Editor:follow_cursor()
  if self.mode ~= "normal" then return end
  local pos = vim.api.nvim_win_get_cursor(self.win.win)
  local spans = self.spans[pos[1]]
  local y, x = self.y, self.x
  if spans then
    y, x = pos[1] == 1 and 0 or pos[1] - 2, #spans
    for c, span in ipairs(spans) do
      if pos[2] < span[2] then
        x = c
        break
      end
    end
  end
  local anchor = self.spans[self:line()][self.x][1] + 1
  if y == self.y and x == self.x and pos[1] == self:line() and pos[2] == anchor then return end
  self.y, self.x = y, x
  self:render()
end

--- Edit the selected cell in a one-line float laid over it.
function Editor:insert()
  if #self.t.titles == 0 then return end
  self.mode = "insert"
  self:render()
  local span = self.spans[self:line()][self.x]
  local function input_width() return math.max(self.widths[self.x], width(self:get()) + 1) end

  local input = Snacks.win {
    relative = "win",
    win = self.win.win,
    bufpos = { self:line() - 1, span[1] + 1 },
    row = 0,
    col = 0,
    width = input_width(),
    height = 1,
    border = "none",
    minimal = true,
    enter = true,
    keys = { q = false },
    bo = { buftype = "nofile" },
    b = { completion = false },
    wo = { winhighlight = "Normal:MdttInsert", wrap = false, sidescrolloff = 0 },
  }
  self.input = input
  vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { self:get() })
  vim.cmd.startinsert { bang = true }

  -- leaving through a mapping to <Esc> fires InsertLeave; <C-c> alone does not
  for _, lhs in ipairs { "<CR>", "<C-c>" } do
    vim.keymap.set("i", lhs, "<Esc>", { buffer = input.buf, desc = "Back to normal mode" })
  end
  input:on({ "TextChanged", "TextChangedI" }, function()
    self:set(table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), " "))
    self:render()
    if not input:valid() then return end
    vim.api.nvim_win_set_config(input.win, { width = input_width() })
    -- the keystroke that outgrew the old width scrolled the text left; it fits now
    vim.api.nvim_win_call(input.win, function() vim.fn.winrestview { leftcol = 0 } end)
  end, { buf = true })
  input:on({ "InsertLeave", "BufLeave" }, function()
    vim.schedule(function() self:leave_insert() end)
  end, { buf = true })
end

function Editor:leave_insert()
  if self.mode ~= "insert" then return end
  self.mode = "normal"
  local input = self.input
  self.input = nil
  if input then input:close() end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd.stopinsert() end
  if not self.win:valid() then return end
  vim.api.nvim_set_current_win(self.win.win)
  self:render()
end

--- mdtt's `I`: edit the selected cell in a larger markdown float. Lines are
--- joined with `<br>`, which also splits the cell into lines on the way in.
function Editor:edit_cell()
  local y, x = self.y, self.x
  local cell = Snacks.win {
    width = 0.6,
    height = 0.4,
    border = "rounded",
    title = (" %s, column %d (q applies) "):format(y == 0 and "Header" or "Row " .. y, x),
    title_pos = "center",
    ft = "markdown",
    enter = true,
    bo = { buftype = "nofile" },
    wo = { wrap = true, linebreak = true },
    on_close = function(win)
      local lines = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
      while #lines > 0 and vim.trim(lines[#lines]) == "" do
        table.remove(lines)
      end
      self.y, self.x = y, x
      self:set(table.concat(vim.tbl_map(vim.trim, lines), "<br>"))
      vim.schedule(function()
        if not self.win:valid() then return end
        vim.api.nvim_set_current_win(self.win.win)
        self:render()
      end)
    end,
  }
  vim.api.nvim_buf_set_lines(cell.buf, 0, -1, false, vim.split(self:get(), BR))
end

--- Buffer-local normal-mode keys. `nowait` on everything except the `v`/`d`/
--- `y` prefixes, so `g`/`f`/`<C-d>` do not wait out global `gg`/flash/
--- `<C-d><C-d>`.
--- @param buf integer
function Editor:map(buf)
  local function count() return vim.v.count1 end
  local function half() return math.max(1, math.floor(self:page() / 2)) end
  local keys = {
    { { "k", "<Up>" }, function() self:up(count()) end, "Up" },
    { { "j", "<Down>" }, function() self:down(count()) end, "Down" },
    { { "h", "<Left>" }, function() self:right(-count()) end, "Left" },
    { { "l", "<Right>" }, function() self:right(count()) end, "Right" },
    { { "b", "<PageUp>" }, function() self:up(self:page()) end, "Page up" },
    { { "f", "<PageDown>" }, function() self:down(self:page()) end, "Page down" },
    { { "<C-u>" }, function() self:up(half()) end, "Half page up" },
    { { "<C-d>" }, function() self:down(half()) end, "Half page down" },
    { { "g", "<Home>" }, function() self:up(math.huge) end, "Go to start" },
    { { "G", "<End>" }, function() self.y = #self.t.rows end, "Go to end" },
    { { "i" }, function() self:insert() end, "Insert mode" },
    { { "I" }, function() self:edit_cell() end, "Edit cell in a float" },
    { { "o" }, function() self:add_row() end, "Add row" },
    {
      { "vo" },
      function()
        self:add_col()
        self:insert()
      end,
      "Add column",
    },
    { { "dd" }, function() self:delete_row() end, "Delete row" },
    { { "vd" }, function() self:delete_col() end, "Delete column" },
    { { "x" }, function() self:set "" end, "Clear cell" },
    { { "yy" }, function() self:copy_row() end, "Copy row" },
    { { "vy" }, function() self:copy_col() end, "Copy column" },
    { { "y." }, function() self.reg = { kind = "cell", value = self:get() } end, "Copy cell" },
    { { "p" }, function() self:paste() end, "Paste" },
    -- bare prefixes: keep native visual mode and operators out of the grid
    { { "v", "d", "y" }, function() end, nil, prefix = true },
    { { "q" }, function() self:quit() end, "Write table and close", help = true },
    {
      { "?" },
      function() self.mode = self.mode == "help" and "normal" or "help" end,
      "Toggle help",
      help = true,
    },
  }
  for _, spec in ipairs(keys) do
    for _, lhs in ipairs(spec[1]) do
      vim.keymap.set("n", lhs, function()
        if self.mode == "help" and not spec.help then return end
        spec[2]()
        if self.mode ~= "insert" then self:render() end
      end, { buffer = buf, nowait = not spec.prefix, desc = spec[3] })
    end
  end
end

function Editor:quit()
  self.saved = true
  self.win:close()
end

--- Open the editor on `t`, which it edits in place.
--- @param t mdtt.Table
--- @param opts {title: string, on_write: fun(t: mdtt.Table), win?: snacks.win.Config}
--- @return mdtt.Editor
function M.open(t, opts)
  local self = setmetatable({
    t = t,
    x = 1,
    y = #t.rows > 0 and 1 or 0,
    mode = "normal",
    saved = false,
    widths = {},
    spans = {},
    on_write = opts.on_write,
  }, Editor)

  self.win = Snacks.win(vim.tbl_extend("force", {
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    width = 1,
    height = 1,
    enter = true,
    minimal = true,
    keys = { q = false },
    bo = { buftype = "nofile", modifiable = false, undolevels = -1 },
    b = { completion = false },
    wo = { wrap = false, scrolloff = 0, sidescrolloff = 0 },
    on_close = function()
      if self.input then self.input:close() end
      if self.saved then vim.schedule(function() self.on_write(self.t) end) end
    end,
  }, opts.win or {}))

  self:map(self.win.buf)
  self.win:on("CursorMoved", function() self:follow_cursor() end, { buf = true })
  self:render()
  return self
end

return M
