-- Test less than operator
if 5 < 10 then
    print("✓ 5 < 10 is true")
else
    print("✗ 5 < 10 should be true")
end

if 10 < 5 then
    print("✗ 10 < 5 should be false") 
else
    print("✓ 10 < 5 is false")
end

-- Test greater than operator  
if 15 > 10 then
    print("✓ 15 > 10 is true")
else
    print("✗ 15 > 10 should be true")
end

if 5 > 10 then
    print("✗ 5 > 10 should be false")
else
    print("✓ 5 > 10 is false") 
end

-- Test less than or equal operator
if 5 <= 5 then
    print("✓ 5 <= 5 is true")
else
    print("✗ 5 <= 5 should be true")
end

if 5 <= 10 then
    print("✓ 5 <= 10 is true") 
else
    print("✗ 5 <= 10 should be true")
end

if 10 <= 5 then
    print("✗ 10 <= 5 should be false")
else
    print("✓ 10 <= 5 is false")
end

-- Test greater than or equal operator
if 10 >= 10 then
    print("✓ 10 >= 10 is true")
else
    print("✗ 10 >= 10 should be true") 
end

if 15 >= 10 then
    print("✓ 15 >= 10 is true")
else
    print("✗ 15 >= 10 should be true")
end

if 5 >= 10 then
    print("✗ 5 >= 10 should be false")
else
    print("✓ 5 >= 10 is false")
end