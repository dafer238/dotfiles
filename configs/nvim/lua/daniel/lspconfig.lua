-- ~/.config/nvim/lua/daniel/lspconfig.lua
local capabilities = require('blink.cmp').get_lsp_capabilities()
local lspconfig = require('lspconfig')

-- Define servers and their configurations
local servers = {
    lua_ls = {},   -- Lua Language Server
    pyright = {},  -- Python Language Server
    ruff = {},     -- Ruff Linter (LSP mode)
    -- rust_analyzer = {}, -- Rust Language Server
    marksman = {}, -- Markdown Language Server
    clangd = {},   -- C Language Server
    -- zls = {},           -- Zig Language Server
    -- cssls = {},         -- CSS Language Server
    -- ts_ls = {},         -- Typescript Language Server
    -- ltex = {            -- LaTeX Language Sever
    --     language = "auto",
    --     settings = {
    --         ltex = {
    --             checkFrequency = "save" }
    --     },
    --     additionalRules = {
    --         enablePickyRules = true,
    --         motherTongue = "es-ES",
    --     },
    -- },
    -- texlab = {},
}

-- Setup each server with capabilities
for server, config in pairs(servers) do
    config.capabilities = vim.tbl_deep_extend("force", config.capabilities or {}, capabilities)
    lspconfig[server].setup(config)
end

vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
    callback = function(event)
        -- Helper function to set mappings
        local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end

        -- Jump to the definition of the word under your cursor.
        map('gd', vim.lsp.buf.definition, '[G]oto [D]efinition')

        -- Find references for the word under your cursor.
        map('gr', vim.lsp.buf.references, '[G]oto [R]eferences')

        -- Jump to the implementation of the word under your cursor.
        map('gI', vim.lsp.buf.implementation, '[G]oto [I]mplementation')

        -- Go to declaration.
        map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

        -- Jump to the type of the word under your cursor.
        map('<leader>D', vim.lsp.buf.type_definition, 'Type [D]efinition')

        -- List all symbols in the current document.
        map('<leader>ds', vim.lsp.buf.document_symbol, '[D]ocument [S]ymbols')

        -- List all symbols in the current workspace.
        map('<leader>ws', vim.lsp.buf.workspace_symbol, '[W]orkspace [S]ymbols')

        -- Rename the variable under your cursor.
        map('<F2>', vim.lsp.buf.rename, 'Rename variable')

        -- Execute a code action.
        map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' })

        -- Highlight references of the word under your cursor.
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client:supports_method(vim.lsp.protocol.Methods.textDocument_documentHighlight) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
                buffer = event.buf,
                group = highlight_augroup,
                callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
                buffer = event.buf,
                group = highlight_augroup,
                callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
                group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
                callback = function(event2)
                    vim.lsp.buf.clear_references()
                    vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
                end,
            })
        end
    end,
})

return servers
