-- Legacy blocking supervisor launcher, retained while the framework flag is off.

local Supervisor = require("src.supervisor").Supervisor

local function run(config)
  local ok, err = Supervisor.new(config):start()
  if ok == false then error("Supervisor stopped with an error: " .. tostring(err)) end
end

return { run = run }
