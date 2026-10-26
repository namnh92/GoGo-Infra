#!/usr/bin/env python3
"""Run a command whose stdin is a pseudo-terminal that "types" an answer.

    pty-answer-stdin.py <text> -- <command> [args...]

The `answer-stdin` mode of PR #254 shape rev 3 (A-S-04), kept in harness/test
because scripts/lib/tty-harness.py belongs to PR #253. Unlike tty-harness.py
`answer`, stdin here IS the terminal (isatty is true), as when the owner runs
`jev-prompt setup` from a shell; stdout and stderr stay the caller's, so the
test reads them. Exit status is the command's; 124 past DEADLINE_S.
"""
import os
import pty
import select
import sys
import time

DEADLINE_S = 30


def main(argv):
    if len(argv) < 3 or argv[1] != "--":
        sys.stderr.write(__doc__)
        sys.exit(2)
    answer = argv[0].encode() + b"\n"
    cmd = argv[2:]
    stdout, stderr = os.dup(1), os.dup(2)
    pid, master = pty.fork()
    if pid == 0:
        os.dup2(stdout, 1)
        os.dup2(stderr, 2)
        os.execvp(cmd[0], cmd)

    os.write(master, answer)
    deadline = time.time() + DEADLINE_S
    status = None
    while status is None:
        # Drain the echo: a slave nobody reads cannot close on macOS.
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
            sys.stderr.write("pty-answer-stdin: command did not finish in %ds\n" % DEADLINE_S)
            sys.exit(124)
    os.close(master)
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))


if __name__ == "__main__":
    main(sys.argv[1:])
