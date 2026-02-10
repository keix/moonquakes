-- Test os.date

-- Test 1: Default format (no arguments)
print("Test 1: os.date()")
print(os.date())

-- Test 2: *t format returns table
print("\nTest 2: os.date('*t')")
local t = os.date("*t")
print("year: " .. t.year)
print("month: " .. t.month)
print("day: " .. t.day)
print("hour: " .. t.hour)
print("min: " .. t.min)
print("sec: " .. t.sec)
print("wday: " .. t.wday)
print("yday: " .. t.yday)
print("isdst: " .. tostring(t.isdst))

-- Test 3: Format specifiers
print("\nTest 3: Format specifiers")
print("Year: " .. os.date("%Y"))
print("Month: " .. os.date("%m"))
print("Day: " .. os.date("%d"))
print("Time: " .. os.date("%H:%M:%S"))
print("Date: " .. os.date("%Y-%m-%d"))
print("Full: " .. os.date("%Y-%m-%d %H:%M:%S"))

-- Test 4: Specific timestamp
print("\nTest 4: Specific timestamp (0 = 1970-01-01)")
local epoch = os.date("*t", 0)
print("Epoch year: " .. epoch.year)
print("Epoch month: " .. epoch.month)
print("Epoch day: " .. epoch.day)

-- Test 5: UTC with !
print("\nTest 5: UTC format")
print("UTC: " .. os.date("!%Y-%m-%d %H:%M:%S"))

-- Test 6: Weekday and month names
print("\nTest 6: Weekday and month names")
print("Weekday abbrev: " .. os.date("%a"))
print("Weekday full: " .. os.date("%A"))
print("Month abbrev: " .. os.date("%b"))
print("Month full: " .. os.date("%B"))

print("\nAll os.date tests completed!")
