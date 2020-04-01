--- cosock is a library that provides a coroutine executor for luasocket.
--- Unlike existing coroutine executors it aims to provoce an as close to
--- identical to luasocket interface inside coroutines, including APIs like
--- `select`.

local cosocket = require "cosocket"
local socket = require "socket"

local threads = {} --TODO: use set instead of list
local newthreads = {} -- threads to be added before next iteration of run
local threadnames = {}
local threadswaitingfor = {} -- what each thread is waiting for
local threadsocketmap = {} -- maps threads from which socket is being waiting
local socketwrappermap = {} -- from native socket to async socket TODO: weak ref
local threaderrorhandler = nil
local threadtimeouts = {} -- map of thread => timeout info map
local threadtimeoutlist = {} -- ordered list of timeout info maps

local m = {}

m.socket = cosocket

function m.spawn(fn, name)
  local thread = coroutine.create(fn)
  print("cosocket spawn", name or thread)
  threadnames[thread] = name
  table.insert(newthreads, thread)
end

-- Implementaion Notes:
-- This run loop is where all the magic happens
function m.run()
  local runstarttime = socket.gettime()
  local recvr, sendr = {}, {} -- ready to send/recv sockets from luasocket.select
  while true do
    if socket.gettime() - runstarttime > 0.3 then error("should be over by now") end
    print(string.format("================= %s ======================", socket.gettime() - runstarttime))
    local deadthreads = {} -- indexed list of thread objects
    local wakethreads = {} -- map of thread => named resume params (rdy skts, timeout, etc)
    local sendt, recvt, timeout = {}, {}, nil -- cumulative values across all threads

    -- threads can't be added while iterating through the main list
    for _, thread in pairs(newthreads) do
      threads[thread] = thread
      wakethreads[thread] = {} -- empty no ready sockets or errors
    end
    newthreads = {}

    for _,lskt in ipairs(recvr) do
      print("**** recvr ****")
      local skt = socketwrappermap[lskt]
      assert(skt)
      local srcthreads = threadsocketmap[skt]
      assert(srcthreads, "no thread waiting on socket")
      assert(srcthreads.recv, "no thread waiting on recv ready")
      wakethreads[srcthreads.recv] = wakethreads[srcthreads.recv] or {}
      wakethreads[srcthreads.recv].recvr = wakethreads[srcthreads.recv].recvr or {}
      table.insert(wakethreads[srcthreads.recv].recvr, skt)
      local threadtimeoutinfo = threadtimeouts[srcthreads.recv]
      if threadtimeoutinfo then threadtimeoutinfo.timeouttime = nil end -- mark timeout canceled
    end

    for _,lskt in ipairs(sendr) do
      local skt = socketwrappermap[lskt]
      print("**** sendr ****", skt)
      assert(skt)
      local srcthreads = threadsocketmap[skt]
      for k,thread in pairs(srcthreads) do print(k,threadnames[thread] or thread) end
      assert(srcthreads, "no thread waiting on socket")
      assert(srcthreads.send, "no thread waiting on send ready")
      wakethreads[srcthreads.send] = wakethreads[srcthreads.send] or {}
      wakethreads[srcthreads.send].sendr = wakethreads[srcthreads.send].sendr or {}
      table.insert(wakethreads[srcthreads.send].sendr, skt)
      local threadtimeoutinfo = threadtimeouts[srcthreads.send]
      if threadtimeoutinfo then threadtimeoutinfo.timeouttime = nil end -- mark timeout canceled
    end

    local now = socket.gettime()
    for _,toinfo in ipairs(threadtimeoutlist) do
      if toinfo.timeouttime then -- skip canceled timeouts
        if now < toinfo.timeouttime then break end -- only process expired timeouts
        print(toinfo.timeouttime, now, toinfo.timeouttime - now)

        wakethreads[toinfo.thread] = {err = "timeout" }
	toinfo.timeouttime = nil -- mark timeout handled
      end
    end

    -- run all threads
    for thread, params in pairs(wakethreads) do
      print("+++++++++++++ waking", threadnames[thread] or thread, params.recvr, params.sendr, params.err)
      if coroutine.status(thread) == "suspended" then
        local status, threadrecvt_or_err, threadsendt, threadtimeout =
          coroutine.resume(thread, params.recvr, params.sendr, params.err)

        if status and coroutine.status(thread) == "suspended" then
          local threadrecvt = threadrecvt_or_err
          print("--------------- suspending", threadnames[thread] or thread, threadrecvt, threadsendt, threadtimeout)
          -- note which sockets this thread is waiting on
          threadswaitingfor[thread] = {recvt = threadrecvt, sendt = threadsendt, timeout = threadtimeout}
          if threadtimeout then
            local timeoutinfo = {
              thread = thread,
              timeouttime = threadtimeout + socket.gettime()
            }
            threadtimeouts[thread] = timeoutinfo
            table.insert(threadtimeoutlist, timeoutinfo)
          end
        elseif coroutine.status(thread) == "dead" then
          if not status and not threaderrorhandler then
            local err = threadrecvt_or_err
            if debug and debug.traceback then
              print(debug.traceback(thread, err))
            else
              print(err)
            end
            os.exit(-1)
          end
          print("dead", threadnames[thread] or thread, status, threadrecvt_or_err)
          table.insert(deadthreads, thread)
        end
      else
        print("warning: non-suspended thread encountered", coroutine.status(thread))
      end
    end

    -- threads can't be removed while iterating through the main list
    -- reverse sort, must pop larger indicies before smaller
    for _, thread in ipairs(deadthreads) do
      threads[thread] = nil
    end

    -- cull dead timeouts
    local listlen = #threadtimeoutlist -- list will shrink during iteration
    for i = 1, #threadtimeoutlist do
      local ri = listlen - i + 1
      print("idx", i, ri, listlen)
      print(threadtimeoutlist[ri])
      if not threadtimeoutlist[ri] then
        print(string.format("internal error: empty element in timeout list at %s/%s", ri, listlen))
        table.remove(threadtimeoutlist, ri)
      elseif not threadtimeoutlist[ri].timeouttime then
        local toinfo = table.remove(threadtimeoutlist, ri)
        threadtimeouts[toinfo.thread] = nil
      end
    end

    local running = false
    for _, thread in pairs(threads) do
      print("thread", threadnames[thread] or thread, coroutine.status(thread))
      if coroutine.status(thread) ~= "dead" then running = true end
    end
    if not running then break end

    for thread, params in pairs(threadswaitingfor) do
      if params.recvt then
        for _, skt in pairs(params.recvt) do
          print("thread for recvt:", threadnames[thread] or thread)
          threadsocketmap[skt] = {recv = thread}
          table.insert(recvt, skt.inner_sock)
          socketwrappermap[skt.inner_sock] = skt;
        end
      end
      if params.sendt then
        for _, skt in pairs(params.sendt) do
          print("thread for sendt:", threadnames[thread] or thread)
          threadsocketmap[skt] = {send = thread}
          table.insert(sendt, skt.inner_sock)
          socketwrappermap[skt.inner_sock] = skt;
        end
      end
      -- TODO: probably something with timers/outs
    end

    if #newthreads > 0 then
      print("new thread waiting, no timeout")
      timeout = 0
    else
      -- this is exceptionally inefficient, but it works, TODO: I dunno, timerwheel, after benchmarks
      table.sort(threadtimeoutlist, function(a,b) return a.timeouttime and b.timeouttime and a.timeouttime < b.timeouttime end)
      local timeouttime = (threadtimeoutlist[1] or {}).timeouttime
      if timeouttime then
        timeout = math.max(timeouttime - socket.gettime(), 0) -- negative timeouts mean infinity
        print("earliest timeout", timeout)
        local now = socket.gettime()
        for k,v in ipairs(threadtimeoutlist) do print(k,v,v.timeouttime - now) end
      end
    end

    if not timeout and #recvt == 0 and #sendt == 0 then
      -- in case of bugs
      timeout = 1
      print("WARNING: cosock tried to call socket select with no sockets and no timeout"
        --[[ TODO: for when things actually work: .." this is a bug, please report it"]])
    end

    print("start select", #recvt, #sendt, timeout)
    --for k,v in pairs(recvt) do print("r", k, v) end
    --for k,v in pairs(sendt) do print("s", k, v) end
    local err
    recvr, sendr, err = socket.select(recvt, sendt, timeout)
    print("return select", #recvr, #sendr)

    if err and err ~= "timeout" then error(err) end
  end

  print("run exit")
  --for k,v in ipairs(threadtimeoutlist) do print(k,v); print(threadnames[v.thread] or v.thread, v.timeouttime) end
  assert(#threadtimeoutlist == 0, "thread timeoutlist")

end

return m
