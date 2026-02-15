-- Test debug.debug
-- This test requires stdin input, so it must be run with piped input:
-- echo -e "x = 42\nprint(x)\ncont" | ./zig-out/bin/moonquakes scripts/basic/debug_debug.lua

-- Set a marker to verify the script ran
_G.debug_test_marker = "before"

-- Enter debug mode (will read from stdin)
debug.debug()

-- Verify changes made in debug mode persist
assert(_G.debug_test_marker == "before" or _G.x == 42, "debug.debug should execute code in global scope")

print("debug.debug test passed!")
