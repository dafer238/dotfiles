---@diagnostic disable: missing-fields
local dap = require("dap")
local dapui = require("dapui")

dapui.setup({
    layouts = {
        {
            -- Layout for Console/Terminal
            elements = {
                { id = "scopes", size = 0.5 }, -- Full height for console
                { id = "repl",   size = 0.3 }, -- Show REPL with half of the layout
            },
            size = 12,                         -- Height of this layout (for horizontal)
            position = "bottom",               -- Position of this layout
        },

        {
            -- Layout for Scopes and REPL
            elements = {
                { id = "console", size = 1 }, -- Show Scopes with half of the layout
            },
            size = 30,                        -- Width of this layout (for vertical)
            position = "left",                -- Position of this layout
        },
    },
    floating = {
        max_height = nil,
        max_width = nil,
        border = "rounded",           -- Rounded borders for floating windows
        mappings = {
            close = { "q", "<Esc>" }, -- Close the floating window with these keys
        },
    },
    windows = { indent = 1 },  -- Adjust indentation in windows
    render = {
        max_type_length = nil, -- Don't truncate variable types
    },
})

-- Open/Close UI hooks
dap.listeners.after.event_initialized["dapui_config"] = function()
    dapui.open()
end
dap.listeners.before.event_terminated["dapui_config"] = function()
    dapui.close()
end
dap.listeners.before.event_exited["dapui_config"] = function()
    dapui.close()
end

-- Define the sign for breakpoints
vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint", linehl = "", numhl = "" })
vim.fn.sign_define("DapBreakpointRejected", { text = "×", texthl = "DapBreakpointRejected", linehl = "", numhl = "" })
vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DapStopped", linehl = "DapStoppedLine", numhl = "" })

-- Keymaps for DAP
vim.keymap.set({ "n", "v", "x" }, '<leader>db', function()
    require('dap').continue()
end, { desc = "Start debugging session" })

vim.keymap.set({ "n", "v", "x" }, '<F9>', function()
    require('dap').toggle_breakpoint()
end, { desc = "Toggle breakpoint" })

vim.keymap.set({ "n", "v", "x" }, '<F8>', function()
    require('dapui').toggle()
end, { desc = "Toggle debugging UI" })

vim.keymap.set({ "n", "v", "x" }, '<F10>', function()
    require('dap').continue()
end, { desc = "Continue" })

-- Bug since F11 is shared to toggle full screen
-- vim.keymap.set({ "n", "v", "x" }, '<F11>', function()
--     require('dap').step_into()
-- end, { desc = "Step into" })
--
-- vim.keymap.set({ "n", "v", "x" }, '<S-F11>', function()
--     require('dap').step_out()
-- end, { desc = "Step out" })

vim.keymap.set({ "n", "v", "x" }, '<F12>', function()
    require('dap').terminate()
end, { desc = "Stop debugging session" })


vim.api.nvim_set_hl(0, "DapBreakpoint", { fg = "#FF0000", bold = true })         -- Red dot
vim.api.nvim_set_hl(0, "DapBreakpointRejected", { fg = "#FFA500", bold = true }) -- Orange for rejected breakpoints
vim.api.nvim_set_hl(0, "DapStopped", { fg = "#00FF00", bold = true })            -- Green for current line
vim.api.nvim_set_hl(0, "DapStoppedLine", { bg = "#003300" })                     -- Background for stopped line
