local function is_any_floating_window_open()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(winid).relative ~= "" then
            return true
        end
    end
    return false
end

local function show_line_diagnostics()
    if not is_any_floating_window_open() then
        vim.diagnostic.open_float(nil, {
            -- focusable = false,
            scope = "line",
            border = "rounded",
        })
    end
end

local diagnostic_group = vim.api.nvim_create_augroup('DiagnosticFloat', { clear = true })

vim.api.nvim_create_autocmd("CursorHold", {
    group = diagnostic_group,
    callback = show_line_diagnostics,
    desc = "Show line diagnostics in a floating window if no other floating windows are open",
})

vim.diagnostic.config({ virtual_text = true })
