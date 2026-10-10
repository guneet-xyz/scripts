# Linux headless setup

An idempotent Bash installer for a Debian-based headless machine. It sets up
**zsh, Starship, zoxide, eza, btop, Neovim, Docker, Git, and Delta**, with numbered steps,
an animated terminal spinner, color-aware status messages, and a persistent log.
Neovim uses the default profile from [guneet-xyz/rice](https://github.com/guneet-xyz/rice),
and the managed eza aliases explicitly enable icons, including in piped output.
The UI is native Bash, so it does not need Gum or another bootstrap dependency.
Redirected output automatically uses readable, non-animated progress messages.

## Run

Use a current Debian/Ubuntu installation with `amd64` or `arm64` userspace,
outbound HTTPS access to GitHub and Docker, and working APT repositories.
Debian 12+ and Ubuntu 22.04+ are the intended baseline; older distributions may
lack btop or the libraries needed by the latest upstream binaries.

Install directly without cloning the repository (requires `curl` and `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/guneet-xyz/scripts/refs/heads/main/linux-headless-setup/setup.sh \
  | sudo bash -s -- --yes
```

Review [the installer](setup.sh) first: this executes remote code as root.
The installer configures the invoking user's account rather than root's.
`--yes` skips the confirmation prompt because Bash is reading the script from
the pipe. Append other options after `--yes` as needed.

Alternatively, use a local checkout:

```bash
# From the repository root; configures the invoking user's home, not root's.
./linux-headless-setup/setup.sh

# Unattended, or when already logged in as root:
sudo ./linux-headless-setup/setup.sh --yes --user alice
```

The target account and its home directory must already exist. The script uses
`sudo` when necessary and asks for confirmation unless you pass `--yes`.
It installs missing APT packages, not a full system upgrade.

### Options

| Option | Effect |
| --- | --- |
| `--yes`, `-y` | Accept the plan without an interactive prompt. |
| `--user USER` | Configure this user; defaults to `SUDO_USER` or the current user. |
| `--no-change-shell` | Keep the user's existing login shell. |
| `--docker-group` | Opt in to Docker access without sudo; **grants root-equivalent privileges**. |
| `--no-start-docker` | Suppress Docker/containerd start/restart hooks during APT installation and skip explicit service startup. Useful in containers. Does not stop an already-running daemon. |
| `--upgrade-docker` | Upgrade official Docker packages to the latest APT candidates. Package upgrades may restart Docker and interrupt containers. |
| `--no-neovim-config` | Keep the existing Neovim configuration; skip rice and its runtime/tool/parser setup. |
| `--docker-codename NAME` | Override the repository suite with the corresponding Debian/Ubuntu base release for a derivative. |
| `--plain` | No colors or spinner. `NO_COLOR=1` also disables colors. |
| `--help`, `-h` | Show usage. |

GitHub's unauthenticated API has a shared-IP rate limit. If necessary, provide a
token with access to public release metadata; it is used only for API requests,
not download requests, and is not written to the log:

```bash
export GITHUB_TOKEN='your-token'
sudo --preserve-env=GITHUB_TOKEN ./linux-headless-setup/setup.sh --yes --user "$USER"
```

## Installation sources

| Tool | Source / location |
| --- | --- |
| Git, less, zsh, btop | Distribution APT packages. Git is installed explicitly; less is available for Delta's pager. |
| Starship | Latest stable `starship/starship` GitHub release; Linux musl binary. |
| zoxide | Latest stable `ajeetdsouza/zoxide` GitHub release; Linux musl binary. |
| eza | Latest stable `eza-community/eza` GitHub release; musl on amd64, GNU on arm64. |
| Delta | Latest stable `dandavison/delta` GitHub release; musl on amd64, GNU on arm64; SHA-256 verified. |
| Neovim | Latest stable `neovim/neovim` GitHub release; full Linux tarball, **not APT or AppImage**. Includes its runtime and needs no FUSE. |
| Neovim config | The `nvim/.config/nvim` folder from `guneet-xyz/rice`, linked into the target user's `~/.config/nvim`. No other rice packages are installed. |
| Neovim runtimes | Current Node.js **LTS** (including npm/npx), stable Go (including gofmt), and compatible Helm 3, from official archives with published SHA-256 checksums. Python 3, pip, and venv support come from APT. |
| Neovim dependencies | APT build tools, unzip, ripgrep, X11/Wayland clipboard clients, plus the official Tree-sitter CLI. Lazy/Mason install and verify the enabled profile's plugins, language servers, formatters, and native parsers as the target user. |
| Docker | **Docker's official APT repository**, following its [Debian](https://docs.docker.com/engine/install/debian/#install-using-the-repository) / [Ubuntu](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository) instructions. Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`. Never installs the distribution's `docker.io`. |

GitHub assets are checked against their published SHA-256 API digests before
extraction. Docker's signing key is fetched over HTTPS and scoped to its repository
using `Signed-By`; APT verifies package signatures and checksums. The script checks
that Docker package candidates come from the correct official stable repository.
Direct downloads use HTTPS-only redirects, timeouts, and retries.

The GitHub tools live in versioned directories under `/opt/linux-headless-setup/`
and are linked into `/usr/local/bin/`. Neovim retains its full runtime tree.
An older distribution binary in `/usr/bin/` is not deleted; the new installation
takes precedence in the configured zsh PATH. An unmanaged file or symlink already
at a destination in `/usr/local/bin/` causes a clear error instead of being
overwritten. Move that conflict aside yourself if you want this installer to
manage that tool.

## What changes, and what reruns do

- Missing APT dependencies are installed. If all are present, APT is skipped.
- GitHub tools resolve the current stable release on each run. Existing release
  directories are reused; only new versions are downloaded. Old versions are
  retained rather than automatically deleted.
- The rice repository is shallow/sparse-cloned as the target user into
  `~/.local/share/linux-headless-setup/rice`. Existing Neovim configuration is
  moved to a unique `~/.config/nvim.bak.*` backup before installing the symlink.
  Reruns reuse the checkout without pulling, resetting, or overwriting local
  edits, and do not create duplicate backups. All Lua files are syntax-checked
  as the target user before linking the configuration.
- The dependency bootstrap installs missing plugins/tools only, rather than
  updating or cleaning an existing plugin set. A completion marker and executable/
  parser checks let healthy reruns skip the bootstrap. npm helpers are kept in a
  user-owned prefix; Python tools installed through Mason use virtual environments,
  not `sudo pip` or system-Python overrides.
- Docker's official repository and signing key are configured only as needed.
  Existing official repository definitions are reused to avoid duplicate entries.
  Already-installed official Docker packages are reused unless `--upgrade-docker`
  is explicitly supplied. Normal APT upgrades also update Docker afterward.
- Conflicting distro Docker/containerd/runc packages cause an explicit error
  **before installation**; they are never silently removed. Follow Docker's
  linked installation docs to review/remove conflicts yourself. Unmanaged Docker
  executables that would shadow the APT binaries also cause an error.
- Installation is locked against concurrent runs. Downloads and staging files
  are cleaned up on exit; completed installations remain usable if a later step
  fails. Rerunning resumes the remaining setup.
- The script adds exactly one managed source block to `~/.zshrc`. Other content
  is preserved, including an existing `.zshrc` symlink. A private `.zshrc.bak.*`
  backup is created **only when an existing file needs to change**.
- Shell integration lives in `~/.config/linux-headless-setup/zshrc`. It configures
  history, completion, Starship, zoxide's `z` command, `EDITOR`/`VISUAL` defaults,
  and `ls`/`ll`/`la`/`lt` aliases for eza with `--icons=always`. Earlier managed
  definitions are upgraded when the shell integration is sourced again. Other
  personal aliases and editor choices are respected.
  Put personal edits in `.zshrc`, not the generated integration file.
- Git's global config gets one managed include for Delta. Existing identity,
  credentials, aliases, other settings, and `.gitconfig` symlinks are preserved.
  A private `.gitconfig.bak.*` backup is created only when an existing file
  actually changes; reruns do not add duplicate includes or backups.
- zsh becomes the login shell unless disabled. Docker group membership is never
  granted unless you explicitly pass `--docker-group`.
- Logs are retained at `/var/log/linux-headless-setup.*.log`, readable only by
  root. Failures show the last log lines and the full log path.

The shell integration assumes the standard `$HOME/.zshrc` location. If you use
`ZDOTDIR`, source `~/.config/linux-headless-setup/zshrc` from your actual zshrc.
Remove any pre-existing manual Starship/zoxide initialization if it would
initialize those tools twice. The existing Starship configuration is not
replaced, and no terminal fonts are installed on the headless server.

## Neovim config and icons

The installer uses rice's `nvim` **default** profile directly, without requiring
the easyrice CLI or changing the upstream configuration. The checkout and
config symlink are user-owned. Use `--no-neovim-config` to opt out.

Tree-sitter's official binaries require newer system libraries on some releases.
On older hosts such as Debian 12 and Ubuntu 22.04, the installer falls back to
building the same CLI version as the target user using an isolated, temporary
Rust/Cargo toolchain. The Rust bootstrap is checksum-verified, Cargo uses its
locked dependencies and registry checksums, and the temporary toolchain is
removed on exit without changing shell profiles or existing Rust installations.
This first-time fallback needs extra downloads, disk space, and several minutes;
reruns reuse the installed CLI instead of rebuilding it.

The installer now bootstraps and checks the profile's dependencies in headless
Neovim **as the target account** (normally an unprivileged user; selecting root
explicitly means the configuration runs as root). It supplies Node.js LTS,
npm/npx, Go/gofmt, Python with pip/venv support, compiler/build tools, and ripgrep.
It installs the selected language servers and formatters through Lazy/Mason,
and extra native parsers needed by the Helm and MDX plugins. Prettier is installed
in `~/.local/share/linux-headless-setup/npm` so the config's `npx prettier` command
works without an interactive package-install prompt. The managed shell exports
that npm prefix when no custom prefix is already set and exposes Mason's tools.

See the [dependency audit](neovim-dependencies.md) for exact package names,
tool-to-feature mapping, and intentionally excluded optional tools. First setup
requires additional HTTPS access to npm, PyPI, Rust distribution endpoints,
and Mason/Tree-sitter package sources. No configuration files in rice are patched.
Use `:Lazy`, `:Mason`, and `:checkhealth` to inspect the resulting setup.

`xclip` and `wl-clipboard` are installed for sessions with an X11/Wayland display;
they do not create a display server or make a remote SSH clipboard available by
themselves. In headless SSH sessions, clipboard integration depends on Neovim's
OSC52 provider and support in your local terminal.

To update the config, review your local changes and pull the user-owned checkout:

```bash
git -C "$HOME/.local/share/linux-headless-setup/rice" pull --ff-only
```

Both eza icons and rice's Neovim settings expect a **Nerd Font in your local
terminal/SSH client**. Installing fonts on the headless server would not change
the font used by your local terminal. Existing custom aliases are not overridden;
add `--icons=always` to any personal eza aliases if needed. Use
`eza --icons=never` directly when plain output is required.

## Git aliases and Delta

The managed zsh integration supplies:

| Command | Expansion |
| --- | --- |
| `gs` | `git status --short` |
| `gl` | `git log --oneline` |
| `gd` | `git diff` |

An existing personal alias with one of these names is not overwritten.

Delta is configured in `~/.config/linux-headless-setup/git-delta.gitconfig`,
included from `~/.gitconfig`:

```gitconfig
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
```

Git uses Delta when displaying paged diffs, log patches, and similar output in
a terminal. Interactive staging uses Delta's color-only filter. Normal redirects
and pipes keep Git's standard non-pager behavior. Per-repository configuration
and `GIT_PAGER` can still override the global pager. No Git name/email or merge
conflict style is chosen by the installer.

## Docker notes

The repository is selected from `/etc/os-release`, using Ubuntu's base codename
where available (for example, on Linux Mint), or Debian's version codename.
Derivatives are not officially supported by Docker. For a derivative whose
codename differs from its base, use `--docker-codename` only if you know the
matching supported base release.

Docker now receives normal package-managed updates. To explicitly upgrade it:

```bash
sudo ./linux-headless-setup/setup.sh --yes --user "$USER" --upgrade-docker
```

On a systemd host, the package-provided Docker and containerd services are enabled
and started, and Docker's local socket is checked. On a host without running
systemd, startup is suppressed and explicitly reported as skipped. A temporary
`policy-rc.d` wrapper blocks Docker/containerd start hooks when needed, preserving
and restoring any existing policy, including symlinks. Package scripts may still
enable services for the next boot; `--no-start-docker` is not a permanent mask.

The script does not expose a TCP socket, replace `/etc/docker/daemon.json` or
custom service units, delete Docker data, or change the host's firewall policy.
Docker itself may configure iptables rules when started; published container
ports can bypass some host firewall rules, so review Docker's firewall guidance.
Compose and Buildx are included, as in Docker's official instructions. Rootless
Docker configuration is outside this installer's scope.

After logging in again:

```bash
zsh --version
starship --version
zoxide --version
eza --version
git --version
delta --version
btop --version
nvim --version
sudo docker run --rm hello-world
```

## Tests

Container tests and their instructions live separately in
[`tests/linux-headless-setup/`](../tests/linux-headless-setup/README.md).
