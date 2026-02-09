-- Simple CSV Parser
-- Demonstrates practical string processing in Moonquakes

-- Split a line by delimiter
function split(str, delim)
    local result = {}
    local count = 0
    local start = 1
    local len = string.len(str)

    while start <= len do
        local pos = string.find(str, delim, start)
        if pos then
            count = count + 1
            result[count] = string.sub(str, start, pos - 1)
            start = pos + 1
        else
            count = count + 1
            result[count] = string.sub(str, start, len)
            start = len + 1
        end
    end

    result.n = count
    return result
end

-- Parse CSV content
function parseCSV(content)
    local rows = {}
    local row_count = 0
    local start = 1
    local len = string.len(content)

    while start <= len do
        local newline = string.find(content, "\n", start)
        local line
        if newline then
            line = string.sub(content, start, newline - 1)
            start = newline + 1
        else
            line = string.sub(content, start, len)
            start = len + 1
        end

        -- Skip empty lines
        if string.len(line) > 0 then
            row_count = row_count + 1
            rows[row_count] = split(line, ",")
        end
    end

    rows.n = row_count
    return rows
end

-- Test with sample CSV data
local csv_data = "name,age,city\nAlice,30,Tokyo\nBob,25,Osaka\nCharlie,35,Kyoto"

print("Parsing CSV data:")
print(csv_data)
print("")

local parsed = parseCSV(csv_data)

print("Parsed " .. tostring(parsed.n) .. " rows:")
print("")

-- Print header
local header = parsed[1]
print("Header: " .. header[1] .. " | " .. header[2] .. " | " .. header[3])
print("---")

-- Print data rows
local i = 2
while i <= parsed.n do
    local row = parsed[i]
    print("Row " .. tostring(i - 1) .. ": " .. row[1] .. " | " .. row[2] .. " | " .. row[3])
    i = i + 1
end

print("")
print("CSV parsing complete!")
