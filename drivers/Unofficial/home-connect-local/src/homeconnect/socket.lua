local socket = require "cosock.socket"
local log = require "log"
local Crypto = require "homeconnect.crypto"

-- Basic WebSocket implementation because st.websocket_client might be high level or not supporting custom encryption in payload.
-- Actually, we can use a raw TCP socket and implement the WebSocket framing if we have to,
-- or use a library. SmartThings *does* have a websocket client.
-- `local websocket = require "socket.http"` no.
-- `require "http.websocket"`?
-- I'll use raw TCP for control if I can't find a library, but implementing WS handshake is annoying.
-- Let's try to assume we can use `cosock.socket` and do a manual handshake.

local Connection = {}

function Connection.connect(host, psk64, iv64)
    local enckey, mackey, iv = Crypto.derive_keys(psk64, iv64)

    local c = socket.tcp()
    c:settimeout(5)
    local res, err = c:connect(host, 80)
    if not res then
        return nil, err
    end

    -- Handshake
    local key = "dGhlIHNhbXBsZSBub25jZQ==" -- Fixed nonce is fine for client
    local req = "GET /homeconnect HTTP/1.1\r\n" ..
                "Host: " .. host .. "\r\n" ..
                "Upgrade: websocket\r\n" ..
                "Connection: Upgrade\r\n" ..
                "Sec-WebSocket-Key: " .. key .. "\r\n" ..
                "Sec-WebSocket-Version: 13\r\n\r\n"

    c:send(req)

    local status_line, err = c:receive("*l")
    if not status_line then return nil, err end
    if not status_line:find("101") then return nil, "Handshake failed: " .. status_line end

    -- Skip headers
    while true do
        local line, err = c:receive("*l")
        if not line or line == "" then break end
    end

    local conn = {
        sock = c,
        enckey = enckey,
        mackey = mackey,
        iv = iv,
        last_rx_hmac = string.rep("\0", 16),
        last_tx_hmac = string.rep("\0", 16)
    }

    return conn
end

function Connection.send(conn, msg)
    local enc_payload, new_hmac = Crypto.encrypt(msg, conn.enckey, conn.mackey, conn.iv, conn.last_tx_hmac)
    conn.last_tx_hmac = new_hmac

    -- Frame it as binary (Opcode 0x2)
    local frame = string.char(0x82) -- FIN + Binary
    local len = #enc_payload

    if len < 126 then
        frame = frame .. string.char(len + 0x80) -- Mask bit set
    elseif len < 65536 then
        frame = frame .. string.char(126 + 0x80)
        frame = frame .. string.char(math.floor(len / 256)) .. string.char(len % 256)
    else
        -- support large frames? unlikely needed for commands
        return nil, "Message too large"
    end

    -- Masking is required for Client -> Server
    local mask_key = {math.random(0,255), math.random(0,255), math.random(0,255), math.random(0,255)}
    frame = frame .. string.char(mask_key[1], mask_key[2], mask_key[3], mask_key[4])

    local masked_payload = {}
    for i = 1, len do
        local byte = enc_payload:byte(i)
        local mask = mask_key[((i-1) % 4) + 1]
        table.insert(masked_payload, string.char(byte ~ mask))
    end

    frame = frame .. table.concat(masked_payload)

    return conn.sock:send(frame)
end

function Connection.receive(conn)
    local head, err = conn.sock:receive(2) -- Byte 1 and 2
    if not head then return nil, err end

    local b1 = head:byte(1)
    local b2 = head:byte(2)

    local opcode = b1 & 0x0F
    local fin = (b1 & 0x80) ~= 0
    local len = b2 & 0x7F

    if len == 126 then
        local lbytes, err = conn.sock:receive(2)
        if not lbytes then return nil, err end
        len = lbytes:byte(1) * 256 + lbytes:byte(2)
    elseif len == 127 then
        -- skip 8 bytes
        local lbytes, err = conn.sock:receive(8)
        if not lbytes then return nil, err end
        -- ignore high bits, assume small enough
        len = lbytes:byte(7) * 256 + lbytes:byte(8) -- Simplified
    end

    local payload, err = conn.sock:receive(len)
    if not payload then return nil, err end

    -- Opcode 0x2 is Binary, 0x1 is Text. We expect Binary.
    if opcode == 0x2 then
        local msg, hmac = Crypto.decrypt(payload, conn.enckey, conn.mackey, conn.iv, conn.last_rx_hmac)
        if msg then
            conn.last_rx_hmac = hmac
            return msg
        else
            return nil, "Decryption failed"
        end
    elseif opcode == 0x8 then
        return nil, "Closed"
    end

    return nil, "Unknown opcode"
end

return Connection
