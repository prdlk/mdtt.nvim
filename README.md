# mdtt.nvim

Markdown table editor for Neovim. It is a Lua port of [mdtt](https://github.com/szktkfm/mdtt), the Bubble Tea table editor, built on [snacks.nvim](https://github.com/folke/snacks.nvim) windows and the picker, with mdtt's vim-style keys.

- Opens the pipe table under the cursor in a float laid over it, drawn as a grid.
- Off a table, picks one of the buffer's tables (with a preview) or a new one below the cursor. A buffer with no tables goes straight to a new one.
- `q` writes the table back as one undo step, aligned the way mdtt prints it. `:q` / `<C-w>c` discards it.
- Tables are found with Neovim's bundled markdown tree-sitter parser: tables in fenced code are skipped, and tables in list items or blockquotes keep their indent / `>` prefix. Works in `markdown.mdx` buffers too.

## Requirements

- Neovim 0.11+ (bundled `markdown` tree-sitter parser)
- [snacks.nvim](https://github.com/folke/snacks.nvim)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "prdlk/mdtt.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = "Mdtt",
  keys = {
    { "<leader>mt", function() require("mdtt").edit() end, ft = { "markdown", "markdown.mdx" }, desc = "Edit table" },
  },
}
```

No `setup()` call is needed. The plugin defines `:Mdtt` and `require("mdtt").edit()`; map either to a key.

## Keys

| Key | Action |
| --- | --- |
| `k` `j` `h` `l` / arrows | Move; up from the first row selects the header |
| `b` / `<PageUp>`, `f` / `<PageDown>` | Page up / down |
| `<C-u>` / `<C-d>` | Half page up / down |
| `g` / `<Home>`, `G` / `<End>` | First row (again: header) / last row |
| `i` | Edit the cell in place; `<Esc>`, `<C-c>` or `<CR>` returns |
| `I` | Edit the cell in a larger markdown float; lines join with `<br>` |
| `o` / `vo` | Add a row / column after the cursor and start editing it |
| `dd` / `vd` | Delete the row / column (copied to the register) |
| `x` | Clear the cell |
| `yy` / `vy` / `y.` | Copy the row / column / cell |
| `p` | Paste after the cursor (a cell replaces the current one) |
| `?` | Toggle help |
| `q` | Write the table and close |

Mouse clicks and `/` searches select the cell they land on.

## Differences from mdtt

- Cells keep their markdown source. mdtt re-renders cells from goldmark's AST, which turns `*x*` into `_x_`, drops `~~` and image syntax, and unescapes `\|`. A `|` typed into a cell is escaped to `\|`.
- Columns are padded by display width; mdtt pads by byte length, which misaligns CJK text.
- Rows longer than the header get untitled columns instead of losing cells.
- `I` edits in a float instead of `$EDITOR`.
- `:q` discards changes; mdtt can only quit by writing.
- `G` from the header goes to the last row, `vd` works from the header, and deleting the last column is refused.

## Highlights

Linked by default, re-applied after `:colorscheme`:

| Group | Default | Used for |
| --- | --- | --- |
| `MdttHeader` | `Title` | Header row |
| `MdttBorder` | `FloatBorder` | Column separators and the delimiter row |
| `MdttCursor` | `Visual` | Selected cell |
| `MdttInsert` | `Visual` | Cell being edited |
| `MdttMode` | `PmenuSel` | Mode label in the footer |
