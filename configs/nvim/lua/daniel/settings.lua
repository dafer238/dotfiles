---@diagnostic disable: undefined-global
-- ~/.config/nvim/lua/daniel/settings.lua

vim.g.have_nerd_font = true

vim.opt.cursorline = true
vim.opt.cursorlineopt = 'number'

vim.opt.nu = true
vim.opt.relativenumber = false
vim.opt.signcolumn = 'yes'

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

vim.opt.smartindent = true

vim.opt.swapfile = false
vim.opt.backup = false
if vim.fn.has("win32") == 1 then
    vim.opt.undodir = vim.fn.expand("$USERPROFILE") .. "\\vimfiles\\undodir"
else
    vim.opt.undodir = vim.fn.expand("$HOME") .. "/.vim/undodir"
end
vim.opt.undofile = true -- Ensure undofile is enabled

vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.inccommand = "split"

vim.opt.termguicolors = true

vim.opt.scrolloff = 7

vim.opt.updatetime = 50
vim.opt.timeoutlen = 300
vim.opt.ttimeoutlen = 10

vim.opt.colorcolumn = "100"
vim.opt.wrap = false
vim.keymap.set("n", "<leader>ww", function()
    vim.opt.wrap = not vim.opt.wrap:get()
end, { desc = "Toggle line wrapping" })


vim.o.foldenable = true
vim.o.foldlevel = 99
vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.opt.foldcolumn = "0"
vim.opt.fillchars:append({ fold = " " })
vim.o.foldtext = 'v:lua.custom_foldtext()'
vim.o.fillchars = "fold: ,foldopen: ,foldsep: ,foldclose:>"

function _G.custom_foldtext()
    -- Get the first line of the fold
    local first_line = vim.fn.getline(vim.v.foldstart)
    -- Calculate the number of folded lines
    local fold_count = vim.v.foldend - vim.v.foldstart + 1
    return first_line .. " (" .. fold_count .. " lines hidden)"
end

-- Prefer LSP folding if client supports it
vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client:supports_method('textDocument/foldingRange') then
            local win = vim.api.nvim_get_current_win()
            vim.wo[win][0].foldexpr = 'v:lua.vim.lsp.foldexpr()'
        end
    end
})

vim.opt.spelllang = "en_us"

-- Enable spell checking for common text-based filetypes
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "markdown", "text", "gitcommit", "tex" },
    callback = function()
        vim.opt.spell = true
    end,
})

-- Highlight when yanking (copying) text
vim.api.nvim_create_autocmd('TextYankPost', {
    desc = 'Highlight when yanking (copying) text',
    group = vim.api.nvim_create_augroup('highlight-yank', { clear = true }),
    callback = function()
        vim.highlight.on_yank()
    end,
})

-- Auto-save when leaving insert mode, only if it's a valid file type
vim.api.nvim_create_autocmd("InsertLeave", {
    callback = function()
        -- Ensure buffer is modified, is a normal file, and has a filetype
        if vim.bo.modified and vim.bo.buftype == "" and vim.fn.expand("%:p") ~= "" and vim.bo.modifiable and not vim.bo.readonly then
            local ft = vim.bo.filetype
            local allowed_filetypes = { "python", "rust", "markdown", "go", "c", "cpp", "vim", "lua" } -- Customize as needed

            if vim.tbl_contains(allowed_filetypes, ft) then
                vim.cmd("silent write") -- Auto-save
            end
        end
    end,
})

-- Auto-save on InsertLeave if the filetype can be saved
vim.api.nvim_create_autocmd("InsertLeave", {
    pattern = "*", -- You can adjust this to specific filetypes, e.g., {"python", "lua"}
    callback = function()
        local ft = vim.bo.filetype
        -- Add your list of valid filetypes here (adjust as needed)
        local valid_filetypes = { "python", "lua", "go", "cpp", "rust", "json", "c" }
        if vim.fn.index(valid_filetypes, ft) ~= -1 and vim.fn.bufname() ~= "" then
            vim.cmd("silent write")
        end
    end,
})

-- Autoformat on manual save if LSP is attached and can format
vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*", -- You can adjust this to specific filetypes if needed
    callback = function()
        -- Check if an LSP server is attached and can format
        local clients = vim.lsp.get_clients()
        if next(clients) then
            for _, client in pairs(clients) do
                if client.server_capabilities.documentFormattingProvider then
                    -- Trigger LSP formatting before saving
                    vim.lsp.buf.format({ async = false })
                    break
                end
            end
        end
    end,
})
