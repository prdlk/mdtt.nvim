if vim.g.loaded_mdtt then return end
vim.g.loaded_mdtt = true

vim.api.nvim_create_user_command(
  "Mdtt",
  function() require("mdtt").edit() end,
  { desc = "Edit the markdown table under the cursor, or pick / create one" }
)
