# Rice Neovim dependency audit

Audited `guneet-xyz/rice` at commit
`f166f8d832f076e9662dc671cb84cf66e6f625eb`, including `init.lua`,
`lua/custom/plugins/`, and the enabled `lua/kickstart/plugins/` imports.
The installer leaves these configuration files unchanged.

## Runtimes and shared utilities

| Dependency | Why it is needed | Installation |
| --- | --- | --- |
| Node.js, npm, npx | JSON/TypeScript/YAML language tools and `npx prettier`. The currently published TypeScript language server requires Node **≥22.22.2**, newer than Debian 12/Ubuntu 24.04's Node 18. | Latest Node LTS archive from nodejs.org, published SHA-256 checked; includes npm/npx. |
| Python 3, pip, venv | Mason's Python language server and Python/MDX formatters; avoid writing to distro Python under PEP 668. | APT `python3`, `python3-pip`, `python3-venv`. |
| Go, gofmt | `gofmt` is explicitly selected for Go files. | Latest stable official Go archive; published SHA-256 checked. |
| Helm CLI | `helm-ls` delegates chart rendering/linting/dependency handling to Helm. | Latest stable compatible Helm 3 archive from get.helm.sh, published SHA-256 checked. |
| ripgrep (`rg`) | Telescope uses `rg` explicitly for both file finding and live grep. | APT `ripgrep`. |
| Git | Lazy/plugin installs and Diffview/Gitsigns. | APT `git`. |
| C/C++ compiler, make | Native Telescope fzf extension, LuaSnip regex support, Tree-sitter parsers. | APT `build-essential`. |
| tar, gzip, xz, unzip, curl | Runtime archives, Mason downloads, parser sources. | Existing APT prerequisites plus `unzip`. |
| Tree-sitter CLI | Required by the enabled `nvim-treesitter` **main** branch, including parser generation. | Official CLI release; isolated user-mode source build if prebuilt system-library requirements are too new. |
| xclip, wl-copy/wl-paste | Clipboard providers where X11/Wayland sessions are actually available. | APT `xclip`, `wl-clipboard`; no display server is installed. Headless SSH may instead use OSC52. |
| Nerd Font | Rice sets `have_nerd_font = true`; eza also displays icons. | Configure the **local terminal/SSH client**, not the headless server. |

## Language tools selected by the profile

| Config entry / feature | Executable | Mason package |
| --- | --- | --- |
| `lua_ls` | `lua-language-server` | `lua-language-server` |
| `pylsp` | `pylsp` | `python-lsp-server` |
| `jsonls` | `vscode-json-language-server` | `json-lsp` |
| `ts_ls` | `typescript-language-server` | `typescript-language-server` |
| Helm plugin's external tooling | `helm_ls` | `helm-ls` |
| Helm's YAML integration | `yaml-language-server` | `yaml-language-server` |

Installing Helm tooling does not implicitly enable an LSP server that the rice
configuration has not registered. Helm LSP setup still belongs in the upstream
config. Project-specific chart dependencies and `helm dependency build` are not
run by this machine setup script.

## Every formatter selected by `formatters_by_ft`

| Filetypes | Tools installed |
| --- | --- |
| Lua | `stylua` (Mason) |
| Markdown, Astro, TypeScript/JavaScript, TSX/JSX, JSON | `prettier` (user-owned npm global prefix, available to npx) |
| MDX | `mdformat` (Mason Python environment), plus Prettier |
| Zsh | `shfmt` (Mason) |
| YAML | `yamlfmt` (Mason) |
| Python | `isort`, `ruff` (Mason Python environments) |
| C++, Java | `clang-format` (Mason) |
| Go | `gofmt` (Go distribution), `gofumpt` (Mason) |

Mason installs binaries into the target user's Neovim data directory. These
tools are checked for existence and executable/runtime compatibility after
installation; failures stop setup with the detailed log path.

## Native parser dependencies

The bootstrap covers rice's existing parser list plus TypeScript, TSX,
JavaScript, YAML, Helm, Python, Go, JSON, C++, Java, and Astro. This includes the
extra grammars required by the `mdx.nvim` and `helm-ls.nvim` plugins. Parser
installation and loading are awaited rather than merely queued in the background.

## Intentionally not installed

- `biome` is defined as a formatter override but is **not selected** by any
  `formatters_by_ft` entry; those filetypes currently use Prettier.
- The debug and lint Kickstart imports are commented out, so Delve/DAP adapters
  and `markdownlint` are not required by the enabled profile.
- Commented-out servers such as clangd, gopls, pyright, and rust-analyzer are not
  enabled by the profile. Add their tools when enabling those features.
- `fd` is not required by this config's Telescope searches: their command is
  explicitly set to ripgrep. Additional project/terminal dependencies are not
  guessed or installed automatically.
