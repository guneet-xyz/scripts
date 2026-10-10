#!/usr/bin/env bash
# Focused Git/Delta/icon regression checks inside a disposable container.
set -Eeuo pipefail

SETUP=/opt/headless-setup/setup.sh
USER_NAME=git-test
HOME_DIR=/home/git-test
export PATH="/usr/local/bin:$PATH"

fail() {
    printf 'TEST FAILED: %s\n' "$*" >&2
    exit 1
}

[[ -e /.dockerenv && $(id -u) == 0 ]] || fail 'Run only as root inside the test container.'
useradd --create-home --shell /bin/bash "$USER_NAME"
mkdir -p "$HOME_DIR/dotfiles" "$HOME_DIR/.config"
chmod 700 "$HOME_DIR/.config"
cat >"$HOME_DIR/dotfiles/gitconfig" <<'EOF'
[user]
    name = Existing Git User
    email = existing@example.test
[core]
    pager = less
[alias]
    keep = status --branch
EOF
ln -s dotfiles/gitconfig "$HOME_DIR/.gitconfig"
printf '%s\n' "alias ll='echo personal-alias'" \
    "alias ls='eza --icons=auto --group-directories-first'" >"$HOME_DIR/.zshrc"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
ARGS=(--yes --plain --user "$USER_NAME" --no-change-shell --no-start-docker --no-neovim-config)
bash "$SETUP" "${ARGS[@]}"

snapshot() {
    find /opt/linux-headless-setup/delta "$HOME_DIR/.config/linux-headless-setup" \
        "$HOME_DIR/dotfiles" /usr/local/bin/delta "$HOME_DIR/.gitconfig" "$HOME_DIR/.zshrc" \
        -type f -print0 | sort -z | xargs -0 sha256sum
    find /opt/linux-headless-setup/delta "$HOME_DIR/.config/linux-headless-setup" \
        "$HOME_DIR/dotfiles" /usr/local/bin/delta "$HOME_DIR/.gitconfig" "$HOME_DIR/.zshrc" \
        -printf '%p %y %l %u %g %m %T@\n' | sort
    find "$HOME_DIR" -maxdepth 1 -name '*.bak.*' -printf '%p %m %T@\n' | sort
}
snapshot >/root/git-first.snapshot
sleep 1
bash "$SETUP" "${ARGS[@]}"
snapshot >/root/git-second.snapshot
diff -u /root/git-first.snapshot /root/git-second.snapshot || fail 'Git/Delta setup is not idempotent.'

[[ -L $HOME_DIR/.gitconfig && $(readlink "$HOME_DIR/.gitconfig") == dotfiles/gitconfig ]] || fail 'Git config symlink was replaced.'
[[ $(find "$HOME_DIR" -maxdepth 1 -name '.gitconfig.bak.*' | wc -l) == 1 ]] || fail 'Unexpected Git backup count.'
[[ $(stat -c %a "$HOME_DIR/.config") == 700 ]] || fail 'Private config directory permissions changed.'
[[ $(stat -c %U "$HOME_DIR/.config/linux-headless-setup/git-delta.gitconfig") == "$USER_NAME" ]] || fail 'Wrong managed Git config owner.'
[[ $(grep -c '^# >>> linux-headless-setup git >>>$' "$HOME_DIR/.gitconfig") == 1 ]] || fail 'Duplicate Git config blocks.'
for query in 'user.name|Existing Git User' 'user.email|existing@example.test' \
    'alias.keep|status --branch' 'core.pager|delta' 'interactive.diffFilter|delta --color-only' 'delta.navigate|true'; do
    key=${query%%|*}
    expected=${query#*|}
    [[ $(runuser -u "$USER_NAME" -- git config --global --includes --get "$key") == "$expected" ]] || fail "Unexpected Git config value: $key"
done
grep -Fq 'pager = less' "$HOME_DIR"/.gitconfig.bak.* || fail 'Git backup did not preserve previous settings.'

REPO="$HOME_DIR/repo"
runuser -u "$USER_NAME" -- git init --initial-branch=main "$REPO"
printf 'old line\n' >"$REPO/example.txt"
chown "$USER_NAME:$USER_NAME" "$REPO/example.txt"
runuser -u "$USER_NAME" -- git -C "$REPO" add example.txt
runuser -u "$USER_NAME" -- git -C "$REPO" -c commit.gpgsign=false commit -m 'test: create diff fixture'
printf 'new line\n' >"$REPO/example.txt"

# shellcheck disable=SC2016
runuser -u "$USER_NAME" -- env TEST_REPO="$REPO" TERM=xterm zsh -ic '
    [[ $aliases[gs] == "git status --short" ]] || exit 1
    [[ $aliases[gl] == "git log --oneline" ]] || exit 1
    [[ $aliases[gd] == "git diff" ]] || exit 1
    [[ $aliases[v] == "nvim" ]] || exit 1
    [[ $(v --version) == *NVIM* ]] || exit 1
    [[ $aliases[ll] == "echo personal-alias" ]] || exit 1
    [[ $aliases[ls] == "eza --icons=always --group-directories-first" ]] || exit 1
    [[ $aliases[la] == "eza -lah --icons=always --group-directories-first" ]] || exit 1
    [[ $aliases[lt] == "eza --tree --level=2 --icons=always" ]] || exit 1
    cd "$TEST_REPO"
    [[ $(gs) == " M example.txt" ]] || exit 1
    [[ $(gl) == *"test: create diff fixture" ]] || exit 1
    [[ $(gd) == *"-old line"* ]] || exit 1
    plain=$(eza --icons=never --color=never example.txt)
    decorated=$(ls --color=never example.txt)
    [[ $plain != $decorated && $decorated == *example.txt* ]] || exit 1
    alias ls="eza --icons=auto --group-directories-first"
    source "$HOME/.config/linux-headless-setup/zshrc"
    [[ $aliases[ls] == "eza --icons=always --group-directories-first" ]] || exit 1
' || fail 'Git aliases or icon aliases did not behave as requested.'

# Force Git to use its configured pager, but make Delta's inner pager noninteractive.
script --quiet --return --command \
    "runuser -u '$USER_NAME' -- env TERM=xterm GIT_TRACE=1 DELTA_PAGER=cat git -C '$REPO' --paginate diff" \
    /root/git-delta-tty.log >/root/git-delta-output.log
grep -E 'run_command:.*delta' /root/git-delta-output.log >/dev/null || fail 'Git did not launch Delta.'
# Word-level highlighting inserts color escapes inside otherwise plain text.
sed 's/\x1b\[[0-9;]*m//g' /root/git-delta-output.log >/root/git-delta-plain.log
grep -F 'new line' /root/git-delta-plain.log >/dev/null || {
    cat /root/git-delta-plain.log
    fail 'Delta did not render the diff.'
}
runuser -u "$USER_NAME" -- delta --version

# Confirm aliases chosen by the user are not silently discarded.
useradd --create-home --shell /bin/bash git-custom
printf '%s\n' "alias gs='echo personal-status'" "alias v='echo personal-editor'" >/home/git-custom/.zshrc
chown git-custom:git-custom /home/git-custom/.zshrc
bash "$SETUP" --yes --plain --user git-custom --no-change-shell --no-start-docker --no-neovim-config
# shellcheck disable=SC2016
runuser -u git-custom -- zsh -ic '
    [[ $aliases[gs] == "echo personal-status" ]] &&
    [[ $aliases[v] == "echo personal-editor" ]]
' || fail 'A personal Git or editor alias was replaced.'

printf '\nAll Git/Delta/icon assertions passed.\n'
