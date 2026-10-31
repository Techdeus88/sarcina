-- sarcina/main_module.lua
-- Finds the Lua module that a plugin's `opts` belong to.

local M = {}

local function normalize(name)
    local base =
        name:lower():gsub('%.lua$', ''):gsub('%.nvim$', ''):gsub('^nvim[%-_.]', ''):gsub('[%-_.]nvim$', '')
    return (base:gsub('[^%w]', ''))
end

local function list_modules(dir)
    local modules = {}
    for entry, kind in vim.fs.dir(dir .. '/lua') do
        if kind == 'directory' then
            table.insert(modules, entry)
        elseif kind == 'file' and entry:match('%.lua$') then
            table.insert(modules, (entry:gsub('%.lua$', '')))
        end
    end
    table.sort(modules)
    return modules
end

--- Match `names` (candidate plugin names, in priority order) against the modules in `<dir>/lua`.
--- A lone module wins by default. Returns the module name, or nil and a reason.
function M.find(dir, names)
    if not vim.uv.fs_stat(dir .. '/lua') then return nil, 'no lua/ directory in ' .. dir end
    local modules = list_modules(dir)
    for _, name in ipairs(names) do
        local wanted = normalize(name)
        for _, module in ipairs(modules) do
            if normalize(module) == wanted then return module end
        end
    end
    if #modules == 1 then return modules[1] end
    return nil, string.format('cannot tell which of [%s] gets opts, set `main`', table.concat(modules, ', '))
end

return M
