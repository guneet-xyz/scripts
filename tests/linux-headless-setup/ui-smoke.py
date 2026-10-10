#!/usr/bin/env python3
"""Exercise the installer's actual output renderer without installing packages."""

import errno
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "linux-headless-setup/setup.sh").read_text()


def function(name):
    start = SOURCE.index(f"\n{name}() {{") + 1
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


FUNCTIONS = "\n".join(function(name) for name in (
    "stop_spinner", "print_log_line", "render_step_output", "on_error", "result", "run_step"
))


def screen(text, width=40):
    """Minimal terminal model for the controls used by this renderer."""
    rows = [[]]
    row = col = index = 0
    while index < len(text):
        match = re.match(r"\x1b\[([0-9;?]*)([A-Za-z])", text[index:])
        if match:
            parameter, command = match.groups()
            if command == "A":
                row = max(0, row - int(parameter or "1"))
            elif command == "K":
                assert parameter == "2"
                rows[row] = []
            index += len(match.group())
            continue
        char = text[index]
        if char == "\r":
            col = 0
        elif char == "\n":
            row += 1
            col = 0
            while len(rows) <= row:
                rows.append([])
        else:
            if col >= width:
                row += 1
                col = 0
                while len(rows) <= row:
                    rows.append([])
            while len(rows[row]) <= col:
                rows[row].append(" ")
            rows[row][col] = char
            col += 1
        index += 1
    return ["".join(line).rstrip() for line in rows]


def run_case(*, tty, color, fail=False, plain=False):
    with tempfile.TemporaryDirectory(prefix="headless-ui-") as directory:
        root = Path(directory)
        code = f"""#!/usr/bin/env bash
set -Eeuo pipefail
WORK_DIR={directory!r}
LOG_FILE="$WORK_DIR/setup.log"
: >"$LOG_FILE"
exec 3>&1 4>&2
SPINNER_PID='' OUTPUT_DONE='' CURRENT_STEP='' STEP_RESULT=''
STEP=0 TOTAL_STEPS=2 PLAIN={int(plain)}
CYAN='' GREEN='' RED='' DIM='' RESET=''
if [[ ${{USE_COLOR:-0}} == 1 ]]; then
    CYAN=$'\\033[1;36m' GREEN=$'\\033[1;32m' RED=$'\\033[1;31m'
    DIM=$'\\033[2;90m' RESET=$'\\033[0m'
fi
{FUNCTIONS}
trap 'stop_spinner || true' EXIT
trap 'on_error "$?" "$LINENO"' ERR
fixture() {{
    printf 'stdout first\\n'
    printf 'stderr next\\n' >&2
    printf '\\033[31mcommand color\\033[0m\\n'
    printf 'wrapped %090d\\n' 1
    sleep 0.4
    printf 'partial '
    sleep 0.2
    printf 'line\\n'
    printf 'final without newline'
    {'bash -c "exit 7"' if fail else 'result "Fixture complete"'}
    {'printf "UNREACHABLE\\n"' if fail else ':'}
}}
run_step 'A long status title that should stay on one terminal row' fixture
printf 'FINISHED\\n'
"""
        script = root / "fixture.sh"
        script.write_text(code)
        env = {**os.environ, "TERM": "xterm", "COLUMNS": "40", "USE_COLOR": str(int(color))}
        master = None
        if tty:
            master, slave = pty.openpty()
            process = subprocess.Popen(["bash", str(script)], stdout=slave, stderr=slave, env=env)
            os.close(slave)
            fd = master
        else:
            process = subprocess.Popen(["bash", str(script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            fd = process.stdout.fileno()
        chunks = []
        deadline = time.monotonic() + 10
        live = False
        footer_checked = False
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            chunks.append(chunk)
            output = b"".join(chunks).decode()
            if "stdout first" in output and process.poll() is None:
                live = True
            if tty and not plain and "stderr next" in output and "partial line" not in output:
                rows = screen(output)
                positions = [i for i, value in enumerate(rows) if value.startswith(("| [", "/ [", "- [", "\\ ["))]
                if positions:
                    assert len(positions) == 1, rows
                    assert positions[0] > 0 and rows[positions[0] - 1] == "", rows
                    footer_checked = True
        else:
            process.kill()
            raise AssertionError("Output renderer did not terminate")
        status = process.wait(timeout=5)
        if master is not None:
            os.close(master)
        output = b"".join(chunks).decode()
        log = (root / "setup.log").read_text()
        assert live, "Command output was not streamed while the step was running"
        for message in ("stdout first", "stderr next", "partial line", "final without newline"):
            assert message in output and message in log, message
        assert "\x1b[31mcommand color\x1b[0m" in log, "Persistent log lost original command bytes"
        assert "\x1b[31m" not in output, "Command ANSI overrode the dimmed display"
        if tty and not plain:
            assert footer_checked, "Blank line above the live footer was not observed"
            assert "\x1b[?25l" in output
            assert "\x1b[?25h" in output, "Terminal cursor was not restored"
        else:
            assert "\x1b" not in output, "Plain/non-terminal output used terminal controls"
        if color:
            assert "\x1b[2;90mstdout first\x1b[0m" in output, "Logs were not dimmed"
        else:
            assert "\x1b[2;90m" not in output
        if fail:
            assert status == 7, (status, output)
            assert "FAILED" in output and "FINISHED" not in output and "UNREACHABLE" not in output
        else:
            assert status == 0 and " OK" in output and "FINISHED" in output, (status, output)
        print(f"PASS: tty={tty}, color={color}, failure={fail}, plain={plain}")


for case in ((True, True, False), (True, False, False), (False, False, False),
             (True, True, True), (False, False, True)):
    run_case(tty=case[0], color=case[1], fail=case[2])
run_case(tty=True, color=False, plain=True)
