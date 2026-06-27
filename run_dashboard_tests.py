#!/usr/bin/env python3
"""Run the dashboard Lua test suite via lupa."""
import sys, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
from lupa import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
    package.path = [[./src/?.lua;./supervisor/?.lua;./supervisor/?/init.lua;./tests/?.lua;./tests/?/init.lua;]] .. package.path
""")
lua.execute('dofile([[tests/unit/test_dashboard.lua]])')
