-- =========================================================
--  Smooth-Move Multi-Point Clicker
--  + GREEN Gate (global exits)
--  + Standardized Steps + Debug Prints
--  + Randomized delays: (base - 0.16) .. (base + 0.15)
--  + OPTIONAL: Stop after N full cycles, then quit frontmost app
--  + GUARANTEED IDLE MOUSE DURING WAITS (incl. GREEN WATCH)
--
--  Hotkeys:
--    Cmd + Alt + Ctrl + S   Start
--    Cmd + Alt + Ctrl + X   Stop
--    Cmd + Alt + Ctrl + P   Print mouse position
--    Cmd + Alt + Ctrl + C   Sample pixel color under cursor
-- =========================================================

-- ================= SETTINGS =================
local debug = true
local PRINT_EVERY_GREEN_CHECK = false
local PRINT_IDLE_DEBUG = true  -- set false once verified

-- ===== Optional: stop after N full cycles =====
local STOP_AFTER_CYCLES = 30
local cyclesCompleted = 0

-- Smooth mouse movement (scripted moves)
local moveDurationMin = 0.02
local moveDurationMax = 0.04
local moveFPS = 240

-- -------- IDLE SETTINGS --------
-- 30% of cycles do NO idle at all
local IDLE_DO_NOTHING_CYCLE_PROB = 0.30

-- Idle timer tick + probability
local IDLE_TIMER_TICK = 0.12
local IDLE_ACTION_PROB_PER_TICK = 0.3  -- bump this down later (0.15–0.25 feels subtle)

-- quick nudge sizes (px)
local IDLE_NUDGE_MIN = 2
local IDLE_NUDGE_MAX = 7

-- sometimes do a long slow drag instead
local IDLE_LONG_DRAG_PROB = 0.3
local IDLE_LONG_DRAG_DIST_MIN = 25
local IDLE_LONG_DRAG_DIST_MAX = 140
local IDLE_LONG_DRAG_DUR_MIN  = 0.55
local IDLE_LONG_DRAG_DUR_MAX  = 1.85

-- drift bias that accumulates (resting hand pressure)
-- +x right, +y down
local DRIFT_BIAS_X = 0.35
local DRIFT_BIAS_Y = 0.80
local DRIFT_NOISE  = 0.45
local DRIFT_MAX    = 20

-- -------- GREEN gate --------
local GREEN_X1, GREEN_X2 = 828, 830
local GREEN_Y1, GREEN_Y2 = 678, 680
local GREEN_SAMPLES = 5
local GREEN_HIT_RATIO = 0.40
local GREEN_MIN_G = 90
local GREEN_DELTA = 40
local GREEN_POLL_INTERVAL = 0.15

-- -------- Base delays (randomized ± as requested) --------
local CLICK_SETTLE_BASE       = 0.06

local PAUSE_AFTER_A_BASE      = 0.14
local PAUSE_AFTER_B_BASE      = 0.14
local PAUSE_AFTER_C_BASE      = 0.14

local FIRE_WINDOW_BASE        = 9.08
local PAUSE_AFTER_PASS_BASE   = 5.10
local LOOP_GAP_BASE           = 0.15

local EXIT_GAP_7_TO_8_BASE    = 0.12
local EXIT_GAP_8_TO_RESTART_BASE = 0.25

-- ================= COORDINATES =================
local START_X1, START_X2 = 1282, 1379
local START_Y1, START_Y2 =  606,  625

local FIRE1_X1, FIRE1_X2 = 718, 841
local FIRE1_Y1, FIRE1_Y2 = 289, 354

local FIRE2_X1, FIRE2_X2 = 800, 854
local FIRE2_Y1, FIRE2_Y2 = 331, 375

local TRUEFIRE_X1, TRUEFIRE_X2 = 800, 827
local TRUEFIRE_Y1, TRUEFIRE_Y2 = 384, 410

local B_X1, B_X2 = 635, 656
local B_Y1, B_Y2 = 493, 510

local C_X1, C_X2 = 748, 775
local C_Y1, C_Y2 = 541, 562

local EXIT7_X1, EXIT7_X2 = 907, 970
local EXIT7_Y1, EXIT7_Y2 = 680, 692

local EXIT8_X1, EXIT8_X2 = 888, 938
local EXIT8_Y1, EXIT8_Y2 = 678, 691

local A_X1, A_X2 = 513, 543
local A_Y1, A_Y2 = 422, 444

local PASS_X1, PASS_X2 = 60, 88
local PASS_Y1, PASS_Y2 = 258, 275

local R_X1, R_X2 = 366, 371
local R_Y1, R_Y2 = 868, 874

-- ================= DEBUG HELPERS =================
local function dbg(msg)
  if debug then
    print(os.date("%H:%M:%S") .. " | " .. msg)
  end
end

local function idbg(msg)
  if PRINT_IDLE_DEBUG then
    print(os.date("%H:%M:%S") .. " | " .. msg)
  end
end

local function notify(msg)
  hs.notify.new({title="Clicker", informativeText=msg}):send()
end

-- ================= RANDOM HELPERS =================
local function randRange(a, b)
  local lo, hi = math.min(a, b), math.max(a, b)
  return lo + math.random() * (hi - lo)
end

local function randPoint(x1, x2, y1, y2)
  return { x = randRange(x1, x2), y = randRange(y1, y2) }
end

local function i(n) return math.floor(n + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Randomize delays: base-0.16 .. base+0.15 (clamped >= 0)
local function jitterDelay(base)
  local lo = math.max(0, base - 0.16)
  local hi = math.max(0, base + 0.15)
  return randRange(lo, hi)
end

local function dClickSettle() return jitterDelay(CLICK_SETTLE_BASE) end
local function dA() return jitterDelay(PAUSE_AFTER_A_BASE) end
local function dB() return jitterDelay(PAUSE_AFTER_B_BASE) end
local function dC() return jitterDelay(PAUSE_AFTER_C_BASE) end
local function dFireWin() return jitterDelay(FIRE_WINDOW_BASE) end
local function dPass() return jitterDelay(PAUSE_AFTER_PASS_BASE) end
local function dLoopGap() return jitterDelay(LOOP_GAP_BASE) end
local function dExitGap1() return jitterDelay(EXIT_GAP_7_TO_8_BASE) end
local function dExitGap2() return jitterDelay(EXIT_GAP_8_TO_RESTART_BASE) end

-- ================= STATE =================
local running = false
local WAITING = false

local stepTimer, moveTimer = nil, nil
local greenPollTimer = nil
local idleTimer = nil

-- idle controls
local idleEnabledThisCycle = true
local driftX, driftY = 0, 0

local function cancelTimers()
  if moveTimer then moveTimer:stop(); moveTimer=nil end
  if stepTimer then stepTimer:stop(); stepTimer=nil end
  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end
  if idleTimer then idleTimer:stop(); idleTimer=nil end
end

local function stopAndQuitFrontmost()
  dbg("=== CYCLE LIMIT REACHED → STOP + QUIT FRONTMOST APP ===")
  running = false
  WAITING = false
  cancelTimers()
  notify("Cycle limit reached. Quitting frontmost app.")

  local app = hs.application.frontmostApplication()
  if app then
    dbg("Quitting app: " .. (app:name() or "(unknown)"))
    app:kill() -- polite quit (like Cmd+Q)
  end
end

-- ================= SNAPSHOT / COLOR =================
local function snapshotColorAtAbsolute(ax, ay)
  local scr = hs.screen.find(hs.geometry.point(ax,ay)) or hs.screen.mainScreen()
  local frame = scr:fullFrame()
  local scale = (scr:currentMode() or {}).scale or 1
  local img = scr:snapshot()
  local px = (ax - frame.x) * scale
  local py = (ay - frame.y) * scale
  local c = img:colorAt(hs.geometry.point(px,py))
  if not c then return nil end
  return hs.drawing.color.asRGB(c)
end

-- -------- GREEN gate --------
local function isGreenish(rgb)
  local r,g,b = rgb.red*255, rgb.green*255, rgb.blue*255
  return g>=GREEN_MIN_G and (g-r)>=GREEN_DELTA and (g-b)>=GREEN_DELTA
end

local function areaLooksGreen()
  local hits = 0
  for _=1,GREEN_SAMPLES do
    local rgb = snapshotColorAtAbsolute(
      randRange(GREEN_X1,GREEN_X2),
      randRange(GREEN_Y1,GREEN_Y2)
    )
    if rgb and isGreenish(rgb) then hits = hits + 1 end
  end
  local ok = hits >= math.ceil(GREEN_SAMPLES*GREEN_HIT_RATIO)
  if PRINT_EVERY_GREEN_CHECK then
    dbg(("GREEN CHECK: hits=%d/%d → %s"):format(hits, GREEN_SAMPLES, ok and "TRUE" or "FALSE"))
  end
  return ok, hits
end

-- -------- R identifiers --------
local function isFireId(rgb)
  local r,g,b = rgb.red*255, rgb.green*255, rgb.blue*255
  return (r < 40) and (g < 30) and (b < 30) and (r >= g) and (g >= b)
end

local function isYellowId(rgb)
  local r,g,b = rgb.red*255, rgb.green*255, rgb.blue*255
  return (r >= 75 and r <= 140) and (g <= 45) and (b <= 35) and ((r - g) >= 40) and ((r - b) >= 45)
end

local function sampleR()
  local ax = randRange(R_X1,R_X2)
  local ay = randRange(R_Y1,R_Y2)
  local rgb = snapshotColorAtAbsolute(ax, ay)
  if rgb then
    dbg(("R CHECK: RGB=(%d,%d,%d)"):format(i(rgb.red*255), i(rgb.green*255), i(rgb.blue*255)))
  else
    dbg("R CHECK: rgb=nil")
  end
  return rgb
end

-- ================= MOTION =================
local function smoothMoveTo(pt, cb, durOverride)
  if not running then return end
  WAITING = false

  local dur = durOverride or (moveDurationMin + math.random()*(moveDurationMax-moveDurationMin))
  local start = hs.mouse.absolutePosition()
  local dx,dy = pt.x-start.x, pt.y-start.y
  local interval = 1/moveFPS
  local stepsCount = math.max(1, math.floor(dur/interval))
  local k=0

  if moveTimer then moveTimer:stop(); moveTimer=nil end

  moveTimer = hs.timer.doEvery(interval, function()
    if not running then
      moveTimer:stop(); moveTimer=nil
      return
    end
    k=k+1
    local t=k/stepsCount
    t=t*t*(3-2*t)
    hs.mouse.absolutePosition({x=start.x+dx*t,y=start.y+dy*t})
    if k>=stepsCount then
      moveTimer:stop(); moveTimer=nil
      if cb then cb() end
    end
  end)
end

-- ================= GUARANTEED IDLE TIMER =================
local function idleDoAction(tag)
  -- drift accumulates
  driftX = clamp(driftX + DRIFT_BIAS_X + randRange(-DRIFT_NOISE, DRIFT_NOISE), -DRIFT_MAX, DRIFT_MAX)
  driftY = clamp(driftY + DRIFT_BIAS_Y + randRange(-DRIFT_NOISE, DRIFT_NOISE), -DRIFT_MAX, DRIFT_MAX)

  local p = hs.mouse.absolutePosition()
  local doLong = (math.random() < IDLE_LONG_DRAG_PROB)

  if doLong then
    local ang = randRange(0, math.pi*2)
    local dist = randRange(IDLE_LONG_DRAG_DIST_MIN, IDLE_LONG_DRAG_DIST_MAX)
    local out = { x = p.x + math.cos(ang)*dist + driftX, y = p.y + math.sin(ang)*dist + driftY }
    local back = { x = p.x + driftX + randRange(-2,2), y = p.y + driftY + randRange(-2,2) }
    local dur = randRange(IDLE_LONG_DRAG_DUR_MIN, IDLE_LONG_DRAG_DUR_MAX)
    idbg(("IDLE(%s): LONG drag dur=%.2f drift=(%.1f,%.1f)"):format(tag or "wait", dur, driftX, driftY))

    smoothMoveTo(out, function()
      if not running then return end
      hs.timer.doAfter(randRange(0.06, 0.18), function()
        if not running or moveTimer then return end
        smoothMoveTo(back, nil, randRange(0.18, 0.55))
      end)
    end, dur)
  else
    local n = randRange(IDLE_NUDGE_MIN, IDLE_NUDGE_MAX)
    local out = { x = p.x + randRange(-n,n) + driftX*0.25, y = p.y + randRange(-n,n) + driftY*0.25 }
    local back = { x = p.x + driftX*0.25 + randRange(-1,1), y = p.y + driftY*0.25 + randRange(-1,1) }
    idbg(("IDLE(%s): nudge drift=(%.1f,%.1f)"):format(tag or "wait", driftX, driftY))

    smoothMoveTo(out, function()
      if not running then return end
      hs.timer.doAfter(randRange(0.04, 0.12), function()
        if not running or moveTimer then return end
        smoothMoveTo(back, nil, randRange(0.05, 0.16))
      end)
    end, randRange(0.06, 0.18))
  end
end

local function ensureIdleTimer()
  if idleTimer then return end
  idleTimer = hs.timer.doEvery(IDLE_TIMER_TICK, function()
    if not running then return end

    if not WAITING then
      -- idbg("IDLE: skip (not waiting)")
      return
    end
    if not idleEnabledThisCycle then
      -- idbg("IDLE: skip (disabled this cycle)")
      return
    end
    if moveTimer then
      -- idbg("IDLE: skip (scripted move active)")
      return
    end

    if math.random() < IDLE_ACTION_PROB_PER_TICK then
      idleDoAction("waiting")
    end
  end)
end

-- ================= WAIT (with WAITING flag) =================
local function wait(seconds, cb, tag)
  if stepTimer then stepTimer:stop(); stepTimer=nil end
  if seconds <= 0 then if cb then cb() end; return end

  WAITING = true
  ensureIdleTimer()

  local deadline = hs.timer.secondsSinceEpoch() + seconds
  stepTimer = hs.timer.doEvery(0.05, function()
    if not running then
      stepTimer:stop(); stepTimer=nil
      return
    end
    if hs.timer.secondsSinceEpoch() >= deadline then
      stepTimer:stop(); stepTimer=nil
      WAITING = false
      if cb then cb() end
    end
  end)
end

-- ================= CLICK =================
local function doClickAt(pt, label, cb)
  dbg(("CLICK %s → (%.0f,%.0f)"):format(label, pt.x, pt.y))
  WAITING = false
  smoothMoveTo(pt, function()
    wait(dClickSettle(), function()
      if not running then return end
      WAITING = false
      hs.eventtap.leftClick(hs.geometry.point(pt.x,pt.y))
      if cb then cb() end
    end, "settle")
  end)
end

local function clickTrueFire(cb)
  dbg("ACTION: TRUE FIRE click")
  doClickAt(randPoint(TRUEFIRE_X1, TRUEFIRE_X2, TRUEFIRE_Y1, TRUEFIRE_Y2), "TRUE FIRE", cb)
end

-- ================= FLOW DECLS =================
local function runStep(_) end
local function enterLoop() end
local function runExit() end

-- Poll green for `duration`; sets WAITING=true for whole window
local function pollGreenFor(duration, label, onTimeout)
  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end

  dbg(("GREEN WATCH START (%s) for %.2fs"):format(label, duration))
  WAITING = true
  ensureIdleTimer()

  local deadline = hs.timer.secondsSinceEpoch() + duration
  greenPollTimer = hs.timer.doEvery(GREEN_POLL_INTERVAL, function()
    if not running then
      greenPollTimer:stop(); greenPollTimer=nil
      return
    end

    local ok = areaLooksGreen()
    if ok then
      greenPollTimer:stop(); greenPollTimer=nil
      WAITING = false
      dbg(("GREEN HIT during %s → EXIT (7,8)"):format(label))
      return runExit()
    end

    if hs.timer.secondsSinceEpoch() >= deadline then
      greenPollTimer:stop(); greenPollTimer=nil
      WAITING = false
      dbg(("GREEN WATCH END (%s): no hit"):format(label))
      if onTimeout then onTimeout() end
    end
  end)
end

-- Steps 7–8 (exit), then restart at Step 1
function runExit()
  if not running then return end
  dbg("== EXIT SEQUENCE START ==")

  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end
  WAITING = false

  dbg("Step 7: EXIT click 1")
  doClickAt(randPoint(EXIT7_X1, EXIT7_X2, EXIT7_Y1, EXIT7_Y2), "EXIT 7", function()
    wait(dExitGap1(), function()
      dbg("Step 8: EXIT click 2")
      doClickAt(randPoint(EXIT8_X1, EXIT8_X2, EXIT8_Y1, EXIT8_Y2), "EXIT 8", function()
        wait(dExitGap2(), function()
          dbg("EXIT complete")

          cyclesCompleted = cyclesCompleted + 1
          dbg(("CYCLES COMPLETED: %d"):format(cyclesCompleted))

          if STOP_AFTER_CYCLES > 0 and cyclesCompleted >= STOP_AFTER_CYCLES then
            return stopAndQuitFrontmost()
          end

          dbg("→ restarting at Step 1")
          runStep(1)
        end, "exitgap2")
      end)
    end, "exitgap1")
  end)
end

-- LOOP until green hits
function enterLoop()
  if not running then return end
  dbg("== ENTER LOOP ==")

  local ok = areaLooksGreen()
  if ok then
    dbg("GREEN already true on loop entry → EXIT")
    return runExit()
  end

  dbg("LOOP: click A")
  doClickAt(randPoint(A_X1,A_X2,A_Y1,A_Y2), "A", function()
    wait(dA(), function()
      local r1 = sampleR()
      if r1 and isFireId(r1) then
        dbg("LOOP DECISION: R says FIRE → TRUE FIRE")
        return clickTrueFire(function()
          pollGreenFor(dFireWin(), "LOOP FIRE", function()
            wait(dLoopGap(), enterLoop, "loopgap")
          end)
        end)
      end

      if r1 and isYellowId(r1) then
        dbg("LOOP DECISION: R says NOT READY → click B")
        doClickAt(randPoint(B_X1,B_X2,B_Y1,B_Y2), "B", function()
          wait(dB(), function()
            local r2 = sampleR()
            if r2 and isFireId(r2) then
              dbg("LOOP DECISION: after B, R says FIRE → TRUE FIRE")
              return clickTrueFire(function()
                pollGreenFor(dFireWin(), "LOOP FIRE", function()
                  wait(dLoopGap(), enterLoop, "loopgap")
                end)
              end)
            end

            if r2 and isYellowId(r2) then
              dbg("LOOP DECISION: after B, still NOT READY → click C")
              doClickAt(randPoint(C_X1,C_X2,C_Y1,C_Y2), "C", function()
                wait(dC(), function()
                  local r3 = sampleR()
                  if r3 and isFireId(r3) then
                    dbg("LOOP DECISION: after C, R says FIRE → TRUE FIRE")
                    return clickTrueFire(function()
                      pollGreenFor(dFireWin(), "LOOP FIRE", function()
                        wait(dLoopGap(), enterLoop, "loopgap")
                      end)
                    end)
                  end

                  dbg("LOOP DECISION: after C, still NOT READY → PASS")
                  doClickAt(randPoint(PASS_X1,PASS_X2,PASS_Y1,PASS_Y2), "PASS", function()
                    wait(dPass() + dLoopGap(), enterLoop, "passwait")
                  end)
                end, "afterC")
              end)
              return
            end

            dbg("LOOP DECISION: after B, no match → PASS (conservative)")
            doClickAt(randPoint(PASS_X1,PASS_X2,PASS_Y1,PASS_Y2), "PASS", function()
              wait(dPass() + dLoopGap(), enterLoop, "passwait")
            end)
          end, "afterB")
        end)
        return
      end

      dbg("LOOP DECISION: R no match → wait and repeat loop")
      wait(dLoopGap(), enterLoop, "loopgap")
    end, "afterA")
  end)
end

-- Steps 1–6
function runStep(n)
  if not running then return end
  dbg(("== ENTER STEP %d =="):format(n))

  if n == 1 then
    idleEnabledThisCycle = (math.random() >= IDLE_DO_NOTHING_CYCLE_PROB)
    dbg(("IDLE THIS CYCLE: %s"):format(idleEnabledThisCycle and "ENABLED" or "DISABLED"))

    return doClickAt(randPoint(START_X1, START_X2, START_Y1, START_Y2), "STEP1 START", function()
      runStep(2)
    end)
  end

  if n == 2 then
    doClickAt(randPoint(FIRE1_X1, FIRE1_X2, FIRE1_Y1, FIRE1_Y2), "STEP2 FIRE #1", function()
      pollGreenFor(dFireWin(), "STEP2 FIRE WINDOW", function()
        runStep(3)
      end)
    end)
    return
  end

  if n == 3 then
    doClickAt(randPoint(B_X1, B_X2, B_Y1, B_Y2), "STEP3 B", function()
      runStep(4)
    end)
    return
  end

  if n == 4 then
    doClickAt(randPoint(FIRE2_X1, FIRE2_X2, FIRE2_Y1, FIRE2_Y2), "STEP4 FIRE #2", function()
      pollGreenFor(dFireWin(), "STEP4 FIRE WINDOW", function()
        runStep(5)
      end)
    end)
    return
  end

  if n == 5 then
    doClickAt(randPoint(C_X1, C_X2, C_Y1, C_Y2), "STEP5 C", function()
      runStep(6)
    end)
    return
  end

  if n == 6 then
    clickTrueFire(function()
      pollGreenFor(dFireWin(), "STEP6 FIRE WINDOW", function()
        dbg("No green after Step 6 fire window → ENTER LOOP")
        enterLoop()
      end)
    end)
    return
  end
end

-- ================= CONTROLS =================
local function start()
  if running then return end
  running = true

  math.randomseed(hs.timer.absoluteTime())

  cancelTimers()
  cyclesCompleted = 0
  driftX, driftY = 0, 0
  WAITING = false

  ensureIdleTimer()

  notify("Started")
  dbg("=== STARTED ===")
  runStep(1)
end

local function stop()
  running = false
  WAITING = false
  cancelTimers()
  notify("Stopped")
  dbg("=== STOPPED ===")
end

hs.hotkey.bind({"cmd","alt","ctrl"}, "S", start)
hs.hotkey.bind({"cmd","alt","ctrl"}, "X", stop)

hs.hotkey.bind({"cmd","alt","ctrl"}, "P", function()
  local p = hs.mouse.absolutePosition()
  print(string.format("Mouse abs: x=%.0f y=%.0f", p.x, p.y))
end)

hs.hotkey.bind({"cmd","alt","ctrl"}, "C", function()
  local p = hs.mouse.absolutePosition()
  local rgb = snapshotColorAtAbsolute(p.x, p.y)
  if not rgb then
    print("Cursor sample: nil color")
    return
  end
  print(string.format("Cursor RGB=(%d,%d,%d)", i(rgb.red*255), i(rgb.green*255), i(rgb.blue*255)))
end)

notify("Loaded (GUARANTEED idle during waits + green watch). Start(S), Stop(X)")
dbg("=== LOADED INIT.LUA ===")
