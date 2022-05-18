-- disable this test for 5.1 since we can't asyncify
if _VERSION == "Lua 5.1" then os.exit(0) end
local cosock = require "cosock"
local expected_requires = {
    ["cosock.lua"] = true,
    ["cosock/socket.lua"] = true,
    ["cosock/socket/tcp.lua"] = true,
    ["cosock/socket/udp.lua"] = true,
    -- used to populate socket.(url|headers) only
    ["socket/url.lua"] = true,
    ["socket/headers.lua"] = true,
    -- realrequire on the asyncify function will get called form C
    ["[C]"] = true,
}
-- import the sync versions of one and two for comparison later
local sync_one = require("test.asyncify.one")
local sync_two = require("test.asyncify.two")

local _realrequire = require
require = function(name)
    if name == "socket" then
        local info = debug.getinfo(2, "Sln")
        print(string.format("requiring socket from %s (%s)", info.short_src, info.name or ""))
        local match
        if not match then
            match = info.short_src:match("socket/url.lua$")
        end
        if not match then
            match = info.short_src:match("socket/headers.lua$")
        end
        if not match then
            match = info.short_src:match("cosock/cosock.+")
            if match then
                match = match:sub(8)
            end
        end
        if not match then
            match = info.short_src:match("cosock.+")
        end
        if not expected_requires[match or info.short_src] then
            print(info.what, info.name, info.namewhat, info.linedefined)
            print(debug.traceback(1))
            error("required socket outside of cosock: " .. (match or "") .. " " .. info.short_src)
        end
    end
    return _realrequire(name)
end

print("Trying non-nested asyncify")
local one = cosock.asyncify "test.asyncify.one"
assert(type(one) ~= "string", "Expected table found string for one: " .. tostring(one))
assert(one._COSOCK_VERSION == cosock._VERSION, "(one) Exepcted cosock version ".. cosock._VERSION .." found " .. tostring(one._COSOCK_VERSION))
assert(sync_one ~= one, "require produced the same result as asyncify")
assert(sync_one._COSOCK_VERSION == nil, "require test.asyncify.one returned cosock version " .. tostring(sync_one._COSOCK_VERSION))

print("Trying nested asyncify")
local two = cosock.asyncify "test.asyncify.two"
assert(type(two) ~= "string", "Expected table found string for two: " .. tostring(two))
assert(two._COSOCK_VERSION == cosock._VERSION, "(two) Exepcted cosock version ".. cosock._VERSION .." found " .. tostring(two._COSOCK_VERSION))
assert(sync_two ~= two, "require produced the same result as asyncify")
assert(sync_two._COSOCK_VERSION == nil, "require test.asyncify.one returned cosock version " .. tostring(sync_one._COSOCK_VERSION))

local t = require "table"
local at = cosock.asyncify("table")
assert(at == t, string.format("%s", at))
local nat = cosock.asyncify("test.asyncify.nested.table")
assert(nat == t, string.format("%s", nat))
