-- Word Frequency Counter Demo
-- Demonstrates: for...in pairs/ipairs, table manipulation

-- Sample text to analyze
local text = [[
the quick brown fox jumps over the lazy dog
the dog barks at the fox
the fox runs away from the dog
quick quick quick
]]

-- Split text into words (simple split by spaces and newlines)
local function split_words(s)
    local words = {}
    local count = 0
    local word = ""
    local i = 1
    local len = string.len(s)

    while i <= len do
        local c = string.sub(s, i, i)
        if c == " " or c == "\n" or c == "\t" then
            if string.len(word) > 0 then
                count = count + 1
                words[count] = word
                word = ""
            end
        else
            word = word .. c
        end
        i = i + 1
    end

    -- Don't forget the last word
    if string.len(word) > 0 then
        count = count + 1
        words[count] = word
    end

    return words
end

-- Count word frequencies
local function count_frequencies(words)
    local freq = {}

    for i, word in ipairs(words) do
        if freq[word] then
            freq[word] = freq[word] + 1
        else
            freq[word] = 1
        end
    end

    return freq
end

-- Find top N most frequent words
local function top_words(freq, n)
    -- Collect all words into an array
    local words = {}
    local count = 0

    for word, cnt in pairs(freq) do
        count = count + 1
        words[count] = {word = word, count = cnt}
    end

    -- Simple bubble sort (descending by count)
    for i = 1, count do
        for j = i + 1, count do
            if words[j].count > words[i].count then
                local tmp = words[i]
                words[i] = words[j]
                words[j] = tmp
            end
        end
    end

    -- Return top N
    local result = {}
    for i = 1, n do
        if i <= count then
            result[i] = words[i]
        end
    end

    return result
end

-- Main
print("=== Word Frequency Counter ===")
print("")

local words = split_words(text)
print("Total words: " .. #words)

local freq = count_frequencies(words)

-- Count unique words
local unique = 0
for k in pairs(freq) do
    unique = unique + 1
end
print("Unique words: " .. unique)
print("")

print("Top 5 most frequent words:")
print("--------------------------")
local top = top_words(freq, 5)

for i, item in ipairs(top) do
    print(i .. ". " .. item.word .. ": " .. item.count)
end

print("")
print("All word frequencies:")
print("--------------------")

for word, cnt in pairs(freq) do
    print("  " .. word .. ": " .. cnt)
end
