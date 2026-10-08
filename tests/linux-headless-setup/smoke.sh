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

ARGS=(--yes --plain --user "$USER_NAME" --docker-group --no-start-docker)
bash "$SETUP" "${ARGS[@]}"
sha256sum /usr/sbin/policy-rc.d >/root/policy-after.snapshot
stat -c '%F %a %U %G %Y %N' /usr/sbin/policy-rc.d >>/root/policy-after.snapshot
diff -u /root/policy-before.snapshot /root/policy-after.snapshot || fail 'Existing service policy was not restored.'

snapshot() {
    find /opt/linux-headless-setup /usr/local/bin "$HOME_DIR" /etc/systemd/system /etc/apt/keyrings /etc/apt/sources.list.d \
        -type f ! -name '.zcompdump*' -print0 | sort -z | xargs -0 sha256sum
    find /opt/linux-headless-setup /usr/local/bin "$HOME_DIR" /etc/systemd/system /etc/apt/keyrings /etc/apt/sources.list.d \
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

# Expanded by the child zsh, not by this Bash test process.
# shellcheck disable=SC2016
runuser -u "$USER_NAME" -- env TERM=xterm zsh -ic '
    [[ $KEEP_EXISTING_CONFIG == yes ]] || exit 1
    [[ $aliases[ll] == "echo custom-alias" ]] || exit 1
    [[ $aliases[ls] == "eza --group-directories-first" ]] || exit 1
    (( $+functions[z] && $+functions[prompt_starship_precmd] )) || exit 1
    [[ $EDITOR == nvim ]] || exit 1
    [[ $(command -v nvim) == /usr/local/bin/nvim ]] || exit 1
    z /usr
    [[ $PWD == /usr ]] || exit 1
' || fail 'Shell integration does not work.'
runuser -u "$USER_NAME" -- nvim --headless -u NONE -i NONE '+quit'

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
    "env -u NO_COLOR TERM=xterm bash '$SETUP' --yes --user headless-other --no-change-shell" \
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
