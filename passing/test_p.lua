-- $Id: testes/files.lua $
-- See Copyright Notice in file all.lua

local debug = require "debug"

local maxint = math.maxinteger

assert(type(os.getenv"PATH") == "string")

assert(io.input(io.stdin) == io.stdin)
assert(not pcall(io.input, "non-existent-file"))
assert(io.output(io.stdout) == io.stdout)


local function testerr (msg, f, ...)
  local stat, err = pcall(f, ...)
  return (not stat and string.find(err, msg, 1, true))
end


local function checkerr (msg, f, ...)
  assert(testerr(msg, f, ...))
end


-- cannot close standard files
assert(not io.close(io.stdin) and
       not io.stdout:close() and
       not io.stderr:close())

-- cannot call close method without an argument (new in 5.3.5)
checkerr("got no value", io.stdin.close)


assert(type(io.input()) == "userdata" and io.type(io.output()) == "file")
assert(type(io.stdin) == "userdata" and io.type(io.stderr) == "file")
assert(not io.type(8))
local a = {}; setmetatable(a, {})
assert(not io.type(a))

assert(getmetatable(io.input()).__name == "FILE*")

local a,b,c = io.open('xuxu_nao_existe')
assert(not a and type(b) == "string" and type(c) == "number")

a,b,c = io.open('/a/b/c/d', 'w')
assert(not a and type(b) == "string" and type(c) == "number")

local file = os.tmpname()
local f, msg = io.open(file, "w")
if not f then
  (Message or print)("'os.tmpname' file cannot be open; skipping file tests")

else  --{  most tests here need tmpname
f:close()

print('testing i/o')

local otherfile = os.tmpname()

checkerr("invalid mode", io.open, file, "rw")
checkerr("invalid mode", io.open, file, "rb+")
checkerr("invalid mode", io.open, file, "r+bk")
checkerr("invalid mode", io.open, file, "")
checkerr("invalid mode", io.open, file, "+")
checkerr("invalid mode", io.open, file, "b")
assert(io.open(file, "r+b")):close()
assert(io.open(file, "r+")):close()
assert(io.open(file, "rb")):close()

assert(os.setlocale('C', 'all'))

io.input(io.stdin); io.output(io.stdout);

os.remove(file)
assert(not loadfile(file))
checkerr("", dofile, file)
assert(not io.open(file))
io.output(file)
assert(io.output() ~= io.stdout)

if not _port then   -- invalid seek
  local status, msg, code = io.stdin:seek("set", 1000)
  assert(not status and type(msg) == "string" and type(code) == "number")
end

assert(io.output():seek() == 0)
assert(io.write("alo alo"):seek() == string.len("alo alo"))
assert(io.output():seek("cur", -3) == string.len("alo alo")-3)
assert(io.write("joao"))
assert(io.output():seek("end") == string.len("alo joao"))

assert(io.output():seek("set") == 0)

assert(io.write('"alo"', "{a}\n", "second line\n", "third line \n"))
assert(io.write('Xfourth_line'))
io.output(io.stdout)
collectgarbage()  -- file should be closed by GC
assert(io.input() == io.stdin and rawequal(io.output(), io.stdout))
print('+')

-- test GC for files
collectgarbage()
for i=1,120 do
  for i=1,5 do
    io.input(file)
    assert(io.open(file, 'r'))
    io.lines(file)
  end
  collectgarbage()
end

io.input():close()
io.close()

assert(os.rename(file, otherfile))
assert(not os.rename(file, otherfile))

io.output(io.open(otherfile, "ab"))
assert(io.write("\n\n\t\t  ", 3450, "\n"));
io.close()


do
  -- closing file by scope
  local F = nil
  do
    local f <close> = assert(io.open(file, "w"))
    F = f
  end
  assert(tostring(F) == "file (closed)")
end
assert(os.remove(file))


do
  -- test writing/reading numbers
  local f <close> = assert(io.open(file, "w"))
  f:write(maxint, '\n')
  f:write(string.format("0X%x\n", maxint))
  f:write("0xABCp-3", '\n')
  f:write(0, '\n')
  f:write(-maxint, '\n')
  f:write(string.format("0x%X\n", -maxint))
  f:write("-0xABCp-3", '\n')
  assert(f:close())
  local f <close> = assert(io.open(file, "r"))
  assert(f:read("n") == maxint)
  assert(f:read("n") == maxint)
  assert(f:read("n") == 0xABCp-3)
  assert(f:read("n") == 0)
  assert(f:read("*n") == -maxint)            -- test old format (with '*')
  assert(f:read("n") == -maxint)
  assert(f:read("*n") == -0xABCp-3)            -- test old format (with '*')
end
assert(os.remove(file))


-- testing multiple arguments to io.read
do
  local f <close> = assert(io.open(file, "w"))
  f:write[[
a line
another line
1234
3.45
one
two
three
]]
  local l1, l2, l3, l4, n1, n2, c, dummy
  assert(f:close())
  local f <close> = assert(io.open(file, "r"))
  l1, l2, n1, n2, dummy = f:read("l", "L", "n", "n")
  assert(l1 == "a line" and l2 == "another line\n" and
         n1 == 1234 and n2 == 3.45 and dummy == nil)
  assert(f:close())
  local f <close> = assert(io.open(file, "r"))
  l1, l2, n1, n2, c, l3, l4, dummy = f:read(7, "l", "n", "n", 1, "l", "l")
  assert(l1 == "a line\n" and l2 == "another line" and c == '\n' and
         n1 == 1234 and n2 == 3.45 and l3 == "one" and l4 == "two"
         and dummy == nil)
  assert(f:close())
  local f <close> = assert(io.open(file, "r"))
  -- second item failing
  l1, n1, n2, dummy = f:read("l", "n", "n", "l")
  assert(l1 == "a line" and not n1)
end
assert(os.remove(file))



-- test yielding during 'dofile'
f = assert(io.open(file, "w"))
f:write[[
local x, z = coroutine.yield(10)
local y = coroutine.yield(20)
return x + y * z
]]
assert(f:close())
print('LINE 200 OK')
end
