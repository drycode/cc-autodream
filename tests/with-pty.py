#!/usr/bin/env python3
"""Run a command with a pseudo-terminal as its stdin, stdout and stderr, whatever ours are.

BSD `script -q /dev/null cmd` does the same job but calls tcgetattr on ITS OWN stdin, so it
dies with "Operation not supported on socket" when the caller hands it a socket or a closed
descriptor. This opens the pty itself, so it does not care.

The child's terminal is sent one newline and then end-of-file, so a command that reads a
prompt from its terminal gets an answer and a closed input instead of waiting forever. Its
output is copied to our stdout. Exit status is the child's.

Usage: with-pty.py <command> [args...]
"""
import os
import pty
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: with-pty.py <command> [args...]", file=sys.stderr)
        return 2
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        except OSError as err:
            # In the child, stderr is the pty: say it plainly, not as a traceback, and use the
            # shell's status for a command that cannot be run.
            print(f"with-pty: cannot run {sys.argv[1]}: {err.strerror}", file=sys.stderr)
            os._exit(127)
    # Best effort, once the child has had time to exec: canonical mode, so the newline completes
    # a line and ^D at the start of a line is end-of-file. A program that flushes its terminal
    # input after this (readline does) discards them, and one that reads its terminal would then
    # wait; the commands this runs do not.
    time.sleep(0.2)
    try:
        os.write(fd, b"\n\x04")
    except OSError:
        pass  # the child already exited
    while True:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break  # EIO: every holder of the slave side has gone
        if not data:
            break
        os.write(1, data)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
