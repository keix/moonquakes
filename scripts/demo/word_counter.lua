-- Word Frequency Counter Demo
-- Demonstrates: pairs, ipairs, next, string manipulation

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

    -- Use ipairs to iterate over the word array
    local iter, tbl, idx = ipairs(words)
    local i, word = iter(tbl, idx)
    while i do
        if freq[word] then
            freq[word] = freq[word] + 1
        else
            freq[word] = 1
        end
        i, word = iter(tbl, i)
    end

    return freq
end

-- Find top N most frequent words
local function top_words(freq, n)
    -- Collect all words into an array
    local words = {}
    local count = 0

    -- Use pairs to iterate over the frequency table
    local iter, tbl, k = pairs(freq)
    local word, cnt = iter(tbl, k)
    while word do
        count = count + 1
        words[count] = {word = word, count = cnt}
        word, cnt = iter(tbl, word)
    end

    -- Simple bubble sort (descending by count)
    local i = 1
    while i <= count do
        local j = i + 1
        while j <= count do
            if words[j].count > words[i].count then
                local tmp = words[i]
                words[i] = words[j]
                words[j] = tmp
            end
            j = j + 1
        end
        i = i + 1
    end

    -- Return top N
    local result = {}
    i = 1
    while i <= n and i <= count do
        result[i] = words[i]
        i = i + 1
    end

    return result
end

-- Main
print("=== Word Frequency Counter ===")
print("")

local words = split_words(text)
print("Total words: " .. #words)

local freq = count_frequencies(words)

-- Count unique words using next
local unique = 0
local k = next(freq, nil)
while k do
    unique = unique + 1
    k = next(freq, k)
end
print("Unique words: " .. unique)
print("")

print("Top 5 most frequent words:")
print("--------------------------")
local top = top_words(freq, 5)

local iter, tbl, idx = ipairs(top)
local i, item = iter(tbl, idx)
while i do
    print(i .. ". " .. item.word .. ": " .. item.count)
    i, item = iter(tbl, i)
end

print("")
print("All word frequencies:")
print("--------------------")

-- Display all frequencies using pairs
local iter2, tbl2, k2 = pairs(freq)
local word, cnt = iter2(tbl2, k2)
while word do
    print("  " .. word .. ": " .. cnt)
    word, cnt = iter2(tbl2, word)
end
