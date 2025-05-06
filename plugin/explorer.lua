-- Remove Netrw
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

pcall(vim.api.nvim_del_augroup_by_name, 'FileExplorer')
pcall(vim.api.nvim_del_augroup_by_name, 'Network')
