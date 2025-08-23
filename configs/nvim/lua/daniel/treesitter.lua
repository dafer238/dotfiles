---@diagnostic disable: missing-fields, undefined-global
require('nvim-treesitter.configs').setup {
    -- A list of parser names, or "all" (the listed parsers MUST always be installed)
    ensure_installed = {
        "bash",
        "c",
        "diff",
        "html",
        "lua",
        "luadoc",
        "vim",
        "vimdoc",
        "query",
        "markdown",
        "markdown_inline",
        "python",
        "rust",
        "javascript",
        "typescript",
        "json",
        "zig",
        "regex",
        "gitignore",
        "toml",
        -- "latex"
    },


    -- Install parsers synchronously (only applied to `ensure_installed`)
    sync_install = false,

    -- Automatically install missing parsers when entering buffer
    auto_install = true,

    highlight = {
        enable = true,

        additional_vim_regex_highlighting = true,
    },
}
