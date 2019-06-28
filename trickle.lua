-- trickle v0.1.0 - Lua bitstream
-- https://github.com/bjornbytes/trickle
-- MIT License

local trickle = {}

local bit = bit32 or require 'bit'
local lshift, rshift, band, bxor, bnot, tobit = bit.lshift, bit.rshift, bit.band, bit.bxor, bit.bnot, bit.tobit

local extract = bit.extract or function(x, i, n)
  return band(rshift(x, i), lshift(1, n or 1) - 1)
end

local replace = bit.replace or function(x, y, i, n)
  local mask = lshift(rshift(bit.bnot(0), 31 - (n - 1)), i)
  return bit.bxor(x, bit.band(bit.bxor(x, lshift(y, i)), mask))
end

function trickle.create(bytesOrString)
  local bytes = bytesOrString

  if type(bytesOrString) == 'string' then
    -- insert in reverse order so we can pop efficiently with table.remove
    bytes = {}
    for i = #bytesOrString, 1, -1 do
      table.insert(bytes, string.byte(bytesOrString, i))
    end
  end

  local stream = {
    bytes = bytes or {},
    byte = nil,
    byteLen = nil
  }

  return setmetatable(stream, trickle)
end

function trickle:truncate()
  if self.byte then
    table.insert(self.bytes, string.char(self.byte))
    self.byte = nil
    self.byteLen = nil
  end
end

function trickle:tostring()
  local chars = {}
  for i = #self.bytes, 1, -1 do
    table.insert(chars, string.char(self.bytes[i]))
  end

  if self.byte then
    table.insert(chars, string.char(self.byte))
  end

  return table.concat(chars)
end

function trickle:clear()
  self.bytes = {}
  self.byte = nil
  self.byteLen = nil
  return self
end

function trickle:copy()
  local new = trickle.create(self.bytes)
  new.byte = self.byte
  new.byteLen = self.byteLen
  return new
end

function trickle:write(x, kind)
  if kind == 'byte' then self:writeByte(x)
  elseif kind == 'char' then self:writeChar(x)
  elseif kind == 'bytes' then self:writeBytes(x)
  elseif kind == 'cstring' then self:writeCString(x)
  elseif kind == 'bool' then self:writeBool(x)
  else
    local n = tonumber(kind:match('(%d+)bit'))
    if n then self:writeBits(x, n)
    else
      n = tonumber(kind:match('^[ui](%d+)$'))
      if n then self:writeBits(x, n)
      else
        error('Couldn\'t parse kind ' .. tostring(kind))
      end
    end
  end

  return self
end

function trickle:writeByte(byte)
  self:writeBits(byte, 8)
end

function trickle:writeChar(char)
  self:writeByte(string.byte(char))
end

function trickle:writeBytes(bytesString)
  for i = 1, #bytesString do
    self:writeChar(string.sub(bytesString, i, i))
  end
end

function trickle:writeCString(str)
  self:writeBytes(str)
  self:writeByte(0x00)
end

function trickle:writeBool(bool)
  local x = bool and 1 or 0
  self:writeBits(x, 1)
end

function trickle:writeBits(x, n)
  local idx = 0
  repeat
    if not self.byte then self.byte = 0 self.byteLen = 0 end
    local numWrite = math.min(n, (7 - self.byteLen) + 1)
    local toWrite = extract(x, idx, numWrite)
    self.byte = replace(self.byte, toWrite, self.byteLen, numWrite)
    self.byteLen = self.byteLen + numWrite

    if self.byteLen == 8 then
      -- insert to the front of the list because bytes is reversed
      -- so that readBits is more efficient in popping from the end
      table.insert(self.bytes, 1, self.byte)
      self.byte = nil
      self.byteLen = nil
    end

    n = n - numWrite
    idx = idx + numWrite
  until n == 0
end

function trickle:read(kind, bytesLen)
  if kind == 'byte' then return self:readByte()
  elseif kind == 'char' then return self:readChar()
  elseif kind == 'bytes' then return self:readBytes(bytesLen)
  elseif kind == 'cstring' then return self:readCString()
  elseif kind == 'bool' then return self:readBool()
  else
    local n = tonumber(kind:match('(%d+)bit'))
    if n then return self:readBits(n)
    else
      local sign
      sign, n = kind:match('^([ui])(%d+)$')
      n = tonumber(n)

      if sign and n then
        if sign == 'u' then
          return self:readBits(n)
        elseif sign == 'i' then
          return tobit(self:readBits(n))
        end
      else
        error('Couldn\'t parse kind ' .. tostring(kind))
      end
    end
  end
end

function trickle:readByte()
  return self:readBits(8)
end

function trickle:readChar()
  return string.char(self:readByte())
end

function trickle:readBytes(len)
  local chars = {}
  for i = 1, len do
    table.insert(chars, self:readChar())
  end
  return table.concat(chars, '')
end

function trickle:readCString()
  local chars = {}
  while true do
    local char = self:readChar()
    if char == "\x00" then break end

    table.insert(chars, char)
  end
  return table.concat(chars, '')
end

function trickle:readBool()
  return self:readBits(1) > 0
end

function trickle:readBits(n)
  local x = 0
  local idx = 0
  while n > 0 do
    if not self.byte then
      self.byte = self.bytes[#self.bytes] or 0 self.byteLen = 0
    end
    local numRead = math.min(n, (7 - self.byteLen) + 1)
    x = x + (extract(self.byte, self.byteLen, numRead) * (2 ^ idx))
    self.byteLen = self.byteLen + numRead

    if self.byteLen == 8 then
      table.remove(self.bytes)
      self.byte = nil
      self.byteLen = nil
    end

    n = n - numRead
    idx = idx + numRead
  end

  return x
end

function trickle:pack(data, signature)
  local keys
  if signature.delta then
    keys = {}
    for _, key in ipairs(signature.delta) do
      if type(key) == 'table' then
        local has = 0
        for i = 1, #key do
          if data[key[i]] ~= nil then
            keys[key[i]] = true
            has = has + 1
          else
            keys[key[i]] = false
          end
        end
        if has == 0 then self:write(0, '1bit')
        elseif has == #key then self:write(1, '1bit')
        else error('Only part of message delta group "' .. table.concat(key, ', ') .. '" was provided.') end
      else
        self:write(data[key] ~= nil and 1 or 0, '1bit')
        keys[key] = data[key] ~= nil and true or false
      end
    end
  end

  for _, sig in ipairs(signature) do
    if not keys or keys[sig[1]] ~= false then
      if type(sig[2]) == 'table' then
        self:write(#data[sig[1]], '4bits')
        for i = 1, #data[sig[1]] do self:pack(data[sig[1]][i], sig[2]) end
      else
        self:write(data[sig[1]], sig[2])
      end
    end
  end
  return self
end

function trickle:unpack(signature)
  local keys
  if signature.delta then
    keys = {}
    for i = 1, #signature.delta do
      local val = self:read('1bit') > 0
      if type(signature.delta[i]) == 'table' then
        for j = 1, #signature.delta[i] do keys[signature.delta[i][j]] = val end
      else
        keys[signature.delta[i]] = val
      end
    end
  end

  local data = {}
  for _, sig in ipairs(signature) do
    if not keys or keys[sig[1]] ~= false then
      if type(sig[2]) == 'table' then
        local ct = self:read('4bits')
        data[sig[1]] = {}
        for i = 1, ct do table.insert(data[sig[1]], self:unpack(sig[2])) end
      else
        if sig[2] == 'bytes' then
          data[sig[1]] = self:read(sig[2], sig[3])
        else
          data[sig[1]] = self:read(sig[2])
        end
      end
    end
  end
  return data
end

function trickle:getNumBitsLeft()
  return (#self.bytes * 8) - (self.byteLen or 0)
end

function trickle:getNumBytesLeft()
  -- round down to byte so 1 bit left means 0 bytes left
  return math.floor(self:getNumBitsLeft() / 8)
end

function trickle:getNumBitsWritten()
  return (#self.bytes * 8) + (self.byteLen or 0)
end

function trickle:getNumBytesWritten()
  -- round up to byte so 1 bit written means 1 byte written
  return math.ceil(self:getNumBitsWritten() / 8)
end

trickle.__tostring = trickle.tostring
trickle.__index = trickle

return { create = trickle.create }
