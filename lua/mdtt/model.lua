--- Markdown pipe table <-> plain data.
---
--- A table is `{ titles = string[], aligns = Align[], rows = string[][] }`
--- with every row as long as `titles`. Cells keep their markdown source
--- (trimmed), so inline markup, HTML and `\|` escapes round-trip untouched.
---
--- `render` reproduces mdtt's printer: each column is padded to its widest
--- cell plus one space, and the delimiter row carries the alignment colons.
--- @module mdtt.model

local M = {}

---@alias mdtt.Align ""|"left"|"center"|"right"

---@class mdtt.Table
---@field titles string[]
---@field aligns mdtt.Align[]
---@field rows string[][]

local width = vim.api.nvim_strwidth

--- Cells of one table line, split on unescaped pipes; the optional leading
--- and trailing pipes do not open empty cells.
--- @param line string
--- @return string[]
function M.split(line)
  line = vim.trim(line)
  local cells, cur, i = {}, {}, 1
  if line:sub(1, 1) == "|" then i = 2 end
  while i <= #line do
    local c = line:sub(i, i)
    if c == "\\" then
      cur[#cur + 1] = line:sub(i, i + 1)
      i = i + 2
    else
      if c == "|" then
        cells[#cells + 1] = vim.trim(table.concat(cur))
        cur = {}
      else
        cur[#cur + 1] = c
      end
      i = i + 1
    end
  end
  -- text after the last pipe is a cell; nothing after it is the closing pipe
  local tail = vim.trim(table.concat(cur))
  if tail ~= "" or #cells == 0 or line:sub(-1) ~= "|" or line:sub(-2) == "\\|" then cells[#cells + 1] = tail end
  return cells
end

--- @param cell string delimiter row cell, e.g. `:--`
--- @return mdtt.Align?
local function align(cell)
  if not cell:find "^:?%-+:?$" then return nil end
  local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
  return left and right and "center" or left and "left" or right and "right" or ""
end

--- Parse table lines (header, delimiter, body), prefixes already removed.
--- Rows longer than the header grow untitled columns instead of losing cells.
--- @param lines string[]
--- @return mdtt.Table? table, string? err
function M.parse(lines)
  if #lines < 2 then return nil, "a table needs a header and a delimiter row" end
  local t = { titles = M.split(lines[1]), aligns = {}, rows = {} }
  for i, cell in ipairs(M.split(lines[2])) do
    local a = align(cell)
    if not a then return nil, ("line 2 is not a delimiter row (cell %d: %q)"):format(i, cell) end
    t.aligns[i] = a
  end
  local ncols = #t.titles
  for i = 3, #lines do
    local row = M.split(lines[i])
    ncols = math.max(ncols, #row)
    t.rows[#t.rows + 1] = row
  end
  for c = 1, ncols do
    t.titles[c] = t.titles[c] or ""
    t.aligns[c] = t.aligns[c] or ""
    for _, row in ipairs(t.rows) do
      row[c] = row[c] or ""
    end
  end
  -- delimiter cells beyond the header have no column
  for c = ncols + 1, #t.aligns do
    t.aligns[c] = nil
  end
  return t
end

--- mdtt's empty table: two untitled columns, one empty row.
--- @return mdtt.Table
function M.new() return { titles = { "", "" }, aligns = { "", "" }, rows = { { "", "" } } } end

--- A literal `|` typed into a cell would split it; escape every unescaped one.
--- @param s string
local function escape(s)
  return (s:gsub("\\?|", function(m) return #m == 2 and m or "\\|" end))
end

--- @param s string
--- @param n integer display width
local function pad(s, n) return s .. (" "):rep(n - width(s)) end

--- Render as aligned markdown lines, mdtt-style.
--- @param t mdtt.Table
--- @return string[]
function M.render(t)
  local titles = vim.tbl_map(escape, t.titles)
  local rows = vim.tbl_map(function(row) return vim.tbl_map(escape, row) end, t.rows)
  local widths = {}
  for c, title in ipairs(titles) do
    local w = width(title)
    for _, row in ipairs(rows) do
      w = math.max(w, width(row[c]))
    end
    widths[c] = w + 2
  end

  local function line(cells)
    local out = {}
    for c, w in ipairs(widths) do
      out[c] = "| " .. pad(cells[c], math.max(w - 1, 2))
    end
    return table.concat(out) .. "|"
  end

  local delim = {}
  for c, w in ipairs(widths) do
    local dashes = ("-"):rep(math.max(w - 2, 1))
    local a = t.aligns[c]
    delim[c] = (a == "left" or a == "center") and "|:" or "| "
    delim[c] = delim[c] .. dashes .. ((a == "right" or a == "center") and ":" or " ")
  end

  local out = { line(titles), table.concat(delim) .. "|" }
  for _, row in ipairs(rows) do
    out[#out + 1] = line(row)
  end
  return out
end

return M
