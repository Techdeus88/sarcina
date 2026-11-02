-- sarcina/confirm.lua
-- The yes/no question before `update` and `delete`. `setup({ confirm = false })` turns it off.

local M = {}

M.enabled = true

--- Read the `confirm` option of setup(): anything but `false` keeps the question.
function M.configure(opt) M.enabled = opt ~= false end

--- Calls `callback(true)` at once with the question off. Otherwise the question is asked in the right of the
--- header (see ui.ask) and `callback` gets the answer later. A function so tests can swap it.
function M.ask(prompt, callback)
    if not M.enabled then return callback(true) end
    require('sarcina.ui').ask(prompt, callback)
end

return M
