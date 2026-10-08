# Linux headless setup tests

The container test runner and smoke tests are kept here, separate from the
installer in [`linux-headless-setup/`](../../linux-headless-setup/README.md).

## Run

From the repository root, with a working Docker daemon:

```bash
./tests/linux-headless-setup/test-in-docker.sh
# Optional alternative base image:
./tests/linux-headless-setup/test-in-docker.sh ubuntu:24.04
```

The runner resolves paths relative to its own location, so it also works when
invoked by an absolute path from another directory. If `GITHUB_TOKEN` is set,
it is forwarded to the test container for GitHub release API requests.

## Coverage and isolation

The test creates a disposable, **unprivileged** container, installs all tools,
runs the installer twice, checks user ownership, initialization, versions,
backups, file timestamps, Docker package origins, service-policy restoration, and
Neovim headless startup, then removes only its own container. It also checks the
opt-in Docker upgrade path with the same release.
Additional checks cover official-repository reuse, opt-in group access, terminal
colors/spinner, `NO_COLOR`, interactive cancellation, and installation through
Bash stdin (as used by the documented curl-to-Bash command).

Only the installer folder and this test folder are copied into the container;
the repository's `.git` directory and other scripts are not copied. The Docker
host socket is not mounted. Docker binaries are tested, but service startup and
nested containers are not: a normal test container has no systemd or privileges
to run a Docker daemon. No host packages or dotfiles are modified.
