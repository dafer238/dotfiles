-- Check the operating system
if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
	-- If on Windows, set the DiffCommand to FC
	vim.g.undotree_DiffCommand = "FC"
else
	-- If not Windows, don't set the DiffCommand
	-- This block is intentionally left blank
end

-- Toggle undo tree
vim.keymap.set('n', '<leader>u', vim.cmd.UndotreeToggle, { desc = "Toggle undo tree" })

