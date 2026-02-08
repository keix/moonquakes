local passed = 0
local failed = 0

local function run(file)
    local cmd = string.format('./zig-out/bin/moonquakes "%s"', file)
    local p = io.popen(cmd .. ' 2>&1')
    local output = p:read('*a')
    local ok = p:close()

    if ok then
        print('[PASS]', file)
        passed = passed + 1
    else
        print('[FAIL]', file)
        local snippet = string.match(output, "([^\n]*\n[^\n]*\n[^\n]*)") or output
        print(snippet)
        failed = failed + 1
    end
end

-- Get all test files (exclude this script itself)
local p = io.popen('find scripts -name "*.lua" -type f ! -name "invoke-sctipt.lua" | sort')
local file_list = p:read('*a')
p:close()

-- Run each test file
local i = 1
local file = ""
while i <= #file_list do
    local c = string.sub(file_list, i, i)
    if c == "\n" then
        if #file > 0 then
            run(file)
        end
        file = ""
    else
        file = file .. c
    end
    i = i + 1
end
if #file > 0 then
    run(file)
end

-- Summary
print("")
print(string.format("Total: %d passed, %d failed", passed, failed))
