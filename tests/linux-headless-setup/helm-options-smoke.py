#!/usr/bin/env python3
"""Check the real option parser and Helm selection without installing anything."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "linux-headless-setup/setup.sh").read_text()
PREFIX = SOURCE[:SOURCE.index('[[ $(uname -s) == Linux')]
start = SOURCE.index("\ninstall_helm() {") + 1
INSTALL_HELM = SOURCE[start:SOURCE.index("\n}\n", start) + 3]
REPORT = r'''
printf 'helm=%s\nneovim=%s\n' "$WITH_HELM" "$CONFIGURE_NEOVIM"
printf 'packages=%s\n' "${NVIM_MASON_PACKAGES[*]}"
printf 'commands=%s\n' "${NVIM_MASON_COMMANDS[*]}"
printf 'parsers=%s\n' "${NVIM_PARSERS[*]}"
'''


for args, helm, neovim in (
    ([], False, True),
    (["--with-helm"], True, True),
    (["--no-neovim-config"], False, False),
    (["--with-helm", "--no-neovim-config"], True, False),
    (["--no-neovim-config", "--with-helm"], True, False),
):
    result = subprocess.run(["bash", "-s", "--", *args], input=PREFIX + REPORT,
                            text=True, capture_output=True, check=True)
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert fields["helm"] == str(int(helm))
    assert fields["neovim"] == str(int(neovim))
    selected = helm and neovim
    for name in ("helm-ls", "yaml-language-server"):
        assert (name in fields["packages"].split()) == selected
    for name in ("helm_ls", "yaml-language-server"):
        assert (name in fields["commands"].split()) == selected
    assert ("helm" in fields["parsers"].split()) == selected
    # YAML formatting/highlighting and MDX support remain default dependencies.
    assert "yamlfmt" in fields["packages"].split()
    assert {"yaml", "typescript", "tsx"} <= set(fields["parsers"].split())
    print(f"PASS: args={args}, Helm dependencies selected={selected}")

# No opt-in means no HTTP/metadata/runtime installer calls, even when retaining
# the default Neovim profile. Exercise the actual install_helm function body.
STUBS = r'''
result() { printf '%s\n' "$*"; }
curl() { printf 'Unexpected network request\n' >&2; exit 99; }
download() { printf 'Unexpected download\n' >&2; exit 99; }
install_verified_runtime() { printf 'Unexpected Helm install\n' >&2; exit 99; }
'''
result = subprocess.run(["bash", "-s", "--"], input=PREFIX + STUBS + INSTALL_HELM + "\ninstall_helm\n",
                        text=True, capture_output=True, check=True)
assert "Helm is opt-in" in result.stdout
print("PASS: default install_helm makes no network/install calls")

# Mock only network/archive installation, while keeping the real version,
# checksum, URL, architecture, and opt-in control flow intact.
OPT_IN_STUBS = r'''
WORK_DIR="$HELM_TEST_WORK"
ARCH=arm64
result() { printf '%s\n' "$*"; }
curl() {
  while (($#)); do
    if [[ $1 == --output ]]; then
      printf '%s\n' '[{"tag_name":"v4.0.0","draft":false,"prerelease":false},{"tag_name":"v3.22.0","draft":false,"prerelease":false}]' >"$2"
      return
    fi
    shift
  done
  exit 98
}
download() { printf '%064d  helm-v3.22.0-linux-arm64.tar.gz\n' 0 >"$2"; }
install_verified_runtime() {
  [[ $1 == helm && $2 == v3.22.0 && $3 == helm-v3.22.0-linux-arm64.tar.gz ]] || exit 97
  [[ $4 == https://get.helm.sh/helm-v3.22.0-linux-arm64.tar.gz && $6 == linux-arm64 ]] || exit 96
  [[ ${#5} == 64 ]] || exit 95
  printf 'Verified requested Helm installation\n'
}
'''
if shutil.which("jq"):
    with tempfile.TemporaryDirectory(prefix="helm-opt-in-") as directory:
        for args in (["--with-helm"], ["--with-helm", "--no-neovim-config"]):
            result = subprocess.run(["bash", "-s", "--", *args],
                                    input=PREFIX + OPT_IN_STUBS + INSTALL_HELM + "\ninstall_helm\n",
                                    env={**os.environ, "HELM_TEST_WORK": directory},
                                    text=True, capture_output=True)
            assert result.returncode == 0, result.stderr
            assert "Verified requested Helm installation" in result.stdout
            print(f"PASS: real opt-in install control flow, args={args}")
else:
    print("SKIP: real opt-in metadata flow needs jq (selection/no-network checks passed)")
