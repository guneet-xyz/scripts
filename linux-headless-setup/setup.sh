#!/usr/bin/env bash
# Set up a Debian-based headless workstation without replacing existing dotfiles.
set -Eeuo pipefail
umask 022

APP_ROOT=/opt/linux-headless-setup
BIN_DIR=/usr/local/bin
MANAGED_MARKER='# Managed by linux-headless-setup.'
YES=0
PLAIN=0
CHANGE_SHELL=1
DOCKER_GROUP=0
START_DOCKER=1
UPGRADE_DOCKER=0
DOCKER_CODENAME=''
TARGET_USER=${SUDO_USER:-$(id -un)}
WORK_DIR=''
LOG_FILE=''
SPINNER_PID=''
CURRENT_STEP=''
STEP_RESULT=''
STEP=0
TOTAL_STEPS=9
DOCKER_SERVICE_STATE=not-started
POLICY_INSTALLED=0
POLICY_BACKUP=''
TEMP_PATHS=()
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Install and configure zsh, Starship, zoxide, eza, btop, Neovim, and Docker.
Supports Debian-based Linux on amd64 and arm64. Needs root or sudo.

  -y, --yes             Accept the installation plan without prompting.
  --user USER           Configure this existing user (default: invoking user).
  --no-change-shell     Do not make zsh the user's login shell.
  --docker-group        Grant the user root-equivalent Docker group access.
  --no-start-docker     Suppress Docker/containerd starts, including APT hooks.
  --upgrade-docker      Upgrade official Docker packages (may restart Docker).
  --docker-codename NAME  Use a base Debian/Ubuntu codename for a derivative.
  --plain               Disable colors and the animated spinner.
  -h, --help            Show this help.

Neovim and the other GitHub tools track the latest stable release on reruns.
Docker uses Docker's official APT repository, never the distro's docker.io.
Conflicting Docker packages and unmanaged /usr/local/bin files are protected.
Set GITHUB_TOKEN for a higher GitHub API rate limit. NO_COLOR disables colors.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    if [[ -n $CURRENT_STEP && -n $LOG_FILE ]]; then
        on_error 1 "${BASH_LINENO[0]}"
    fi
    exit 1
}

while (($#)); do
    case "$1" in
        -y | --yes) YES=1 ;;
        --user)
            (($# >= 2)) && [[ -n $2 && $2 != -* ]] || die '--user requires a username.'
            TARGET_USER=$2
            shift
            ;;
        --no-change-shell) CHANGE_SHELL=0 ;;
        --docker-group) DOCKER_GROUP=1 ;;
        --no-start-docker) START_DOCKER=0 ;;
        --upgrade-docker) UPGRADE_DOCKER=1 ;;
        --docker-codename)
            (($# >= 2)) && [[ -n $2 && $2 != -* ]] || die '--docker-codename requires a codename.'
            DOCKER_CODENAME=$2
            shift
            ;;
        --plain) PLAIN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "Unknown option: $1 (use --help)." ;;
    esac
    shift
done

[[ $(uname -s) == Linux && -r /etc/os-release ]] || die 'This script requires Linux.'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == debian || ${ID_LIKE:-} == *debian* || ${ID:-} == ubuntu ]] ||
    die 'This script requires a Debian-based distribution.'
command -v apt-get >/dev/null || die 'apt-get is required.'
if [[ ${ID:-} == ubuntu || ${ID_LIKE:-} == *ubuntu* || -n ${UBUNTU_CODENAME:-} ]]; then
    DOCKER_DISTRO=ubuntu
    DOCKER_CODENAME=${DOCKER_CODENAME:-${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}}
else
    DOCKER_DISTRO=debian
    DOCKER_CODENAME=${DOCKER_CODENAME:-${VERSION_CODENAME:-}}
fi
[[ $DOCKER_CODENAME =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    die 'Cannot determine a safe Docker suite. Use --docker-codename with the corresponding Debian/Ubuntu release.'
USER_ENTRY=$(getent passwd "$TARGET_USER") || die "User '$TARGET_USER' does not exist. Create it first."
IFS=: read -r TARGET_USER _ TARGET_UID TARGET_GID _ TARGET_HOME TARGET_SHELL <<<"$USER_ENTRY"
[[ $TARGET_HOME == /* && $TARGET_HOME != / && -d $TARGET_HOME ]] ||
    die "User '$TARGET_USER' needs an existing, absolute home directory other than /."

if ((EUID != 0)); then
    command -v sudo >/dev/null || die 'Run this script as root, or install sudo first.'
    SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
    SUDO_OPTIONS=()
    # Do not put the token in command-line arguments or send it to download hosts.
    [[ -z ${GITHUB_TOKEN:-} ]] || SUDO_OPTIONS+=(--preserve-env=GITHUB_TOKEN)
    [[ ! ${NO_COLOR+x} ]] || SUDO_OPTIONS+=(--preserve-env=NO_COLOR)
    exec sudo "${SUDO_OPTIONS[@]}" -- bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}" --user "$TARGET_USER"
fi

case "$(dpkg --print-architecture)" in
    amd64)
        ARCH=amd64
        RUST_ARCH=x86_64
        NVIM_ARCH=x86_64
        EZA_TARGET=x86_64-unknown-linux-musl
        ;;
    arm64)
        ARCH=arm64
        RUST_ARCH=aarch64
        NVIM_ARCH=arm64
        EZA_TARGET=aarch64-unknown-linux-gnu
        ;;
    *) die 'Only 64-bit amd64 and arm64 systems are supported.' ;;
esac

export PATH="$BIN_DIR:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CYAN='' GREEN='' YELLOW='' RED='' RESET=''
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]] && ((! PLAIN)); then
    CYAN=$'\033[1;36m' GREEN=$'\033[1;32m' YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m' RESET=$'\033[0m'
fi

printf '\n%sLinux Headless Setup%s\n' "$CYAN" "$RESET"
printf '  System: %s (%s)\n  User:   %s (%s)\n\n' "${PRETTY_NAME:-Linux}" "$ARCH" "$TARGET_USER" "$TARGET_HOME"
printf '  APT:    zsh, btop, and installation/runtime prerequisites\n'
printf '  GitHub: latest stable Starship, zoxide, eza, and Neovim\n'
printf '  Docker: Docker\047s official APT repo (%s/%s), including Compose + Buildx\n' "$DOCKER_DISTRO" "$DOCKER_CODENAME"
printf '  Shell:  preserve ~/.zshrc; add a managed integration block\n\n'
((! DOCKER_GROUP)) || printf '%sWarning:%s Docker group membership grants root-equivalent access.\n' "$YELLOW" "$RESET"
((! UPGRADE_DOCKER)) || printf '%sWarning:%s Upgrading Docker packages may restart the daemon/containers.\n' "$YELLOW" "$RESET"
if ((! YES)); then
    [[ -t 0 ]] || die 'No interactive input. Use --yes to accept the plan.'
    read -r -p 'Continue? [y/N] ' REPLY || REPLY=''
    if [[ ! $REPLY =~ ^([yY]|[yY][eE][sS])$ ]]; then
        printf 'Cancelled; no changes made.\n'
        exit 0
    fi
fi

command -v flock >/dev/null || die 'flock is required. Install the util-linux package first.'
mkdir -p /run/lock
exec 9>/run/lock/linux-headless-setup.lock
flock -n 9 || die 'Another linux-headless-setup process is running.'
WORK_DIR=$(mktemp -d -t linux-headless-setup.XXXXXXXX)
LOG_FILE=$(mktemp /var/log/linux-headless-setup.XXXXXXXX.log)
# Keep diagnostics readable only by root, and preserve terminal FDs during steps.
chmod 600 "$LOG_FILE"
exec 3>&1 4>&2

stop_spinner() {
    if [[ -n $SPINNER_PID ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=''
        printf '\r\033[2K' >&3
    fi
}

cleanup() {
    stop_spinner
    restore_service_policy
    # Every path here was created with mktemp by this invocation.
    local path
    for path in "${TEMP_PATHS[@]}"; do
        [[ ! -e $path && ! -L $path ]] || rm -rf -- "$path"
    done
    [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
}

has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null
}

on_error() {
    local status=$1 line=$2
    trap - ERR
    stop_spinner
    printf '\n%sFAILED%s [%s/%s] %s (line %s, exit %s)\n' \
        "$RED" "$RESET" "$STEP" "$TOTAL_STEPS" "$CURRENT_STEP" "$line" "$status" >&4
    tail -n 30 "$LOG_FILE" >&4 || true
    printf '\nFull log: %s\n' "$LOG_FILE" >&4
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'on_error "$?" "$LINENO"' ERR

result() {
    STEP_RESULT=$*
    printf '%s\n' "$STEP_RESULT"
}

run_step() {
    local title=$1
    shift
    STEP=$((STEP + 1))
    CURRENT_STEP=$title
    STEP_RESULT='Done'
    printf '\n[%s/%s] %s\n' "$STEP" "$TOTAL_STEPS" "$title" >>"$LOG_FILE"
    if [[ -t 1 && ${TERM:-dumb} != dumb ]] && ((! PLAIN)); then
        (
            trap - ERR EXIT
            trap 'exit 0' INT TERM
            frames=('|' '/' '-' "\\")
            i=0
            while :; do
                printf '\r%s[%s/%s]%s %s %s' "$CYAN" "$STEP" "$TOTAL_STEPS" "$RESET" "${frames[i % 4]}" "$title" >&3
                i=$((i + 1))
                sleep 0.12
            done
        ) &
        SPINNER_PID=$!
    else
        printf '[%s/%s] %s...\n' "$STEP" "$TOTAL_STEPS" "$title"
    fi
    # Deliberately not in an if/|| expression: Bash's errexit must stay active
    # inside installation functions, including failures before their last command.
    "$@" >>"$LOG_FILE" 2>&1
    stop_spinner
    printf '%s OK%s [%s/%s] %s - %s\n' "$GREEN" "$RESET" "$STEP" "$TOTAL_STEPS" "$title" "$STEP_RESULT"
}

package_installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]
}

install_apt_packages() {
    local package
    local missing=()
    for package in ca-certificates curl jq git tar xz-utils procps iptables util-linux passwd zsh btop; do
        package_installed "$package" || missing+=("$package")
    done
    if ((${#missing[@]} == 0)); then
        result 'zsh, btop, and prerequisites already installed'
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold \
        install --yes --no-remove --no-install-recommends "${missing[@]}"
    result "Installed ${#missing[@]} missing packages"
}

download() {
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --max-time 600 --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$2" "$1"
}

check_managed_link() {
    local destination=$1 prefix=$2
    if [[ -e $destination || -L $destination ]]; then
        [[ -L $destination && $(readlink -- "$destination") == "$prefix/"* ]] ||
            die "Refusing to replace unmanaged path: $destination. Move it aside yourself and rerun."
    fi
}

managed_link() {
    local source=$1 destination=$2 prefix=$3 temporary
    check_managed_link "$destination" "$prefix"
    if [[ -L $destination && $(readlink -- "$destination") == "$source" ]]; then
        return
    fi
    temporary=$(mktemp "${destination}.XXXXXXXX")
    TEMP_PATHS+=("$temporary")
    rm -- "$temporary"
    ln -s -- "$source" "$temporary"
    mv -Tf -- "$temporary" "$destination"
}

install_github_tool() {
    local app=$1 command=$2 repo=$3 pattern=$4
    local metadata="$WORK_DIR/$app.json" fields tag asset url digest release binary stage extracted candidate
    local headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    [[ -z ${GITHUB_TOKEN:-} ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    check_managed_link "$BIN_DIR/$command" "$APP_ROOT/$app"
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --max-time 60 --proto '=https' --proto-redir '=https' --tlsv1.2 "${headers[@]}" \
        --output "$metadata" "https://api.github.com/repos/$repo/releases/latest" ||
        die "Could not fetch the latest $repo release. Check HTTPS access; set GITHUB_TOKEN if the API rate limit was reached."
    fields=$(jq -er --arg pattern "$pattern" '
        select(.draft == false and .prerelease == false) |
        .tag_name as $tag | .assets[] | select(.name | test($pattern)) |
        [$tag, .name, .browser_download_url, (.digest // "")] | @tsv
    ' "$metadata") || die "No matching stable release asset for $repo ($pattern)."
    [[ $fields != *$'\n'* ]] || die "Ambiguous release assets for $repo."
    IFS=$'\t' read -r tag asset url digest <<<"$fields"
    [[ $tag =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Unsafe release tag from $repo."
    [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]] || die "$repo did not publish a SHA-256 digest for $asset."
    [[ $url == "https://github.com/$repo/releases/download/"* ]] || die "Unexpected asset URL from $repo."
    release="$APP_ROOT/$app/$tag-$ARCH"
    binary="$release/$command"
    [[ $app != neovim ]] || binary="$release/bin/nvim"
    if [[ ! -d $release ]]; then
        extracted="$WORK_DIR/$app-extracted"
        mkdir -p "$extracted" "$APP_ROOT/$app" "$BIN_DIR"
        download "$url" "$WORK_DIR/$asset"
        printf '%s  %s\n' "${digest#sha256:}" "$WORK_DIR/$asset" | sha256sum --check --status ||
            die "SHA-256 verification failed for $asset; the download was not installed."
        tar --extract --gzip --file "$WORK_DIR/$asset" --directory "$extracted" --no-same-owner --no-same-permissions
        stage=$(mktemp -d "$APP_ROOT/$app/.install.XXXXXXXX")
        TEMP_PATHS+=("$stage")
        if [[ $app == neovim ]]; then
            [[ -x $extracted/nvim-linux-$NVIM_ARCH/bin/nvim ]] || die 'Unexpected Neovim archive layout.'
            cp -a "$extracted/nvim-linux-$NVIM_ARCH/." "$stage/"
            candidate="$stage/bin/nvim"
        else
            candidate=$(find "$extracted" -type f -name "$command" -print -quit)
            [[ -n $candidate ]] || die "No $command binary in $asset."
            install -m 0755 "$candidate" "$stage/$command"
            candidate="$stage/$command"
        fi
        "$candidate" --version
        printf '%s\n%s\n' "$url" "$digest" >"$stage/.source"
        # mktemp directories start at 0700; these system-wide binaries must be
        # traversable by the configured user, not only by root.
        chmod 0755 "$stage"
        mv -T -- "$stage" "$release"
        managed_link "$binary" "$BIN_DIR/$command" "$APP_ROOT/$app"
        result "$tag installed (SHA-256 verified)"
    else
        [[ -x $binary && -f $release/.source ]] || die "Incomplete release directory: $release. Move it aside and rerun."
        if [[ $(stat -c %a "$release") != 755 ]]; then
            chmod 0755 "$release"
        fi
        "$binary" --version
        managed_link "$binary" "$BIN_DIR/$command" "$APP_ROOT/$app"
        result "Already current ($tag)"
    fi
}

check_docker_conflicts() {
    local package executable path
    local conflicts=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
        podman-docker containerd runc moby-engine moby-cli moby-containerd moby-runc; do
        package_installed "$package" && conflicts+=("$package")
    done
    if ((${#conflicts[@]})); then
        die "Conflicting distribution Docker/runtime packages: ${conflicts[*]}. Review and remove them before rerunning, per Docker's installation docs. Nothing was removed."
    fi
    for executable in docker dockerd; do
        path=$(command -v "$executable" || true)
        if [[ -n $path ]]; then
            [[ $(readlink -f "$path") == "$(readlink -f "/usr/bin/$executable")" ]] ||
                die "Unmanaged $executable at $path would shadow the official APT binary. Move it aside yourself first."
        fi
    done
}

restore_service_policy() {
    if ((POLICY_INSTALLED)); then
        rm -f -- /usr/sbin/policy-rc.d
        if [[ -n $POLICY_BACKUP ]]; then
            mv -T -- "$POLICY_BACKUP" /usr/sbin/policy-rc.d
        fi
        POLICY_INSTALLED=0
        POLICY_BACKUP=''
    fi
}

suppress_docker_autostart() {
    # APT post-install hooks otherwise start daemons even with --no-start-docker.
    # Preserve an existing policy, including a symlink, and delegate other services.
    if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
        POLICY_BACKUP=$(mktemp /usr/sbin/.headless-policy.XXXXXXXX)
        mv -Tf -- /usr/sbin/policy-rc.d "$POLICY_BACKUP"
    fi
    POLICY_INSTALLED=1
    cat >/usr/sbin/policy-rc.d <<EOF
#!/bin/sh
for argument do
    case "\$argument" in docker|docker.service|containerd|containerd.service) exit 101 ;; esac
done
if [ -n '$POLICY_BACKUP' ] && [ -x '$POLICY_BACKUP' ]; then
    exec '$POLICY_BACKUP' "\$@"
fi
exit 0
EOF
    chmod 755 /usr/sbin/policy-rc.d
}

install_docker() {
    local key=/etc/apt/keyrings/docker.asc source=/etc/apt/sources.list.d/docker.sources
    local uri="https://download.docker.com/linux/$DOCKER_DISTRO" existing package candidate
    local refresh=0 missing=()
    local packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    existing=$(grep -El '^[[:space:]]*(deb[[:space:]].*|URIs:[[:space:]]*)https://download\.docker\.com/linux/' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)
    # Reuse an existing official repository rather than introduce duplicate entries
    # or a conflicting Signed-By setting. Only rewrite our own managed source.
    if [[ -z $existing ]] || { [[ $existing == "$source" ]] && grep -Fxq "$MANAGED_MARKER" "$source"; }; then
        mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
        if [[ ! -f $key ]]; then
            download "$uri/gpg" "$WORK_DIR/docker.asc"
            grep -Fxq -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$WORK_DIR/docker.asc" || die 'Invalid Docker signing key.'
            install -m 0644 "$WORK_DIR/docker.asc" "$key"
            refresh=1
        fi
        cat >"$WORK_DIR/docker.sources" <<EOF
$MANAGED_MARKER
Types: deb
URIs: $uri
Suites: $DOCKER_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: $key
EOF
        if ! cmp -s "$WORK_DIR/docker.sources" "$source"; then
            [[ ! -e $source ]] || grep -Fxq "$MANAGED_MARKER" "$source" ||
                die "Refusing to replace unmanaged repository file: $source"
            install -m 0644 "$WORK_DIR/docker.sources" "$source"
            refresh=1
        fi
    else
        printf 'Reusing existing official Docker repository: %s\n' "$existing"
    fi
    for package in "${packages[@]}"; do
        package_installed "$package" || missing+=("$package")
        [[ -n $(apt-cache madison "$package") ]] || refresh=1
    done
    if ((refresh || UPGRADE_DOCKER || ${#missing[@]})); then
        apt-get -o DPkg::Lock::Timeout=120 update
    fi
    # Check provenance rather than accidentally installing a similarly named
    # package from a third-party repository or an incompatible distro suite.
    for package in "${packages[@]}"; do
        candidate=$(apt-cache policy "$package" | sed -n 's/^[[:space:]]*Candidate: //p')
        [[ -n $candidate && $candidate != '(none)' ]] || die "No $package candidate. Check Docker support for $DOCKER_DISTRO/$DOCKER_CODENAME."
        apt-cache madison "$package" | awk -F '|' -v version="$candidate" -v repo="$uri" -v suite="$DOCKER_CODENAME/stable" '
            { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2) }
            $2 == version && index($3, repo " ") && index($3, suite " ") { found = 1 }
            END { exit !found }
        ' || die "$package candidate is not from Docker's official $DOCKER_DISTRO/$DOCKER_CODENAME stable repository."
    done
    if ((${#missing[@]} == 0 && ! UPGRADE_DOCKER)); then
        result 'Official Docker Engine, Compose, and Buildx already installed'
        return
    fi
    if ((! START_DOCKER)) || ! has_systemd; then
        suppress_docker_autostart
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold \
        install --yes --no-remove --no-install-recommends "${packages[@]}"
    restore_service_policy
    result "Docker Engine, Compose, and Buildx installed from Docker's official APT repository"
}

configure_docker_service() {
    if ((! START_DOCKER)); then
        DOCKER_SERVICE_STATE=not-started
        result 'Automatic starts suppressed; daemon startup deliberately skipped'
    elif ! has_systemd; then
        DOCKER_SERVICE_STATE=no-systemd
        result 'Package service installed; no running systemd, so the daemon was not started'
    else
        systemctl enable --now containerd docker
        systemctl is-active --quiet docker
        env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock info
        DOCKER_SERVICE_STATE=running
        result 'Docker enabled, running, and responding on its local Unix socket'
    fi
}

configure_shell() {
    local config_dir="$TARGET_HOME/.config/linux-headless-setup" zshrc="$TARGET_HOME/.zshrc"
    local start='# >>> linux-headless-setup >>>' end='# <<< linux-headless-setup <<<' backup directory
    for directory in "$TARGET_HOME/.config" "$config_dir"; do
        [[ -d $directory ]] || install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$directory"
    done
    cat >"$WORK_DIR/zsh-integration" <<'EOF'
# Managed by linux-headless-setup.
# Put personal customizations in ~/.zshrc, not this generated file.
typeset -U path PATH
path=(/usr/local/bin "$HOME/.local/bin" $path)
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
(( HISTSIZE >= 10000 )) || HISTSIZE=10000
(( SAVEHIST >= 10000 )) || SAVEHIST=10000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS INTERACTIVE_COMMENTS

autoload -Uz compinit
(( $+functions[compdef] )) || compinit

if (( $+commands[eza] )); then
    (( $+aliases[ls] )) || alias ls='eza --group-directories-first'
    (( $+aliases[ll] )) || alias ll='eza -lh --group-directories-first'
    (( $+aliases[la] )) || alias la='eza -lah --group-directories-first'
    (( $+aliases[lt] )) || alias lt='eza --tree --level=2'
fi
if (( $+commands[zoxide] )); then
    eval "$(zoxide init zsh)"
fi
if (( $+commands[starship] )); then
    eval "$(starship init zsh)"
fi
EOF
    if ! cmp -s "$WORK_DIR/zsh-integration" "$config_dir/zshrc"; then
        if [[ -e $config_dir/zshrc || -L $config_dir/zshrc ]]; then
            grep -Fxq "$MANAGED_MARKER" "$config_dir/zshrc" || die "Refusing to replace unmanaged file: $config_dir/zshrc"
        fi
        install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$WORK_DIR/zsh-integration" "$config_dir/zshrc"
    fi
    cat >"$WORK_DIR/zsh-source-block" <<'EOF'
# >>> linux-headless-setup >>>
if [[ -r "$HOME/.config/linux-headless-setup/zshrc" ]]; then
    source "$HOME/.config/linux-headless-setup/zshrc"
fi
# <<< linux-headless-setup <<<
EOF
    [[ ! -L $zshrc || -e $zshrc ]] || die "Broken .zshrc symlink: $zshrc"
    [[ ! -e $zshrc || -f $zshrc ]] || die "Not a regular file: $zshrc"
    if [[ -e $zshrc ]]; then
        # Replace our block in place, leaving other lines (and symlinks) intact.
        awk -v start="$start" -v end="$end" -v block="$WORK_DIR/zsh-source-block" '
            function emit( line) {
                while ((getline line < block) > 0) print line
                close(block)
            }
            $0 == start {
                if (inside) { bad = 1; exit 2 }
                if (!seen) emit()
                seen = 1; inside = 1; next
            }
            $0 == end {
                if (!inside) { bad = 1; exit 2 }
                inside = 0; next
            }
            !inside { print }
            END {
                if (bad || inside) exit 2
                if (!seen) { if (NR) print ""; emit() }
            }
        ' "$zshrc" >"$WORK_DIR/zshrc"
    else
        cp "$WORK_DIR/zsh-source-block" "$WORK_DIR/zshrc"
    fi
    if ! cmp -s "$WORK_DIR/zshrc" "$zshrc"; then
        if [[ -e $zshrc ]]; then
            backup=$(mktemp "$zshrc.bak.XXXXXXXX")
            cat "$zshrc" >"$backup"
            chown "$TARGET_UID:$TARGET_GID" "$backup"
            printf 'Backed up existing .zshrc to %s\n' "$backup"
            cat "$WORK_DIR/zshrc" >"$zshrc"
        else
            install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$WORK_DIR/zshrc" "$zshrc"
        fi
    fi
    runuser -u "$TARGET_USER" -- zsh -fn "$config_dir/zshrc"
    runuser -u "$TARGET_USER" -- zsh -fn "$zshrc"
    if ((CHANGE_SHELL)); then
        local zsh_bin
        zsh_bin=$(command -v zsh)
        grep -Fxq "$zsh_bin" /etc/shells || printf '%s\n' "$zsh_bin" >>/etc/shells
        [[ $TARGET_SHELL == "$zsh_bin" ]] || usermod --shell "$zsh_bin" "$TARGET_USER"
    fi
    if ((DOCKER_GROUP && TARGET_UID != 0)); then
        getent group docker >/dev/null || groupadd --system docker
        if [[ " $(id -nG "$TARGET_USER") " != *' docker '* ]]; then
            usermod --append --groups docker "$TARGET_USER"
        fi
    fi
    result 'Shell integration ready; existing settings and aliases preserved'
}

verify_tools() {
    local command executable
    for command in zsh starship zoxide eza btop nvim docker; do
        executable=$(command -v "$command")
        printf '%s\n' "$executable"
        runuser -u "$TARGET_USER" -- "$executable" --version
    done
    runuser -u "$TARGET_USER" -- /usr/bin/docker compose version
    runuser -u "$TARGET_USER" -- /usr/bin/docker buildx version
    # No plugins, user init, or ShaDa writes during the smoke check.
    runuser -u "$TARGET_USER" -- "$BIN_DIR/nvim" --headless -u NONE -i NONE '+quit'
    result 'All seven tools verified; Neovim headless startup passed'
}

printf '\nDetailed log: %s\n\n' "$LOG_FILE"
check_docker_conflicts
run_step 'Install zsh, btop, and prerequisites' install_apt_packages
run_step 'Install Starship' install_github_tool starship starship starship/starship "^starship-$RUST_ARCH-unknown-linux-musl\\.tar\\.gz$"
run_step 'Install zoxide' install_github_tool zoxide zoxide ajeetdsouza/zoxide "^zoxide-[0-9.]+-$RUST_ARCH-unknown-linux-musl\\.tar\\.gz$"
run_step 'Install eza' install_github_tool eza eza eza-community/eza "^eza_$EZA_TARGET\\.tar\\.gz$"
run_step 'Install latest stable Neovim' install_github_tool neovim nvim neovim/neovim "^nvim-linux-$NVIM_ARCH\\.tar\\.gz$"
run_step 'Install Docker from its official APT repository' install_docker
run_step 'Configure Docker service' configure_docker_service
run_step 'Configure user shell and permissions' configure_shell
run_step 'Verify installation' verify_tools

printf '\n%sSetup complete.%s\n' "$GREEN" "$RESET"
if ((CHANGE_SHELL)); then
    printf 'Log out and back in to use zsh as your login shell, or run: exec zsh\n'
else
    printf 'Start the configured shell with: zsh\n'
fi
if ((DOCKER_GROUP && TARGET_UID != 0)); then
    printf 'Log out and back in before using Docker without sudo.\n'
fi
case "$DOCKER_SERVICE_STATE" in
    running) printf 'Docker is running. Optional end-to-end check: sudo docker run --rm hello-world\n' ;;
    not-started | no-systemd)
        printf 'Docker daemon startup was skipped. On a systemd host: sudo systemctl enable --now docker\n'
        printf 'Without systemd, start Docker using your init system or a supervisor.\n'
        ;;
esac
printf 'Update Docker later through APT, or run: sudo bash %q --user %q --yes --upgrade-docker\n' \
    "$(readlink -f -- "${BASH_SOURCE[0]}")" "$TARGET_USER"
printf 'Full log: %s\n' "$LOG_FILE"
