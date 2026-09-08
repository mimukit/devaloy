-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- General improvements
vim.keymap.set("n", ";", ":", { desc = "CMD enter command mode" })

vim.keymap.set("n", "n", "nzzzv", { desc = "Go to next search item and keep cursor in center of the screen" })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Go to previous search item and keep cursor in center of the screen" })

-- The Navigator.nvim maps from the laptop config are dropped here on purpose:
-- the plugin is not in this spec, so <CMD>NavigatorLeft<CR> would print E492 on
-- every press. LazyVim's own <C-h/j/k/l> window maps cover split-to-split
-- movement; what is lost is the hop out to a tmux pane and the terminal mode.

-- Clipboard management
vim.keymap.set("n", "<leader>yb", "<cmd>%y+<CR>", { desc = "Copy whole file" })
vim.keymap.set("v", "<leader>y", '"+y', { desc = "Copy selection to system clipboard" })
vim.keymap.set("n", "<leader>yy", '"+yy', { desc = "Copy line to system clipboard" })
vim.keymap.set({ "n", "v" }, "<leader>p", '"+p', { desc = "Paste from system clipboard" })
