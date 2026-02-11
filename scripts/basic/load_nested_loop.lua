-- GC integration test: nested proto repeated
-- Verifies recursive mark of closure -> proto -> nested proto

for i = 1, 1000 do
  local f = load("local function a() local function b() return 1 end return b() end return a()")
  f()
end

collectgarbage()
print("nested loop done")
-- expect: nested loop done
