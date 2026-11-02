-- sarcina/paths.lua
-- Filesystem locations shared by the task factory and the executors.

local M = {}

-- Outside every 'packpath' entry, so Neovim never loads these on its own.
function M.plugins_dir() return vim.fn.stdpath('data') .. '/sarcina/plugins/' end

local dirs = {} -- plugin name -> the directory of a plugin that lives outside the plugins directory

--- The directory of a plugin: where its spec's `dir` says, or its place in the plugins directory.
function M.install(name) return dirs[name] or (M.plugins_dir() .. name) end

--- A plugin that lives in `dir`, such as one you are working on. The resolver sets it from the spec's `dir`.
function M.set_dir(name, dir) dirs[name] = dir end

--- Forget every `dir`, before the resolver reads the specs again.
function M.reset_dirs() dirs = {} end

-- The commit of every installed plugin, kept with your config so it can be committed. See lock.lua.
function M.lock_file() return vim.fn.stdpath('config') .. '/sarcina-lock.json' end

-- How long each plugin took to install, kept next to the plugins. See installs.lua.
function M.installs_file() return vim.fn.stdpath('data') .. '/sarcina/installs.json' end

-- Inside the plugins directory, so the move to the final place is a rename on one filesystem. The leading
-- dot keeps `clean` from taking it for a plugin.
function M.staging(name) return string.format('%s.staging/%s_%d', M.plugins_dir(), name, vim.uv.hrtime()) end

return M
