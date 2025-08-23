require("lualine").setup({
    options = {
        theme = "auto", -- Choose a theme that fits your style
        icons_enabled = true,
    },
    sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "lsp_progress" }, -- Add LSP progress
        lualine_c = { "diagnostics", { "filename", path = 0 } },
        lualine_x = { "encoding", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" }
    }
})
