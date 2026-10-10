# Linux headless setup tests

The container test runner and smoke tests are kept here, separate from the
installer in [`linux-headless-setup/`](../../linux-headless-setup/README.md).

## Run

From the repository root, with a working Docker daemon:

```bash
./tests/linux-headless-setup/test-in-docker.sh
# Optional alternative base image:
./tests/linux-headless-setup/test-in-docker.sh ubuntu:24.04

# Fast Git/Delta/icon regression suite (skips Neovim's dependency bootstrap):
TEST_SUITE=git ./tests/linux-headless-setup/test-in-docker.sh
TEST_SUITE=git ./tests/linux-headless-setup/test-in-docker.sh ubuntu:24.04
```

The runner resolves paths relative to its own location, so it also works when
invoked by an absolute path from another directory. If `GITHUB_TOKEN` is set,
it is forwarded to the test container for GitHub release API requests.
Temporary downloads/builds and test users' homes use size-limited tmpfs mounts
to avoid filling the Docker host's disk. Run the tests with enough available
RAM (up to 4 GiB of tmpfs space plus the running tools), especially when testing
the older-system Tree-sitter source-build fallback.

## Coverage and isolation

The test creates a disposable, **unprivileged** container, installs all tools,
runs the installer twice, checks user ownership, initialization, versions,
backups, file timestamps, Docker package origins, service-policy restoration, and
Neovim headless startup, then removes only its own container. It also checks the
opt-in Docker upgrade path with the same release.
Additional checks cover official-repository reuse, opt-in group access, terminal
colors/spinner, `NO_COLOR`, interactive cancellation, and installation through
Bash stdin (as used by the documented curl-to-Bash command).
Neovim checks cover the rice symlink and source layout, user ownership, private
directory permissions, one-time backups, preservation of local edits, and
`--no-neovim-config`. Eza aliases are checked for icon flags. The tests now execute
rice's real plugin bootstrap and check its Node/npm/Python/Go runtimes, configured
Mason tools, offline npx/Prettier resolution, and native Helm/MDX parser loading.
Runtime logs/caches and Go telemetry are excluded from filesystem-idempotence
snapshots; installed files, config content, ownership, and permissions are checked.
The Git suite additionally checks identity/settings preservation, `.gitconfig`
symlinks and one-time backups, alias behavior in a real repository, Delta pager
invocation/rendering, icons even in captured output, and upgrades of older
managed eza definitions when the shell configuration is sourced again.

Only the installer folder and this test folder are copied into the container;
the repository's `.git` directory and other scripts are not copied. The Docker
host socket is not mounted. Docker binaries are tested, but service startup and
nested containers are not: a normal test container has no systemd or privileges
to run a Docker daemon. No host packages or dotfiles are modified.
