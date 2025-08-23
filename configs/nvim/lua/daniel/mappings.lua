---@diagnostic disable: undefined-global
-- ~/.config/nvim/lua/daniel/mappings.lua

-- Map ';' to ':' and other command line tools
vim.keymap.set({ "n", "v", "x" }, ";", ":")

-- Quick navigating
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Navigate down and stay centered" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Navigate up and stay centered" })

-- Move lines in visual mode
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { silent = true, noremap = true, desc = "Move down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { silent = true, noremap = true, desc = "Move down" })

-- Keep centered when next and previous
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- Insert white line without leaving normal mode
vim.keymap.set({ "n", "v", "x" }, "<leader>o", "o<Esc>k", { desc = "Insert white line below" })
vim.keymap.set({ "n", "v", "x" }, "<leader>O", "O<Esc>j", { desc = "Insert white line above" })

-- Remap 'jk' to 'Esc' in insert mode
vim.keymap.set("i", "jk", "<Esc>", { silent = true })

vim.keymap.set("v", ">", ">gv", { noremap = true, silent = true })
vim.keymap.set("v", "<", "<gv", { noremap = true, silent = true })

-- Navigate buffers
vim.keymap.set("n", "<M-j>", ":bprevious<CR>",
    { silent = true, noremap = true, desc = "Previous buffer" })
vim.keymap.set("n", "<M-k>", ":bnext<CR>",
    { silent = true, noremap = true, desc = "Next buffer" })

-- Close buffer
vim.keymap.set({ "n", "v", "x" }, "<leader>bd", ":bd<CR>",
    { silent = true, noremap = true, desc = "Close current buffer" })

-- Esc + clear highlight
vim.keymap.set({ "n", "v", "x" }, '<Esc>', function()
    if require("multicursor-nvim").hasCursors() then
        require("multicursor-nvim").clearCursors()
    end

    -- Simulate pressing <Esc>
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)

    -- Clear search highlights
    vim.cmd("noh")

    -- Close floating windows (LSP popups, Noice, etc.)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
            local cfg = vim.api.nvim_win_get_config(win)
            if cfg.relative ~= '' then
                vim.api.nvim_win_close(win, true)
            end
        end
    end
end, { silent = true })

-- Avoid Q
vim.keymap.set("n", "Q", "<nop>")

-- Substitute current cursor position word
vim.keymap.set("n", "<leader>*", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]],
    { desc = "Substitute in active buffer" })

-- Format Buffer
vim.keymap.set({ "n", "v", "x" }, '<leader>fm', function()
    vim.lsp.buf.format({ async = true })
end, { desc = "Format Buffer" })

vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Copy Content
vim.keymap.set({ "n", "v", "x" }, "<C-c>", '"+y', { desc = "Copy Content" })

-- Paste in visual mode without copying the replaced text
vim.keymap.set("x", "p", '"_dp', { desc = "Paste without overwriting register in visual mode" })

-- Paste in visual line mode without overwriting
vim.keymap.set("x", "P", '"_dP', { desc = "Paste before without overwriting register" })

-- Window navigation
vim.keymap.set('n', '<C-h>', '<C-w>h', { noremap = true, silent = true, desc = "Move to left window" })
vim.keymap.set('n', '<C-l>', '<C-w>l', { noremap = true, silent = true, desc = "Move to right window" })
vim.keymap.set('n', '<C-j>', '<C-w>j', { noremap = true, silent = true, desc = "Move to lower window" })
vim.keymap.set('n', '<C-k>', '<C-w>k', { noremap = true, silent = true, desc = "Move to upper window" })

-- Sizing of vertical and horizontal splits
vim.keymap.set("n", "<C-w><right>", "5<C-w>>", { desc = "Increase vertical split width by 5" })
vim.keymap.set("n", "<C-w><left>", "5<C-w><", { desc = "Decrease vertical split width by 5" })

vim.keymap.set("n", "<C-w><up>", "5<C-w>+", { desc = "Increase horizontal split height by 5" })
vim.keymap.set("n", "<C-w><down>", "5<C-w>-", { desc = "Decrease horizontal split height by 5" })
