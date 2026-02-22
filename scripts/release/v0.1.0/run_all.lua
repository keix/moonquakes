-- v0.1.0 Release Test Suite Runner
-- Run with: zig build run -- scripts/release/v0.1.0/run_all.lua

local tests = {
    "scripts/release/v0.1.0/test_basic.lua",
    "scripts/release/v0.1.0/test_string.lua",
    "scripts/release/v0.1.0/test_math.lua",
    "scripts/release/v0.1.0/test_table.lua",
    "scripts/release/v0.1.0/test_io.lua",
    "scripts/release/v0.1.0/test_os.lua",
    "scripts/release/v0.1.0/test_debug.lua",
    "scripts/release/v0.1.0/test_utf8.lua",
    "scripts/release/v0.1.0/test_metamethods.lua",
    "scripts/release/v0.1.0/test_control.lua",
}

local count = 0
for _, test in ipairs(tests) do
    local ok, err = pcall(dofile, test)
    if ok then
        count = count + 1
    else
        print("[FAIL] " .. test)
        error(err)
    end
end

print(string.format("All %d tests passed!", count))
