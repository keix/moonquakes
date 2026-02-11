-- base64.lua - Base64 encoder/decoder
-- Usage: moonquakes base64.lua encode "text"
--        moonquakes base64.lua decode "SGVsbG8="
--        moonquakes base64.lua (runs demo)

local base64 = {}

-- Base64 alphabet
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Build reverse lookup table
local decode_table = {}
for i = 1, 64 do
    decode_table[string.sub(alphabet, i, i)] = i - 1
end

-- Encode a string to Base64
base64.encode = function(input)
    local result = {}
    local len = string.len(input)
    local i = 1

    while i <= len do
        -- Get up to 3 bytes
        local b1 = string.byte(input, i) or 0
        local b2 = string.byte(input, i + 1) or 0
        local b3 = string.byte(input, i + 2) or 0

        -- Convert 3 bytes to 4 base64 characters
        local n = b1 * 65536 + b2 * 256 + b3

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        result[#result + 1] = string.sub(alphabet, c1 + 1, c1 + 1)
        result[#result + 1] = string.sub(alphabet, c2 + 1, c2 + 1)

        if i + 1 <= len then
            result[#result + 1] = string.sub(alphabet, c3 + 1, c3 + 1)
        else
            result[#result + 1] = "="
        end

        if i + 2 <= len then
            result[#result + 1] = string.sub(alphabet, c4 + 1, c4 + 1)
        else
            result[#result + 1] = "="
        end

        i = i + 3
    end

    return table.concat(result)
end

-- Decode a Base64 string
base64.decode = function(input)
    -- Remove whitespace and padding count
    local clean = ""
    local padding = 0

    for i = 1, string.len(input) do
        local c = string.sub(input, i, i)
        if c == "=" then
            padding = padding + 1
            clean = clean .. "A"  -- Placeholder
        elseif decode_table[c] then
            clean = clean .. c
        end
    end

    local result = {}
    local len = string.len(clean)
    local i = 1

    while i <= len do
        local c1 = decode_table[string.sub(clean, i, i)] or 0
        local c2 = decode_table[string.sub(clean, i + 1, i + 1)] or 0
        local c3 = decode_table[string.sub(clean, i + 2, i + 2)] or 0
        local c4 = decode_table[string.sub(clean, i + 3, i + 3)] or 0

        -- Convert 4 base64 chars to 3 bytes
        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256

        result[#result + 1] = string.char(b1)
        if i + 2 <= len then
            result[#result + 1] = string.char(b2)
        end
        if i + 3 <= len then
            result[#result + 1] = string.char(b3)
        end

        i = i + 4
    end

    -- Remove padding bytes
    local output = table.concat(result)
    if padding > 0 then
        output = string.sub(output, 1, string.len(output) - padding)
    end

    return output
end

-- Demo / self-test
local function demo()
    local test_cases = {
        "",
        "H",
        "He",
        "Hel",
        "Hell",
        "Hello",
        "Hello, World!",
        "The quick brown fox jumps over the lazy dog",
    }

    print("Base64 Encoder/Decoder Demo")
    print("===========================")
    print("")

    for i = 1, #test_cases do
        local original = test_cases[i]
        local encoded = base64.encode(original)
        local decoded = base64.decode(encoded)

        print("Original: \"" .. original .. "\"")
        print("Encoded:  " .. encoded)
        print("Decoded:  \"" .. decoded .. "\"")

        if original == decoded then
            print("Status:   OK")
        else
            print("Status:   FAIL")
        end
        print("")
    end
end

local function usage()
    print("Usage: moonquakes base64.lua [encode|decode] [text]")
    print("       e/d can be used as shortcuts")
    print("")
    print("Examples:")
    print("  moonquakes base64.lua encode 'Hello, World!'")
    print("  moonquakes base64.lua decode 'SGVsbG8sIFdvcmxkIQ=='")
    print("")
    print("Run without arguments to see a demo.")
end

-- Main: command line interface
local function main()
    local mode = arg[1]
    local input = arg[2]

    if mode == "encode" or mode == "e" then
        if not input then
            print("Error: missing text to encode")
            return
        end
        print(base64.encode(input))
    elseif mode == "decode" or mode == "d" then
        if not input then
            print("Error: missing text to decode")
            return
        end
        print(base64.decode(input))
    elseif mode == "help" or mode == "-h" or mode == "--help" then
        usage()
    elseif mode then
        print("Unknown command: " .. mode)
        usage()
    else
        demo()
    end
end

main()
