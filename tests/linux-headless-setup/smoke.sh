#!/usr/bin/env bash
# Executed inside a disposable container by test-in-docker.sh, not on the host.
set -Eeuo pipefail

SETUP=/opt/headless-setup/setup.sh
USER_NAME=headless-test
HOME_DIR=/home/headless-test
export PATH="/usr/local/bin:$PATH"

fail() {
    printf 'TEST FAILED: %s\n' "$*" >&2
    exit 1
}

[[ -e /.dockerenv && $(id -u) == 0 ]] || fail 'Only run this test as root inside its Docker container.'
useradd --create-home --shell /bin/bash "$USER_NAME"
mkdir -p "$HOME_DIR/dotfiles"
printf '%s\n' '# Existing user configuration' "alias ll='echo custom-alias'" \
    'export KEEP_EXISTING_CONFIG=yes' >"$HOME_DIR/dotfiles/zshrc"
ln -s dotfiles/zshrc "$HOME_DIR/.zshrc"
mkdir -p "$HOME_DIR/.config/nvim" "$HOME_DIR/.local"
chmod 700 "$HOME_DIR/.config" "$HOME_DIR/.local"
printf '%s\n' '-- Existing personal Neovim configuration' >"$HOME_DIR/.config/nvim/init.lua"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"

# Exercise restoration of an existing service-start policy (including a symlink).
if [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 0\n' >/usr/sbin/headless-test-policy
    chmod 755 /usr/sbin/headless-test-policy
    ln -s headless-test-policy /usr/sbin/policy-rc.d
fi
sha256sum /usr/sbin/policy-rc.d >/root/policy-before.snapshot
stat -c '%F %a %U %G %Y %N' /usr/sbin/policy-rc.d >>/root/policy-before.snapshot

# Reject incorrect arguments before doing any installation work.
bash "$SETUP" --help >/dev/null
if bash "$SETUP" --user >/dev/null 2>&1; then fail 'Missing --user argument was accepted.'; fi
if bash "$SETUP" --unknown >/dev/null 2>&1; then fail 'Unknown argument was accepted.'; fi
if bash "$SETUP" --yes --user no-such-test-user >/dev/null 2>&1; then fail 'Missing account was accepted.'; fi

# Piped execution cannot re-open its source file to elevate privileges.
if cat "$SETUP" | runuser -u "$USER_NAME" -- bash -s -- --yes >/root/unprivileged-pipe.log 2>&1; then
    fail 'Piped execution was accepted without root privileges.'
fi
grep -Fq 'When piping the script, run it as root' /root/unprivileged-pipe.log ||
    fail 'Piped privilege diagnostic is missing.'

ARGS=(--yes --plain --user "$USER_NAME" --docker-group --no-start-docker)
# Exercise the same stdin execution mode used by the documented curl command.
if ! cat "$SETUP" | bash -s -- "${ARGS[@]}" >/root/piped-setup.log 2>&1; then
    cat /root/piped-setup.log
    fail 'Piped installation failed.'
fi
cat /root/piped-setup.log
grep -Fq 'Setup complete.' /root/piped-setup.log || fail 'Piped installation did not finish.'
if grep -Fq 'unbound variable' /root/piped-setup.log; then fail 'Piped execution assumed a source file.'; fi
sha256sum /usr/sbin/policy-rc.d >/root/policy-after.snapshot
stat -c '%F %a %U %G %Y %N' /usr/sbin/policy-rc.d >>/root/policy-after.snapshot
diff -u /root/policy-before.snapshot /root/policy-after.snapshot || fail 'Existing service policy was not restored.'

snapshot() {
    find /opt/linux-headless-setup /usr/local/bin "$HOME_DIR" /etc/systemd/system /etc/apt/keyrings /etc/apt/sources.list.d \
        \( -path "$HOME_DIR/.cache" -o -path "$HOME_DIR/.npm" -o -path "$HOME_DIR/.local/state" -o -path "$HOME_DIR/.config/go/telemetry" \
        -o -path "$HOME_DIR/.local/share/nvim/mason/packages/lua-language-server/libexec/log" \) -prune -o \
        -type f ! -name '.zcompdump*' -print0 | sort -z | xargs -0 sha256sum
    find /opt/linux-headless-setup /usr/local/bin "$HOME_DIR" /etc/systemd/system /etc/apt/keyrings /etc/apt/sources.list.d \
        \( -path "$HOME_DIR/.cache" -o -path "$HOME_DIR/.npm" -o -path "$HOME_DIR/.local/state" -o -path "$HOME_DIR/.config/go/telemetry" \
        -o -path "$HOME_DIR/.local/share/nvim/mason/packages/lua-language-server/libexec/log" \) -prune -o \
        -printf '%p %y %l %u %g %m %T@\n' | sort
    getent passwd "$USER_NAME"
    getent group docker
    cat /etc/shells
}

snapshot >/root/first-run.snapshot
sleep 1
bash "$SETUP" "${ARGS[@]}"
snapshot >/root/second-run.snapshot
diff -u /root/first-run.snapshot /root/second-run.snapshot || fail 'The second run changed managed files, ownership, timestamps, or account settings.'

[[ -L $HOME_DIR/.zshrc && $(readlink "$HOME_DIR/.zshrc") == dotfiles/zshrc ]] || fail '.zshrc symlink was replaced.'
[[ $(grep -c '^# >>> linux-headless-setup >>>$' "$HOME_DIR/.zshrc") == 1 ]] || fail 'Duplicate source blocks.'
[[ $(find "$HOME_DIR" -maxdepth 1 -name '.zshrc.bak.*' | wc -l) == 1 ]] || fail 'Unexpected number of backups.'
grep -Fxq 'export KEEP_EXISTING_CONFIG=yes' "$HOME_DIR/.zshrc" || fail 'Existing configuration was lost.'
[[ $(stat -c %U "$HOME_DIR/.config/linux-headless-setup/zshrc") == "$USER_NAME" ]] || fail 'Wrong integration-file owner.'
[[ $(getent passwd "$USER_NAME" | cut -d: -f7) == /usr/bin/zsh ]] || fail 'Login shell was not configured.'
[[ " $(id -nG "$USER_NAME") " == *' docker '* ]] || fail 'Docker group membership was not granted.'
RICE_DIR="$HOME_DIR/.local/share/linux-headless-setup/rice"
[[ -L $HOME_DIR/.config/nvim && $(readlink "$HOME_DIR/.config/nvim") == "$RICE_DIR/nvim/.config/nvim" ]] || fail 'The rice Neovim profile is not linked.'
[[ $(stat -c %U "$RICE_DIR/.git") == "$USER_NAME" ]] || fail 'The rice checkout is not user-owned.'
[[ $(stat -c %U "$HOME_DIR/.config/nvim") == "$USER_NAME" ]] || fail 'The Neovim symlink is not user-owned.'
[[ $(stat -c %a "$HOME_DIR/.config") == 700 && $(stat -c %a "$HOME_DIR/.local") == 700 ]] || fail 'Existing private-directory permissions changed.'
[[ $(find "$HOME_DIR/.config" -maxdepth 1 -name 'nvim.bak.*' | wc -l) == 1 ]] || fail 'Unexpected number of Neovim config backups.'
grep -Fx -- '-- Existing personal Neovim configuration' "$HOME_DIR"/.config/nvim.bak.*/init.lua >/dev/null || fail 'The old Neovim config was not backed up.'
[[ ! -d $RICE_DIR/ghostty && ! -e $HOME_DIR/.config/ghostty ]] || fail 'An unrelated rice package was installed.'
runuser -u "$USER_NAME" -- git -C "$RICE_DIR" remote get-url origin | grep -Fx 'https://github.com/guneet-xyz/rice.git' >/dev/null || fail 'Wrong rice origin.'

# Expanded by the child zsh, not by this Bash test process.
# shellcheck disable=SC2016
runuser -u "$USER_NAME" -- env TERM=xterm zsh -ic '
    [[ $KEEP_EXISTING_CONFIG == yes ]] || exit 1
    [[ $aliases[ll] == "echo custom-alias" ]] || exit 1
    [[ $aliases[ls] == "eza --icons=auto --group-directories-first" ]] || exit 1
    [[ $aliases[la] == "eza -lah --icons=auto --group-directories-first" ]] || exit 1
    [[ $aliases[lt] == "eza --tree --level=2 --icons=auto" ]] || exit 1
    (( $+functions[z] && $+functions[prompt_starship_precmd] )) || exit 1
    [[ $EDITOR == nvim ]] || exit 1
    [[ $(command -v nvim) == /usr/local/bin/nvim ]] || exit 1
    z /usr
    [[ $PWD == /usr ]] || exit 1
' || fail 'Shell integration does not work.'
runuser -u "$USER_NAME" -- nvim --headless -u NONE -i NONE '+quit'
# Check the repository's actual settings without bootstrapping network plugins.
runuser -u "$USER_NAME" -- env RICE_OPTIONS="$HOME_DIR/.config/nvim/lua/custom/options.lua" \
    nvim --headless -u NONE -i NONE \
    "+lua dofile(vim.env.RICE_OPTIONS); if vim.g.mapleader ~= ',' or vim.g.have_nerd_font ~= true then vim.cmd('cquit 1') end" '+quit'
for dependency in cc make unzip rg tree-sitter node npm npx python3 go gofmt helm; do
    # shellcheck disable=SC2016
    runuser -u "$USER_NAME" -- sh -c 'command -v "$1"' test "$dependency" >/dev/null || fail "Missing Neovim dependency: $dependency"
done
NODE_PREFIX="$HOME_DIR/.local/share/linux-headless-setup/npm"
MASON_BIN="$HOME_DIR/.local/share/nvim/mason/bin"
runuser -u "$USER_NAME" -- env PATH="$MASON_BIN:$HOME_DIR/.local/bin:$PATH" NPM_CONFIG_PREFIX="$NODE_PREFIX" \
    npx --offline --no-install prettier --version
runuser -u "$USER_NAME" -- python3 -c 'import venv, ensurepip'
runuser -u "$USER_NAME" -- node -e 'if (Number(process.versions.node.split(".")[0]) < 24) process.exit(1)'
for dependency in lua-language-server pylsp vscode-json-language-server typescript-language-server \
    stylua shfmt clang-format gofumpt yamlfmt isort ruff mdformat helm_ls yaml-language-server; do
    [[ -x $MASON_BIN/$dependency ]] || fail "Missing configured Neovim tool: $dependency"
done
[[ $(stat -c %U "$NODE_PREFIX/lib/node_modules/prettier") == "$USER_NAME" ]] || fail 'Prettier was installed as root.'
[[ $(stat -c %U "$HOME_DIR/.local/share/nvim/mason") == "$USER_NAME" ]] || fail 'Mason tools were installed as root.'
# Load the installed native parser modules with plugins/config disabled.
runuser -u "$USER_NAME" -- nvim --headless -u NONE -i NONE \
    "+lua for _, lang in ipairs({'typescript','tsx','javascript','yaml','helm','python','go'}) do if not pcall(vim.treesitter.language.add, lang) then vim.cmd('cquit 1') end end" '+quit'

for tool in zsh starship zoxide eza btop nvim docker dockerd; do
    "$tool" --version
done
for package in neovim docker.io; do
    [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]] ||
        fail "$package was installed via APT."
done
for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    [[ $(dpkg-query -W -f='${Status}' "$package") == 'install ok installed' ]] || fail "$package is not installed."
    apt-cache policy "$package" | grep -F 'https://download.docker.com/linux/' >/dev/null || fail "$package is not from Docker's repository."
done
[[ $(readlink /usr/local/bin/nvim) == /opt/linux-headless-setup/neovim/*/bin/nvim ]] || fail 'Neovim is not using its GitHub runtime tree.'
docker compose version
docker buildx version
! pgrep -x dockerd >/dev/null || fail 'Docker daemon was unexpectedly started.'
! pgrep -x containerd >/dev/null || fail 'containerd was unexpectedly started.'

# Same-release Docker upgrades must also leave package binaries/repo files intact.
find /usr/bin/docker /usr/bin/dockerd /etc/apt/keyrings /etc/apt/sources.list.d /etc/systemd/system \
    -printf '%p %y %l %T@\n' | sort >/root/docker-before.snapshot
bash "$SETUP" "${ARGS[@]}" --upgrade-docker
find /usr/bin/docker /usr/bin/dockerd /etc/apt/keyrings /etc/apt/sources.list.d /etc/systemd/system \
    -printf '%p %y %l %T@\n' | sort >/root/docker-after.snapshot
diff -u /root/docker-before.snapshot /root/docker-after.snapshot || fail 'Same-version Docker upgrade changed the installation.'

# Reuse an official repository stored under a different name, without duplicates.
mv /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/existing-docker.sources
bash "$SETUP" "${ARGS[@]}"
[[ ! -e /etc/apt/sources.list.d/docker.sources ]] || fail 'A duplicate Docker repository was created.'
mv /etc/apt/sources.list.d/existing-docker.sources /etc/apt/sources.list.d/docker.sources

# Default access stays sudo-only; --no-change-shell and no-systemd are respected.
useradd --create-home --shell /bin/bash headless-other
# A pseudo-terminal also exercises the color/spinner path without noisy test output.
if ! script --quiet --return --command \
    "env -u NO_COLOR TERM=xterm bash '$SETUP' --yes --user headless-other --no-change-shell --no-neovim-config" \
    /root/tty.log >/root/tty-output.log; then
    cat /root/tty-output.log
    fail 'Terminal UI run failed.'
fi
grep -Fq $'\033[1;36m' /root/tty-output.log || fail 'Terminal UI did not use color.'
grep -Fq 'Setup complete.' /root/tty-output.log || fail 'Terminal UI did not finish.'
[[ $(getent passwd headless-other | cut -d: -f7) == /bin/bash ]] || fail '--no-change-shell was ignored.'
[[ " $(id -nG headless-other) " != *' docker '* ]] || fail 'Docker group access was granted without consent.'
! pgrep -x dockerd >/dev/null || fail 'No-systemd path started Docker.'

# Cancelling an interactive plan must not start installation; NO_COLOR is honored.
script --quiet --return --command \
    "env NO_COLOR=1 TERM=xterm bash '$SETUP' --user headless-other --no-change-shell" \
    /root/cancel.log <<<'n' >/root/cancel-output.log
grep -Fq 'Cancelled; no changes made.' /root/cancel-output.log || fail 'Cancellation did not work.'
if grep -Fq $'\033[1;' /root/cancel-output.log; then fail 'NO_COLOR was ignored.'; fi

# Local changes in the user-owned checkout must survive another installer run.
printf '\n-- Keep this local edit\n' >>"$RICE_DIR/nvim/.config/nvim/lua/custom/options.lua"
sha256sum "$RICE_DIR/nvim/.config/nvim/lua/custom/options.lua" >/root/local-edit-before.snapshot
bash "$SETUP" "${ARGS[@]}"
sha256sum "$RICE_DIR/nvim/.config/nvim/lua/custom/options.lua" >/root/local-edit-after.snapshot
diff -u /root/local-edit-before.snapshot /root/local-edit-after.snapshot || fail 'Local rice edits were overwritten.'
[[ $(find "$HOME_DIR/.config" -maxdepth 1 -name 'nvim.bak.*' | wc -l) == 1 ]] || fail 'A rerun created another Neovim backup.'

# Users can opt out without moving or modifying their personal Neovim config.
useradd --create-home --shell /bin/bash headless-skip
mkdir -p /home/headless-skip/.config/nvim
printf '%s\n' '-- Keep this config' >/home/headless-skip/.config/nvim/init.lua
chown -R headless-skip:headless-skip /home/headless-skip/.config
bash "$SETUP" --yes --plain --user headless-skip --no-change-shell --no-start-docker --no-neovim-config
[[ ! -L /home/headless-skip/.config/nvim ]] || fail '--no-neovim-config replaced the config.'
grep -Fxq -- '-- Keep this config' /home/headless-skip/.config/nvim/init.lua || fail 'The opted-out config changed.'
[[ ! -e /home/headless-skip/.local/share/linux-headless-setup/rice ]] || fail 'Rice was cloned despite opting out.'

# Protect an unmanaged binary instead of silently overwriting it.
mv /usr/local/bin/starship /usr/local/bin/starship.managed-test
printf '#!/bin/sh\nprintf "unmanaged-test\\n"\n' >/usr/local/bin/starship
chmod 755 /usr/local/bin/starship
if bash "$SETUP" "${ARGS[@]}" >/root/conflict.log 2>&1; then fail 'An unmanaged binary was overwritten.'; fi
grep -Fq 'Refusing to replace unmanaged path: /usr/local/bin/starship' /root/conflict.log || fail 'Unmanaged conflict diagnostic is missing.'
grep -Fq 'unmanaged-test' /usr/local/bin/starship || fail 'Unmanaged binary contents changed.'
rm /usr/local/bin/starship
mv /usr/local/bin/starship.managed-test /usr/local/bin/starship

printf '\nAll installer assertions passed.\n'
