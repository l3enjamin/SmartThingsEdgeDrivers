local crypto = require "st.crypto"
local base64 = require "st.base64"

local Crypto = {}

-- Base64URL decode
function Crypto.base64url_decode(input)
  if not input then return nil end
  input = input:gsub("%-", "+"):gsub("_", "/")
  local padding = #input % 4
  if padding > 0 then
    input = input .. string.rep("=", 4 - padding)
  end
  return base64.decode(input)
end

function Crypto.base64url_encode(input)
    local res = base64.encode(input)
    res = res:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
    return res
end

function Crypto.hmac_sha256(key, msg)
  return crypto.hmac(key, msg, crypto.HASH_ALGO.SHA256)
end

function Crypto.derive_keys(psk64, iv64)
    local psk = Crypto.base64url_decode(psk64 .. "===")
    local iv = Crypto.base64url_decode(iv64 .. "===")
    local enckey = Crypto.hmac_sha256(psk, "ENC")
    local mackey = Crypto.hmac_sha256(psk, "MAC")
    return enckey, mackey, iv
end

function Crypto.encrypt(clear_msg, enckey, mackey, iv, last_tx_hmac)
    -- Pad
    local pad_len = 16 - (#clear_msg % 16)
    if pad_len == 1 then pad_len = 17 end

    local random_bytes = crypto.generate_random_bytes(pad_len - 2)

    local pad = string.char(0) .. random_bytes .. string.char(pad_len)
    local padded_msg = clear_msg .. pad

    local enc_msg = crypto.aes_encrypt(padded_msg, enckey, iv, crypto.CIPHER_MODE.CBC, crypto.PADDING.NONE)

    -- HMAC
    -- hmac_msg = iv + direction + enc_msg
    -- direction = b'\x45' + last_tx_hmac
    local direction = "\x45" .. last_tx_hmac
    local hmac_input = iv .. direction .. enc_msg
    local new_hmac = Crypto.hmac_sha256(mackey, hmac_input)
    local truncated_hmac = new_hmac:sub(1, 16)

    return enc_msg .. truncated_hmac, truncated_hmac
end

function Crypto.decrypt(buf, enckey, mackey, iv, last_rx_hmac)
    if #buf < 32 then return nil, "Short message" end
    if #buf % 16 ~= 0 then return nil, "Unaligned message" end

    local enc_msg = buf:sub(1, -17)
    local their_hmac = buf:sub(-16)

    local direction = "\x43" .. last_rx_hmac
    local hmac_input = iv .. direction .. enc_msg
    local our_hmac_full = Crypto.hmac_sha256(mackey, hmac_input)
    local our_hmac = our_hmac_full:sub(1, 16)

    if their_hmac ~= our_hmac then
        return nil, "HMAC failure"
    end

    local padded_msg = crypto.aes_decrypt(enc_msg, enckey, iv, crypto.CIPHER_MODE.CBC, crypto.PADDING.NONE)

    local pad_len = padded_msg:byte(-1)
    if #padded_msg < pad_len then return nil, "Padding error" end

    local msg = padded_msg:sub(1, -1 - pad_len)
    return msg, their_hmac
end

return Crypto
