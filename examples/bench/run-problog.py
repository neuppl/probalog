"""Runs the problog command with room for deep recursion.

ProbLog fixes Python's recursion limit at 10000 when imported (its
--recursion-limit option is never applied), and its cycle breaking
recurses once per step along a chain, so long chains fail with
RecursionError. The limit is raised after the import, and ProbLog runs
in a thread whose stack is large enough for the deeper recursion.
"""

import os
import sys
import threading

from problog.tasks import main

sys.setrecursionlimit(1_000_000)
threading.stack_size(1 << 30)
code = [1]


def go():
    try:
        code[0] = main(sys.argv[1:]) or 0
    except SystemExit as e:
        code[0] = e.code or 0


t = threading.Thread(target=go)
t.start()
t.join()
sys.stdout.flush()
os._exit(code[0] if isinstance(code[0], int) else 1)
