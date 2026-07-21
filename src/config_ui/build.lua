-- config_ui/build.lua -- buildExecConfig
local ConfigUI = require("src.config_ui.persist")
-- ===========================================================================
-- Build config for exec_broker.new()
-- ===========================================================================

--- Convert the stored config to an exec_broker.new()-compatible table.
-- Resolves addresses to component proxies and builds the machines table.
-- @return table  ready for exec_broker.new(config)
function ConfigUI:buildExecConfig()
  local cfg = self._config
  if not cfg then return nil end

  local component = self._component or require("component")

  -- Build machines table
  local machines = {}
  local capabilityMap = {}
  if cfg.machines then
    for _, lane in ipairs(cfg.machines) do
      local addr = lane.machineAddr or lane.address
      local laneId = lane.laneId or addr
      if addr and addr ~= "" then
        -- machineTypes is persisted as address -> capability mask. Keep the
        -- address as MachineNode's lookup key so HAL can resolve the profile.
        -- The manually configured address remains authoritative even when
        -- discovery is enabled elsewhere.
        local machineType = addr
        local flags = cfg.machineTypes and (cfg.machineTypes[addr] or cfg.machineTypes[laneId])
        if type(flags) == "number" then
          capabilityMap[addr] = flags
        end
        local proxy = nil
        if component then
          local ok, p = pcall(component.proxy, addr)
          if ok then proxy = p end
        end

        -- Import MachineNode if available
        local MachineNode
        local ok, mod = pcall(require, "src.MachineNode")
        if ok then MachineNode = mod end

        local node
        if MachineNode then
          node = MachineNode.new(addr, {
            machineType = machineType,
            hardwareAddress = addr,
            laneId = laneId,
            interfaceAddress = lane.interfaceAddress
              or (cfg.machineTransposers and cfg.machineTransposers[laneId]
                  and cfg.machineTransposers[laneId].dualInterface)
              or nil,
          })
        else
          node = { address = addr, machineType = machineType, _proxy = proxy }
        end

        table.insert(machines, {
          laneId = laneId,
          machineAddr = addr,
          _node = node,
        })
      end
    end
  end

  -- Build modem table
  local modem = nil
  if cfg.modemAddress and cfg.modemAddress ~= "" then
    if component then
      local ok, p = pcall(component.proxy, cfg.modemAddress)
      if ok then modem = p end
    end
  end

  -- Build HAL config
  local halConfig = { capabilityMap = capabilityMap }

  -- Preserve a stable machine name for discovery conflict resolution.  An
  -- address is a fallback only when the adapter does not expose a name.
  local staticMachines = {}
  for _, lane in ipairs(cfg.machines or {}) do
    local staticLane = {}
    for key, value in pairs(lane) do staticLane[key] = value end
    if not staticLane.machineName and component then
      local address = staticLane.machineAddr or staticLane.address
      local ok, proxy = pcall(component.proxy, address)
      if ok and proxy and type(proxy.getMachineName) == "function" then
        local named, machineName = pcall(proxy.getMachineName)
        if named and type(machineName) == "string" and machineName ~= "" then
          staticLane.machineName = machineName
        end
      end
    end
    table.insert(staticMachines, staticLane)
  end

  local execConfig = {
    brokerId          = cfg.brokerId or "broker-1",
    machines          = machines,
    halConfig         = halConfig,
    queueSize         = cfg.queueSize or 64,
    modem             = modem,
    telemetryPort     = cfg.telemetryPort or 123,
    controlPort       = cfg.controlPort or 124,
    useStateMachine       = cfg.useStateMachine == true,
    useProgramFramework  = cfg.useProgramFramework == true,
    useTimeSliceScheduler = cfg.useTimeSliceScheduler == true,
    useCoroutineTransfer  = cfg.useCoroutineTransfer == true,
    enableAutoCrafting    = cfg.enableAutoCrafting == true,
    autoCraftInputs       = cfg.autoCraftInputs or {},
    enableDiscovery       = cfg.enableDiscovery == true,
    minMachines           = cfg.minMachines or 1,
    staticMachines        = staticMachines,
    componentApi          = component,
    enablePersistence     = cfg.enablePersistence == true,
    enableRemoteControl   = cfg.enableRemoteControl == true,
    enableRemoteThrottle  = cfg.enableRemoteThrottle == true,
    enableRemoteRestart   = cfg.enableRemoteRestart == true,
    controlAuthSecret     = cfg.controlAuthSecret or "",
    pollInterval      = cfg.pollInterval or 0.5,
    heartbeatInterval = cfg.heartbeatInterval or 2.0,
    debounceWindow    = cfg.debounceWindow or 1.5,
    dbSlots           = cfg.dbSlots or 9,
    machineTransposers = cfg.machineTransposers or {},
  }

  -- ME Controller and database addresses (expected by exec_broker)
  execConfig.meControllerAddr = cfg.meControllerAddr or ''
  execConfig.databaseAddr = cfg.databaseAddr or ''
  execConfig.redstoneAddress = cfg.redstoneAddress or ''
  execConfig.redstoneSide = cfg.redstoneSide or 5

  -- Build bufferFeeder closure: single HAL call to ME Controller
  -- (replaces old inventory_controller + tank_controller dual-adapter approach)
  local bufferFeeder = nil
  local meAddr = execConfig.meControllerAddr
  if meAddr and meAddr ~= '' then
    local ok, HAL_mod = pcall(require, "src.hal")
    local hal = (ok and HAL_mod) and HAL_mod:new() or nil
    bufferFeeder = function()
      if hal then return hal:getMEContents(meAddr) end
      return { items = {}, fluids = {} }
    end
  end
  execConfig.bufferFeeder = bufferFeeder

  return execConfig
end


return ConfigUI
