if vim.g.loaded_sarcina then return end
vim.g.loaded_sarcina = true

vim.api.nvim_create_user_command('Sarcina', function(opts) require('sarcina.cli').dispatch(opts) end, {
    nargs = '*',
    complete = function(lead) return require('sarcina.cli').complete(lead) end,
    desc = 'Sarcina',
})
