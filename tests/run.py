#!/usr/bin/env python3
"""Run tests/run_tests.lua under Lua 5.2 (Factorio's Lua version) via `lupa`.

    pip install lupa
    python3 tests/run.py
"""
import os
import sys

from lupa import lua52

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
lua = lua52.LuaRuntime(unpack_returned_tuples=True)
# Route os.exit through Python so the exit status is preserved.
lua.globals().os.exit = lambda code=0: sys.exit(int(code) if code not in (True, None) else 0)
lua.execute(open(os.path.join("tests", "run_tests.lua"), encoding="utf-8").read())
