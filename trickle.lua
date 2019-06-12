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

function trickle.create(str)
  local stream = {
    str = str or '',
    byte = nil,
    byteLen = nil
  }

  return setmetatable(stream, trickle)
end

function trickle:truncate()
  if self.byte then
    self.str = self.str .. string.char(self.byte)
    self.byte = nil
    self.byteLen = nil
  end

  return self.str
end

function trickle:clear()
  self.str = ''
  self.byte = nil
  self.byteLen = nil
  return self
end

function trickle:write(x, kind)
  if kind == 'string' then self:writeString(x)
  elseif kind == 'cstring' then self:writeCString(x)
  elseif kind == 'bool' then self:writeBool(x)
  elseif kind == 'float' then self:writeFloat(x)
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

function trickle:writeString(string)
  self:truncate()
  string = tostring(string)
  self.str = self.str .. string.char(#string) .. string
end

function trickle:writeCString(str)
  for i = 1, #str do
    local byte = string.byte(str, i)
    self:writeBits(byte, 8)
  end
  self:writeBits(0x00, 8)
end

function trickle:writeBool(bool)
  local x = bool and 1 or 0
  self:writeBits(x, 1)
end

function trickle:writeFloat(float)
  self:writeString(float)
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
      self.str = self.str .. string.char(self.byte)
      self.byte = nil
      self.byteLen = nil
    end

    n = n - numWrite
    idx = idx + numWrite
  until n == 0
end

function trickle:read(kind)
  if kind == 'string' then return self:readString()
  elseif kind == 'cstring' then return self:readCString()
  elseif kind == 'bool' then return self:readBool()
  elseif kind == 'float' then return self:readFloat()
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

function trickle:readString()
  if self.byte then
    self.str = self.str:sub(2)
    self.byte = nil
    self.byteLen = nil
  end
  local len = self.str:byte(1)
  local res = ''
  if len then
    self.str = self.str:sub(2)
    res = self.str:sub(1, len)
    self.str = self.str:sub(len + 1)
  end
  return res
end

function trickle:readCString()
  local chars = {}

  while true do
    local byte = self:readBits(8)
    if byte == 0x00 then break end

    table.insert(chars, string.char(byte))
  end

  return table.concat(chars, '')
end

function trickle:readBool()
  return self:readBits(1) > 0
end

function trickle:readFloat()
  return tonumber(self:readString())
end

function trickle:readBits(n)
  local x = 0
  local idx = 0
  while n > 0 do
    if not self.byte then self.byte = self.str:byte(1) or 0 self.byteLen = 0 end
    local numRead = math.min(n, (7 - self.byteLen) + 1)
    x = x + (extract(self.byte, self.byteLen, numRead) * (2 ^ idx))
    self.byteLen = self.byteLen + numRead

    if self.byteLen == 8 then
      self.str = self.str:sub(2)
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
        data[sig[1]] = self:read(sig[2])
      end
    end
  end
  return data
end

trickle.__tostring = trickle.truncate
trickle.__index = trickle

return { create = trickle.create }
