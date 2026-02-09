-- CSV File Reader
-- Reads and parses a CSV file from disk

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

-- Parse CSV content into table of rows
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

-- Read file
local filename = "scripts/demo/sample.csv"
local file = io.open(filename, "r")
if not file then
    print("Error: Could not open file " .. filename)
    return
end

local content = file:read("*a")
file:close()

print("Reading from: " .. filename)
print("")

-- Parse CSV
local data = parseCSV(content)

-- Print results
local header = data[1]
print("Columns: " .. header[1] .. ", " .. header[2] .. ", " .. header[3] .. ", " .. header[4])
print(string.rep("-", 40))

local i = 2
while i <= data.n do
    local row = data[i]
    print(row[1] .. "\t" .. row[2] .. "\t" .. row[3] .. "\t" .. row[4])
    i = i + 1
end

print("")
print("Total records: " .. tostring(data.n - 1))
