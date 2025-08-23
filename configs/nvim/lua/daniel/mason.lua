-- ~/.config/nvim/lua/daniel/mason.lua
require("mason").setup()

-- Load servers table from lspconfig.lua
local servers = require("daniel.lspconfig")

require("mason-lspconfig").setup({
    ensure_installed = vim.tbl_keys(servers),
})
