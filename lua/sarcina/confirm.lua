-- sarcina/confirm.lua
-- The yes/no question before `update` and `remove`. `setup({ confirm = false })` turns it off.

local M = {}

M.enabled = true

--- Read the `confirm` option of setup(): anything but `false` keeps the question.
function M.configure(opt) M.enabled = opt ~= false end

--- Whether the user said yes. Always true with the question off. A function so tests can swap it.
function M.ask(prompt)
    if not M.enabled then return true end
    return vim.fn.confirm(prompt, '&Yes\n&No', 2) == 1
end

return M
