-- 玉長賽事 v10 · CSP online script (Ctrl+M)
-- Layout rule: everything flows top-to-bottom (no absolute positioning), so nothing can overlap.
-- Requests: hidden "ACR|" chat lines. Replies: server HTTP mailbox (port 8766) + chat fallback.
local MENU_VERSION = '11'
local REPLAY_PORT, MAILBOX_PORT = 8765, 8766
local W, H, NAV_W = 780, 720, 176

-- state -----------------------------------------------------------------------
local visible, page = false, 'go'
local gotHello, clock = false, 0
local P = nil   -- pedal statistics of the current run
local sub = { go = 'practice', results = 'last', board = 'board' }
local S = {
  routes = {}, route = nil, laps = 1, admin = false, roster = {}, invite = nil, locked = {},
  lobby = nil, ready = false, hud = nil, result = nil, stats = nil, series = nil, go = nil, gate = nil,
  records = nil, board = {}, boardKey = nil, boardClass = '', classes = {}, weekly = nil,
  lobbies = {}, duelMode = 'duel', split = nil, msg = nil, msgColor = nil, msgUntil = 0,
  pollError = nil, routeName = 'east-full', wrongWay = 0, routeInfo = {},
}
local A = { invite_seconds = '30', countdown_seconds = '5', limit_seconds = '900', time = '18:30', raceId = '' }

-- theme -----------------------------------------------------------------------
local C = {
  bg = rgbm(0.06, 0.07, 0.09, 0.97), nav = rgbm(0.04, 0.045, 0.06, 1), panel = rgbm(0.10, 0.115, 0.15, 1),
  accent = rgbm(0.96, 0.62, 0.16, 1), accentHi = rgbm(1, 0.72, 0.3, 1), accentSoft = rgbm(0.96, 0.62, 0.16, 0.16),
  text = rgbm(0.94, 0.95, 0.98, 1), dim = rgbm(0.6, 0.64, 0.72, 1), dark = rgbm(0.08, 0.06, 0.03, 1),
  btn = rgbm(0.15, 0.17, 0.22, 1), btnHi = rgbm(0.2, 0.23, 0.3, 1),
  ok = rgbm(0.4, 0.88, 0.55, 1), okBtn = rgbm(0.17, 0.45, 0.27, 1), bad = rgbm(1, 0.45, 0.42, 1), badBtn = rgbm(0.5, 0.18, 0.18, 1),
}
local FONT, BOLD = 'Microsoft JhengHei UI', 'Microsoft JhengHei UI:Weight=Bold'
local WF_PAD = (type(ui.WindowFlags) == 'table' and ui.WindowFlags.AlwaysUseWindowPadding) or 0
local function pushVar(name, value)
  local id = ui.StyleVar and ui.StyleVar[name]
  if id then ui.pushStyleVar(id, value); return 1 end
  return 0
end

-- protocol ----------------------------------------------------------------------
-- outgoing commands are queued and sent one by one: the game drops chat lines sent in the same instant
local outbox, outboxTimer = {}, 0
local function send(...)
  local line = 'ACR|' .. table.concat({ ... }, '|')
  if outbox[#outbox] ~= line then outbox[#outbox + 1] = line end
  -- when backed up, drop only routine messages (speed samples, list refreshes), never results
  local i = 1
  while #outbox > 25 and i <= #outbox do
    local kind = outbox[i]:match('^ACR|(%w+)')
    if kind == 'spd' or kind == 'roster' or kind == 'lobbies' or kind == 'records' or kind == 'classes' or kind == 'weekly' then
      table.remove(outbox, i)
    else
      i = i + 1
    end
  end
end
local function flushOutbox(dt)
  outboxTimer = outboxTimer - dt
  if outboxTimer > 0 or #outbox == 0 then return end
  ac.sendChatMessage(table.remove(outbox, 1))
  outboxTimer = 0.35
end

local function split(s, sep)
  local out = {}
  if not s or s == '' or s == '-' then return out end
  for part in (s .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
  return out
end

local function flash(text, color) S.msg, S.msgColor, S.msgUntil = text, color or C.dim, clock + 5 end

-- pedal statistics (measured in the game during a run) --------------------------------
local function pedalReset() P = { wallHits = 0, carHits = 0, lastHit = -9, lastSpeed = nil, t = 0, gasT = 0, gasSum = 0, fullT = 0, gasN = 0, gasOn = false,
                                 brakeT = 0, brakeSum = 0, brakeMax = 0, brakeN = 0, brakeOn = false } end
local function pedalSample(dt, car)
  if not P then pedalReset() end
  local gas, brake = car.gas or 0, car.brake or 0
  P.t = P.t + dt
  -- contacts: CSP collision info when available, otherwise a sudden deceleration without braking
  local speed = car.speedKmh or 0
  local hit, withCar = false, false
  if car.collidedWith ~= nil and car.collidedWith >= 0 then hit, withCar = true, true end
  if (car.collisionDepth or 0) > 0.01 then hit = true end
  if P.lastSpeed and dt > 0 and (P.lastSpeed - speed) / 3.6 / dt > 22 and brake < 0.5 then hit = true end
  P.lastSpeed = speed
  if hit then
    if P.t - P.lastHit > 1.5 then
      if withCar then P.carHits = P.carHits + 1 else P.wallHits = P.wallHits + 1 end
    end
    P.lastHit = P.t                     -- continuous scraping counts once
  end
  if gas > 0.05 then
    P.gasT, P.gasSum = P.gasT + dt, P.gasSum + gas * dt
    if gas > 0.95 then P.fullT = P.fullT + dt end
    if not P.gasOn then P.gasN = P.gasN + 1 end
  end
  P.gasOn = gas > 0.05
  if brake > 0.05 then
    P.brakeT, P.brakeSum = P.brakeT + dt, P.brakeSum + brake * dt
    P.brakeMax = math.max(P.brakeMax, brake)
    if not P.brakeOn then P.brakeN = P.brakeN + 1 end
  end
  P.brakeOn = brake > 0.05
end
local function pedalSummary()
  if not P or P.t <= 0 then return nil end
  local pct = function(a, b) return b > 0 and a / b * 100 or 0 end
  return {
    gas_share = pct(P.gasT, P.t), gas_avg = pct(P.gasSum, P.gasT), gas_full = pct(P.fullT, P.t),
    gas_presses = P.gasN, gas_hold = P.gasN > 0 and P.gasT / P.gasN or 0,
    brake_share = pct(P.brakeT, P.t), brake_avg = pct(P.brakeSum, P.brakeT), brake_max = P.brakeMax * 100,
    brake_presses = P.brakeN, brake_hold = P.brakeN > 0 and P.brakeT / P.brakeN or 0,
    wall_hits = P.wallHits, car_hits = P.carHits,
  }
end

local handlers = {}
handlers.routes = function(f)
  S.routes = split(f[2], ',')
  S.gates = {}
  local found = false
  for _, r in ipairs(S.routes) do if r == S.route then found = true end end
  if not found then S.route = S.routes[1] end
end
handlers.routeinfo = function(f)
  local pts = {}
  for _, p in ipairs(split(f[3], ';')) do
    local xy = split(p, ',')
    if #xy == 2 then pts[#pts + 1] = vec2(tonumber(xy[1]), tonumber(xy[2])) end
  end
  S.routeInfo[f[2]] = pts
end
handlers.gateinfo = function(f)
  local name, kind = f[2], f[3]
  local g = { kind = kind, a = vec2(tonumber(f[4]), tonumber(f[5])), b = vec2(tonumber(f[6]), tonumber(f[7])) }
  S.gates = S.gates or {}
  if kind == 's' or not S.gates[name] then S.gates[name] = {} end
  table.insert(S.gates[name], g)
end
handlers.routepath = function(f)
  local pts = {}
  for _, p in ipairs(split(f[3], ';')) do
    local xy = split(p, ',')
    if #xy == 2 then pts[#pts + 1] = vec2(tonumber(xy[1]), tonumber(xy[2])) end
  end
  if #pts > 1 then S.routePath = S.routePath or {}; S.routePath[f[2]] = pts end
end
handlers.locked = function(f) S.locked = {}; for _, r in ipairs(split(f[2], ',')) do S.locked[r] = true end end
handlers.admin = function(f) S.admin = f[2] == '1' end
handlers.roster = function(f)
  S.roster = {}
  for _, row in ipairs(split(f[2], ';')) do
    local p = split(row, ':')
    if #p >= 3 then S.roster[#S.roster + 1] = { slot = p[1], name = p[2], status = p[3] } end
  end
end
handlers.invited = function(f)
  S.invite = { slot = f[2], name = f[3], route = f[4], expires = clock + (tonumber(f[5]) or 30) }
  visible, page = true, 'go'
end
handlers.lobby = function(f)
  P = nil
  S.ghost, S.segments, S.runStart, S.ghostDelta = nil, nil, nil, nil
  S.newPB, S.chase, S.brakes = nil, nil, nil
  S.lastLaps = tonumber(f[4]) or 1
  S.lastRoute = f[3]
  S.lobby = { id = f[2], route = f[3], laps = f[4], solo = f[13] == '1' }
  S.gate = vec2((tonumber(f[5]) + tonumber(f[7])) / 2, (tonumber(f[6]) + tonumber(f[8])) / 2)
  S.gateDir = f[11] and vec2(tonumber(f[11]), tonumber(f[12])) or nil
  visible = false
  S.ready, S.hud, S.stats, S.split = false, nil, nil, nil
  page = 'go'
end
handlers.go = function(f) S.go = clock + (tonumber(f[2]) or 5) end
handlers.hud = function(f)
  S.runStart = clock - (tonumber(f[2]) or 0)
  S.hud = { time = tonumber(f[2]) or 0, laps = tonumber(f[3]) or 0, sectors = tonumber(f[4]) or 0, gap = f[5],
            pos = f[6], of = f[7], totalLaps = f[8], cps = tonumber(f[9]) or 0 }
end
handlers.split = function(f) S.split = { label = f[2], time = f[3], delta = f[4], untilT = clock + 4 } end
handlers.stats = function(f)
  S.stats = { top = f[2], avg = f[3], moving = f[4], stops = f[5], wall = f[6], car = f[7], third = f[8], jump = f[9] == '1',
              shifts = f[10] or '0', stopped = f[11] or '0', teleport = f[12] == '1' }
end
handlers.series = function(f) S.series = { me = f[2], them = f[3], round = f[4], done = f[5] == '1' } end
handlers.result = function(f)
  local ped = pedalSummary()
  S.pedals = ped
  if ped and f[2] then
    send('pedals', f[2], string.format('%.1f', ped.gas_share), string.format('%.1f', ped.gas_avg), string.format('%.1f', ped.gas_full),
      ped.gas_presses, string.format('%.2f', ped.gas_hold), string.format('%.1f', ped.brake_share), string.format('%.1f', ped.brake_avg),
      string.format('%.1f', ped.brake_max), ped.brake_presses, string.format('%.2f', ped.brake_hold), ped.wall_hits, ped.car_hits)
  end
  P = nil
  S.result = { id = f[2], status = f[3], best = f[4], won = f[5] == 'True', port = f[6] or tostring(REPLAY_PORT), video = f[7] ~= '0' }
  sub.results = 'last'
  S.lobby, S.hud, S.gate = nil, nil, nil
  visible, page = true, 'results'
  S.details = false
  if S.autoRerun and not S.series and not S.elim then S.rerunAt = clock + 6 end
  send('records')
end
handlers.records = function(f)
  local p = split(f[2], ':')
  S.records = { runs = p[1] or '0', done = p[2] or '0', best = {} }
  for _, row in ipairs(split(table.concat(p, ':', 3), ';')) do
    local r = split(row, ':')
    if #r == 2 then S.records.best[#S.records.best + 1] = r end
  end
end
handlers.board = function(f)
  S.board = {}
  for _, row in ipairs(split(f[3], ';')) do S.board[#S.board + 1] = split(row, ':') end
end
handlers.weekly = function(f)
  S.weekly = { route = f[2] ~= '-' and f[2] or nil, car = f[3] ~= '-' and f[3] or nil, board = {} }
  for _, row in ipairs(split(f[4], ';')) do S.weekly.board[#S.weekly.board + 1] = split(row, ':') end
end
handlers.classes = function(f) S.classes = split(f[2], ',') end
handlers.carlist = function(f)
  S.carList = {}
  for _, row in ipairs(split(f[2], ';')) do
    local p = split(row, '~')
    if #p >= 2 then S.carList[#S.carList + 1] = { id = p[1], name = p[2], class = p[3] or '' } end
  end
end
handlers.lobbies = function(f)
  S.lobbies = {}
  for _, row in ipairs(split(f[2], ';')) do
    local p = split(row, '~')
    if #p >= 6 then S.lobbies[#S.lobbies + 1] = { host = p[1], hostName = p[2], route = p[3], laps = p[4], count = p[5], names = p[6], kind = p[7] or 'race' } end
  end
end
handlers.cancelled = function(f)
  if S.lobby and S.lobby.id == f[2] then S.lobby, S.hud, S.gate = nil, nil, nil end
end
handlers.ghostpref = function(f) S.ghostPref = { mode = f[2], target = f[3] or '' } end
handlers.ghostlist = function(f)
  S.ghostList = { route = f[2], rows = {} }
  for _, row in ipairs(split(f[3], ';')) do
    local p = split(row, '~')
    if #p == 3 then S.ghostList.rows[#S.ghostList.rows + 1] = { id = p[1], name = p[2], time = p[3] } end
  end
end
handlers.ghost = function(f)
  if f[3] == 'off' or f[3] == 'none' then S.ghost = nil; return end
  local pts = {}
  for _, p in ipairs(split(f[5], ';')) do
    local v = split(p, ',')
    if #v == 3 then pts[#pts + 1] = { t = tonumber(v[1]), x = tonumber(v[2]), z = tonumber(v[3]) } end
  end
  if #pts > 1 then S.ghost = { route = f[2], label = f[3], time = f[4], pts = pts, idx = 1 } else S.ghost = nil end
end
handlers.segments = function(f)
  local mine, ref = {}, {}
  for _, v in ipairs(split(f[2], ',')) do mine[#mine + 1] = tonumber(v) end
  for _, v in ipairs(split(f[3], ',')) do ref[#ref + 1] = tonumber(v) end
  S.segments = { mine = mine, ref = ref, refName = f[4] ~= '-' and f[4] or nil }
end
handlers.badge = function(f)
  S.badgePopup = { name = f[2], desc = f[3], untilT = clock + 6 }
  send('profile')
end
handlers.badges = function(f)
  S.badges = { list = {}, total = tonumber(f[3]) or 12 }
  for _, row in ipairs(split(f[2], ';')) do
    local p = split(row, '~')
    if #p == 3 then S.badges.list[#S.badges.list + 1] = { id = p[1], name = p[2], desc = p[3] } end
  end
end
handlers.titles = function(f) S.titles = f[2] ~= '-' and f[2] or nil end
handlers.newpb = function(f) S.newPB = { time = f[2], gain = f[3] ~= '' and f[3] or nil } end
handlers.brakes = function(f)
  S.brakes = { route = f[2], pts = {} }
  for _, p in ipairs(split(f[3], ';')) do
    local v = split(p, ',')
    if #v == 3 then S.brakes.pts[#S.brakes.pts + 1] = { x = tonumber(v[1]), z = tonumber(v[2]), v = tonumber(v[3]) } end
  end
end
handlers.chase = function(f) S.chase = { follower = f[2], avg = f[3], max = f[4], score = f[5] } end
handlers.elim = function(f)
  S.elim = { round = f[2], alive = f[3], out = f[4], done = f[5] == '1' }
  flash(string.format('第 %s 輪淘汰：%s', f[2], f[4]), C.bad)
end
handlers.event = function(f)
  if f[2] == '-' then S.event = nil; return end
  S.event = { route = f[2], attempts = tonumber(f[3]) or 3, used = tonumber(f[4]) or 0, left = tonumber(f[5]) or 0,
              at = clock, board = {} }
  for _, row in ipairs(split(f[6], ';')) do S.event.board[#S.event.board + 1] = split(row, ':') end
end
handlers.ok = function(f) flash('✓ ' .. (f[2] or ''), C.ok) end
handlers.error = function(f) flash('✕ ' .. (f[2] or ''), C.bad) end
handlers.declined = function(f) flash((f[2] or '') .. ' 拒絕了邀請', C.bad) end
handlers.invite_expired = function() flash('邀請已逾時', C.dim) end

local function handle(message)
  local at = message:find('ACR|', 1, true)
  if not at then return false end
  local f = split(message:sub(at + 4), '|')
  if f[1] == 'routes' then
    gotHello = true
    if not S.carSent then
      S.carSent = true
      pcall(function()
        local id = ac.getCarID and ac.getCarID(0)
        local name = ac.getCarName and ac.getCarName(0)
        if id and name and name ~= '' then send('carname', id, (name:gsub('[|~:;]', ' '))) end
      end)
    end
  end
  local h = handlers[f[1]]
  if h then pcall(h, f) end
  return true
end

ac.onChatMessage(function(message) return handle(message) end)

-- ghost -------------------------------------------------------------------------
local function ghostAt(t)
  local g = S.ghost
  if not g then return nil end
  local pts = g.pts
  if t <= pts[1].t then return pts[1] end
  if t >= pts[#pts].t then return pts[#pts] end
  for i = 2, #pts do
    if pts[i].t >= t then
      local a, b = pts[i - 1], pts[i]
      local k = (t - a.t) / math.max(0.001, b.t - a.t)
      return { x = a.x + (b.x - a.x) * k, z = a.z + (b.z - a.z) * k, t = t }
    end
  end
end

local function updateGhostDelta(car)
  local g = S.ghost
  if not g or not S.hud or not S.runStart then return end
  local elapsed = clock - S.runStart
  local best, bestD = g.idx, math.huge
  for i = math.max(1, g.idx - 5), math.min(#g.pts, g.idx + 40) do
    local p = g.pts[i]
    local dx, dz = p.x - car.position.x, p.z - car.position.z
    local d = dx * dx + dz * dz
    if d < bestD then best, bestD = i, d end
  end
  if bestD < 60 * 60 then
    g.idx = best
    S.ghostDelta = elapsed - g.pts[best].t
  end
end

-- update ------------------------------------------------------------------------
local pollTimer, polling, helloTimer, speedTimer, comboHeld = 0, false, 3, 0, false
local restartButton, restartHeld = nil, false
local lastSpline, wrongTimer = nil, 0

local function poll(dt)
  pollTimer = pollTimer + dt
  if polling or pollTimer < 0.5 then return end
  pollTimer, polling = 0, true
  local url = string.format('http://%s:%d/acr/%d', ac.getServerIP(), MAILBOX_PORT, ac.getCar(0).sessionID)
  web.get(url, function(err, response)
    polling = false
    S.pollError = err and tostring(err) or nil
    if response and response.body then
      for line in response.body:gmatch('[^\n]+') do handle(line) end
    end
  end)
end

function script.update(dt)
  clock = clock + dt
  flushOutbox(dt)
  poll(dt)
  if not gotHello then
    helloTimer = helloTimer + dt
    if helloTimer > 4 then helloTimer = 0; send('hello', MENU_VERSION) end
  end
  local ctrl, m = ac.isKeyDown(ac.KeyIndex.Control), ac.isKeyDown(ac.KeyIndex.M)
  if ctrl and m and not comboHeld then
    visible = not visible
    if visible then
      if #S.routes == 0 then send('hello', MENU_VERSION) end
      send('roster'); send('records'); send('lobbies')
    end
  end
  comboHeld = ctrl and m
  -- quick restart: Ctrl+R or a bindable wheel button ("ACR 快速重開" in CSP controls)
  local r = ac.isKeyDown(ac.KeyIndex.R)
  local wheel = false
  if restartButton == nil then
    local ok, b = pcall(function() return ac.ControlButton('__EXT_ACR_RESTART') end)
    restartButton = ok and b or false
  end
  if restartButton then pcall(function() wheel = restartButton:pressed() end) end
  if ((ctrl and r and not restartHeld) or wheel) and (S.lobby or S.hud or S.result) then
    send('restart'); flash('重開中…', C.dim); S.rerunAt = nil
  end
  restartHeld = ctrl and r
  if S.rerunAt and clock >= S.rerunAt then S.rerunAt = nil; send('restart') end
  local car = ac.getCar(0)
  if S.hud then pedalSample(dt, car); updateGhostDelta(car) end
  if S.hud or S.lobby then
    speedTimer = speedTimer + dt
    if speedTimer >= 4 then speedTimer = 0; send('spd', string.format('%.1f', car.speedKmh)) end
  end
  -- wrong-way detection during a run: track progress going backwards while moving
  if S.hud and car.splinePosition then
    if lastSpline and car.speedKmh > 15 then
      local d = car.splinePosition - lastSpline
      if d < 0 and d > -0.5 then wrongTimer = wrongTimer + dt else wrongTimer = math.max(0, wrongTimer - dt * 2) end
    end
    lastSpline = car.splinePosition
  else
    wrongTimer, lastSpline = 0, nil
  end
end

-- widgets (flow layout only) ----------------------------------------------------
local function txt(s, size, color, bold)
  ui.pushDWriteFont(bold and BOLD or FONT)
  ui.dwriteText(s, (size or 18) + 2, color or C.text)
  ui.popDWriteFont()
end
local function title(s, sub)
  txt(s, 26, C.text, true)
  if sub then txt(sub, 15, C.dim) end
  ui.offsetCursorY(10)
end
local function label(s) txt(s, 15, C.dim); ui.offsetCursorY(2) end
local function space(h) ui.offsetCursorY(h or 10) end

local styles = {
  normal = { C.btn, C.btnHi, C.text }, primary = { C.accent, C.accentHi, C.dark },
  ok = { C.okBtn, rgbm(0.22, 0.55, 0.33, 1), C.text }, bad = { C.badBtn, rgbm(0.6, 0.22, 0.22, 1), C.text },
  selected = { C.accentSoft, rgbm(0.96, 0.62, 0.16, 0.26), C.accent }, ghost = { rgbm(0, 0, 0, 0), C.btnHi, C.dim },
}
local crispButtons = true
-- width: number, or nil = full available width
local function btn(id, text, width, height, style)
  local st = styles[style or 'normal']
  ui.pushStyleColor(ui.StyleColor.Button, st[1])
  ui.pushStyleColor(ui.StyleColor.ButtonHovered, st[2])
  ui.pushStyleColor(ui.StyleColor.ButtonActive, st[2])
  ui.pushStyleColor(ui.StyleColor.Text, st[3])
  local pushed = pushVar('FrameRounding', 8)
  local size = vec2(width or ui.availableSpaceX(), (height or 38) + 6)
  local clicked
  if crispButtons then
    clicked = ui.button('##' .. id, size)
    local ok = pcall(function()
      local a, b = ui.itemRectMin(), ui.itemRectMax()
      local fs = size.y >= 44 and 20 or 18
      ui.pushDWriteFont(BOLD)
      local m = ui.measureDWriteText(text, fs)
      ui.dwriteDrawText(text, fs, vec2((a.x + b.x - m.x) / 2, (a.y + b.y - m.y) / 2), st[3])
      ui.popDWriteFont()
    end)
    if not ok then crispButtons = false end
  else
    clicked = ui.button(text .. '##' .. id, size)
  end
  if pushed > 0 then ui.popStyleVar() end
  ui.popStyleColor(4)
  return clicked
end

-- equal-width buttons on one row; returns index clicked
local function row(id, items, height)
  local n = #items
  local w = (ui.availableSpaceX() - (n - 1) * 8) / n
  local clicked = nil
  for i, it in ipairs(items) do
    if i > 1 then ui.sameLine(0, 8) end
    if btn(id .. i, it[1], w, height or 36, it[2]) then clicked = i end
  end
  return clicked
end

-- two-column list rows: left text, right widget/text
local function listRow(left, right, rightColor, bold)
  ui.columns(2, false)
  ui.setColumnWidth(0, ui.windowWidth() * 0.62)
  txt(left, 16, C.text, bold)
  ui.nextColumn()
  if type(right) == 'function' then right() else txt(right or '', 16, rightColor or C.text, true) end
  ui.nextColumn()
  ui.columns(1)
end

local function panel(id, height, fn)
  ui.pushStyleColor(ui.StyleColor.ChildBg, C.panel)
  local pushed = pushVar('ChildRounding', 10)
  ui.childWindow(id, vec2(ui.availableSpaceX(), height), false, WF_PAD, function()
    ui.offsetCursorY(4)
    fn()
  end)
  if pushed > 0 then ui.popStyleVar() end
  ui.popStyleColor()
  space(10)
end

-- shared pickers ------------------------------------------------------------------
local function routePicker(id)
  label('① 選擇路線')
  if #S.routes == 0 then txt('還沒有路線 → 先到「路線」頁建立', 15, C.bad); return false end
  for i, r in ipairs(S.routes) do
    if btn(id .. 'r' .. i, (r == S.route and '● ' or '○ ') .. r .. (S.locked[r] and '  🔒' or ''), nil, 34,
        r == S.route and 'selected' or 'normal') then S.route = r end
    space(4)
  end
  space(6)
  label('② 圈數')
  local opts = { 1, 2, 3, 5 }
  local items = {}
  for _, n in ipairs(opts) do items[#items + 1] = { n .. ' 圈', S.laps == n and 'selected' or 'normal' } end
  local c = row(id .. 'laps', items, 34)
  if c then S.laps = opts[c] end
  space(6)
  return true
end

local function directionTo(target)
  local car = ac.getCar(0)
  if not car or not target then return nil end
  local to = vec2(target.x - car.position.x, target.y - car.position.z)
  local dist = math.sqrt(to.x * to.x + to.y * to.y)
  local look = car.look or vec3 and vec3(0, 0, 1) or { x = 0, z = 1 }
  local fx, fz = look.x, look.z
  local ang = math.deg((math.atan2 or math.atan)(fx * to.y - fz * to.x, fx * to.x + fz * to.y))
  local arrows = { '↑ 前方', '↗ 右前', '→ 右側', '↘ 右後', '↓ 後方', '↙ 左後', '← 左側', '↖ 左前' }
  local idx = math.floor(((-ang + 360 + 22.5) % 360) / 45) + 1
  return arrows[idx], dist
end

local function lobbyPanel()
  if not S.lobby then return false end
  panel('lobbyp', 230, function()
    txt((S.lobby.solo and '練習已開始 · ' or '準備中 · ') .. S.lobby.route, 22, C.accent, true)
    txt('場次 ' .. S.lobby.id .. ' · ' .. S.lobby.laps .. ' 圈 · 飛馳起跑', 15, C.dim)
    space(6)
    local arrow, dist = directionTo(S.gate)
    if arrow then txt(string.format('起點在 %s %.0f 公尺', arrow, dist), 20, C.text, true) end
    if S.lobby.solo then
      txt('開往起點，沿正確方向過線就自動開始計時', 16, C.dim)
      txt('想直接過去：用傳送插件選「賽事起點 → ' .. S.lobby.route .. '」（伺服器重開後才會出現新路線）', 14, C.dim)
      space(8)
      if btn('lbc', '取消練習', nil, 40, 'bad') then send('cancel'); S.lobby = nil end
    else
      txt('雙方都按「準備好了」後倒數，倒數完才能過線，提早過線算搶跑', 16, C.dim)
      space(8)
      local c = row('lb', { { S.ready and '已準備 · 等待對手' or '準備好了', S.ready and 'normal' or 'ok' }, { '取消', 'bad' } }, 40)
      if c == 1 and not S.ready then send('ready'); S.ready = true end
      if c == 2 then send('cancel'); S.lobby = nil end
    end
  end)
  return true
end

-- route map preview ---------------------------------------------------------------
local mapInfo = nil
local function loadMap()
  if mapInfo ~= nil then return mapInfo end
  mapInfo = false
  pcall(function()
    local folders = {}
    pcall(function() folders[#folders + 1] = ac.getFolder(ac.FolderID.CurrentTrackLayout) end)
    pcall(function() folders[#folders + 1] = ac.getFolder(ac.FolderID.ContentTracks) .. '/' .. ac.getTrackID() .. '/' .. ac.getTrackLayout() end)
    pcall(function() folders[#folders + 1] = ac.getFolder(ac.FolderID.ContentTracks) .. '/' .. ac.getTrackID() end)
    local folder
    for _, f in ipairs(folders) do
      if f and io.fileExists(f .. '/map.png') and io.fileExists(f .. '/data/map.ini') then folder = f; break end
    end
    if not folder then return end
    local ini = ac.INIConfig.load(folder .. '/data/map.ini')
    mapInfo = {
      image = folder .. '/map.png',
      w = ini:get('PARAMETERS', 'WIDTH', 0), h = ini:get('PARAMETERS', 'HEIGHT', 0),
      ox = ini:get('PARAMETERS', 'X_OFFSET', 0), oz = ini:get('PARAMETERS', 'Z_OFFSET', 0),
      scale = ini:get('PARAMETERS', 'SCALE_FACTOR', 1),
    }
    if mapInfo.w <= 0 or mapInfo.h <= 0 then mapInfo = false end
  end)
  return mapInfo
end

local function routeMap(name, height)
  local pts = S.routeInfo[name or '']
  local w = ui.availableSpaceX()
  ui.dummy(vec2(w, height))
  local ok = pcall(function()
    local a = ui.itemRectMin()
    ui.drawRectFilled(a, a + vec2(w, height), C.panel, 10)
    local map = loadMap()
    local toScreen
    if map then
      local k = math.min(w / map.w, height / map.h)
      local dw, dh = map.w * k, map.h * k
      local o = a + vec2((w - dw) / 2, (height - dh) / 2)
      ui.drawImage(map.image, o, o + vec2(dw, dh), rgbm(1, 1, 1, 0.85))
      toScreen = function(p) return o + vec2((p.x + map.ox) / map.scale * k, (p.y + map.oz) / map.scale * k) end
    elseif pts and #pts > 1 then
      local all = (S.routePath and S.routePath[name or '']) or pts
      local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
      for _, p in ipairs(all) do minx, miny, maxx, maxy = math.min(minx, p.x), math.min(miny, p.y), math.max(maxx, p.x), math.max(maxy, p.y) end
      local k = math.min((w - 40) / math.max(1, maxx - minx), (height - 40) / math.max(1, maxy - miny))
      toScreen = function(p) return a + vec2(20 + (p.x - minx) * k, 20 + (p.y - miny) * k) end
    end
    if not toScreen then return end
    local path = S.routePath and S.routePath[name or '']
    if path then
      for i = 2, #path do ui.drawLine(toScreen(path[i - 1]), toScreen(path[i]), C.accent, 3) end
    end
    if pts and #pts > 1 then
      if not path then
        for i = 2, #pts do ui.drawLine(toScreen(pts[i - 1]), toScreen(pts[i]), rgbm(0.96, 0.62, 0.16, 0.5), 2) end
      end
      ui.drawCircleFilled(toScreen(pts[1]), 7, C.ok, 16)
      ui.drawCircleFilled(toScreen(pts[#pts]), 7, C.bad, 16)
      for i = 2, #pts - 1 do ui.drawCircleFilled(toScreen(pts[i]), 4, C.text, 12) end
    end
    local car = ac.getCar(0)
    if car then ui.drawCircleFilled(toScreen(vec2(car.position.x, car.position.z)), 5, rgbm(0.4, 0.8, 1, 1), 12) end
  end)
  if not ok then ui.offsetCursorY(0) end
  space(4)
  txt((S.routePath and S.routePath[name or ''] and '路線＝最快一趟的實際行駛線' or '還沒有人跑完：先顯示起終點連線') .. '　綠＝起點 紅＝終點 藍＝你', 14, C.dim)
  space(8)
end

-- pages -----------------------------------------------------------------------
local pages = {}

local function subTabs(id, key, items)
  local list = {}
  for _, it in ipairs(items) do list[#list + 1] = { it[2], sub[key] == it[1] and 'selected' or 'normal' } end
  local c = row(id, list, 32)
  if c then sub[key] = items[c][1]; return items[c][1] end
  space(6)
end

local function toggle(id, text, value)
  if btn(id, (value and '☑ ' or '☐ ') .. text, nil, 30, 'ghost') then return not value end
  return value
end

local function myBest(route)
  for _, r in ipairs(S.records and S.records.best or {}) do
    if r[1] == route then return r[2] end
  end
end

local function ghostPicker()
  label('幽靈車（只是畫面上的影子，不會撞到）')
  local pref = S.ghostPref or { mode = 'pb', target = '' }
  local modes = { { 'off', '關閉' }, { 'pb', '我的最佳' }, { 'record', '第一名' }, { 'player', '指定車手' } }
  local items = {}
  for _, m in ipairs(modes) do items[#items + 1] = { m[2], pref.mode == m[1] and 'selected' or 'normal' } end
  local c = row('gh', items, 32)
  if c then
    local mode = modes[c][1]
    S.ghostPref = { mode = mode, target = '' }
    if mode == 'player' then send('ghostlist', S.route) else send('ghostpref', mode) end
  end
  if (S.ghostPref and S.ghostPref.mode) == 'player' then
    local list = S.ghostList
    if not list or list.route ~= S.route then
      if btn('ghl', '載入這條路線的車手名單', nil, 28, 'ghost') then send('ghostlist', S.route) end
    elseif #list.rows == 0 then
      txt('這條路線還沒有有效成績', 14, C.dim)
    else
      for i, r in ipairs(list.rows) do
        local chosen = S.ghostPref.target == r.id
        if btn('gp' .. i, string.format('%s%d. %s  %s 秒', chosen and '● ' or '', i, r.name, r.time), nil, 28,
            chosen and 'selected' or 'normal') then
          send('ghostpref', 'player', r.id)
          S.ghostPref = { mode = 'player', target = r.id }
        end
        space(3)
      end
    end
  end
end

local function settingsBlock()
  if btn('setx', (S.showSettings and '▾ ' or '▸ ') .. '設定：路線、圈數、幽靈車、輔助', nil, 32, 'ghost') then
    S.showSettings = not S.showSettings
  end
  if not S.showSettings then space(6); return end
  panel('settings', 420 + ((S.ghostPref and S.ghostPref.mode == 'player') and 200 or 0), function()
    routePicker('s')
    ghostPicker()
    space(6)
    S.showBrakes = toggle('tb', '顯示煞車點（第一名開始煞車的位置）', S.showBrakes ~= false)
    S.autoRerun = toggle('ta', '完賽後 6 秒自動再跑一趟', S.autoRerun == true)
    txt('快速重開：Ctrl+R，或在 CSP 控制設定綁定「__EXT_ACR_RESTART」到方向盤按鍵', 13, C.dim)
  end)
end

local function inviteCard()
  local inv = S.invite
  if not (inv and clock < inv.expires) then return end
  panel('inv', 120, function()
    txt(inv.name .. ' 向你發起挑戰', 20, C.accent, true)
    txt(string.format('%s · 剩 %.0f 秒', inv.route, inv.expires - clock), 14, C.dim)
    space(6)
    local c = row('ia', { { '接受', 'ok' }, { '拒絕', 'bad' } }, 40)
    if c == 1 then send('accept'); S.invite = nil end
    if c == 2 then send('decline'); S.invite = nil end
  end)
end

local function eventBanner()
  local ev = S.event
  if not ev then return end
  local left = ev.left - (clock - ev.at)
  if left <= 0 then return end
  panel('ev', 96, function()
    txt(string.format('⏱ 計時賽進行中 · %s · 剩 %d 分', ev.route, math.ceil(left / 60)), 18, C.accent, true)
    txt(string.format('已用 %d / %d 次 · 取最佳成績', ev.used, ev.attempts), 14, C.dim)
    space(4)
    if ev.used < ev.attempts and btn('evgo', '參加計時賽', nil, 32, 'primary') then
      S.route = ev.route; send('practice', ev.route, 1)
    end
  end)
end

pages.go = function()
  title('開跑', nil)
  inviteCard()
  if lobbyPanel() then
    settingsBlock()
    return
  end
  eventBanner()
  local mode = subTabs('gomode', 'go', { { 'practice', '練習' }, { 'duel', '單挑' }, { 'bo3', '三戰兩勝' },
    { 'chase', '追走' }, { 'multi', '多人' }, { 'elim', '淘汰賽' } }) or sub.go
  if #S.routes == 0 then
    txt('還沒有路線 → 到「路線」頁建立', 16, C.bad)
    return
  end
  if not S.route then S.route = S.routes[1] end
  if mode == 'practice' then
    panel('hero', 150, function()
      txt(S.route, 26, C.text, true)
      local mine = myBest(S.route)
      txt((mine and ('我的最佳 ' .. mine .. ' 秒') or '還沒有成績') .. ' · ' .. S.laps .. ' 圈', 15, C.dim)
      space(8)
      if btn('startp', S.result and '↻ 再跑一次' or '▶ 開始練習', nil, 48, 'primary') then send('practice', S.route, S.laps) end
    end)
    routeMap(S.route, 170)
    settingsBlock()
  elseif mode == 'multi' or mode == 'elim' then
    txt(mode == 'elim' and '淘汰賽：每輪最慢的人淘汰，直到剩一人（至少 3 人）' or '多人房：最多 8 人同場', 15, C.dim)
    space(6)
    if btn('host', '用「' .. S.route .. '」開房', nil, 42, 'primary') then
      send('host', S.route, S.laps, mode == 'elim' and 'elim' or 'race')
    end
    space(6)
    if #S.lobbies == 0 then txt('目前沒有房間', 15, C.dim) end
    local myName = ac.getDriverName and ac.getDriverName(0) or ''
    for i, l in ipairs(S.lobbies) do
      panel('lob' .. i, 104, function()
        txt(string.format('%s%s 的房間 · %s · %s/8', l.kind == 'elim' and '【淘汰賽】' or '', l.hostName, l.route, l.count), 16, C.text, true)
        txt(l.names, 13, C.dim)
        space(4)
        if l.hostName == myName then
          local c2 = row('lh' .. i, { { '開始比賽', 'primary' }, { '解散', 'bad' } }, 32)
          if c2 == 1 then send('launch') end
          if c2 == 2 then send('leave') end
        else
          local c2 = row('lj' .. i, { { '加入', 'ok' }, { '離開', 'normal' } }, 32)
          if c2 == 1 then send('join', l.host) end
          if c2 == 2 then send('leave') end
        end
      end)
    end
    settingsBlock()
  else
    local desc = { duel = '單挑：一場決勝負', bo3 = '三戰兩勝：先贏兩場的人獲勝，每局自動開下一局',
                   chase = '追走：你當前車，對方跟車；跟得越近分數越高（不列入排行榜）' }
    txt(desc[mode], 15, C.dim)
    space(6)
    if btn('refresh', '↻ 重新整理名單', nil, 28, 'ghost') then send('roster') end
    if #S.roster == 0 then txt('目前沒有其他車手在線', 15, C.dim) end
    for _, p in ipairs(S.roster) do
      listRow(p.name, function()
        if p.status == 'racing' then txt('比賽中', 15, C.dim)
        elseif btn('inv' .. p.slot, '邀請', nil, 30, 'primary') then send('invite', p.slot, S.route, S.laps, mode) end
      end)
      space(4)
    end
    space(6)
    settingsBlock()
  end
end

local function lastResult()
  local r = S.result
  if not r then txt('完成一場後，結果會顯示在這裡', 16, C.dim); return end
  local head = S.stats and S.stats.teleport and '有傳送 · 成績作廢' or S.stats and S.stats.jump and '搶跑 · 不列入排行'
    or (r.won and '🏆 勝利' or (r.status == 'finished' and '完賽' or '未完賽'))
  panel('sum', 130, function()
    txt(head .. (S.newPB and '　🎉 新個人最佳！' or ''), 18, S.newPB and C.ok or C.text, true)
    txt(r.best ~= '-' and (r.best .. ' 秒') or '—', 40, C.accent, true)
    local line = '賽事 ' .. r.id
    if S.newPB and S.newPB.gain then line = string.format('比上次最佳快 %s 秒 · %s', S.newPB.gain, line) end
    txt(line, 13, C.dim)
  end)
  if S.series then
    txt(string.format('三戰兩勝 · 你 %s : %s 對手 · 第 %s 局%s', S.series.me, S.series.them, S.series.round,
      S.series.done and '（結束）' or '（下一局已開房）'), 16, C.accent, true)
  end
  if S.elim then
    txt(string.format('淘汰賽第 %s 輪 · 淘汰：%s · 剩下：%s%s', S.elim.round, S.elim.out, S.elim.alive,
      S.elim.done and '（結束）' or ''), 15, C.accent, true)
  end
  if S.chase then
    txt(string.format('追走 %s：平均距離 %s m、最遠 %s m · 分數 %s', S.chase.follower, S.chase.avg, S.chase.max, S.chase.score), 16, C.accent, true)
  end
  local sg = S.segments
  if sg and #sg.ref > 0 then
    local worst, wd = nil, -math.huge
    for i, t in ipairs(sg.mine) do if sg.ref[i] and t - sg.ref[i] > wd then worst, wd = i, t - sg.ref[i] end end
    if worst and wd > 0.05 then txt(string.format('最需要加強：第 %d 段（%d%%–%d%%），比紀錄慢 %.2f 秒', worst, (worst - 1) * 20, worst * 20, wd), 16, C.bad, true) end
  end
  space(6)
  local third = S.stats and tonumber(S.stats.third or 0) > 0
  local c = row('ra', { { '↻ 再跑一次', 'primary' }, { r.video and '看回放' or '結果頁', 'normal' }, { '上傳畫面', 'normal' } }, 44)
  if c == 1 then send(third and 'rerun' or 'restart') end
  if c == 2 then os.openURL(string.format('http://%s:%s/%s/index.html', ac.getServerIP(), r.port, r.id)) end
  if c == 3 then os.openURL(string.format('http://%s:%d/upload/%s?name=%s', ac.getServerIP(), MAILBOX_PORT, r.id,
    ac.getDriverName and ac.getDriverName(0) or '')) end
  if S.rerunAt then txt(string.format('%.0f 秒後自動再跑（按 Ctrl+R 立即開始）', S.rerunAt - clock), 14, C.dim) end
  space(6)
  if btn('det', (S.details and '▾ ' or '▸ ') .. '詳細數據：速度、停車、踏板、分段', nil, 32, 'ghost') then S.details = not S.details end
  if not S.details then return end
  if S.stats then
    panel('st', 220, function()
      local wall, carh = tonumber(S.stats.wall) or 0, tonumber(S.stats.car) or 0
      if S.pedals then wall, carh = math.max(wall, S.pedals.wall_hits or 0), math.max(carh, S.pedals.car_hits or 0) end
      listRow('最高速', S.stats.top .. ' km/h')
      listRow('行駛均速 / 全程均速', S.stats.moving .. ' / ' .. S.stats.avg .. ' km/h')
      listRow('停車（車速歸零）', S.stats.stops .. ' 次 / ' .. S.stats.stopped .. ' 秒')
      listRow('撞牆 / 撞車 / 第三方', wall .. ' / ' .. carh .. ' / ' .. S.stats.third)
      listRow('換檔次數', S.stats.shifts)
    end)
  end
  local pd = S.pedals
  if pd then
    panel('pd', 190, function()
      listRow('踩油門時間 / 全油門', string.format('%.0f%% / %.0f%%', pd.gas_share, pd.gas_full))
      listRow('平均油門力度', string.format('%.0f%%', pd.gas_avg))
      listRow('每次油門平均', string.format('%.1f 秒（%d 次）', pd.gas_hold, pd.gas_presses))
      listRow('踩煞車時間 / 平均力度', string.format('%.0f%% / %.0f%%', pd.brake_share, pd.brake_avg))
      listRow('最大煞車 / 次數', string.format('%.0f%% / %d 次', pd.brake_max, pd.brake_presses))
    end)
  end
  if sg and #sg.mine > 0 then
    panel('seg', 50 + #sg.mine * 30, function()
      txt(sg.refName and ('分段比較（對比 ' .. sg.refName .. '）') or '分段時間', 15, C.text, true)
      for i, t in ipairs(sg.mine) do
        local ref = sg.ref[i]
        if ref then listRow(string.format('第 %d 段', i), string.format('%.2f  %s%.2f', t, t > ref and '+' or '', t - ref), t > ref and C.bad or C.ok)
        else listRow(string.format('第 %d 段', i), string.format('%.2f 秒', t)) end
      end
    end)
  end
end

pages.results = function()
  title('成績', nil)
  local s2 = subTabs('rs', 'results', { { 'last', '本場' }, { 'mine', '我的紀錄' }, { 'badges', '成就' } }) or sub.results
  if s2 == 'last' then lastResult()
  elseif s2 == 'mine' then
    local rec = S.records
    if not rec then send('records'); txt('載入中…', 15, C.dim); return end
    if S.titles then txt('頭銜：' .. S.titles, 16, C.accent, true); space(4) end
    panel('rc', 60, function() listRow('出賽 / 有效完賽', rec.runs .. ' / ' .. rec.done) end)
    label('各路線個人最佳')
    if #rec.best == 0 then txt('還沒有有效完賽', 15, C.dim) end
    for _, r2 in ipairs(rec.best) do listRow(r2[1], r2[2] .. ' 秒', C.accent); space(4) end
    space(6)
    if btn('web', '在瀏覽器開我的個人頁（進步曲線）', nil, 34, 'ghost') then
      os.openURL(string.format('http://%s:%d/player?id=%s', ac.getServerIP(), REPLAY_PORT, ac.getDriverName and ac.getDriverName(0) or ''))
    end
  else
    if not S.badges then send('profile'); txt('載入中…', 15, C.dim); return end
    txt(string.format('已解鎖 %d / %d', #S.badges.list, S.badges.total), 18, C.accent, true)
    if S.titles then txt('頭銜：' .. S.titles, 15, C.text) end
    space(6)
    if #S.badges.list == 0 then txt('完成第一趟有效計時就會拿到第一個徽章！', 15, C.dim) end
    for _, b2 in ipairs(S.badges.list) do listRow('🏅 ' .. b2.name, b2.desc, C.dim, true); space(4) end
  end
end

local function boardList(list, routeName)
  if #list == 0 then txt('這個條件下還沒有有效成績，跑一趟就上榜！', 15, C.dim) end
  local first = list[1] and tonumber(list[1][2])
  for i, r in ipairs(list) do
    local t = tonumber(r[2])
    local gap = (i > 1 and first and t) and string.format('  +%.3f', t - first) or ''
    listRow((i <= 3 and ({ '🥇 ', '🥈 ', '🥉 ' })[i] or (i .. '.  ')) .. (r[1] or ''), (r[2] or '') .. gap, i == 1 and C.accent or C.text, i <= 3)
    local detail = {}
    if r[3] and r[3] ~= '' then detail[#detail + 1] = '🚗 ' .. r[3] end
    detail[#detail + 1] = (r[4] and r[4] ~= '') and (r[4] .. ' 級') or '未分級'
    if routeName then detail[#detail + 1] = '📍 ' .. routeName end
    txt('      ' .. table.concat(detail, '  ·  '), 13, C.dim)
    space(5)
  end
end

pages.board = function()
  title('排行', nil)
  local s3 = subTabs('bs', 'board', { { 'board', '排行榜' }, { 'weekly', '每週挑戰' }, { 'event', '計時賽' } }) or sub.board
  if #S.routes == 0 then txt('還沒有路線', 15, C.bad); return end
  if s3 == 'board' then
    label('📍 地圖路線')
    local items = {}
    for _, r in ipairs(S.routes) do items[#items + 1] = { r, r == S.route and 'selected' or 'normal' } end
    if #items <= 4 then
      local c = row('br', items, 30); if c then S.route = S.routes[c] end
    else
      for i, r in ipairs(S.routes) do if btn('br' .. i, r, nil, 28, r == S.route and 'selected' or 'normal') then S.route = r end; space(3) end
    end
    space(4)
    label('🏷 車輛級距')
    local cl = { { '全部', S.boardClass == '' and 'selected' or 'normal' } }
    for _, c2 in ipairs(S.classes) do cl[#cl + 1] = { c2 .. ' 級', S.boardClass == c2 and 'selected' or 'normal' } end
    if #S.classes == 0 then txt('管理員還沒把車輛分級（管理 → 車輛分級）', 13, C.dim) end
    local per = 6
    for start = 1, #cl, per do
      local chunk = {}
      for k = start, math.min(#cl, start + per - 1) do chunk[#chunk + 1] = cl[k] end
      local c = row('cls' .. start, chunk, 28)
      if c then local pick = start + c - 1; S.boardClass = pick == 1 and '' or S.classes[pick - 1] end
      space(3)
    end
    local key = (S.route or '') .. '|' .. S.boardClass
    if S.boardKey ~= key then S.boardKey = key; S.board = {}; send('board', S.route, S.boardClass ~= '' and S.boardClass or '-') end
    space(6)
    panel('bsum', 44, function()
      txt(string.format('📍 %s　·　🏷 %s', S.route or '—', S.boardClass ~= '' and (S.boardClass .. ' 級') or '全部級距'), 16, C.accent, true)
    end)
    boardList(S.board, S.route)
  elseif s3 == 'weekly' then
    if not S.weekly then send('weekly'); S.weekly = { board = {} } end
    if not S.weekly.route then txt('管理員還沒設定本週挑戰', 15, C.dim); return end
    txt(S.weekly.route .. (S.weekly.car and (' · 指定車：' .. S.weekly.car) or ' · 不限車'), 18, C.accent, true)
    txt('每週一重置，用「練習」跑這條路線即可參加', 14, C.dim)
    space(6)
    boardList(S.weekly.board, S.weekly.route)
  else
    if not S.eventAsked then S.eventAsked = true; send('event') end
    if not S.event then txt('目前沒有計時賽。管理員可以在「管理」頁開一場。', 15, C.dim); return end
    eventBanner()
    boardList(S.event.board, S.event.route)
  end
end

local function nodePos(name)
  local ok, nodes = pcall(ac.findNodes, name)
  if not ok or not nodes or nodes:size() == 0 then return nil end
  return nodes:getPosition()
end

local function trackGates()
  local out = {}
  local function add(kind, l, r)
    local a, b = nodePos(l), nodePos(r)
    if a and b then out[#out + 1] = string.format('%s|%.2f|%.2f|%.2f|%.2f', kind, a.x, a.z, b.x, b.z); return true end
  end
  local hasStart = add('start', 'AC_AB_START_L', 'AC_AB_START_R') or add('start', 'AC_TIME_0_L', 'AC_TIME_0_R')
  local hasFinish = add('finish', 'AC_AB_FINISH_L', 'AC_AB_FINISH_R')
  return hasStart and hasFinish, out
end

pages.route = function()
  title('路線', '所有車手都能建立路線 · 被鎖定的路線只有管理員能改')
  label('路線名稱（新名稱＝新增，現有名稱＝更新）')
  ui.setNextItemWidth(ui.availableSpaceX())
  S.routeName = ui.inputText('##rname', S.routeName)
  space(6)
  if S.routeInfo[S.routeName] then routeMap(S.routeName, 170) end
  panel('auto', 100, function()
    txt('方法一：一鍵套用地圖計時線', 16, C.text, true)
    space(4)
    if btn('trk', '套用地圖計時線', nil, 38, 'primary') then
      local ok, parts = trackGates()
      if ok then
        send('gbegin', S.routeName)
        for _, part in ipairs(parts) do send('gadd', part) end
        send('gend', S.routeName)
      else flash('這張地圖沒有起終點計時線，請用方法二', C.bad) end
    end
  end)
  panel('manual', 110, function()
    txt('方法二：停在線上、車頭朝行駛方向後按下', 16, C.text, true)
    space(4)
    local c = row('man', { { '設為起點', 'normal' }, { '設為終點', 'normal' } }, 38)
    if c then send('gate', S.routeName, ({ 'start', 'finish' })[c]); send('hello', MENU_VERSION) end
  end)
  if btn('webr', '在瀏覽器開路線頁（排行與最快回放）', nil, 32, 'ghost') then
    os.openURL(string.format('http://%s:%d/route?name=%s', ac.getServerIP(), REPLAY_PORT, S.routeName))
  end
end

pages.admin = function()
  title('管理員', '僅管理員名單內的 Steam ID 可用')
  panel('adm1', 220, function()
    for _, k in ipairs({ { 'invite_seconds', '邀請時限（秒）' }, { 'countdown_seconds', '起跑倒數（秒）' },
      { 'limit_seconds', '完賽時限（秒）' }, { 'time', '時間 HH:MM（重啟後生效）' } }) do
      listRow(k[2], function()
        ui.setNextItemWidth(ui.availableSpaceX() - 76)
        A[k[1]] = ui.inputText('##' .. k[1], A[k[1]])
        ui.sameLine(0, 6)
        if btn('ap' .. k[1], '套用', 70, 26) then send('set', k[1], A[k[1]]) end
      end)
      space(3)
    end
  end)
  label('目前選擇的路線：' .. (S.route or '（無）'))
  local c = row('rt', { { '鎖定', 'normal' }, { '解鎖', 'normal' }, { '設為本週挑戰', 'primary' } }, 34)
  if c and S.route then send('set', ({ 'lock', 'unlock', 'weekly' })[c], S.route) end
  space(8)
  label('計時賽：用目前路線開一場（分鐘 / 每人次數）')
  A.evMin, A.evTry = A.evMin or '60', A.evTry or '3'
  ui.setNextItemWidth(90); A.evMin = ui.inputText('分鐘##evm', A.evMin); ui.sameLine(0, 10)
  ui.setNextItemWidth(90); A.evTry = ui.inputText('次數##evt', A.evTry)
  local c3 = row('evr', { { '開始計時賽', 'primary' }, { '結束計時賽', 'bad' } }, 32)
  if c3 == 1 and S.route then send('set', 'event', S.route, A.evMin, A.evTry) end
  if c3 == 2 then send('set', 'event', 'stop') end
  space(8)
  label('裁判：賽事編號')
  if A.raceId == '' and S.result then A.raceId = S.result.id end
  ui.setNextItemWidth(ui.availableSpaceX())
  A.raceId = ui.inputText('##raceid', A.raceId)
  local c2 = row('jd', { { '判無效', 'bad' }, { '恢復有效', 'normal' } }, 32)
  if c2 then send('set', c2 == 1 and 'invalidate' or 'restore', A.raceId) end
  space(8)
  if btn('cls_open', (S.showClasses and '▾ ' or '▸ ') .. '車輛分級（排行榜用 1 級、2 級…）', nil, 32, 'ghost') then
    S.showClasses = not S.showClasses
    if S.showClasses then send('carlist') end
  end
  if S.showClasses then
    if not S.carList then txt('載入中…', 14, C.dim)
    elseif #S.carList == 0 then txt('還沒有任何車跑過', 14, C.dim) end
    for i, car in ipairs(S.carList or {}) do
      txt(car.name .. '　' .. (car.class ~= '' and (car.class .. ' 級') or '未分級'), 15, car.class ~= '' and C.text or C.dim, true)
      local items = { { '未分', car.class == '' and 'selected' or 'normal' } }
      for lv = 1, 5 do items[#items + 1] = { lv .. ' 級', car.class == tostring(lv) and 'selected' or 'normal' } end
      local c = row('cc' .. i, items, 28)
      if c then send('set', 'carclass', car.id, c == 1 and '-' or tostring(c - 1)) end
      space(5)
    end
  end
  space(8)
  label('伺服器')
  local c4 = row('srv', { { '查看玩家選單版本', 'normal' }, { '重開伺服器', 'bad' } }, 34)
  if c4 == 1 then send('set', 'versions') end
  if c4 == 2 then
    if S.confirmRestart and clock - S.confirmRestart < 5 then send('set', 'restart_server'); S.confirmRestart = nil
    else S.confirmRestart = clock; flash('再按一次「重開伺服器」確認（5 秒內）', C.bad) end
  end
end

local nav = { { 'go', '開跑' }, { 'results', '成績' }, { 'board', '排行' }, { 'route', '路線' } }

-- 3D markers in the world ----------------------------------------------------------
local groundCache = {}
local function groundY(p)
  local key = string.format('%.1f,%.1f', p.x, p.y)
  local y = groundCache[key]
  if y ~= nil then return y end
  y = false
  pcall(function()
    local car = ac.getCar(0)
    local top = car.position.y + 400
    local hit = physics.raycastTrack(vec3(p.x, top, p.y), vec3(0, -1, 0), 1200)
    if hit and hit > 0 then y = top - hit end
  end)
  if y then groundCache[key] = y end
  return y or ac.getCar(0).position.y
end

local markerColors = { s = rgbm(0.15, 0.95, 0.35, 0.9), c = rgbm(1, 1, 1, 0.6), f = rgbm(1, 0.25, 0.2, 0.9) }

-- a vertical/horizontal bar made of quads so it is hidden behind walls and cars
local function bar(p, q, width, color, up)
  local dx, dy, dz = q.x - p.x, q.y - p.y, q.z - p.z
  local ox, oz = 0, 0
  if up then
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 0 then ox, oz = -dz / len * width / 2, dx / len * width / 2 end
    render.quad(vec3(p.x - ox, p.y, p.z - oz), vec3(p.x + ox, p.y, p.z + oz), vec3(q.x + ox, q.y, q.z + oz), vec3(q.x - ox, q.y, q.z - oz), color)
  else
    render.quad(vec3(p.x - width / 2, p.y, p.z), vec3(p.x + width / 2, p.y, p.z), vec3(q.x + width / 2, q.y, q.z), vec3(q.x - width / 2, q.y, q.z), color)
    render.quad(vec3(p.x, p.y, p.z - width / 2), vec3(p.x, p.y, p.z + width / 2), vec3(q.x, q.y, q.z + width / 2), vec3(q.x, q.y, q.z - width / 2), color)
  end
end

local function drawGhost()
  if not (S.ghost and S.hud and S.runStart) then return end
  local p = ghostAt(clock - S.runStart)
  if not p then return end
  pcall(function()
    local y = groundY(vec2(p.x, p.z))
    local c = rgbm(0.7, 0.45, 1, 0.45)
    bar(vec3(p.x, y, p.z), vec3(p.x, y + 1.4, p.z), 1.8, c, false)
    bar(vec3(p.x, y + 1.4, p.z), vec3(p.x, y + 1.6, p.z), 0.6, rgbm(0.85, 0.7, 1, 0.9), false)
  end)
end

local function drawBrakes()
  if not (S.brakes and S.showBrakes ~= false and (S.lobby or S.hud)) then return end
  local car = ac.getCar(0)
  for _, b in ipairs(S.brakes.pts) do
    pcall(function()
      local dx, dz = b.x - car.position.x, b.z - car.position.z
      if dx * dx + dz * dz > 600 * 600 then return end
      local y = groundY(vec2(b.x, b.z)) + 0.07
      local c = rgbm(1, 0.55, 0.1, 0.8)
      render.quad(vec3(b.x - 1.2, y, b.z - 1.2), vec3(b.x + 1.2, y, b.z - 1.2), vec3(b.x + 1.2, y, b.z + 1.2), vec3(b.x - 1.2, y, b.z + 1.2), c)
      bar(vec3(b.x, y, b.z), vec3(b.x, y + 2.2, b.z), 0.25, c, false)
    end)
  end
end

function script.draw3D()
  drawGhost()
  drawBrakes()
  if not (S.lobby or S.hud) then return end            -- only racers see the gates
  local name = (S.lobby and S.lobby.route) or S.lastRoute
  local gates = S.gates and S.gates[name]
  if not gates then return end
  local car = ac.getCar(0)
  pcall(function()
    if render.setDepthMode and render.DepthMode then render.setDepthMode(render.DepthMode.ReadOnlyLessEqual or render.DepthMode.Normal) end
    if render.setBlendMode and render.BlendMode then render.setBlendMode(render.BlendMode.AlphaBlend) end
    if render.setCullMode and render.CullMode then render.setCullMode(render.CullMode.None) end
  end)
  for _, g in ipairs(gates) do
    pcall(function()
      local mid = vec2((g.a.x + g.b.x) / 2, (g.a.y + g.b.y) / 2)
      local dx, dz = mid.x - car.position.x, mid.y - car.position.z
      if dx * dx + dz * dz > 5000 * 5000 then return end
      local color = markerColors[g.kind] or markerColors.c
      local ya, yb = groundY(g.a), groundY(g.b)
      local a0, b0 = vec3(g.a.x, ya, g.a.y), vec3(g.b.x, yb, g.b.y)
      if g.kind == 'c' then
        -- checkpoint: a box outline lying on the road
        local ux, uz = g.b.x - g.a.x, g.b.y - g.a.y
        local len = math.sqrt(ux * ux + uz * uz)
        local nx, nz = -uz / len * 1.5, ux / len * 1.5
        local h = 0.06
        local c1, c2 = vec3(g.a.x - nx, ya + h, g.a.y - nz), vec3(g.b.x - nx, yb + h, g.b.y - nz)
        local c3, c4 = vec3(g.b.x + nx, yb + h, g.b.y + nz), vec3(g.a.x + nx, ya + h, g.a.y + nz)
        bar(c1, c2, 0.3, color, true); bar(c2, c3, 0.3, color, true); bar(c3, c4, 0.3, color, true); bar(c4, c1, 0.3, color, true)
      else
        -- start / finish: a big gantry (two posts + banner) plus a line on the road
        local H = 7
        bar(a0, vec3(a0.x, a0.y + H, a0.z), 0.35, color, false)
        bar(b0, vec3(b0.x, b0.y + H, b0.z), 0.35, color, false)
        local t1, t2 = vec3(a0.x, a0.y + H, a0.z), vec3(b0.x, b0.y + H, b0.z)
        render.quad(vec3(t1.x, t1.y - 1.4, t1.z), vec3(t2.x, t2.y - 1.4, t2.z), t2, t1, rgbm(color.r, color.g, color.b, 0.55))
        bar(vec3(a0.x, a0.y + 0.05, a0.z), vec3(b0.x, b0.y + 0.05, b0.z), 0.6, color, true)
      end
    end)
  end
end

-- windows ---------------------------------------------------------------------
local noticeStart, noticeClosed = nil, false

-- progress of the run (0..1) from the route path; ghost progress at the same time
local function progressOf(x, z)
  local path = S.routePath and S.routePath[S.lastRoute or '']
  if not path or #path < 2 then return nil end
  local best, bi = math.huge, 1
  for i, p in ipairs(path) do
    local dx, dz = p.x - x, p.y - z
    local d = dx * dx + dz * dz
    if d < best then best, bi = d, i end
  end
  return (bi - 1) / (#path - 1)
end

local function topPanel(screen)
  local W2 = 440
  local lines = {}
  local h = S.hud
  local warn = nil
  if wrongTimer > 1.5 then warn = '⚠ 逆向行駛' end
  ui.toolWindow('ACR_TOP', vec2(screen.x / 2 - W2 / 2, 14), vec2(W2, 150), true, false, function()
    local H2 = 150
    ui.drawRectFilled(vec2(0, 0), vec2(W2, H2), C.bg, 14)
    ui.drawRectFilled(vec2(0, 0), vec2(W2, 3), warn and C.bad or C.accent)
    if h then
      ui.setCursor(vec2(18, 8))
      txt(string.format('%d:%06.3f', math.floor(h.time / 60), h.time % 60), 40, C.accent, true)
      ui.setCursor(vec2(250, 14))
      local info = {}
      if tonumber(h.totalLaps or 1) > 1 then info[#info + 1] = string.format('第 %d/%s 圈', math.min(h.laps + 1, tonumber(h.totalLaps)), h.totalLaps) end
      if h.of and tonumber(h.of) and tonumber(h.of) > 1 then info[#info + 1] = string.format('名次 %s/%s', h.pos, h.of) end
      info[#info + 1] = string.format('%.0f km/h', ac.getCar(0).speedKmh)
      txt(table.concat(info, '\n'), 15, C.text)
    elseif S.lobby then
      local arrow, dist = directionTo(S.gate)
      ui.setCursor(vec2(18, 12))
      txt(S.lobby.solo and '前往起點，過線開始計時' or '準備中：雙方按「準備好了」', 17, C.text, true)
      if arrow then ui.setCursor(vec2(18, 40)); txt(string.format('起點 %s %.0f m', arrow, dist), 26, C.accent, true) end
    end
    -- progress bar: me (orange) vs ghost (purple)
    local car = ac.getCar(0)
    local mine = h and progressOf(car.position.x, car.position.z)
    local ghostP = nil
    if h and S.ghost and S.runStart then
      local g = ghostAt(clock - S.runStart)
      if g then ghostP = progressOf(g.x, g.z) end
    end
    local by = 86
    ui.drawRectFilled(vec2(18, by), vec2(W2 - 18, by + 8), rgbm(1, 1, 1, 0.08), 4)
    if mine then ui.drawRectFilled(vec2(18, by), vec2(18 + (W2 - 36) * mine, by + 8), C.accent, 4) end
    if ghostP then ui.drawCircleFilled(vec2(18 + (W2 - 36) * ghostP, by + 4), 6, rgbm(0.75, 0.5, 1, 1), 12) end
    -- one info line: warning > split > ghost gap > gap to car ahead
    ui.setCursor(vec2(18, 104))
    if warn then
      txt(warn, 20, C.bad, true)
    elseif S.split and clock < S.split.untilT then
      local d = S.split.delta
      txt(string.format('%s %s  %s', S.split.label, S.split.time, d == '' and '首次紀錄' or ('比最佳 ' .. d)), 17,
        d == '' and C.text or (d:sub(1, 1) == '-' and C.ok or C.bad), true)
    elseif h and S.ghost and S.ghostDelta then
      local d = S.ghostDelta
      txt(string.format('👻 %s  %s%.2f 秒', S.ghost.label, d > 0 and '+' or '', d), 17, d > 0 and C.bad or C.ok, true)
    elseif h and h.gap and h.gap ~= '' then
      txt('落後前車 ' .. h.gap:gsub('^%+', '') .. ' 秒', 17, C.bad, true)
    elseif h then
      txt(mine and '路線進度' or 'Ctrl+R 快速重開', 14, C.dim)
    end
  end)
end

function script.drawUI()
  local screen = ui.windowSize()
  if visible then noticeClosed = true end
  local now = (os.preciseClock and os.preciseClock()) or os.clock()
  if not noticeStart then noticeStart = now end
  local left = noticeClosed and 0 or (10 - (now - noticeStart))
  if left > 0 then
    ui.toolWindow('ACR_LOADED', vec2(screen.x / 2 - 210, 70), vec2(420, 52), true, true, function()
      ui.drawRectFilled(vec2(0, 0), vec2(420, 52), C.bg, 10)
      ui.drawRectFilled(vec2(0, 0), vec2(4, 52), C.accent)
      ui.setCursor(vec2(18, 13))
      txt(string.format('玉長賽事已載入 · Ctrl+M 開啟　(%d)', math.ceil(left)), 17, C.text, true)
      ui.setCursor(vec2(380, 10))
      if btn('closeNotice', '✕', 30, 26, 'ghost') then noticeClosed = true end
    end)
  end

  local function safe(tag, fn)
    local ok, err = pcall(fn)
    if not ok and not S['warned_' .. tag] then S['warned_' .. tag] = true; pcall(ac.log, 'ACR ' .. tag .. ' failed: ' .. tostring(err)) end
  end
  if S.hud or S.lobby then safe('top', function() topPanel(screen) end) end

  if S.go and clock < S.go then safe('go', function()
    local n = math.ceil(S.go - clock)
    ui.toolWindow('ACR_GO', vec2(screen.x / 2 - 70, screen.y * 0.28), vec2(140, 140), true, false, function()
      ui.drawCircleFilled(vec2(70, 70), 66, C.bg, 40)
      ui.drawCircle(vec2(70, 70), 66, C.accent, 40, 3)
      ui.setCursor(vec2(n >= 10 and 30 or 48, 26))
      txt(tostring(n), 72, C.accent, true)
    end)
  end) end

  if S.badgePopup and clock < S.badgePopup.untilT then safe('badge', function()
    ui.toolWindow('ACR_BADGE', vec2(screen.x - 380, screen.y * 0.18), vec2(340, 76), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(340, 76), C.bg, 12)
      ui.drawRectFilled(vec2(0, 0), vec2(4, 76), C.ok)
      ui.setCursor(vec2(18, 10)); txt('🏅 解鎖成就：' .. S.badgePopup.name, 18, C.ok, true)
      ui.setCursor(vec2(18, 42)); txt(S.badgePopup.desc, 14, C.dim)
    end)
  end) end

  if not visible then return end
  ui.toolWindow('ACR_MENU', vec2(60, math.max(20, screen.y / 2 - H / 2)), vec2(W, H), true, true, function()
    ui.drawRectFilled(vec2(0, 0), vec2(W, H), C.bg, 14)
    ui.pushStyleColor(ui.StyleColor.ChildBg, C.nav)
    ui.childWindow('ACR_NAV', vec2(NAV_W, H), false, WF_PAD, function()
      ui.offsetCursorY(12)
      txt('玉長賽事', 22, C.accent, true)
      txt('v' .. MENU_VERSION, 12, C.dim)
      space(14)
      local items = {}
      for _, n in ipairs(nav) do items[#items + 1] = n end
      if S.admin then items[#items + 1] = { 'admin', '管理' } end
      for _, n in ipairs(items) do
        local badge = ''
        if n[1] == 'go' and S.invite and clock < S.invite.expires then badge = '  ●' end
        if n[1] == 'results' and S.result and page ~= 'results' then badge = '  ●' end
        if btn('nav' .. n[1], n[2] .. badge, nil, 42, page == n[1] and 'selected' or 'ghost') then
          page = n[1]
          if page == 'board' then send('classes'); S.boardKey = nil; S.eventAsked = false end
          if page == 'results' then send('records'); send('profile') end
          if page == 'go' then send('event') end
        end
        space(4)
      end
      space(16)
      txt(gotHello and '● 已連線' or '● 連線中…', 13, gotHello and C.ok or C.bad)
      txt('Ctrl+M 關閉 · Ctrl+R 重開', 12, C.dim)
    end)
    ui.popStyleColor()
    ui.sameLine(0, 0)
    ui.childWindow('ACR_BODY', vec2(W - NAV_W, H), false, WF_PAD, function()
      ui.offsetCursorY(8)
      if S.msg and clock < S.msgUntil then
        panel('toast', 40, function() txt(S.msg, 15, S.msgColor or C.text, true) end)
      end
      if not gotHello then
        txt('等待伺服器回應…' .. (S.pollError and ('  ' .. S.pollError) or ''), 13, C.bad)
        space(6)
      end
      local fn = pages[page] or pages.go
      local ok, err = pcall(fn)
      if not ok then txt('此頁發生錯誤（請截圖給管理員）：' .. tostring(err), 13, C.bad) end
    end)
  end)
end
