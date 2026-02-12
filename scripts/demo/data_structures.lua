-- Data structures implementation demo
print("=== Data Structures Demo ===")

-- Stack implementation
local function createStack()
    local stack = {}
    local data = {}
    local size = 0

    stack.push = function(self, value)
        size = size + 1
        data[size] = value
    end

    stack.pop = function(self)
        if size == 0 then
            return nil
        end
        local value = data[size]
        data[size] = nil
        size = size - 1
        return value
    end

    stack.peek = function(self)
        if size == 0 then
            return nil
        end
        return data[size]
    end

    stack.isEmpty = function(self)
        return size == 0
    end

    stack.getSize = function(self)
        return size
    end

    return stack
end

-- Queue implementation
local function createQueue()
    local queue = {}
    local data = {}
    local front = 1
    local back = 0

    queue.enqueue = function(self, value)
        back = back + 1
        data[back] = value
    end

    queue.dequeue = function(self)
        if front > back then
            return nil
        end
        local value = data[front]
        data[front] = nil
        front = front + 1
        return value
    end

    queue.peek = function(self)
        if front > back then
            return nil
        end
        return data[front]
    end

    queue.isEmpty = function(self)
        return front > back
    end

    queue.getSize = function(self)
        return back - front + 1
    end

    return queue
end

-- Linked List implementation
local function createLinkedList()
    local list = {}
    local head = nil
    local tail = nil
    local size = 0

    local function createNode(value)
        return { value = value, next = nil, prev = nil }
    end

    list.append = function(self, value)
        local node = createNode(value)
        if tail then
            tail.next = node
            node.prev = tail
            tail = node
        else
            head = node
            tail = node
        end
        size = size + 1
    end

    list.prepend = function(self, value)
        local node = createNode(value)
        if head then
            head.prev = node
            node.next = head
            head = node
        else
            head = node
            tail = node
        end
        size = size + 1
    end

    list.removeFirst = function(self)
        if not head then
            return nil
        end
        local value = head.value
        head = head.next
        if head then
            head.prev = nil
        else
            tail = nil
        end
        size = size - 1
        return value
    end

    list.removeLast = function(self)
        if not tail then
            return nil
        end
        local value = tail.value
        tail = tail.prev
        if tail then
            tail.next = nil
        else
            head = nil
        end
        size = size - 1
        return value
    end

    list.toArray = function(self)
        local arr = {}
        local current = head
        local i = 1
        while current do
            arr[i] = current.value
            i = i + 1
            current = current.next
        end
        return arr
    end

    list.getSize = function(self)
        return size
    end

    list.isEmpty = function(self)
        return size == 0
    end

    return list
end

-- Priority Queue (min-heap) implementation
local function createPriorityQueue()
    local pq = {}
    local data = {}
    local size = 0

    local function parent(i) return math.floor(i / 2) end
    local function left(i) return 2 * i end
    local function right(i) return 2 * i + 1 end

    local function swap(i, j)
        local tmp = data[i]
        data[i] = data[j]
        data[j] = tmp
    end

    local function heapifyUp(i)
        while i > 1 and data[parent(i)].priority > data[i].priority do
            swap(i, parent(i))
            i = parent(i)
        end
    end

    local function heapifyDown(i)
        local smallest = i
        local l = left(i)
        local r = right(i)

        if l <= size and data[l].priority < data[smallest].priority then
            smallest = l
        end
        if r <= size and data[r].priority < data[smallest].priority then
            smallest = r
        end

        if smallest ~= i then
            swap(i, smallest)
            heapifyDown(smallest)
        end
    end

    pq.insert = function(self, value, priority)
        size = size + 1
        data[size] = { value = value, priority = priority }
        heapifyUp(size)
    end

    pq.extractMin = function(self)
        if size == 0 then
            return nil
        end
        local min = data[1].value
        data[1] = data[size]
        data[size] = nil
        size = size - 1
        if size > 0 then
            heapifyDown(1)
        end
        return min
    end

    pq.peek = function(self)
        if size == 0 then
            return nil
        end
        return data[1].value
    end

    pq.isEmpty = function(self)
        return size == 0
    end

    pq.getSize = function(self)
        return size
    end

    return pq
end

-- Test Stack
print("\n-- Stack Tests --")
local stack = createStack()
stack:push(1)
stack:push(2)
stack:push(3)
print("Stack size after 3 pushes: " .. stack:getSize())
print("Peek: " .. stack:peek())
print("Pop: " .. stack:pop())
print("Pop: " .. stack:pop())
print("Size now: " .. stack:getSize())
print("isEmpty: " .. tostring(stack:isEmpty()))
stack:pop()
print("isEmpty after popping all: " .. tostring(stack:isEmpty()))

-- Test Queue
print("\n-- Queue Tests --")
local queue = createQueue()
queue:enqueue("first")
queue:enqueue("second")
queue:enqueue("third")
print("Queue size: " .. queue:getSize())
print("Peek: " .. queue:peek())
print("Dequeue: " .. queue:dequeue())
print("Dequeue: " .. queue:dequeue())
print("Size now: " .. queue:getSize())
print("Dequeue: " .. queue:dequeue())
print("isEmpty: " .. tostring(queue:isEmpty()))

-- Test Linked List
print("\n-- Linked List Tests --")
local list = createLinkedList()
list:append(1)
list:append(2)
list:append(3)
list:prepend(0)

local arr = list:toArray()
local arrStr = ""
for i = 1, #arr do
    if i > 1 then arrStr = arrStr .. ", " end
    arrStr = arrStr .. arr[i]
end
print("List contents: " .. arrStr)
print("Size: " .. list:getSize())

print("Remove first: " .. list:removeFirst())
print("Remove last: " .. list:removeLast())
arr = list:toArray()
arrStr = ""
for i = 1, #arr do
    if i > 1 then arrStr = arrStr .. ", " end
    arrStr = arrStr .. arr[i]
end
print("List after removals: " .. arrStr)

-- Test Priority Queue
print("\n-- Priority Queue Tests --")
local pq = createPriorityQueue()
pq:insert("low priority", 10)
pq:insert("high priority", 1)
pq:insert("medium priority", 5)
pq:insert("urgent", 0)

print("Processing in priority order:")
while not pq:isEmpty() do
    print("  " .. pq:extractMin())
end

-- Combined example: Task scheduler
print("\n-- Task Scheduler Example --")
local taskQueue = createPriorityQueue()

taskQueue:insert("Send emails", 3)
taskQueue:insert("Fix critical bug", 1)
taskQueue:insert("Update documentation", 5)
taskQueue:insert("Deploy to production", 2)
taskQueue:insert("Write unit tests", 4)

print("Task execution order:")
local order = 1
while not taskQueue:isEmpty() do
    print("  " .. order .. ". " .. taskQueue:extractMin())
    order = order + 1
end

-- Expression evaluator using stack
print("\n-- Expression Evaluator (Postfix) --")
local function evaluatePostfix(tokens)
    local evalStack = createStack()

    for i = 1, #tokens do
        local token = tokens[i]
        if type(token) == "number" then
            evalStack:push(token)
        else
            local b = evalStack:pop()
            local a = evalStack:pop()
            if token == "+" then
                evalStack:push(a + b)
            elseif token == "-" then
                evalStack:push(a - b)
            elseif token == "*" then
                evalStack:push(a * b)
            elseif token == "/" then
                evalStack:push(a / b)
            end
        end
    end

    return evalStack:pop()
end

-- Evaluate: (3 + 4) * 2 = 14
-- Postfix: 3 4 + 2 *
local expr1 = {3, 4, "+", 2, "*"}
print("(3 + 4) * 2 = " .. evaluatePostfix(expr1))

-- Evaluate: 5 + 3 * 2 = 11
-- Postfix: 5 3 2 * +
local expr2 = {5, 3, 2, "*", "+"}
print("5 + 3 * 2 = " .. evaluatePostfix(expr2))

-- Evaluate: (10 - 4) / (2 + 1) = 2
-- Postfix: 10 4 - 2 1 + /
local expr3 = {10, 4, "-", 2, 1, "+", "/"}
print("(10 - 4) / (2 + 1) = " .. evaluatePostfix(expr3))

print("\n=== Data Structures Demo PASSED ===")
