#!/usr/bin/env python3
"""Run a command under a chosen controlling terminal, for the secret-script tests.

    tty-harness.py no-tty -- <command> [args...]
        A new session with no controlling terminal: opening /dev/tty fails
        (ENXIO) on macOS and Linux alike, whatever terminal the test suite was
        started from — or whether it was started from one at all.

    tty-harness.py answer <text> -- <command> [args...]
        A new session whose controlling terminal is a pseudo-terminal that
        "types" <text> and a newline. The command keeps the harness's own
        stdin, stdout and stderr, so the test decides what stdin is (a pipe,
        /dev/null) and /dev/tty is the only terminal in reach — the
        redirected-stdin prod lane of GoGo-Infra#231 (Sol F-02).

Why this exists: `confirm_prod` reads its answer from /dev/tty. A test that
runs it directly inherits whatever the suite has — a developer's terminal,
where the read would block on their keyboard, or none in CI, where it fails.
The suite has to assert the same thing in both places, so the terminal is
made here, deliberately, per case.

Exit status is the command's; 124 if it did not finish in DEADLINE_S.
"""
import os
import pty
import select
import sys
import time

DEADLINE_S = 30


def usage():
    sys.stderr.write(__doc__)
    sys.exit(2)


def exit_status(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


def main(argv):
    if len(argv) >= 3 and argv[0] == "no-tty" and argv[1] == "--":
        os.setsid()
        os.execvp(argv[2], argv[2:])
    if len(argv) >= 4 and argv[0] == "answer" and argv[2] == "--":
        answer = argv[1].encode() + b"\n"
        cmd = argv[3:]
    else:
        usage()

    stdin, stdout, stderr = os.dup(0), os.dup(1), os.dup(2)
    pid, master = pty.fork()
    if pid == 0:
        # Keep one descriptor on the slave. On macOS a session leader that
        # closes its last one loses the controlling terminal, and /dev/tty
        # stops opening — which would turn this into the no-tty case.
        os.dup2(0, 9)
        os.dup2(stdin, 0)
        os.dup2(stdout, 1)
        os.dup2(stderr, 2)
        os.execvp(cmd[0], cmd)

    os.write(master, answer)
    deadline = time.time() + DEADLINE_S
    status = None
    while status is None:
        # Drain the echo. A slave whose output nobody reads cannot close on
        # macOS (close waits for the output queue to drain), so the child
        # would hang at exit.
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                os.read(master, 4096)
            except OSError:
                pass
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid:
            status = st
        elif time.time() > deadline:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            os.close(master)
            sys.stderr.write("tty-harness: command did not finish in %ds\n" % DEADLINE_S)
            sys.exit(124)
    os.close(master)
    sys.exit(exit_status(status))


if __name__ == "__main__":
    main(sys.argv[1:])
