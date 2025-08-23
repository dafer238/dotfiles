---@diagnostic disable: missing-fields, undefined-global
-- ~/.config/nvim/lua/daniel/plugins.lua

require("lazy").setup({
    -- **Plugin Manager**
    { "folke/lazy.nvim" },
    -- **LSP and Tooling Management**
    {
        'neovim/nvim-lspconfig',
        dependencies = { 'saghen/blink.cmp',
            "mason-org/mason.nvim",
            "mason-org/mason-lspconfig.nvim",
        },
        config = function() require("daniel.mason") end,
    },
    {
        'saghen/blink.cmp',
        version = '*',

        -- Load the configuration from the external file
        opts = require("daniel.blink_cmp"),
    },
    -- Debugger Adapter Protocols
    { 'mfussenegger/nvim-dap' },
    { "rcarriga/nvim-dap-ui", dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" } },

    -- **Git integration**
    {
        "kdheepak/lazygit.nvim",
        lazy = true,
        cmd = {
            "LazyGit",
            "LazyGitConfig",
            "LazyGitCurrentFile",
            "LazyGitFilter",
            "LazyGitFilterCurrentFile",
        },
        -- optional for floating window border decoration
        dependencies = {
            "nvim-lua/plenary.nvim",
        },
        keys = {
            { "<leader>gg", "<cmd>LazyGit<cr>", desc = "Open Lazygit" }
        }
    },
    {
        "lewis6991/gitsigns.nvim",
        config = function() require("gitsigns").setup() end,
    },
    -- **Treesitter**
    {
        "nvim-treesitter/nvim-treesitter",
        build = ":TSUpdate",
        config = function() require("daniel.treesitter") end,
    },
    -- **UI Enhancements**
    {
        "windwp/nvim-autopairs",
        config = true,
        opts = {
            map_bs = false,
        },
    },
    {
        "lukas-reineke/indent-blankline.nvim",
        config = function()
            require("ibl").setup({
                indent = {
                    char = "▏", -- Use a thin line character
                },
                scope = { enabled = false }
            })
        end
    },
    {
        "akinsho/toggleterm.nvim",
        config = function() require("toggleterm").setup() end,
    },
    {
        'petertriho/nvim-scrollbar',
        config = function()
            require("scrollbar").setup({
                handle = {
                    blend = 20,
                    color = "#504945",
                },
                handlers = { gitsigns = true }
            })
        end
    },
    {
        "folke/noice.nvim",
        event = "VeryLazy",
        dependencies = {
            "MunifTanjim/nui.nvim",
            {
                "rcarriga/nvim-notify",
                opts = {
                    top_down = false,
                },
            },
            "stevearc/dressing.nvim",
        },
        config = function() require("daniel.noice") end,
    },
    {
        "jake-stewart/multicursor.nvim",
        branch = '1.0',
        config = function() require("daniel.multicursor").setup() end,
    },
    {
        "ibhagwan/fzf-lua",
        -- optional for icon support
        dependencies = { "nvim-tree/nvim-web-devicons" },
        config = function() require("daniel.fzf_lua") end,
    },
    {
        "kyazdani42/nvim-tree.lua",
        dependencies = { "kyazdani42/nvim-web-devicons" },
        config = function() require("daniel.tree") end,
    },
    {
        "folke/which-key.nvim",
        config = function() require("which-key").setup({ preset = 'modern' }) end,
    },
    {
        "nvim-lualine/lualine.nvim",
        dependencies = { "kyazdani42/nvim-web-devicons" },
        config = function() require("daniel.statusbar") end,
    },
    -- **Undo Tree**
    {
        "mbbill/undotree",
        config = function() require("daniel.undotree") end,
    },

    -- **Commenting**
    {
        "folke/todo-comments.nvim",
        dependencies = { "nvim-lua/plenary.nvim" },
        opts = {}
    },
    -- **Themes**
    {
        -- "catppuccin/nvim",
        -- "rebelot/kanagawa.nvim",
        "sainnhe/gruvbox-material",
        lazy = false,
        priority = 1000,
        config = function()
            require('daniel.theme').setup()
        end,
    },
})
