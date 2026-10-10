#!/usr/bin/env bash
# Set up a Debian-based headless workstation, preserving backups of user dotfiles.
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
CONFIGURE_NEOVIM=1
RICE_REPO=https://github.com/guneet-xyz/rice.git
DOCKER_CODENAME=''
TARGET_USER=${SUDO_USER:-$(id -un)}
WORK_DIR=''
LOG_FILE=''
SPINNER_PID=''
OUTPUT_DONE=''
CURRENT_STEP=''
STEP_RESULT=''
STEP=0
TOTAL_STEPS=17
DOCKER_SERVICE_STATE=not-started
POLICY_INSTALLED=0
POLICY_BACKUP=''
TEMP_PATHS=()
ORIGINAL_ARGS=("$@")
NVIM_MASON_PACKAGES=(lua-language-server python-lsp-server json-lsp typescript-language-server
    stylua shfmt clang-format gofumpt yamlfmt isort ruff mdformat helm-ls yaml-language-server)
NVIM_MASON_COMMANDS=(lua-language-server pylsp vscode-json-language-server typescript-language-server
    stylua shfmt clang-format gofumpt yamlfmt isort ruff mdformat helm_ls yaml-language-server)
NVIM_PARSERS=(bash c diff html lua luadoc markdown markdown_inline query vim vimdoc
    typescript tsx javascript yaml helm python go json cpp java astro)

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Install and configure zsh, Starship, zoxide, eza, btop, Neovim, Docker, Git, and Delta.
Supports Debian-based Linux on amd64 and arm64. Needs root or sudo.

  -y, --yes             Accept the installation plan without prompting.
  --user USER           Configure this existing user (default: invoking user).
  --no-change-shell     Do not make zsh the user's login shell.
  --docker-group        Grant the user root-equivalent Docker group access.
  --no-start-docker     Suppress Docker/containerd starts, including APT hooks.
  --upgrade-docker      Upgrade official Docker packages (may restart Docker).
  --no-neovim-config    Keep Neovim config; skip rice and editor dependency setup.
  --docker-codename NAME  Use a base Debian/Ubuntu codename for a derivative.
  --plain               Disable colors and the animated spinner.
  -h, --help            Show this help.

Neovim and the other GitHub tools track the latest stable release on reruns.
Neovim uses guneet-xyz/rice's default profile; existing configs are backed up.
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
        --no-neovim-config) CONFIGURE_NEOVIM=0 ;;
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
    [[ -n ${BASH_SOURCE[0]:-} ]] ||
        die 'When piping the script, run it as root (e.g. curl ... | sudo bash -s -- --yes).'
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
        TREE_SITTER_ARCH=x64
        EZA_TARGET=x86_64-unknown-linux-musl
        DELTA_TARGET=x86_64-unknown-linux-musl
        ;;
    arm64)
        ARCH=arm64
        RUST_ARCH=aarch64
        NVIM_ARCH=arm64
        TREE_SITTER_ARCH=arm64
        EZA_TARGET=aarch64-unknown-linux-gnu
        DELTA_TARGET=aarch64-unknown-linux-gnu
        ;;
    *) die 'Only 64-bit amd64 and arm64 systems are supported.' ;;
esac

export PATH="$BIN_DIR:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CYAN='' GREEN='' YELLOW='' RED='' DIM='' RESET=''
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]] && ((! PLAIN)); then
    CYAN=$'\033[1;36m' GREEN=$'\033[1;32m' YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m' RESET=$'\033[0m'
    DIM=$'\033[2;90m'
fi

printf '\n%sLinux Headless Setup%s\n' "$CYAN" "$RESET"
printf '  System: %s (%s)\n  User:   %s (%s)\n\n' "${PRETTY_NAME:-Linux}" "$ARCH" "$TARGET_USER" "$TARGET_HOME"
printf '  APT:    Git, less, zsh, btop, and installation/runtime prerequisites\n'
printf '  GitHub: latest stable Starship, zoxide, eza, Neovim, and Delta\n'
printf '  Git:    gs/gl/gd shell aliases + Delta diff pager; preserve existing settings\n'
if ((CONFIGURE_NEOVIM)); then
    printf '  Neovim: rice profile, Node LTS, Go, Python, formatters, and parsers\n'
    printf '          back up existing config; bootstrap tools as the target user\n'
else
    printf '  Neovim: binary only; existing config will not be changed\n'
fi
printf '  Docker: Docker\047s official APT repo (%s/%s), including Compose + Buildx\n' "$DOCKER_DISTRO" "$DOCKER_CODENAME"
printf '  Shell:  preserve ~/.zshrc; add integration and eza icons\n\n'
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
        # The renderer reads a regular file, not a pipeline: even an ERR trap
        # inside a redirected function can drain output without waiting for EOF
        # on its own still-open stdout. It owns all live terminal writes.
        local status=0
        touch -- "$OUTPUT_DONE"
        wait "$SPINNER_PID" || status=$?
        SPINNER_PID=''
        OUTPUT_DONE=''
        return "$status"
    fi
}

print_log_line() {
    local text=$1 fd=${2:-3}
    local ansi_pattern=$'\033''\[[0-?]*[ -/]*[@-~]'
    # Strip command styling/control sequences only from terminal output. The
    # persistent log retains the original bytes for troubleshooting.
    while [[ $text =~ $ansi_pattern ]]; do
        text=${text//"${BASH_REMATCH[0]}"/}
    done
    text=${text//$'\r'/}
    text=${text//$'\033'/?}
    printf '%s%s%s\n' "$DIM" "$text" "$RESET" >&"$fd"
}

render_step_output() {
    local output=$1 done=$2 title=$3 animated=$4
    local line pending='' frame=0 width=${COLUMNS:-80} terminal_size
    local frames=('|' '/' '-' "\\")
    local status="[$STEP/$TOTAL_STEPS] $title"
    if ((animated)) && terminal_size=$(stty size <&3 2>/dev/null); then
        [[ ${terminal_size##* } == 0 ]] || width=${terminal_size##* }
    fi
    [[ $width =~ ^[0-9]+$ ]] && ((width >= 10)) || width=80
    # Keep the status on one row; long command output can wrap normally.
    status=${status:0:width-3}
    exec 5<"$output"
    trap - ERR EXIT
    if ((animated)); then
        trap 'printf "\r\033[2K\033[?25h" >&3; exit 0' INT TERM
        printf '\033[?25l\n%s%s %s%s' "$CYAN" "${frames[0]}" "$status" "$RESET" >&3
    fi
    while :; do
        # Bash's read returns partial data at EOF. Keep it until a newline or
        # step completion, and log the original bytes without ANSI decoration.
        while :; do
            line=''
            if IFS= read -r line <&5; then
                printf '%s\n' "$line" >>"$LOG_FILE"
                pending+=$line
            else
                if [[ -n $line ]]; then
                    printf '%s' "$line" >>"$LOG_FILE"
                    pending+=$line
                fi
                [[ -e $done && -n $pending ]] || break
            fi
            if ((animated)); then
                printf '\r\033[2K\033[1A\r\033[2K' >&3
                print_log_line "$pending"
                printf '\n%s%s %s%s' "$CYAN" "${frames[frame % 4]}" "$status" "$RESET" >&3
            else
                print_log_line "$pending"
            fi
            pending=''
        done
        [[ ! -e $done ]] || break
        if ((animated)); then
            frame=$((frame + 1))
            printf '\r\033[2K%s%s %s%s' "$CYAN" "${frames[frame % 4]}" "$status" "$RESET" >&3
        fi
        sleep 0.12
    done
    if ((animated)); then
        printf '\r\033[2K\033[?25h' >&3
    fi
}

cleanup() {
    stop_spinner || true
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
    local status=$1 line=$2 log_line
    trap - ERR
    stop_spinner || true
    printf '\n%sFAILED%s [%s/%s] %s (line %s, exit %s)\n' \
        "$RED" "$RESET" "$STEP" "$TOTAL_STEPS" "$CURRENT_STEP" "$line" "$status" >&4
    while IFS= read -r log_line; do
        print_log_line "$log_line" 4
    done < <(tail -n 30 "$LOG_FILE")
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
    local output animated=0
    shift
    STEP=$((STEP + 1))
    CURRENT_STEP=$title
    STEP_RESULT='Done'
    printf '\n[%s/%s] %s\n' "$STEP" "$TOTAL_STEPS" "$title" >>"$LOG_FILE"
    output="$WORK_DIR/step-$STEP.output"
    OUTPUT_DONE="$WORK_DIR/step-$STEP.done"
    : >"$output"
    if [[ -t 1 && ${TERM:-dumb} != dumb ]] && ((! PLAIN)); then
        animated=1
    else
        printf '[%s/%s] %s...\n' "$STEP" "$TOTAL_STEPS" "$title"
    fi
    render_step_output "$output" "$OUTPUT_DONE" "$title" "$animated" &
    SPINNER_PID=$!
    # Deliberately not in an if/|| expression: Bash's errexit must stay active
    # inside installation functions, including failures before their last command.
    # Installation commands must not consume the script stream when using bash -s.
    "$@" >>"$output" 2>&1 </dev/null
    stop_spinner
    rm -- "$output" "$WORK_DIR/step-$STEP.done"
    printf '%s OK%s [%s/%s] %s - %s\n' "$GREEN" "$RESET" "$STEP" "$TOTAL_STEPS" "$title" "$STEP_RESULT"
}

package_installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]
}

as_user() {
    # Do not inherit root's working directory or XDG paths when configuring a
    # different account. Config files and Git operations run as their owner.
    # The child shell, not this root process, expands HOME and its arguments.
    # shellcheck disable=SC2016
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" \
        XDG_CONFIG_HOME="$TARGET_HOME/.config" XDG_DATA_HOME="$TARGET_HOME/.local/share" \
        XDG_CACHE_HOME="$TARGET_HOME/.cache" XDG_STATE_HOME="$TARGET_HOME/.local/state" \
        PATH="$BIN_DIR:$TARGET_HOME/.local/bin:$TARGET_HOME/.local/share/nvim/mason/bin:$PATH" \
        NPM_CONFIG_PREFIX="$TARGET_HOME/.local/share/linux-headless-setup/npm" \
        sh -c 'cd "$HOME" && exec "$@"' linux-headless-setup "$@"
}

install_apt_packages() {
    local package
    local missing=()
    local packages=(ca-certificates curl jq git less tar xz-utils procps iptables util-linux passwd zsh btop)
    if ((CONFIGURE_NEOVIM)); then
        packages+=(build-essential unzip ripgrep python3 python3-venv python3-pip xclip wl-clipboard)
    fi
    for package in "${packages[@]}"; do
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
    local archive_type=${5:-tar}
    local metadata="$WORK_DIR/$app.json" fields tag asset url digest release binary stage extracted candidate
    local built_locally=0
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
        if [[ $archive_type == gzip ]]; then
            gzip --decompress --stdout "$WORK_DIR/$asset" >"$extracted/$command"
        else
            tar --extract --gzip --file "$WORK_DIR/$asset" --directory "$extracted" --no-same-owner --no-same-permissions
        fi
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
        if [[ $app == tree-sitter ]]; then
            if ! "$candidate" --version; then
                build_treesitter_cli "$candidate" "$tag"
                "$candidate" --version
                built_locally=1
            fi
        else
            "$candidate" --version
        fi
        printf '%s\n%s\n' "$url" "$digest" >"$stage/.source"
        if ((built_locally)); then
            printf 'Built locally from tree-sitter-cli %s using Cargo --locked.\n' "${tag#v}" >>"$stage/.source"
        fi
        # mktemp directories start at 0700; these system-wide binaries must be
        # traversable by the configured user, not only by root.
        chmod 0755 "$stage"
        mv -T -- "$stage" "$release"
        managed_link "$binary" "$BIN_DIR/$command" "$APP_ROOT/$app"
        rm -rf -- "$extracted"
        rm -- "$WORK_DIR/$asset"
        if ((built_locally)); then
            result "$tag built for local system libraries (Cargo checksums verified)"
        else
            result "$tag installed (SHA-256 verified)"
        fi
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

install_verified_runtime() {
    local app=$1 version=$2 asset=$3 url=$4 checksum=$5 archive_root=$6
    local release="$APP_ROOT/$app/$version-$ARCH" extracted stage name
    local commands=()
    [[ $version =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && $checksum =~ ^[a-fA-F0-9]{64}$ ]] ||
        die "Invalid official $app release metadata."
    case "$app" in
        nodejs) commands=(node npm npx) ;;
        go) commands=(go gofmt) ;;
        helm) commands=(helm) ;;
        *) die "Unknown runtime: $app" ;;
    esac
    for name in "${commands[@]}"; do
        check_managed_link "$BIN_DIR/$name" "$APP_ROOT/$app"
    done
    if [[ ! -d $release ]]; then
        mkdir -p "$APP_ROOT/$app" "$BIN_DIR"
        extracted="$WORK_DIR/$app-runtime"
        mkdir -p "$extracted"
        download "$url" "$WORK_DIR/$asset"
        printf '%s  %s\n' "$checksum" "$WORK_DIR/$asset" | sha256sum --check --status ||
            die "$app archive checksum verification failed."
        tar --extract --file "$WORK_DIR/$asset" --directory "$extracted" --no-same-owner --no-same-permissions
        stage=$(mktemp -d "$APP_ROOT/$app/.install.XXXXXXXX")
        TEMP_PATHS+=("$stage")
        if [[ $app == helm ]]; then
            [[ -f $extracted/$archive_root/helm ]] || die 'Unexpected Helm archive layout.'
            mkdir "$stage/bin"
            install -m 0755 "$extracted/$archive_root/helm" "$stage/bin/helm"
        else
            [[ -d $extracted/$archive_root/bin ]] || die "Unexpected $app archive layout."
            cp -a "$extracted/$archive_root/." "$stage/"
        fi
        if [[ $app == nodejs ]]; then
            "$stage/bin/node" --version
        elif [[ $app == helm ]]; then
            "$stage/bin/helm" version --short
        else
            "$stage/bin/go" version
        fi
        printf '%s\n%s\n' "$url" "$checksum" >"$stage/.source"
        chmod 0755 "$stage"
        mv -T -- "$stage" "$release"
        rm -rf -- "$extracted"
        rm -- "$WORK_DIR/$asset"
    fi
    [[ -f $release/.source ]] || die "Incomplete runtime directory: $release"
    for name in "${commands[@]}"; do
        [[ -x $release/bin/$name ]] || die "Missing runtime executable: $release/bin/$name"
        managed_link "$release/bin/$name" "$BIN_DIR/$name" "$APP_ROOT/$app"
    done
    if [[ $app == nodejs ]]; then
        as_user node --version
        as_user npm --version
        as_user npx --version
    elif [[ $app == helm ]]; then
        as_user helm version --short
    else
        as_user go version
    fi
    result "$version ready (official archive; SHA-256 verified)"
}

install_nodejs() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; Neovim configuration disabled'
        return
    fi
    local version asset checksum
    download https://nodejs.org/dist/index.json "$WORK_DIR/node-index.json"
    version=$(jq -er --arg platform "linux-$TREE_SITTER_ARCH" '
        [.[] | select(.lts | type == "string") | select(.files | index($platform))][0].version
    ' "$WORK_DIR/node-index.json")
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid Node LTS version.'
    asset="node-$version-linux-$TREE_SITTER_ARCH.tar.xz"
    download "https://nodejs.org/dist/$version/SHASUMS256.txt" "$WORK_DIR/node-checksums.txt"
    checksum=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$WORK_DIR/node-checksums.txt")
    install_verified_runtime nodejs "$version" "$asset" "https://nodejs.org/dist/$version/$asset" \
        "$checksum" "node-$version-linux-$TREE_SITTER_ARCH"
}

install_helm() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; Neovim configuration disabled'
        return
    fi
    local version asset checksum
    local headers=(-H 'Accept: application/vnd.github+json')
    [[ -z ${GITHUB_TOKEN:-} ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
        --proto '=https' --proto-redir '=https' "${headers[@]}" \
        'https://api.github.com/repos/helm/helm/releases?per_page=100' --output "$WORK_DIR/helm-releases.json"
    # Keep the compatible Helm 3 line for the current helm-ls profile.
    version=$(jq -er '[.[] | select(.draft == false and .prerelease == false) |
        select(.tag_name | test("^v3\\.[0-9]+\\.[0-9]+$"))][0].tag_name' "$WORK_DIR/helm-releases.json")
    [[ $version =~ ^v3\.[0-9]+\.[0-9]+$ ]] || die 'Invalid official Helm 3 release metadata.'
    asset="helm-$version-linux-$ARCH.tar.gz"
    download "https://get.helm.sh/$asset.sha256sum" "$WORK_DIR/helm.sha256sum"
    checksum=$(awk 'NR == 1 { print $1 }' "$WORK_DIR/helm.sha256sum")
    install_verified_runtime helm "$version" "$asset" "https://get.helm.sh/$asset" "$checksum" "linux-$ARCH"
}

install_go() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; Neovim configuration disabled'
        return
    fi
    local fields version asset checksum
    download 'https://go.dev/dl/?mode=json' "$WORK_DIR/go-index.json"
    fields=$(jq -er --arg arch "$ARCH" '
        [.[] | select(.stable == true)][0] |
        .version as $version | .files[] |
        select(.os == "linux" and .arch == $arch and .kind == "archive") |
        [$version, .filename, .sha256] | @tsv
    ' "$WORK_DIR/go-index.json")
    IFS=$'\t' read -r version asset checksum <<<"$fields"
    [[ $version =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ && $asset == "$version.linux-$ARCH.tar.gz" ]] ||
        die 'Invalid official Go release metadata.'
    install_verified_runtime go "$version" "$asset" "https://go.dev/dl/$asset" "$checksum" go
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

build_treesitter_cli() {
    local destination=$1 tag=$2 build checksum
    local bootstrap="https://static.rust-lang.org/rustup/dist/$RUST_ARCH-unknown-linux-gnu/rustup-init"
    printf 'Official Tree-sitter binary is incompatible; building for this host as %s.\n' "$TARGET_USER"
    build=$(as_user mktemp -d -t linux-headless-setup-tree-sitter.XXXXXXXX)
    TEMP_PATHS+=("$build")
    # Keep Rust entirely inside this temporary directory: no changes to the
    # user's existing toolchains, shell profiles, or ~/.cargo configuration.
    download "$bootstrap" "$WORK_DIR/rustup-init"
    download "$bootstrap.sha256" "$WORK_DIR/rustup-init.sha256"
    checksum=$(awk 'NR == 1 { print $1 }' "$WORK_DIR/rustup-init.sha256")
    [[ $checksum =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid official Rust bootstrap checksum.'
    printf '%s  %s\n' "$checksum" "$WORK_DIR/rustup-init" | sha256sum --check --status ||
        die 'Rust bootstrap SHA-256 verification failed.'
    install -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$WORK_DIR/rustup-init" "$build/rustup-init"
    as_user env -u GITHUB_TOKEN CARGO_HOME="$build/cargo" RUSTUP_HOME="$build/rustup" \
        RUSTUP_INIT_SKIP_PATH_CHECK=yes "$build/rustup-init" -y --profile minimal \
        --no-modify-path --default-toolchain stable
    as_user env -u GITHUB_TOKEN CARGO_HOME="$build/cargo" RUSTUP_HOME="$build/rustup" \
        PATH="$build/cargo/bin:$PATH" RUSTUP_TOOLCHAIN=stable \
        CARGO_BUILD_JOBS=2 CARGO_TERM_COLOR=never "$build/cargo/bin/cargo" install \
        tree-sitter-cli --version "${tag#v}" --locked --no-default-features --root "$build/install"
    install -m 0755 "$build/install/bin/tree-sitter" "$destination"
    # The compiler and build cache are no longer needed once the CLI is copied.
    rm -rf -- "$build"
}

install_treesitter_cli() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; Neovim configuration disabled'
        return
    fi
    install_github_tool tree-sitter tree-sitter tree-sitter/tree-sitter \
        "^tree-sitter-linux-$TREE_SITTER_ARCH\\.gz$" gzip
}

configure_neovim() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; existing Neovim configuration left untouched'
        return
    fi
    local cache="$TARGET_HOME/.local/share/linux-headless-setup"
    local checkout="$TARGET_HOME/.local/share/linux-headless-setup/rice"
    local config="$TARGET_HOME/.config/nvim" source directory stage backup origin revision
    for directory in "$TARGET_HOME/.local" "$TARGET_HOME/.local/share" "$cache" "$TARGET_HOME/.config"; do
        [[ -d $directory ]] || install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$directory"
    done
    if [[ -e $checkout || -L $checkout ]]; then
        [[ -e $checkout/.git && ! -L $checkout ]] || die "Refusing to replace unmanaged path: $checkout"
        origin=$(as_user git -C "$checkout" remote get-url origin)
        [[ $origin == "$RICE_REPO" ]] || die "Unexpected repository at $checkout: $origin"
        printf 'Reusing rice checkout without fetching or overwriting local edits.\n'
    else
        stage=$(as_user mktemp -d "$cache/.rice.XXXXXXXX")
        TEMP_PATHS+=("$stage")
        as_user env GIT_TERMINAL_PROMPT=0 git clone --depth 1 --filter=blob:none --sparse "$RICE_REPO" "$stage"
        as_user git -C "$stage" sparse-checkout set nvim
        [[ -f $stage/nvim/.config/nvim/init.lua && -d $stage/nvim/.config/nvim/lua ]] ||
            die 'The rice default Neovim profile was not found at nvim/.config/nvim.'
        mv -T -- "$stage" "$checkout"
    fi
    source="$checkout/nvim/.config/nvim"
    [[ -f $source/init.lua && -d $source/lua ]] || die "Incomplete Neovim profile: $source"
    # Compile (do not execute) every Lua file before replacing the current config.
    as_user env NVIM_APPNAME=nvim NVIM_CONFIG_DIR="$source" "$BIN_DIR/nvim" --headless -u NONE -i NONE \
        "+lua for _, file in ipairs(vim.fn.globpath(vim.env.NVIM_CONFIG_DIR, '**/*.lua', false, true)) do local chunk, err = loadfile(file); if not chunk then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') end end" \
        '+quit'
    as_user test -w "$TARGET_HOME/.config" || die "$TARGET_USER cannot write to $TARGET_HOME/.config. Fix its permissions first."
    if [[ ! -L $config || $(readlink -- "$config") != "$source" ]]; then
        if [[ -e $config || -L $config ]]; then
            backup=$(as_user mktemp -d "$TARGET_HOME/.config/nvim.bak.XXXXXXXX")
            rmdir -- "$backup"
            mv -T -- "$config" "$backup"
            printf 'Backed up existing Neovim configuration to %s\n' "$backup"
        fi
        as_user ln -s -- "$source" "$config"
    fi
    revision=$(as_user git -C "$checkout" rev-parse --short HEAD)
    result "rice default profile linked ($revision)"
}

install_neovim_dependencies() {
    if ((! CONFIGURE_NEOVIM)); then
        result 'Skipped; Neovim configuration disabled'
        return
    fi
    local cache="$TARGET_HOME/.cache/linux-headless-setup"
    local prefix="$TARGET_HOME/.local/share/linux-headless-setup/npm"
    local marker="$TARGET_HOME/.local/share/linux-headless-setup/neovim-tools-v1"
    local directory script command parser package_list parser_list ready=1
    for directory in "$TARGET_HOME/.cache" "$cache" "$TARGET_HOME/.local/bin"; do
        [[ -d $directory ]] || install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$directory"
    done
    if [[ -e $prefix ]]; then
        [[ -f $prefix/.linux-headless-setup ]] || die "Refusing to replace unmanaged npm prefix: $prefix"
    else
        as_user mkdir -- "$prefix"
        as_user touch "$prefix/.linux-headless-setup"
    fi
    if [[ ! -f $prefix/lib/node_modules/prettier/package.json ]]; then
        # The config invokes npx, so keep Prettier in an explicit user-owned
        # global prefix, not in root's npm directory or a project working tree.
        as_user npm install --global --ignore-scripts --no-audit --no-fund prettier
    fi
    managed_link "$prefix/bin/prettier" "$TARGET_HOME/.local/bin/prettier" "$prefix"
    chown -h "$TARGET_UID:$TARGET_GID" "$TARGET_HOME/.local/bin/prettier"
    [[ -f $marker ]] || ready=0
    for command in "${NVIM_MASON_COMMANDS[@]}"; do
        [[ -x $TARGET_HOME/.local/share/nvim/mason/bin/$command ]] || ready=0
    done
    for parser in "${NVIM_PARSERS[@]}"; do
        [[ -f $TARGET_HOME/.local/share/nvim/site/parser/$parser.so ]] || ready=0
    done
    if ((ready)); then
        verify_neovim_dependencies
        result 'Runtimes, formatters, language tools, and parsers already ready; no plugin sync'
        return
    fi
    script=$(as_user mktemp "$cache/.neovim-tools.XXXXXXXX")
    TEMP_PATHS+=("$script")
    cat >"$script" <<'EOF'
local ok, err = pcall(function()
  -- Install missing plugins only; do not clean or update a user's plugin set.
  require('lazy').install({ wait = true, show = false })
  local registry = require('mason-registry')
  registry.refresh()
  local packages = {}
  for name in vim.env.NVIM_TOOL_PACKAGES:gmatch('[^,]+') do
    local package = registry.get_package(name)
    packages[#packages + 1] = package
    if not package:is_installed() and not package:is_installing() then
      package:install()
    end
  end
  assert(vim.wait(600000, function()
    for _, package in ipairs(packages) do
      if package:is_installing() then return false end
    end
    return true
  end, 200), 'Timed out installing Mason tools')
  for _, package in ipairs(packages) do
    assert(package:is_installed(), 'Mason failed to install ' .. package.name)
  end
  local parsers = vim.split(vim.env.NVIM_TOOL_PARSERS, ',', { trimempty = true })
  require('nvim-treesitter').install(parsers):wait(600000)
  assert(vim.wait(600000, function()
    for _, parser in ipairs(parsers) do
      if not pcall(vim.treesitter.language.add, parser) then return false end
    end
    return true
  end, 200), 'One or more Tree-sitter parsers failed to install/load')
end)
if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
EOF
    printf -v package_list '%s,' "${NVIM_MASON_PACKAGES[@]}"
    printf -v parser_list '%s,' "${NVIM_PARSERS[@]}"
    as_user env NVIM_APPNAME=nvim NVIM_TOOL_BOOTSTRAP="$script" \
        NVIM_TOOL_PACKAGES="${package_list%,}" NVIM_TOOL_PARSERS="${parser_list%,}" \
        nvim --headless -i NONE '+lua dofile(vim.env.NVIM_TOOL_BOOTSTRAP)'
    verify_neovim_dependencies
    as_user touch "$marker"
    result 'Configured language servers, formatters, and parsers installed/checked as the target user'
}

verify_neovim_dependencies() {
    local command
    for command in node npm npx python3 go gofmt helm rg cc make unzip tree-sitter prettier "${NVIM_MASON_COMMANDS[@]}"; do
        # shellcheck disable=SC2016
        as_user sh -c 'command -v "$1"' dependency "$command"
    done
    as_user node --version
    as_user npm --version
    as_user python3 --version
    as_user python3 -c 'import venv, ensurepip'
    as_user go version
    as_user helm version --short
    as_user npx --offline --no-install prettier --version
    as_user stylua --version
    as_user shfmt --version
    as_user clang-format --version
    as_user gofumpt --version
    as_user yamlfmt --version
    as_user isort --version-number
    as_user ruff --version
    as_user mdformat --version
    as_user typescript-language-server --version
    as_user pylsp --version
    as_user lua-language-server --version --logpath="$TARGET_HOME/.cache/linux-headless-setup/lua-language-server"
}

configure_git() {
    local config_dir="$TARGET_HOME/.config/linux-headless-setup" gitconfig="$TARGET_HOME/.gitconfig"
    local start='# >>> linux-headless-setup git >>>' end='# <<< linux-headless-setup git <<<' backup directory
    for directory in "$TARGET_HOME/.config" "$config_dir"; do
        [[ -d $directory ]] || install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$directory"
    done
    cat >"$WORK_DIR/git-delta.gitconfig" <<'EOF'
# Managed by linux-headless-setup.
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
EOF
    if ! cmp -s "$WORK_DIR/git-delta.gitconfig" "$config_dir/git-delta.gitconfig"; then
        if [[ -e $config_dir/git-delta.gitconfig || -L $config_dir/git-delta.gitconfig ]]; then
            grep -Fxq "$MANAGED_MARKER" "$config_dir/git-delta.gitconfig" ||
                die "Refusing to replace unmanaged Git config: $config_dir/git-delta.gitconfig"
        fi
        install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$WORK_DIR/git-delta.gitconfig" "$config_dir/git-delta.gitconfig"
    fi
    printf '%s\n' "$start" >"$WORK_DIR/git-source-block"
    git config --file "$WORK_DIR/git-source-block" include.path "$config_dir/git-delta.gitconfig"
    printf '%s\n' "$end" >>"$WORK_DIR/git-source-block"
    [[ ! -L $gitconfig || -e $gitconfig ]] || die "Broken Git config symlink: $gitconfig"
    [[ ! -e $gitconfig || -f $gitconfig ]] || die "Not a regular Git config file: $gitconfig"
    if [[ -e $gitconfig ]]; then
        # Preserve other settings and any dotfiles symlink; our include is scoped
        # to Delta's three keys, not Git identity, credentials, or repositories.
        awk -v start="$start" -v end="$end" -v block="$WORK_DIR/git-source-block" '
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
        ' "$gitconfig" >"$WORK_DIR/gitconfig"
    else
        cp "$WORK_DIR/git-source-block" "$WORK_DIR/gitconfig"
    fi
    # Validate syntax without logging unrelated (potentially sensitive) values.
    git config --no-includes --file "$WORK_DIR/gitconfig" --list >/dev/null
    if ! cmp -s "$WORK_DIR/gitconfig" "$gitconfig"; then
        if [[ -e $gitconfig ]]; then
            backup=$(mktemp "$gitconfig.bak.XXXXXXXX")
            cat "$gitconfig" >"$backup"
            chown "$TARGET_UID:$TARGET_GID" "$backup"
            printf 'Backed up existing Git config to %s\n' "$backup"
            cat "$WORK_DIR/gitconfig" >"$gitconfig"
        else
            install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$WORK_DIR/gitconfig" "$gitconfig"
        fi
    fi
    [[ $(as_user git config --global --includes --get core.pager) == delta ]] ||
        die 'Another global Git include overrides Delta. Review the include order in ~/.gitconfig.'
    [[ $(as_user git config --global --includes --get interactive.diffFilter) == 'delta --color-only' ]] ||
        die 'Another global Git include overrides the Delta interactive diff filter.'
    result 'Git uses Delta for diffs; existing identity and unrelated settings preserved'
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
if [[ -d "$HOME/.local/share/nvim/mason/bin" ]]; then
    path+=("$HOME/.local/share/nvim/mason/bin")
fi
if [[ -d "$HOME/.local/share/linux-headless-setup/npm" ]]; then
    export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.local/share/linux-headless-setup/npm}"
fi
export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
(( HISTSIZE >= 10000 )) || HISTSIZE=10000
(( SAVEHIST >= 10000 )) || SAVEHIST=10000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS INTERACTIVE_COMMENTS

autoload -Uz compinit
(( $+functions[compdef] )) || compinit

if (( $+commands[eza] )); then
    # Upgrade earlier managed definitions even when ~/.zshrc is sourced again;
    # preserve unrelated personal aliases rather than replacing their commands.
    case "${aliases[ls]-}" in
        '' | 'eza --group-directories-first' | 'eza --icons=auto --group-directories-first')
            alias ls='eza --icons=always --group-directories-first' ;;
    esac
    case "${aliases[ll]-}" in
        '' | 'eza -lh --group-directories-first' | 'eza -lh --icons=auto --group-directories-first')
            alias ll='eza -lh --icons=always --group-directories-first' ;;
    esac
    case "${aliases[la]-}" in
        '' | 'eza -lah --group-directories-first' | 'eza -lah --icons=auto --group-directories-first')
            alias la='eza -lah --icons=always --group-directories-first' ;;
    esac
    case "${aliases[lt]-}" in
        '' | 'eza --tree --level=2' | 'eza --tree --level=2 --icons=auto')
            alias lt='eza --tree --level=2 --icons=always' ;;
    esac
fi
if (( $+commands[git] )); then
    (( $+aliases[gs] )) || alias gs='git status --short'
    (( $+aliases[gl] )) || alias gl='git log --oneline'
    (( $+aliases[gd] )) || alias gd='git diff'
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
    as_user zsh -fn "$config_dir/zshrc"
    as_user zsh -fn "$zshrc"
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
    for command in zsh starship zoxide eza btop nvim docker git delta; do
        executable=$(command -v "$command")
        printf '%s\n' "$executable"
        as_user "$executable" --version
    done
    as_user /usr/bin/docker compose version
    as_user /usr/bin/docker buildx version
    if ((CONFIGURE_NEOVIM)); then
        as_user tree-sitter --version
        as_user test -r "$TARGET_HOME/.config/nvim/init.lua"
        verify_neovim_dependencies
    fi
    # No plugins, user init, or ShaDa writes during the smoke check.
    as_user "$BIN_DIR/nvim" --headless -u NONE -i NONE '+quit'
    result 'All nine tools verified; Neovim headless startup passed'
}

printf '\nDetailed log: %s\n\n' "$LOG_FILE"
check_docker_conflicts
run_step 'Install Git, zsh, btop, and prerequisites' install_apt_packages
run_step 'Install Starship' install_github_tool starship starship starship/starship "^starship-$RUST_ARCH-unknown-linux-musl\\.tar\\.gz$"
run_step 'Install zoxide' install_github_tool zoxide zoxide ajeetdsouza/zoxide "^zoxide-[0-9.]+-$RUST_ARCH-unknown-linux-musl\\.tar\\.gz$"
run_step 'Install eza' install_github_tool eza eza eza-community/eza "^eza_$EZA_TARGET\\.tar\\.gz$"
run_step 'Install Delta for Git diffs' install_github_tool delta delta dandavison/delta "^delta-[0-9.]+-$DELTA_TARGET\\.tar\\.gz$"
run_step 'Install latest stable Neovim' install_github_tool neovim nvim neovim/neovim "^nvim-linux-$NVIM_ARCH\\.tar\\.gz$"
run_step 'Install Tree-sitter CLI for Neovim' install_treesitter_cli
run_step 'Install current Node.js LTS and npm' install_nodejs
run_step 'Install Go runtime and gofmt' install_go
run_step 'Install Helm CLI for the Helm plugin' install_helm
run_step 'Configure Neovim from rice' configure_neovim
run_step 'Install and verify Neovim dependency tools' install_neovim_dependencies
run_step 'Install Docker from its official APT repository' install_docker
run_step 'Configure Docker service' configure_docker_service
run_step 'Configure Git and Delta' configure_git
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
printf 'For eza/Neovim icons, select a Nerd Font in your local terminal (including SSH clients).\n'
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
    printf 'Update Docker later through APT, or run: sudo bash %q --user %q --yes --upgrade-docker\n' \
        "$(readlink -f -- "${BASH_SOURCE[0]}")" "$TARGET_USER"
else
    printf 'Update Docker later through APT, or rerun the download command with --upgrade-docker.\n'
fi
printf 'Full log: %s\n' "$LOG_FILE"
