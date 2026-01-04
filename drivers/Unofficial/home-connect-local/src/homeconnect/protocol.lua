local json = require "dkjson"
local log = require "log"
local Crypto = require "homeconnect.crypto"

local Protocol = {}
Protocol.__index = Protocol

function Protocol.new(conn)
    local self = setmetatable({}, Protocol)
    self.conn = conn
    self.session_id = nil
    self.tx_msg_id = nil
    self.device_name = "smartthings"
    self.device_id = "st-hub-001"
    self.features = nil -- Feature mapping not implemented yet
    return self
end

function Protocol:reply(msg, reply_data)
    local reply = {
        sID = msg.sID,
        msgID = msg.msgID,
        resource = msg.resource,
        version = msg.version,
        action = "RESPONSE",
        data = {reply_data}
    }
    self.conn:send(json.encode(reply))
end

function Protocol:get(resource, version, action, data)
    if not self.session_id then return end

    local msg = {
        sID = self.session_id,
        msgID = self.tx_msg_id,
        resource = resource,
        version = version or 1,
        action = action or "GET"
    }
    if data then
        msg.data = {data}
    end

    self.conn:send(json.encode(msg))
    self.tx_msg_id = self.tx_msg_id + 1
end

function Protocol:parse_values(data_list)
    local result = {}
    if not data_list then return result end

    for _, item in ipairs(data_list) do
        local uid = tostring(item.uid)
        local value = item.value

        -- Mapping logic without external XML is hard.
        -- We will map known UIDs based on observation or try to guess.
        -- Examples:
        -- BSH.Common.Status.DoorState -> DoorState
        -- BSH.Common.Status.OperationState -> OperationState
        -- BSH.Common.Setting.PowerState -> PowerState
        -- BSH.Common.Option.RemainingProgramTime -> RemainingProgramTime

        local short_name = uid:match("([^%.]+)$")
        if short_name then
            result[short_name] = value
        else
            result[uid] = value
        end
    end
    return result
end

function Protocol:handle_message(msg_str)
    local msg, pos, err = json.decode(msg_str)
    if not msg then
        log.error("JSON decode error: " .. tostring(err))
        return nil
    end

    local resource = msg.resource
    local action = msg.action

    if action == "POST" then
        if resource == "/ei/initialValues" then
            self.session_id = msg.sID
            if msg.data and msg.data[1] then
                self.tx_msg_id = msg.data[1].edMsgID
            else
                 self.tx_msg_id = 1
            end

            -- Reply handshake
            self:reply(msg, {
                deviceType = "Application",
                deviceName = self.device_name,
                deviceID = self.device_id
            })

            -- Initialize sequence
            self:get("/ci/services")

            -- Authentication nonce (random 32 bytes base64url)
            -- Using a static one or random is fine?
            -- Python: token = re.sub(r'=', '', base64url_encode(get_random_bytes(32)))
            -- My Crypto.base64url_encode handles replacing +/, but we need to remove =
            local random_bytes = ""
            for i=1,32 do random_bytes = random_bytes .. string.char(math.random(0,255)) end
            local token = Crypto.base64url_encode(random_bytes)

            self:get("/ci/authentication", 2, "GET", {nonce = token})

            self:get("/ci/info", 2)
            self:get("/iz/info")
            self:get("/ni/info")
            self:get("/ei/deviceReady", 2, "NOTIFY")
            self:get("/ro/allDescriptionChanges")
            self:get("/ro/allMandatoryValues")

        else
            log.warn("Unknown POST resource: " .. tostring(resource))
        end

    elseif action == "RESPONSE" or action == "NOTIFY" then
        if resource == "/ro/allMandatoryValues" or resource == "/ro/values" then
            return self:parse_values(msg.data)
        elseif resource == "/ci/services" then
            -- Parse services if needed
        end
    end

    return nil
end

return Protocol
