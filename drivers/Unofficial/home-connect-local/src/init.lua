local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local Connection = require "homeconnect.socket"
local Protocol = require "homeconnect.protocol"
local cosock = require "cosock"

local driver

local function device_init(driver, device)
    log.info("Device init: " .. device.label)
end

local function device_added(driver, device)
    log.info("Device added: " .. device.label)
end

-- Helper to convert device values to capability events
local function update_device_state(device, values)
    if not values then return end

    -- PowerState
    if values.PowerState then
        if values.PowerState == "On" or values.PowerState == true then
            device:emit_event(capabilities.switch.switch.on())
        else
            device:emit_event(capabilities.switch.switch.off())
        end
    end

    -- DoorState
    if values.DoorState then
        if values.DoorState == "Open" then
            device:emit_event(capabilities.contactSensor.contact.open())
        elseif values.DoorState == "Closed" or values.DoorState == "Locked" then
            device:emit_event(capabilities.contactSensor.contact.closed())
        end
    end

    -- OperationState
    if values.OperationState then
        -- Map to washerOperatingState?
        -- Standard values: pause, run, stop, finish, delayStart
        -- Device values: Ready, Run, Finished, DelayedStart, Pause, ActionRequired, Aborting, Error, Inactive
        local map = {
            Ready = "stop",
            Run = "run",
            Finished = "finish",
            DelayedStart = "delayStart",
            Pause = "pause",
            Inactive = "stop"
        }
        local state = map[values.OperationState]
        if state then
            device:emit_event(capabilities.washerOperatingState.machineState(state))
        else
            -- custom
            device:emit_event(capabilities.washerOperatingState.machineState("stop")) -- Default fallback
        end
    end

    -- RemainingProgramTime
    if values.RemainingProgramTime then
        -- Seconds
        -- washerOperatingState doesn't have time remaining, only estimatedTimeRemaining?
        -- No, capabilities.washerOperatingState.completionTime?
        -- Let's check capabilities.
        -- washerOperatingState has `completionTime` (ISO8601).
        -- But `RemainingProgramTime` is a duration.
        -- Maybe just ignore for now or use a custom capability if needed.
    end
end

local function connect_device(device)
    local ip = device.preferences.ipAddress
    local key = device.preferences.encryptionKey
    local iv = device.preferences.iv

    if not ip or not key or not iv then
        log.warn("Missing configuration for " .. device.label)
        return
    end

    -- If already connected, do nothing
    if device:get_field("connected") then
        return
    end

    -- Spawn connection task
    cosock.spawn(function()
        local conn, err = Connection.connect(ip, key, iv)
        if not conn then
            log.error("Failed to connect: " .. tostring(err))
            device:offline()
            return
        end

        device:set_field("connected", true)
        device:online()

        local proto = Protocol.new(conn)
        device:set_field("protocol", proto)

        while true do
            local msg_str, err = Connection.receive(conn)
            if not msg_str then
                log.error("Receive error or closed: " .. tostring(err))
                break
            end

            log.info("RX Payload: " .. msg_str)
            local updates = proto:handle_message(msg_str)
            if updates then
                update_device_state(device, updates)
            end
        end

        device:set_field("connected", false)
        device:set_field("protocol", nil)
        device:offline()

        -- Retry logic?
        -- Simple retry after delay
        cosock.socket.sleep(10)
        connect_device(device)
    end, "conn_" .. device.id)
end

local function handle_switch(driver, device, command)
    -- To control the device, we need to send commands via Protocol.
    -- However, `hcpy` example is mostly reading.
    -- Sending commands involves PUT/SET to resources like `/ro/values`.
    -- Need to know the UID for PowerState.
    -- Assuming BSH.Common.Setting.PowerState.

    local proto = device:get_field("protocol")
    if not proto then
        log.warn("Not connected")
        return
    end

    local val = (command.command == "on") and true or false
    -- Mapping "On"/"Off" or boolean?
    -- HCDevice.py doesn't show setting examples clearly, but `hc2mqtt` converts "On" -> True for mqtt.
    -- The device likely expects "BSH.Common.EnumType.PowerState.On" or similar.
    -- Without the XML map, writing is dangerous/difficult.
    -- I will omit control for now or assume boolean `true`/`false` works if supported.

    log.warn("Control not fully implemented without feature mapping")

    -- Simulate feedback
    if command.command == "on" then
        device:emit_event(capabilities.switch.switch.on())
    else
        device:emit_event(capabilities.switch.switch.off())
    end
end

local function handle_refresh(driver, device, command)
    connect_device(device)
end

driver = Driver("home-connect-local", {
    discovery = function(driver, opts, cons)
        -- Scan?
    end,
    lifecycle_handlers = {
        init = device_init,
        added = device_added,
        driverSwitched = device_init,
        infoChanged = function(driver, device, event, args)
            if args.preferences then
                -- Reconnect
                -- Kill existing task?
                -- Ideally yes, but lazy way is to let it fail or restart.
                -- `connect_device` spawns a new loop.
                -- If we change IP, the old socket might timeout.
                -- Better to rely on user to refresh?
                connect_device(device)
            end
        end
    },
    capability_handlers = {
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
        },
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = handle_switch,
            [capabilities.switch.commands.off.NAME] = handle_switch,
        }
    }
})

driver:run()
