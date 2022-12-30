print("----------------------------------------")
local socket = require "socket"
local _select = socket.select
socket.select = function(r, t, o)
  local msg = "calling select with"
  if r then
    msg = msg .. string.format(" %s receivers", #r)
  else
    msg = msg .. string.format(" timeout of %s", o)
  end
  print(msg)
  _select(r, t, o)
end
local cosock = require "cosock"

local socket = cosock.socket

local ip = "0.0.0.0"
local port = 8765
local listener_count = 4096

local function spawn_client()
  local t = socket.udp()
  assert(t)
  t:setsockname(ip, port)
  cosock.spawn(function()
    assert(t:receive())
  end, "client")
end

cosock.spawn(function()
  print("server running")
  for _i=1, 4096 do
    spawn_client()
    cosock.socket.sleep(0.1)
  end
end, "listen server")

cosock.run()

print("----------------- exit -----------------")
