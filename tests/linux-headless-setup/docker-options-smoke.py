#!/usr/bin/env python3
"""Check safe Docker opt-out without touching host packages or services."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "linux-headless-setup/setup.sh").read_text()
PREFIX = SOURCE[:SOURCE.index('[[ $(uname -s) == Linux')]


def function(name):
    start = SOURCE.index(f"\n{name}() {{") + 1
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


def run(args, code):
    return subprocess.run(["bash", "-s", "--", *args], input=PREFIX + code,
                          text=True, capture_output=True)


for args in (["--skip-docker", "--upgrade-docker"],
             ["--docker-group", "--skip-docker"]):
    result = run(args, "printf 'UNREACHABLE\\n'\n")
    assert result.returncode == 1 and "cannot be combined" in result.stderr
    assert "UNREACHABLE" not in result.stdout
    print(f"PASS: conflicting options rejected before setup: {args}")

STUBS = r'''
result() { printf '%s\n' "$*"; }
package_installed() {
  case "$1" in docker.io|docker-buildx|containerd|runc) return 0 ;; *) return 1 ;; esac
}
apt-get() { printf 'Unexpected APT command\n' >&2; exit 99; }
download() { printf 'Unexpected download\n' >&2; exit 99; }
curl() { printf 'Unexpected HTTP request\n' >&2; exit 99; }
systemctl() { printf 'Unexpected service operation\n' >&2; exit 99; }
groupadd() { printf 'Unexpected group operation\n' >&2; exit 99; }
'''
conflicts = function("check_docker_conflicts")
result = run([], STUBS + conflicts + "\ncheck_docker_conflicts\n")
assert result.returncode == 1, result.stderr
for package in ("docker.io", "docker-buildx", "containerd", "runc"):
    assert package in result.stderr
assert "--skip-docker" in result.stderr
print("PASS: normal install still rejects the user's conflicting Docker packages")

code = STUBS + "\n".join(function(name) for name in (
    "check_docker_conflicts", "install_docker", "configure_docker_service"
)) + r'''
check_docker_conflicts
install_docker
configure_docker_service
[[ $DOCKER_SERVICE_STATE == skipped ]]
printf 'DOCKER_UNTOUCHED\n'
'''
result = run(["--skip-docker"], code)
assert result.returncode == 0 and "DOCKER_UNTOUCHED" in result.stdout, result.stderr
print("PASS: skip bypasses conflicts, repository/download/package work, and service work")

# With only iptables missing, opt-out must not invoke APT for Docker prerequisites.
code = STUBS + function("install_apt_packages") + r'''
package_installed() { [[ $1 != iptables ]]; }
install_apt_packages
'''
result = run(["--skip-docker", "--no-neovim-config"], code)
assert result.returncode == 0, result.stderr
print("PASS: skip does not install Docker-specific iptables prerequisites")

# The skip mode must also succeed when Docker, Compose, and Buildx do not exist.
code = STUBS + function("verify_tools") + r'''
as_user() {
  case "$1" in docker|*/docker) printf 'Unexpected Docker verification\n' >&2; exit 99 ;; esac
}
command() {
  if [[ $1 == -v ]]; then
    [[ $2 != docker ]] || exit 98
    printf '/fake/%s\n' "$2"
  else
    builtin command "$@"
  fi
}
verify_tools
'''
result = run(["--skip-docker", "--no-neovim-config"], code)
assert result.returncode == 0 and "8 requested tools" in result.stdout, result.stderr
print("PASS: skip does not require or invoke Docker/Compose/Buildx during verification")
