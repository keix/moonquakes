-- Graph traversal algorithms demo
print("=== Graph Traversal Demo ===")

-- Graph represented as adjacency list
-- Each node has a list of neighbors
local function createGraph()
    local graph = {}

    graph.addNode = function(self, name)
        if not self[name] then
            self[name] = { neighbors = {} }
        end
    end

    graph.addEdge = function(self, from, to)
        self:addNode(from)
        self:addNode(to)
        local neighbors = self[from].neighbors
        neighbors[#neighbors + 1] = to
    end

    graph.addBidirectionalEdge = function(self, a, b)
        self:addEdge(a, b)
        self:addEdge(b, a)
    end

    return graph
end

-- Depth-First Search
local function dfs(graph, start, visited, result)
    visited = visited or {}
    result = result or {}

    if visited[start] then
        return result
    end

    visited[start] = true
    result[#result + 1] = start

    local node = graph[start]
    if node then
        for i = 1, #node.neighbors do
            dfs(graph, node.neighbors[i], visited, result)
        end
    end

    return result
end

-- Breadth-First Search
local function bfs(graph, start)
    local visited = {}
    local result = {}
    local queue = { start }
    local front = 1

    visited[start] = true

    while front <= #queue do
        local current = queue[front]
        front = front + 1

        result[#result + 1] = current

        local node = graph[current]
        if node then
            for i = 1, #node.neighbors do
                local neighbor = node.neighbors[i]
                if not visited[neighbor] then
                    visited[neighbor] = true
                    queue[#queue + 1] = neighbor
                end
            end
        end
    end

    return result
end

-- Find path between two nodes using BFS
local function findPath(graph, start, goal)
    local visited = {}
    local parent = {}
    local queue = { start }
    local front = 1

    visited[start] = true
    parent[start] = nil

    while front <= #queue do
        local current = queue[front]
        front = front + 1

        if current == goal then
            -- Reconstruct path
            local path = {}
            local node = goal
            while node do
                table.insert(path, 1, node)
                node = parent[node]
            end
            return path
        end

        local nodeData = graph[current]
        if nodeData then
            for i = 1, #nodeData.neighbors do
                local neighbor = nodeData.neighbors[i]
                if not visited[neighbor] then
                    visited[neighbor] = true
                    parent[neighbor] = current
                    queue[#queue + 1] = neighbor
                end
            end
        end
    end

    return nil -- No path found
end

-- Create a sample graph
--    A --- B --- C
--    |     |     |
--    D --- E --- F
--          |
--          G

local graph = createGraph()
graph:addBidirectionalEdge("A", "B")
graph:addBidirectionalEdge("B", "C")
graph:addBidirectionalEdge("A", "D")
graph:addBidirectionalEdge("B", "E")
graph:addBidirectionalEdge("C", "F")
graph:addBidirectionalEdge("D", "E")
graph:addBidirectionalEdge("E", "F")
graph:addBidirectionalEdge("E", "G")

print("\nGraph structure:")
print("    A --- B --- C")
print("    |     |     |")
print("    D --- E --- F")
print("          |      ")
print("          G      ")

-- Test DFS
print("\n-- DFS from A --")
local dfsResult = dfs(graph, "A")
local dfsStr = ""
for i = 1, #dfsResult do
    if i > 1 then dfsStr = dfsStr .. " -> " end
    dfsStr = dfsStr .. dfsResult[i]
end
print("DFS: " .. dfsStr)

-- Test BFS
print("\n-- BFS from A --")
local bfsResult = bfs(graph, "A")
local bfsStr = ""
for i = 1, #bfsResult do
    if i > 1 then bfsStr = bfsStr .. " -> " end
    bfsStr = bfsStr .. bfsResult[i]
end
print("BFS: " .. bfsStr)

-- Test path finding
print("\n-- Path Finding --")
local path1 = findPath(graph, "A", "G")
if path1 then
    local pathStr = ""
    for i = 1, #path1 do
        if i > 1 then pathStr = pathStr .. " -> " end
        pathStr = pathStr .. path1[i]
    end
    print("Path A to G: " .. pathStr)
else
    print("No path from A to G")
end

local path2 = findPath(graph, "D", "C")
if path2 then
    local pathStr = ""
    for i = 1, #path2 do
        if i > 1 then pathStr = pathStr .. " -> " end
        pathStr = pathStr .. path2[i]
    end
    print("Path D to C: " .. pathStr)
else
    print("No path from D to C")
end

-- Test disconnected node
graph:addNode("Z")  -- Isolated node
local path3 = findPath(graph, "A", "Z")
if path3 then
    print("Path A to Z: found")
else
    print("Path A to Z: no path (expected)")
end

print("\n=== Graph Traversal Demo PASSED ===")
