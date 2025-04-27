-- Neovim configuration

-- Configure LSP
require("lspconfig").clangd.setup({})
require("lspconfig").rust_analyzer.setup({})

-- Set color theme
vim.cmd.colorscheme("gruvbox")

-- Remove status bar for a cleaner display
vim.opt.laststatus = 0

-- Highlight current line
vim.opt.cursorline = true

-- Enable telescope for a set of tools for fuzzy searching with a nice
-- interface
require("telescope").setup({})

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
vim.keymap.set('n', '<leader>fb', builtin.buffers, {})
vim.keymap.set('n', '<leader>fh', builtin.help_tags, {})

-- Enable neogit plugin for a nice git interface inside neovim
require("neogit").setup({})

-- Enable gitsigns for extended buffer git information
require("gitsigns").setup({})
