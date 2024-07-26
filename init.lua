-- Neovim configuration

-- Configure LSP
require("lspconfig").clangd.setup({})

-- Set color theme
--  * Default to mocha
--  * Remove italics from comments and conditionals
require("catppuccin").setup({
	flavor = "mocha",
	styles = {
		comments = {},
		conditionals = {},
	},
})

vim.cmd.colorscheme("catppuccin")

-- Enable telescope for a set of tools for fuzzy searching with a nice
-- interface
require("telescope").setup({})

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
vim.keymap.set('n', '<leader>fb', builtin.buffers, {})
vim.keymap.set('n', '<leader>fh', builtin.help_tags, {})

-- Enable gitsigns for extended buffer git information
require("gitsigns").setup({})
