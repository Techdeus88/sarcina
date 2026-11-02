-- sarcina/paths.lua
-- Filesystem locations shared by the task factory and the executors.

local M = {}

-- Outside every 'packpath' entry, so Neovim never loads these on its own.
function M.plugins_dir() return vim.fn.stdpath('data') .. '/sarcina/plugins/' end

function M.install(name) return M.plugins_dir() .. name end

-- How long each plugin took to install, kept next to the plugins. See installs.lua.
function M.installs_file() return vim.fn.stdpath('data') .. '/sarcina/installs.json' end

function M.staging(name)
    return string.format('%s/sarcina_staging/%s_%d', vim.fn.stdpath('cache'), name, vim.uv.hrtime())
end

return M
