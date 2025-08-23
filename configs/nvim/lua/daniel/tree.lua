-- ~/.config/nvim/lua/daniel/tree.lua
require("nvim-tree").setup({
    sync_root_with_cwd = true,
    reload_on_bufenter = true,
    view = {
        width = 30,
        side = "left",
    },
    filters = {
        dotfiles = false,
        git_ignored = false
    },
    renderer = {
        highlight_git = true,
        icons = {
            show = {
                file = true,
                folder = true,
                folder_arrow = true,
                git = true
            },
        },
        indent_markers = {
            enable = true,
        },
    },
    actions = {
        open_file = {
            quit_on_open = true,
        }
    }
})

-- Keymap to toggle the tree view
vim.keymap.set("n", "<leader>t", function()
    -- Toggle the Nvim-Tree
    vim.cmd("NvimTreeToggle")
end, {
    desc = "Toggle file tree",
    silent = true,
    noremap = true
})
