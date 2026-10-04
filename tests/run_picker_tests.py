"""Run picker tests with Hammerspoon's bundled Lua, without opening Hammerspoon."""
import ctypes
import sys
from pathlib import Path

kit = Path(__file__).resolve().parents[1]
lib = ctypes.CDLL('/Applications/Hammerspoon.app/Contents/Frameworks/LuaSkin.framework/LuaSkin')
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ctypes.c_void_p]
state = lib.luaL_newstate()
try:
    lib.luaL_openlibs(state)
    # Lua long strings keep the iCloud path literal, including its spaces.
    files = ('test_picker_tabs.lua', 'test_window_groups.lua', 'test_overview.lua', 'test_picker_display.lua', 'test_picker_panel.lua')
    if len(sys.argv) > 1 and sys.argv[1] == 'bench':
        files = ('bench_picker.lua',)
    source = "KIT = [==[" + str(kit) + "]==];" + ";".join(
        f"dofile(KIT .. '/tests/{name}')" for name in files)
    source = source.encode()
    code = lib.luaL_loadstring(state, source) or lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if code:
        raise RuntimeError(lib.lua_tolstring(state, -1, None).decode())
finally:
    lib.lua_close(state)
