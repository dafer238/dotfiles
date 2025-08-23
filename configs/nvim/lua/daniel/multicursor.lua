-- multicursor.lua
local M = {}

M.setup = function()
    local mc = require("multicursor-nvim")

    mc.setup()

    local set = vim.keymap.set

    -- Add or skip cursor above/below the main cursor.
    set({ "n", "x" }, "<up>", function() mc.lineAddCursor(-1) end)
    set({ "n", "x" }, "<down>", function() mc.lineAddCursor(1) end)
    set({ "n", "x" }, "<C-up>", function() mc.lineSkipCursor(-1) end)
    set({ "n", "x" }, "<C-down>", function() mc.lineSkipCursor(1) end)

    -- Add or skip adding a new cursor by matching word/selection
    set({ "n", "x" }, "<leader>n", function() mc.matchAddCursor(1) end)
    set({ "n", "x" }, "<leader>N", function() mc.matchAddCursor(-1) end)

    -- Add all matches in the document
    set({ "n", "x" }, "<leader>A", mc.matchAllAddCursors)

    -- Rotate the main cursor.
    set({ "n", "x" }, "<left>", mc.nextCursor)
    set({ "n", "x" }, "<right>", mc.prevCursor)

    -- Delete the main cursor.
    set({ "n", "x" }, "<leader>x", mc.deleteCursor, { desc = 'Delete current cursor' })

    -- Add and remove cursors with control + left click.
    set("n", "<c-leftmouse>", mc.handleMouse)
    set("n", "<c-leftdrag>", mc.handleMouseDrag)

    -- Restore cursors if accidentally cleared
    set("n", "<leader>mc", mc.restoreCursors, { desc = 'Restore cursors' })

    -- Align cursor columns.
    set("n", "<leader>a", mc.alignCursors, { desc = 'Aling selected cursors' })

    -- Append/insert for each line of visual selections.
    set("x", "I", mc.insertVisual)
    set("x", "A", mc.appendVisual)

    -- Customize how cursors look.
    local hl = vim.api.nvim_set_hl
    hl(0, "MultiCursorCursor", { link = "Cursor" })
    hl(0, "MultiCursorVisual", { link = "Visual" })
    hl(0, "MultiCursorSign", { link = "SignColumn" })
    hl(0, "MultiCursorMatchPreview", { link = "Search" })
    hl(0, "MultiCursorDisabledCursor", { link = "Visual" })
    hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
    hl(0, "MultiCursorDisabledSign", { link = "SignColumn" })
end

return M
