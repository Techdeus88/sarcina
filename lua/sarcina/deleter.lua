-- sarcina/deleter.lua
-- `delete`: deletes the directories of the plugins you name, one or several in one go. A plugin that is still
-- in your specs comes back at the next startup, so the question says so.

local confirm = require('sarcina.confirm')
local installer = require('sarcina.installer')
local ui = require('sarcina.ui')

local M = {}

--- Delete the installed plugins `names`, after the user agrees.
function M.run(resolved, names)
    if #names == 0 then return ui.emit('error', 'Usage: :Sarcina delete <plugin> [<plugin>...]') end
    local installed, wanted = {}, {}
    for _, name in ipairs(installer.installed()) do
        installed[name] = true
    end
    for _, entry in ipairs(resolved) do
        wanted[entry.name] = true
    end
    local picked, unknown, kept = {}, {}, {}
    for _, name in ipairs(names) do
        if not installed[name] then
            table.insert(unknown, name)
        elseif not vim.tbl_contains(picked, name) then
            table.insert(picked, name)
            if wanted[name] then table.insert(kept, name) end
        end
    end
    if #unknown > 0 then ui.emit('warn', 'Not installed: ' .. table.concat(unknown, ', ')) end
    if #picked == 0 then return end
    local prompt = string.format(
        'Delete %d plugin%s: %s?',
        #picked,
        #picked == 1 and '' or 's',
        table.concat(picked, ', ')
    )
    if #kept > 0 then
        prompt = prompt
            .. '\nStill in your specs, so it installs again at the next startup: '
            .. table.concat(kept, ', ')
    end
    if not confirm.ask(prompt) then return ui.emit('info', 'Nothing deleted') end
    local removed, failed = installer.remove(picked)
    if #removed > 0 then
        ui.emit('info', string.format('Deleted %d: %s', #removed, table.concat(removed, ', ')))
    end
    for _, failure in ipairs(failed) do
        ui.emit('error', failure.name .. ': ' .. failure.why)
    end
end

return M
