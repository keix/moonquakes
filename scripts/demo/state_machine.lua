-- State machine implementation demo
print("=== State Machine Demo ===")

-- Simple state machine for a traffic light
local function createStateMachine(initial)
    local machine = {}
    local currentState = initial
    local states = {}
    local onEnter = {}
    local onExit = {}
    local history = {}

    machine.addState = function(self, name, config)
        states[name] = config or {}
        if config and config.onEnter then
            onEnter[name] = config.onEnter
        end
        if config and config.onExit then
            onExit[name] = config.onExit
        end
    end

    machine.addTransition = function(self, from, event, to, guard)
        if not states[from] then
            states[from] = {}
        end
        if not states[from].transitions then
            states[from].transitions = {}
        end
        states[from].transitions[event] = { target = to, guard = guard }
    end

    machine.trigger = function(self, event)
        local state = states[currentState]
        if not state or not state.transitions then
            return false, "No transitions from state: " .. currentState
        end

        local transition = state.transitions[event]
        if not transition then
            return false, "No transition for event: " .. event
        end

        -- Check guard condition
        if transition.guard and not transition.guard() then
            return false, "Guard condition failed"
        end

        local fromState = currentState
        local toState = transition.target

        -- Execute onExit
        if onExit[fromState] then
            onExit[fromState](fromState)
        end

        -- Transition
        currentState = toState
        history[#history + 1] = { from = fromState, to = toState, event = event }

        -- Execute onEnter
        if onEnter[toState] then
            onEnter[toState](toState)
        end

        return true, toState
    end

    machine.getState = function(self)
        return currentState
    end

    machine.getHistory = function(self)
        return history
    end

    machine.canTrigger = function(self, event)
        local state = states[currentState]
        if not state or not state.transitions then
            return false
        end
        local transition = state.transitions[event]
        if not transition then
            return false
        end
        if transition.guard and not transition.guard() then
            return false
        end
        return true
    end

    return machine
end

-- Traffic Light State Machine
print("\n-- Traffic Light --")
local light = createStateMachine("red")

light:addState("red", {
    onEnter = function(s) print("  [Enter " .. s .. ": Stop all traffic]") end
})
light:addState("green", {
    onEnter = function(s) print("  [Enter " .. s .. ": Traffic may proceed]") end
})
light:addState("yellow", {
    onEnter = function(s) print("  [Enter " .. s .. ": Prepare to stop]") end
})

light:addTransition("red", "timer", "green")
light:addTransition("green", "timer", "yellow")
light:addTransition("yellow", "timer", "red")

print("Initial state: " .. light:getState())
print("Triggering timer...")
light:trigger("timer")
print("Current state: " .. light:getState())
print("Triggering timer...")
light:trigger("timer")
print("Current state: " .. light:getState())
print("Triggering timer...")
light:trigger("timer")
print("Current state: " .. light:getState())

-- Document Workflow State Machine
print("\n-- Document Workflow --")
local document = createStateMachine("draft")

document:addState("draft")
document:addState("review")
document:addState("approved")
document:addState("rejected")
document:addState("published")

document:addTransition("draft", "submit", "review")
document:addTransition("review", "approve", "approved")
document:addTransition("review", "reject", "rejected")
document:addTransition("rejected", "revise", "draft")
document:addTransition("approved", "publish", "published")

print("Document starts in: " .. document:getState())

-- Simulate workflow
local events = {"submit", "reject", "revise", "submit", "approve", "publish"}
for i = 1, #events do
    local event = events[i]
    local success, result = document:trigger(event)
    if success then
        print("  " .. event .. " -> " .. result)
    else
        print("  " .. event .. " failed: " .. result)
    end
end

print("Final state: " .. document:getState())

-- Print history
print("\n-- Document History --")
local history = document:getHistory()
for i = 1, #history do
    local h = history[i]
    print("  " .. h.from .. " --[" .. h.event .. "]--> " .. h.to)
end

-- State machine with guards
print("\n-- Vending Machine (with guards) --")
local vendingMachine = createStateMachine("idle")
local coins = 0
local itemPrice = 100

local function addCoins(amount)
    coins = coins + amount
    print("  Inserted " .. amount .. " yen (total: " .. coins .. ")")
end

vendingMachine:addState("idle")
vendingMachine:addState("selecting")
vendingMachine:addState("dispensing")

vendingMachine:addTransition("idle", "insert", "selecting")
vendingMachine:addTransition("selecting", "insert", "selecting")  -- Can keep inserting
vendingMachine:addTransition("selecting", "select", "dispensing", function()
    return coins >= itemPrice
end)
vendingMachine:addTransition("selecting", "cancel", "idle")
vendingMachine:addTransition("dispensing", "take", "idle")

print("Item price: " .. itemPrice .. " yen")
print("State: " .. vendingMachine:getState())

addCoins(50)
vendingMachine:trigger("insert")
print("State: " .. vendingMachine:getState())

-- Try to select with insufficient funds
local success, msg = vendingMachine:trigger("select")
if not success then
    print("  Cannot select: " .. msg)
end

addCoins(50)
vendingMachine:trigger("insert")

-- Now should work
success, msg = vendingMachine:trigger("select")
if success then
    print("State: " .. msg)
    print("  Dispensing item...")
    coins = coins - itemPrice
end

vendingMachine:trigger("take")
print("State: " .. vendingMachine:getState())
print("Remaining coins: " .. coins)

print("\n=== State Machine Demo PASSED ===")
