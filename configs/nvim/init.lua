---@diagnostic disable: undefined-global
-- Determine the proper path based on OS
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if vim.fn.has('win32') == 1 then
    -- Windows path (using backslashes)
    lazypath = vim.fn.stdpath("data") .. "\\lazy\\lazy.nvim"
end

if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
end

vim.opt.rtp:prepend(lazypath)

vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

vim.g.mapleader = " "


-- Load the plugins configuration
require("daniel.plugins")
require("daniel.settings")

-- Load other configurations
require('daniel.diagnostics')
require('daniel.lspconfig')
require('daniel.run')
require('daniel.debug')
require("daniel.mappings")
