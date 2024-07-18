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
