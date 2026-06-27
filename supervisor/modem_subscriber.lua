--===========================================================================
-- supervisor/modem_subscriber.lua
-- AE2-ES Supervisor — Modem Subscriber Module (Task B1)
--
-- Listens for TelemetryPayload broadcasts from Exec Brokers via OpenComputers
-- modem. Runs a cooperative event loop using event.pull("modem_message"),
-- deserializes incoming payloads, and enqueues them into a bounded FIFO queue.
--
-- Health monitoring tracks per-broker last-heard timestamps and flags brokers
-- as STALE (>30s silent) or OFFLINE (>120s silent).
--
-- Dependencies:
--   - OpenComputers APIs: component, event, computer, serialization
--   - TelemetryPayload (shared/telemetry_payload.lua, Task A7)
--     Falls back to serialization.unserialize() if TelemetryPayload is absent.
--
-- Conventions:
--   - Lua 5.2/5.3 compatible (GTNH OpenComputers)
--   - snake_case variables, PascalCase classes, UPPER_CASE constants
--   - Metatable-based OOP (setmetatable with __index)
--   - Local functions for module-private code
--   - 1-based indexing
--===========================================================================

local ModemSubscriber = {}
ModemSubscriber.__index = ModemSubscriber

--===========================================================================
-- Constants
--===========================================================================

local MAX_QUEUE_SIZE = 1000           -- FIFO cap; oldest entry dropped when full
local STALE_THRESHOLD = 30            -- seconds of silence before broker is STALE
local OFFLINE_THRESHOLD = 120         -- seconds of silence before broker is OFFLINE

--===========================================================================
-- Local utility: find the modem component
--===========================================================================
local function find_modem()
    for address, ctype in component.list() do
        if ctype == "modem" then
            return component.proxy(address)
        end
    end
    return nil
end

--===========================================================================
-- Local fallback deserializer (used when TelemetryPayload module is absent)
-- Uses OpenComputers serialization API directly.
--===========================================================================
local function fallback_deserialize(data)
    if type(data) ~= "string" or data == "" then
        return nil
    end
    local ok, result = pcall(serialization.unserialize, data)
    if not ok then
        return nil
    end
    -- Validate that the result is a table with required fields
    if type(result) ~= "table" then
        return nil
    end
    if result.brokerId == nil or result.timestamp == nil then
        return nil
    end
    return result
end

--===========================================================================
-- TelemetryPayload resolver
-- Tries to require the shared module (Task A7); falls back to local deserializer.
--===========================================================================
local TelemetryPayload = nil
local deserialize_fn = nil

local function resolve_deserializer()
    if deserialize_fn then
        return deserialize_fn
    end

    -- Attempt to load TelemetryPayload from shared/telemetry_payload.lua (Task A7)
    local ok, mod = pcall(require, "shared.telemetry_payload")
    if ok and mod and type(mod.deserialize) == "function" then
        TelemetryPayload = mod
        deserialize_fn = mod.deserialize
    else
        -- Fallback: use serialization.unserialize() with validation
        deserialize_fn = fallback_deserialize
    end

    return deserialize_fn
end

--===========================================================================
-- Queue implementation (FIFO, bounded)
-- Uses a simple table with head/tail indices for O(1) push/pop.
--===========================================================================
local Queue = {}
Queue.__index = Queue

function Queue.new(max_size)
    local self = setmetatable({}, Queue)
    self.items = {}         -- ring buffer storage
    self.head = 1           -- next index to pop
    self.tail = 1           -- next index to write
    self.count = 0
    self.max_size = max_size or MAX_QUEUE_SIZE
    return self
end

function Queue:push(item)
    if self.count >= self.max_size then
        -- FIFO drop: advance head, discarding oldest
        self.items[self.head] = nil
        self.head = self.head + 1
        self.count = self.count - 1
    end
    self.items[self.tail] = item
    self.tail = self.tail + 1
    self.count = self.count + 1
end

function Queue:pop()
    if self.count == 0 then
        return nil
    end
    local item = self.items[self.head]
    self.items[self.head] = nil
    self.head = self.head + 1
    self.count = self.count - 1
    return item
end

function Queue:size()
    return self.count
end

--===========================================================================
-- ModemSubscriber.new(port)
--
-- Creates a new ModemSubscriber instance.
-- Validates modem availability and opens the specified port.
--
-- Parameters:
--   port (number): The modem port to listen on.
--
-- Returns:
--   ModemSubscriber instance on success, or nil and an error message on failure.
--===========================================================================
function ModemSubscriber.new(port)
    if type(port) ~= "number" or port < 1 or port > 65535 then
        return nil, "invalid port: " .. tostring(port)
    end

    -- Resolve the deserializer once at construction time
    local deser = resolve_deserializer()
    if not deser then
        return nil, "no deserializer available"
    end

    -- Find and validate modem
    local modem = find_modem()
    if not modem then
        return nil, "no modem component found"
    end

    -- Open the port
    local open_ok, open_err = pcall(modem.open, modem, port)
    if not open_ok then
        return nil, "failed to open port " .. port .. ": " .. tostring(open_err)
    end

    local self = setmetatable({}, ModemSubscriber)
    self.modem = modem
    self.port = port
    self.deserialize = deser
    self.running = false
    self.queue = Queue.new(MAX_QUEUE_SIZE)
    self.active_brokers = {}       -- brokerId -> last_heard_timestamp (os.time)
    self.brokers_status = {}       -- brokerId -> "ACTIVE" | "STALE" | "OFFLINE"

    return self
end

--===========================================================================
-- subscriber:start()
--
-- Begins the event loop. Listens for modem_message signals, deserializes
-- payloads, enqueues them, and updates broker health tracking.
-- Runs cooperatively — event.pull() yields between messages.
--===========================================================================
function ModemSubscriber:start()
    if self.running then
        return -- already running
    end

    self.running = true

    -- Main event loop
    while self.running do
        -- event.pull("modem_message") yields cooperatively.
        -- Signal signature: (localAddress, remoteAddress, port, distance, ...data)
        local event_data = {event.pull("modem_message")}

        -- event.pull may return nil if computer.pushSignal was used to unblock
        if not event_data[1] then
            -- "modem_message" check below would fail; continue loop to re-check self.running
            goto continue
        end

        local signal_name = event_data[1]
        if signal_name ~= "modem_message" then
            -- Spurious wakeup (e.g. from pushSignal); skip
            goto continue
        end

        -- Extract fields from the signal
        -- Indices: 1=signal, 2=localAddress, 3=remoteAddress, 4=port, 5=distance, 6+=data
        local remote_address = event_data[3]
        local recv_port = event_data[4]
        local data = event_data[6]

        -- Only process messages on our port
        if recv_port ~= self.port then
            goto continue
        end

        -- Deserialize the payload
        local ok, payload = pcall(self.deserialize, data)
        if ok and type(payload) == "table" and payload.brokerId then
            -- Enqueue the payload (bounded FIFO)
            self.queue:push(payload)

            -- Update broker health tracking
            local broker_id = payload.brokerId
            self.active_brokers[broker_id] = os.time()
            self.brokers_status[broker_id] = nil -- reset; recomputed on query
        end

        ::continue::
    end
end

--===========================================================================
-- subscriber:stop()
--
-- Halts the event loop. Uses computer.pushSignal to unblock a currently
-- waiting event.pull(), allowing the loop to exit cleanly.
--===========================================================================
function ModemSubscriber:stop()
    if not self.running then
        return
    end

    self.running = false

    -- Push a signal to unblock any in-progress event.pull()
    -- This ensures the loop exits immediately rather than waiting for the
    -- next modem message.
    pcall(computer.pushSignal, "modem_message")
end

--===========================================================================
-- subscriber:getNextPayload()
--
-- Dequeues the next TelemetryPayload from the internal FIFO queue.
--
-- Returns:
--   A TelemetryPayload table on success, or nil if the queue is empty.
--===========================================================================
function ModemSubscriber:getNextPayload()
    return self.queue:pop()
end

--===========================================================================
-- subscriber:getQueueSize()
--
-- Returns the current number of payloads waiting in the queue.
--===========================================================================
function ModemSubscriber:getQueueSize()
    return self.queue:size()
end

--===========================================================================
-- subscriber:getActiveBrokers()
--
-- Returns a table mapping each known brokerId to its tracking info:
--   {
--     last_heard = <timestamp or nil>,
--     status     = "ACTIVE" | "STALE" | "OFFLINE"
--   }
--
-- Status is computed on each call based on elapsed time since last_heard.
--===========================================================================
function ModemSubscriber:getActiveBrokers()
    local now = os.time()
    local result = {}

    for broker_id, last_heard in pairs(self.active_brokers) do
        local elapsed = now - last_heard
        local status
        if elapsed > OFFLINE_THRESHOLD then
            status = "OFFLINE"
        elseif elapsed > STALE_THRESHOLD then
            status = "STALE"
        else
            status = "ACTIVE"
        end
        result[broker_id] = {
            last_heard = last_heard,
            status = status,
        }
    end

    return result
end

--===========================================================================
-- subscriber:getBrokerStatus(brokerId)
--
-- Utility method that returns the status string for a single broker.
--
-- Parameters:
--   brokerId (string): The broker identifier.
--
-- Returns:
--   "ACTIVE", "STALE", "OFFLINE", or nil if the broker is unknown.
--===========================================================================
function ModemSubscriber:getBrokerStatus(broker_id)
    local last_heard = self.active_brokers[broker_id]
    if not last_heard then
        return nil -- unknown broker
    end

    local elapsed = os.time() - last_heard
    if elapsed > OFFLINE_THRESHOLD then
        return "OFFLINE"
    elseif elapsed > STALE_THRESHOLD then
        return "STALE"
    else
        return "ACTIVE"
    end
end

--===========================================================================
-- subscriber:close()
--
-- Clean shutdown: stops the loop, closes the modem port, and clears state.
-- Call this before discarding the instance.
--===========================================================================
function ModemSubscriber:close()
    self:stop()
    if self.modem then
        pcall(self.modem.close, self.modem, self.port)
    end
    self.queue = nil
    self.active_brokers = {}
    self.brokers_status = {}
end

return ModemSubscriber
