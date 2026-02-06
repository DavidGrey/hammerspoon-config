-- =========================================================
--  Smooth-Move Multi-Point Clicker
--  + GREEN Gate (global exits)
--  + Standardized Steps + Debug Prints
--  + Randomized delays: (base - 0.16) .. (base + 0.15)
--  + OPTIONAL: Stop after N full cycles, then quit frontmost app
--
--  Steps:
--    1 Start
--    2 Fire #1   (fire-treated: green watched for full fire window)
--    3 Click B
--    4 Fire #2   (fire-treated: green watched for full fire window)
--    5 Click C
--    6 Fire #3   (TRUE FIRE: green watched for full fire window)
--    7 Exit click 1
--    8 Exit click 2
--    If GREEN hits during any fire window or loop → do Steps 7&8 then restart at Step 1
--    If after Step 6 fire window no green → enter LOOP
--
--  LOOP (until green):
--    Click A → check R
--      if R==FIRE -> TRUE FIRE
--      if R==YELLOW -> Click B → check R
--        if R==FIRE -> TRUE FIRE
--        if R==YELLOW -> Click C → check R
--          if R==FIRE -> TRUE FIRE
--          else -> PASS
--      else -> wait + repeat
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

-- ===== Optional: stop after N full cycles =====
-- -1 = ignore (run forever)
--  1+ = run that many full cycles, then quit frontmost app + stop script
local STOP_AFTER_CYCLES = 30
local cyclesCompleted = 0

-- Smooth mouse movement
local moveDurationMin = 0.02
local moveDurationMax = 0.04
local moveFPS = 240

-- -------- GREEN gate --------
local GREEN_X1, GREEN_X2 = 828, 830
local GREEN_Y1, GREEN_Y2 = 678, 680
local GREEN_SAMPLES = 5
local GREEN_HIT_RATIO = 0.40
local GREEN_MIN_G = 90
local GREEN_DELTA = 40
local GREEN_POLL_INTERVAL = 0.15

-- -------- Base delays (these will be randomized ± as requested) --------
local CLICK_SETTLE_BASE       = 0.06

local PAUSE_AFTER_A_BASE      = 0.14
local PAUSE_AFTER_B_BASE      = 0.14
local PAUSE_AFTER_C_BASE      = 0.14

local FIRE_WINDOW_BASE        = 9.08  -- how long we watch for green after a fire
local PAUSE_AFTER_PASS_BASE   = 5.10
local LOOP_GAP_BASE           = 0.15

local EXIT_GAP_7_TO_8_BASE    = 0.12
local EXIT_GAP_8_TO_RESTART_BASE = 0.25

-- ================= COORDINATES =================
-- Step 1: Start
local START_X1, START_X2 = 1282, 1379
local START_Y1, START_Y2 =  606,  625

-- Step 2: Fire #1 box
local FIRE1_X1, FIRE1_X2 = 718, 841
local FIRE1_Y1, FIRE1_Y2 = 289, 354

-- Step 4: Fire #2 box
local FIRE2_X1, FIRE2_X2 = 800, 854
local FIRE2_Y1, FIRE2_Y2 = 331, 375

-- TRUE FIRE button (Step 6 + loop fires)
local TRUEFIRE_X1, TRUEFIRE_X2 = 800, 827
local TRUEFIRE_Y1, TRUEFIRE_Y2 = 384, 410

-- B
local B_X1, B_X2 = 635, 656
local B_Y1, B_Y2 = 493, 510

-- C
local C_X1, C_X2 = 748, 775
local C_Y1, C_Y2 = 541, 562

-- Exit (Steps 7–8)
local EXIT7_X1, EXIT7_X2 = 907, 970
local EXIT7_Y1, EXIT7_Y2 = 680, 692

local EXIT8_X1, EXIT8_X2 = 888, 938
local EXIT8_Y1, EXIT8_Y2 = 678, 691

-- Loop helper points
local A_X1, A_X2 = 513, 543
local A_Y1, A_Y2 = 422, 444

local PASS_X1, PASS_X2 = 60, 88
local PASS_Y1, PASS_Y2 = 258, 275

-- R (ready-check) box
local R_X1, R_X2 = 366, 371
local R_Y1, R_Y2 = 868, 874

-- ================= DEBUG HELPERS =================
local function dbg(msg)
  if debug then
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

-- Randomize delays: base-0.16 .. base+0.15 (clamped >= 0)
local function jitterDelay(base)
  local lo = math.max(0, base - 0.16)
  local hi = math.max(0, base + 0.15)
  return randRange(lo, hi)
end

-- Delay getters (so everything is consistently randomized)
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
local stepTimer, moveTimer = nil, nil
local greenPollTimer = nil

local function cancelTimers()
  if moveTimer then moveTimer:stop(); moveTimer=nil end
  if stepTimer then stepTimer:stop(); stepTimer=nil end
  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end
end

local function stopAndQuitFrontmost()
  dbg("=== CYCLE LIMIT REACHED → STOP + QUIT FRONTMOST APP ===")
  running = false
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

-- ================= MOTION / CLICK =================
local function smoothMoveTo(pt, cb)
  if not running then return end
  local dur = moveDurationMin + math.random()*(moveDurationMax-moveDurationMin)
  local start = hs.mouse.absolutePosition()
  local dx,dy = pt.x-start.x, pt.y-start.y
  local interval = 1/moveFPS
  local stepsCount = math.max(1, math.floor(dur/interval))
  local k=0
  if moveTimer then moveTimer:stop() end
  moveTimer = hs.timer.doEvery(interval, function()
    if not running then moveTimer:stop(); return end
    k=k+1
    local t=k/stepsCount; t=t*t*(3-2*t)
    hs.mouse.absolutePosition({x=start.x+dx*t,y=start.y+dy*t})
    if k>=stepsCount then moveTimer:stop(); if cb then cb() end end
  end)
end

local function doClickAt(pt, label, cb)
  dbg(("CLICK %s → (%.0f,%.0f)"):format(label, pt.x, pt.y))
  smoothMoveTo(pt, function()
    stepTimer = hs.timer.doAfter(dClickSettle(), function()
      if not running then return end
      hs.eventtap.leftClick(hs.geometry.point(pt.x,pt.y))
      if cb then cb() end
    end)
  end)
end

local function clickTrueFire(cb)
  local fp = randPoint(TRUEFIRE_X1, TRUEFIRE_X2, TRUEFIRE_Y1, TRUEFIRE_Y2)
  dbg("ACTION: TRUE FIRE click")
  doClickAt(fp, "TRUE FIRE", cb)
end

-- ================= FLOW DECLS =================
local function runStep(_) end
local function enterLoop() end
local function runExit() end

-- Poll green for `duration`; if green hits -> exit; else onTimeout()
local function pollGreenFor(duration, label, onTimeout)
  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end
  dbg(("GREEN WATCH START (%s) for %.2fs"):format(label, duration))

  local deadline = hs.timer.secondsSinceEpoch() + duration
  greenPollTimer = hs.timer.doEvery(GREEN_POLL_INTERVAL, function()
    if not running then greenPollTimer:stop(); greenPollTimer=nil; return end

    local ok = areaLooksGreen()
    if ok then
      greenPollTimer:stop(); greenPollTimer=nil
      dbg(("GREEN HIT during %s → EXIT (7,8)"):format(label))
      return runExit()
    end

    if hs.timer.secondsSinceEpoch() >= deadline then
      greenPollTimer:stop(); greenPollTimer=nil
      dbg(("GREEN WATCH END (%s): no hit"):format(label))
      if onTimeout then onTimeout() end
    end
  end)
end

-- Steps 7–8 (exit), then restart at Step 1 (or stop after N cycles)
function runExit()
  if not running then return end
  dbg("== EXIT SEQUENCE START ==")

  if greenPollTimer then greenPollTimer:stop(); greenPollTimer=nil end

  dbg("Step 7: EXIT click 1")
  local p7 = randPoint(EXIT7_X1, EXIT7_X2, EXIT7_Y1, EXIT7_Y2)
  doClickAt(p7, "EXIT 7", function()
    stepTimer = hs.timer.doAfter(dExitGap1(), function()
      if not running then return end
      dbg("Step 8: EXIT click 2")
      local p8 = randPoint(EXIT8_X1, EXIT8_X2, EXIT8_Y1, EXIT8_Y2)
      doClickAt(p8, "EXIT 8", function()
        stepTimer = hs.timer.doAfter(dExitGap2(), function()
          if not running then return end

          dbg("EXIT complete")

          cyclesCompleted = cyclesCompleted + 1
          dbg(("CYCLES COMPLETED: %d"):format(cyclesCompleted))

          if STOP_AFTER_CYCLES > 0 and cyclesCompleted >= STOP_AFTER_CYCLES then
            return stopAndQuitFrontmost()
          end

          dbg("→ restarting at Step 1")
          runStep(1)
        end)
      end)
    end)
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
  local Apt = randPoint(A_X1,A_X2,A_Y1,A_Y2)
  doClickAt(Apt, "A", function()
    stepTimer = hs.timer.doAfter(dA(), function()
      if not running then return end

      local r1 = sampleR()
      if r1 and isFireId(r1) then
        dbg("LOOP DECISION: R says FIRE → TRUE FIRE")
        return clickTrueFire(function()
          pollGreenFor(dFireWin(), "LOOP FIRE", function()
            stepTimer = hs.timer.doAfter(dLoopGap(), enterLoop)
          end)
        end)
      end

      if r1 and isYellowId(r1) then
        dbg("LOOP DECISION: R says NOT READY → click B")
        local Bpt = randPoint(B_X1,B_X2,B_Y1,B_Y2)
        doClickAt(Bpt, "B", function()
          stepTimer = hs.timer.doAfter(dB(), function()
            if not running then return end

            local r2 = sampleR()
            if r2 and isFireId(r2) then
              dbg("LOOP DECISION: after B, R says FIRE → TRUE FIRE")
              return clickTrueFire(function()
                pollGreenFor(dFireWin(), "LOOP FIRE", function()
                  stepTimer = hs.timer.doAfter(dLoopGap(), enterLoop)
                end)
              end)
            end

            if r2 and isYellowId(r2) then
              dbg("LOOP DECISION: after B, still NOT READY → click C")
              local Cpt = randPoint(C_X1,C_X2,C_Y1,C_Y2)
              doClickAt(Cpt, "C", function()
                stepTimer = hs.timer.doAfter(dC(), function()
                  if not running then return end

                  local r3 = sampleR()
                  if r3 and isFireId(r3) then
                    dbg("LOOP DECISION: after C, R says FIRE → TRUE FIRE")
                    return clickTrueFire(function()
                      pollGreenFor(dFireWin(), "LOOP FIRE", function()
                        stepTimer = hs.timer.doAfter(dLoopGap(), enterLoop)
                      end)
                    end)
                  end

                  dbg("LOOP DECISION: after C, still NOT READY → PASS")
                  doClickAt(randPoint(PASS_X1,PASS_X2,PASS_Y1,PASS_Y2), "PASS", function()
                    stepTimer = hs.timer.doAfter(dPass() + dLoopGap(), enterLoop)
                  end)
                end)
              end)
              return
            end

            dbg("LOOP DECISION: after B, no match → PASS (conservative)")
            doClickAt(randPoint(PASS_X1,PASS_X2,PASS_Y1,PASS_Y2), "PASS", function()
              stepTimer = hs.timer.doAfter(dPass() + dLoopGap(), enterLoop)
            end)
          end)
        end)
        return
      end

      dbg("LOOP DECISION: R no match → wait and repeat loop")
      stepTimer = hs.timer.doAfter(dLoopGap(), enterLoop)
    end)
  end)
end

-- Steps 1–6
function runStep(n)
  if not running then return end
  dbg(("== ENTER STEP %d =="):format(n))

  if n == 1 then
    local p1 = randPoint(START_X1, START_X2, START_Y1, START_Y2)
    return doClickAt(p1, "STEP1 START", function() runStep(2) end)
  end

  if n == 2 then
    local p2 = randPoint(FIRE1_X1, FIRE1_X2, FIRE1_Y1, FIRE1_Y2)
    doClickAt(p2, "STEP2 FIRE #1", function()
      pollGreenFor(dFireWin(), "STEP2 FIRE WINDOW", function()
        runStep(3)
      end)
    end)
    return
  end

  if n == 3 then
    local p3 = randPoint(B_X1, B_X2, B_Y1, B_Y2)
    return doClickAt(p3, "STEP3 B", function() runStep(4) end)
  end

  if n == 4 then
    local p4 = randPoint(FIRE2_X1, FIRE2_X2, FIRE2_Y1, FIRE2_Y2)
    doClickAt(p4, "STEP4 FIRE #2", function()
      pollGreenFor(dFireWin(), "STEP4 FIRE WINDOW", function()
        runStep(5)
      end)
    end)
    return
  end

  if n == 5 then
    local p5 = randPoint(C_X1, C_X2, C_Y1, C_Y2)
    return doClickAt(p5, "STEP5 C", function() runStep(6) end)
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
  math.randomseed(os.time())
  cancelTimers()
  cyclesCompleted = 0
  notify("Started")
  dbg("=== STARTED ===")
  runStep(1)
end

local function stop()
  running = false
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

notify("Loaded (randomized delays + cycle limit). Start(S), Stop(X)")
dbg("=== LOADED INIT.LUA ===")
