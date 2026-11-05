-- 玉長賽事 · CSP online script (Ctrl+M). Talks to ac_plugin.py: requests go out as hidden "ACR|" chat lines,
-- replies come back through the server's HTTP mailbox (port 8766) and, as a fallback, chat.
local REPLAY_PORT, MAILBOX_PORT = 8765, 8766

-- state -----------------------------------------------------------------------
local visible, page = false, 'practice'
local gotHello = false
local S = {
  routes = {}, route = nil, laps = 1, admin = false, roster = {}, invite = nil,
  lobby = nil, ready = false, hud = nil, result = nil, stats = nil, go = nil, gate = nil,
  records = nil, board = {}, boardRoute = nil, msg = nil, msgColor = nil, msgUntil = 0,
  pollError = nil, routeName = 'east-full',
}
local adminVals = { invite_seconds = '30', countdown_seconds = '5', limit_seconds = '900', time = '18:30' }

-- theme -----------------------------------------------------------------------
local T = {
  bg = rgbm(0.055, 0.063, 0.082, 0.96), side = rgbm(0.035, 0.04, 0.055, 0.98),
  card = rgbm(0.09, 0.105, 0.135, 1), cardHi = rgbm(0.12, 0.14, 0.18, 1),
  line = rgbm(1, 1, 1, 0.06), accent = rgbm(0.95, 0.62, 0.15, 1), accentDim = rgbm(0.95, 0.62, 0.15, 0.18),
  text = rgbm(0.93, 0.95, 0.98, 1), dim = rgbm(0.62, 0.66, 0.74, 1), ok = rgbm(0.38, 0.86, 0.52, 1),
  okBg = rgbm(0.16, 0.42, 0.25, 1), bad = rgbm(1, 0.45, 0.4, 1), badBg = rgbm(0.45, 0.16, 0.16, 1),
}
local FONT, FONT_BOLD = 'Microsoft JhengHei UI', 'Microsoft JhengHei UI:Weight=Bold'
local W, H, SIDE = 640, 560, 150
local clock = 0

-- protocol ----------------------------------------------------------------------
local function send(...) ac.sendChatMessage('ACR|' .. table.concat({ ... }, '|')) end

local function split(s, sep)
  local out = {}
  if not s or s == '' or s == '-' then return out end
  for part in (s .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
  return out
end

local function flash(text, color) S.msg, S.msgColor, S.msgUntil = text, color or T.dim, clock + 6 end

local function handle(message)
  local at = message:find('ACR|', 1, true)
  if not at then return false end
  local f = split(message:sub(at + 4), '|')
  local kind = f[1]
  gotHello = true
  if kind == 'routes' then
    S.routes = split(f[2], ',')
    local found = false
    for _, r in ipairs(S.routes) do if r == S.route then found = true end end
    if not found then S.route = S.routes[1] end
  elseif kind == 'admin' then S.admin = f[2] == '1'
  elseif kind == 'roster' then
    S.roster = {}
    for _, row in ipairs(split(f[2], ';')) do
      local p = split(row, ':')
      if #p >= 3 then S.roster[#S.roster + 1] = { slot = p[1], name = p[2], status = p[3] } end
    end
  elseif kind == 'invited' then
    S.invite = { slot = f[2], name = f[3], route = f[4], expires = clock + (tonumber(f[5]) or 30) }
    visible, page = true, 'duel'
  elseif kind == 'lobby' then
    S.lobby = { id = f[2], route = f[3], laps = f[4] }
    S.gate = vec2((tonumber(f[5]) + tonumber(f[7])) / 2, (tonumber(f[6]) + tonumber(f[8])) / 2)
    S.ready, S.result, S.hud, S.stats = false, nil, nil, nil
  elseif kind == 'go' then S.go = clock + (tonumber(f[2]) or 5)
  elseif kind == 'hud' then S.hud = { time = tonumber(f[2]) or 0, laps = f[3], sector = f[4], gap = f[5] }
  elseif kind == 'stats' then
    S.stats = { top = f[2], avg = f[3], moving = f[4], stops = f[5], wall = f[6], car = f[7], third = f[8], jump = f[9] == '1' }
  elseif kind == 'result' then
    S.result = { id = f[2], status = f[3], best = f[4], won = f[5] == 'True', port = f[6] or tostring(REPLAY_PORT) }
    S.lobby, S.hud, S.gate = nil, nil, nil
    visible, page = true, 'result'
    send('records')
  elseif kind == 'records' then
    local p = split(f[2], ':')
    S.records = { runs = p[1] or '0', done = p[2] or '0', best = {} }
    for _, row in ipairs(split(table.concat(p, ':', 3), ';')) do
      local r = split(row, ':')
      if #r == 2 then S.records.best[#S.records.best + 1] = r end
    end
  elseif kind == 'board' then
    S.boardRoute, S.board = f[2], {}
    for _, row in ipairs(split(f[3], ';')) do S.board[#S.board + 1] = split(row, ':') end
  elseif kind == 'ok' then flash('✓  ' .. (f[2] or ''), T.ok)
  elseif kind == 'error' then flash('✕  ' .. (f[2] or ''), T.bad)
  elseif kind == 'declined' then flash((f[2] or '') .. ' 拒絕了邀請', T.bad)
  elseif kind == 'invite_expired' then flash('邀請已逾時', T.dim)
  end
  return true
end

ac.onChatMessage(function(message) return handle(message) end)

local pollTimer, polling, helloTimer, speedTimer, comboHeld = 0, false, 3, 0, false
local function poll(dt)
  pollTimer = pollTimer + dt
  if polling or pollTimer < 1 then return end
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
  poll(dt)
  if not gotHello then
    helloTimer = helloTimer + dt
    if helloTimer > 4 then helloTimer = 0; send('hello') end
  end
  local ctrl, m = ac.isKeyDown(ac.KeyIndex.Control), ac.isKeyDown(ac.KeyIndex.M)
  if ctrl and m and not comboHeld then
    visible = not visible
    if visible then send('roster'); send('records') end
  end
  comboHeld = ctrl and m
  if S.hud or S.lobby then
    speedTimer = speedTimer + dt
    if speedTimer >= 2 then
      speedTimer = 0
      send('spd', string.format('%.1f', ac.getCar(0).speedKmh))
    end
  end
end

-- drawing primitives ------------------------------------------------------------
local function measure(text, size, bold)
  local ok, v = pcall(function()
    ui.pushDWriteFont(bold and FONT_BOLD or FONT)
    local r = ui.measureDWriteText(text, size)
    ui.popDWriteFont()
    return r
  end)
  if ok and v then return v end
  return vec2(#text * size * 0.45, size * 1.3)
end

local function text(str, size, color, bold)
  ui.pushDWriteFont(bold and FONT_BOLD or FONT)
  ui.dwriteText(str, size or 16, color or T.text)
  ui.popDWriteFont()
end

local function textAt(str, pos, size, color, bold)
  ui.setCursor(pos)
  text(str, size, color, bold)
end

local function gap(y) ui.offsetCursorY(y or 8) end

-- custom button: returns true when clicked
local function button(id, label, w, h, style)
  style = style or 'normal'
  local p = ui.getCursor()
  w = w or ui.availableSpaceX()
  h = h or 38
  local clicked = ui.invisibleButton(id, vec2(w, h))
  local hovered = ui.itemHovered()
  local bg = ({ normal = hovered and T.cardHi or T.card, primary = T.accent, ok = T.okBg, bad = T.badBg,
                ghost = hovered and T.cardHi or rgbm(0, 0, 0, 0) })[style]
  if style == 'primary' and hovered then bg = rgbm(1, 0.7, 0.25, 1) end
  ui.drawRectFilled(p, p + vec2(w, h), bg, 8)
  if style == 'normal' or style == 'ghost' then ui.drawRect(p, p + vec2(w, h), T.line, 8) end
  local size = h >= 40 and 18 or 16
  local m = measure(label, size, true)
  local after = ui.getCursor()
  textAt(label, p + vec2((w - m.x) / 2, (h - m.y) / 2), size, style == 'primary' and rgbm(0.08, 0.06, 0.03, 1) or T.text, true)
  ui.setCursor(after)
  return clicked
end

-- card container
local function card(height, fn)
  local p = ui.getCursor()
  local w = ui.availableSpaceX()
  ui.drawRectFilled(p, p + vec2(w, height), T.card, 12)
  ui.setCursor(p + vec2(16, 14))
  ui.beginGroup()
  fn(w - 32)
  ui.endGroup()
  ui.setCursor(p + vec2(0, height + 12))
end

local function sectionTitle(str, sub)
  text(str, 22, T.text, true)
  if sub then text(sub, 14, T.dim) end
  gap(10)
end

local function stat(label, value, x, y, w)
  local p = ui.getCursor()
  ui.drawRectFilled(vec2(x, y), vec2(x + w, y + 58), rgbm(0, 0, 0, 0.25), 8)
  textAt(value, vec2(x + 10, y + 6), 22, T.text, true)
  textAt(label, vec2(x + 10, y + 34), 13, T.dim)
  ui.setCursor(p)
end

local function statGrid(items, cols)
  local origin = ui.getCursor()
  local w = (ui.availableSpaceX() - (cols - 1) * 8) / cols
  for i, it in ipairs(items) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    stat(it[1], it[2], origin.x + c * (w + 8), origin.y + r * 66, w)
  end
  ui.setCursor(origin + vec2(0, math.ceil(#items / cols) * 66))
end

local function chips(list, selected, onPick)
  local x0 = ui.getCursor().x
  local maxX = x0 + ui.availableSpaceX()
  for i, item in ipairs(list) do
    local m = measure(item, 15, true)
    local w = m.x + 28
    if i > 1 then
      ui.sameLine(0, 8)
      if ui.getCursor().x + w > maxX then ui.newLine() end
    end
    if button('chip' .. item, item, w, 32, item == selected and 'primary' or 'normal') then onPick(item) end
  end
end

-- pages -----------------------------------------------------------------------
local function routeSelector()
  text('路線', 14, T.dim)
  gap(4)
  if #S.routes == 0 then
    text('尚未建立路線 → 到「路線」頁按「套用地圖計時線」', 15, T.bad)
    return false
  end
  chips(S.routes, S.route, function(r) S.route = r end)
  gap(10)
  text('圈數', 14, T.dim)
  gap(4)
  local laps = { '1', '2', '3', '5' }
  chips(laps, tostring(S.laps), function(v) S.laps = tonumber(v) end)
  return true
end

local function lobbyCard()
  if not S.lobby then return end
  card(170, function(w)
    text('準備中 · ' .. S.lobby.route, 20, T.accent, true)
    text('場次 ' .. S.lobby.id .. ' · ' .. S.lobby.laps .. ' 圈 · 飛馳起跑', 14, T.dim)
    gap(6)
    local car = ac.getCar(0)
    if S.gate and car then
      local d = vec2(car.position.x, car.position.z):distance(S.gate)
      text(string.format('距起點 %.0f m   ·   倒數結束後才可過線，提早過線算搶跑', d), 15, T.text)
    end
    gap(8)
    if not S.ready then
      if button('ready', '準備好了', w * 0.65, 40, 'ok') then send('ready'); S.ready = true end
    else
      button('readyx', '已準備 · 等待對手', w * 0.65, 40, 'normal')
    end
    ui.sameLine(0, 8)
    if button('cancel', '取消', w * 0.35 - 8, 40, 'bad') then send('cancel'); S.lobby = nil end
  end)
end

local pages = {}

pages.practice = function()
  sectionTitle('快速練習', '單人計時，過起點自動開始、過終點自動結算')
  card(190, function(w)
    if routeSelector() and not S.lobby then
      gap(12)
      if button('startp', '開始練習', w, 44, 'primary') then send('practice', S.route, S.laps) end
    end
  end)
  lobbyCard()
end

pages.duel = function()
  sectionTitle('單挑', '邀請在線車手，雙方到起點並準備後開始')
  local inv = S.invite
  if inv and clock < inv.expires then
    card(120, function(w)
      text(inv.name .. ' 向你發起挑戰', 20, T.accent, true)
      text(string.format('%s · 剩 %.0f 秒', inv.route, inv.expires - clock), 14, T.dim)
      gap(8)
      if button('acc', '接受', w / 2 - 4, 40, 'ok') then send('accept'); S.invite = nil end
      ui.sameLine(0, 8)
      if button('dec', '拒絕', w / 2 - 4, 40, 'bad') then send('decline'); S.invite = nil end
    end)
  end
  card(110, function() routeSelector() end)
  local rows = math.max(1, #S.roster)
  card(60 + rows * 46, function(w)
    text('在線車手', 16, T.text, true)
    ui.sameLine(w - 80)
    if button('refresh', '重新整理', 90, 28, 'ghost') then send('roster') end
    gap(6)
    if #S.roster == 0 then text('目前沒有其他車手', 15, T.dim) end
    for _, p in ipairs(S.roster) do
      local y = ui.getCursor().y
      textAt(p.name, vec2(ui.getCursor().x, y + 8), 16, T.text)
      ui.setCursor(vec2(ui.getCursor().x + w - 110, y))
      if p.status == 'racing' then
        button('busy' .. p.slot, '比賽中', 110, 36, 'ghost')
      elseif button('inv' .. p.slot, '邀請', 110, 36, 'primary') and S.route then
        send('invite', p.slot, S.route, S.laps)
        flash('已邀請 ' .. p.name, T.ok)
      end
      gap(4)
    end
  end)
  lobbyCard()
end

pages.result = function()
  local r = S.result
  if not r then sectionTitle('本場結果', '完成一場後會顯示在這裡'); return end
  local title = S.stats and S.stats.jump and '搶跑 · 成績不列入排行' or (r.won and '勝利！' or (r.status == 'finished' and '完賽' or '未完賽'))
  sectionTitle(title, '賽事編號 ' .. r.id)
  card(100, function()
    text('最快圈', 14, T.dim)
    text(r.best ~= '-' and (r.best .. ' s') or '—', 40, T.accent, true)
  end)
  if S.stats then
    statGrid({ { '最高 km/h', S.stats.top }, { '行駛均速', S.stats.moving }, { '全程均速', S.stats.avg }, { '停車次數', S.stats.stops },
      { '撞牆', S.stats.wall }, { '撞車', S.stats.car }, { '第三方介入', S.stats.third } }, 4)
    gap(12)
  end
  local w = ui.availableSpaceX()
  if button('replay', '看回放', w / 3 - 6, 42, 'primary') then
    os.openURL(string.format('http://%s:%s/%s/index.html', ac.getServerIP(), r.port, r.id))
  end
  ui.sameLine(0, 8)
  if button('again', S.stats and tonumber(S.stats.third or 0) > 0 and '要求重跑' or '再跑 / 再戰', w / 3 - 6, 42, 'normal') then
    send(S.stats and tonumber(S.stats.third or 0) > 0 and 'rerun' or 'rematch')
  end
  ui.sameLine(0, 8)
  if button('up', '上傳我的畫面', w / 3 - 6, 42, 'normal') then
    os.openURL(string.format('http://%s:%d/upload/%s?name=%s', ac.getServerIP(), MAILBOX_PORT, r.id, (ac.getDriverName and ac.getDriverName(0) or '')))
  end
  gap(8)
  if button('free', '返回自由跑', w, 36, 'ghost') then S.result = nil; visible = false end
end

pages.records = function()
  sectionTitle('我的紀錄', '以 Steam ID 歸戶，改名也會保留')
  local rec = S.records
  if not rec then text('載入中…', 15, T.dim); return end
  statGrid({ { '出賽場數', rec.runs }, { '有效完賽', rec.done } }, 2)
  gap(12)
  card(50 + math.max(1, #rec.best) * 32, function(w)
    text('各路線最佳', 16, T.text, true)
    gap(6)
    if #rec.best == 0 then text('還沒有有效完賽', 15, T.dim) end
    for _, row in ipairs(rec.best) do
      local y = ui.getCursor().y
      textAt(row[1], vec2(ui.getCursor().x, y), 16, T.text)
      textAt(row[2] .. ' s', vec2(ui.getCursor().x + w - 110, y), 16, T.accent, true)
      ui.setCursor(vec2(ui.getCursor().x - w + 110, y + 30))
    end
  end)
end

pages.board = function()
  sectionTitle('排行榜', '每人只取最佳有效成績，搶跑與無效場次不列入')
  if #S.routes == 0 then text('尚未建立路線', 15, T.bad); return end
  chips(S.routes, S.route, function(r) S.route = r end)
  gap(10)
  if S.boardRoute ~= S.route then send('board', S.route); S.boardRoute = S.route; S.board = {} end
  card(40 + math.max(1, #S.board) * 38, function(w)
    if #S.board == 0 then text('還沒有有效成績，跑一趟就上榜！', 15, T.dim) end
    for i, row in ipairs(S.board) do
      local p = ui.getCursor()
      if i <= 3 then ui.drawRectFilled(p - vec2(6, 2), p + vec2(w + 6, 32), T.accentDim, 6) end
      textAt(tostring(i), p + vec2(4, 4), 18, i == 1 and T.accent or T.dim, true)
      textAt(row[1] or '', p + vec2(44, 4), 17, T.text)
      textAt((row[2] or '') .. ' s', p + vec2(w - 110, 4), 17, T.text, true)
      ui.setCursor(p + vec2(0, 38))
    end
  end)
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
    if a and b then
      out[#out + 1] = string.format('%s|%.2f|%.2f|%.2f|%.2f', kind, a.x, a.z, b.x, b.z)
      return true
    end
  end
  local hasStart = add('start', 'AC_AB_START_L', 'AC_AB_START_R') or add('start', 'AC_TIME_0_L', 'AC_TIME_0_R')
  local hasFinish = add('finish', 'AC_AB_FINISH_L', 'AC_AB_FINISH_R')
  for i = 1, 30 do add('cp', 'AC_TIME_' .. i .. '_L', 'AC_TIME_' .. i .. '_R') end
  return hasStart and hasFinish, out
end

pages.route = function()
  sectionTitle('路線設定', '所有車手都可以建立或更新路線')
  card(170, function(w)
    text('路線名稱', 14, T.dim)
    ui.setNextItemWidth(w)
    S.routeName = ui.inputText('##rname', S.routeName)
    gap(10)
    text('一鍵套用這張地圖原本「開始計時／結束計時」的位置與分段', 14, T.dim)
    gap(4)
    if button('trk', '套用地圖計時線', w, 44, 'primary') then
      local ok, parts = trackGates()
      if ok then
        send('gbegin', S.routeName)
        for _, part in ipairs(parts) do send('gadd', part) end
        send('gend', S.routeName)
      else flash('這張地圖沒有起終點計時線，請用下方手動設定', T.bad) end
    end
  end)
  card(120, function(w)
    text('手動設定', 16, T.text, true)
    text('停在線上、車頭朝正確行駛方向後按下', 14, T.dim)
    gap(8)
    local bw = (w - 16) / 3
    if button('g1', '設為起點', bw, 38) then send('gate', S.routeName, 'start'); send('hello') end
    ui.sameLine(0, 8)
    if button('g2', '+ 檢查點', bw, 38) then send('gate', S.routeName, 'checkpoint'); send('hello') end
    ui.sameLine(0, 8)
    if button('g3', '設為終點', bw, 38) then send('gate', S.routeName, 'finish'); send('hello') end
  end)
end

pages.admin = function()
  sectionTitle('管理員', '僅伺服器管理員名單內的 Steam ID 可用')
  card(110, function(w)
    text('裁判：賽事判無效／恢復（排行榜同步）', 15, T.text, true)
    gap(6)
    ui.setNextItemWidth(w - 200)
    adminVals.raceId = ui.inputText('##raceid', adminVals.raceId or (S.result and S.result.id or 'AC-'))
    ui.sameLine(0, 8)
    if button('inv', '判無效', 90, 30, 'bad') then send('set', 'invalidate', adminVals.raceId) end
    ui.sameLine(0, 8)
    if button('rst', '恢復', 90, 30) then send('set', 'restore', adminVals.raceId) end
  end)
  card(250, function(w)
    for _, k in ipairs({ { 'invite_seconds', '邀請時限（秒）' }, { 'countdown_seconds', '起跑倒數（秒）' },
      { 'limit_seconds', '完賽時限（秒）' }, { 'time', '時間 HH:MM（下次重啟生效）' } }) do
      local y = ui.getCursor().y
      textAt(k[2], vec2(ui.getCursor().x, y + 8), 15, T.text)
      ui.setCursor(vec2(ui.getCursor().x + w - 220, y))
      ui.setNextItemWidth(120)
      adminVals[k[1]] = ui.inputText('##' .. k[1], adminVals[k[1]])
      ui.sameLine(0, 8)
      if button('ap' .. k[1], '套用', 90, 30) then send('set', k[1], adminVals[k[1]]) end
      ui.setCursor(vec2(ui.getCursor().x - w + 220, y + 50))
    end
  end)
end

local nav = {
  { 'practice', '練習' }, { 'duel', '單挑' }, { 'result', '本場結果' }, { 'records', '我的紀錄' },
  { 'board', '排行榜' }, { 'route', '路線' },
}

-- windows ---------------------------------------------------------------------
local noticeLeft, lastDrawClock = 10, nil
function script.drawUI()
  local screen = ui.windowSize()
  if visible then noticeLeft = 0 end
  noticeLeft = noticeLeft - (clock - (lastDrawClock or clock)); lastDrawClock = clock

  if noticeLeft > 0 then
    ui.toolWindow('ACR_LOADED', vec2(screen.x / 2 - 190, 70), vec2(380, 46), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(380, 46), T.bg, 10)
      ui.drawRectFilled(vec2(0, 0), vec2(4, 46), T.accent)
      textAt('玉長賽事已載入  ·  按 Ctrl+M 開啟', vec2(20, 11), 17, T.text, true)
    end)
  end

  if S.hud then
    ui.toolWindow('ACR_HUD', vec2(screen.x / 2 - 170, 18), vec2(340, 96), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(340, 96), T.bg, 12)
      ui.drawRectFilled(vec2(0, 0), vec2(340, 3), T.accent)
      local t = S.hud.time
      textAt(string.format('%d:%06.3f', math.floor(t / 60), t % 60), vec2(18, 8), 40, T.accent, true)
      textAt(string.format('圈 %s   分段 %s   %.0f km/h', S.hud.laps, S.hud.sector, ac.getCar(0).speedKmh), vec2(20, 64), 15, T.dim)
    end)
  end

  if S.go and clock < S.go then
    local n = math.ceil(S.go - clock)
    ui.toolWindow('ACR_GO', vec2(screen.x / 2 - 70, screen.y * 0.28), vec2(140, 140), true, false, function()
      ui.drawCircleFilled(vec2(70, 70), 66, T.bg, 40)
      ui.drawCircle(vec2(70, 70), 66, T.accent, 40, 3)
      local m = measure(tostring(n), 72, true)
      textAt(tostring(n), vec2(70 - m.x / 2, 70 - m.y / 2), 72, T.accent, true)
    end)
  end

  if not visible then return end
  ui.toolWindow('ACR_MENU', vec2(60, screen.y / 2 - H / 2), vec2(W, H), true, true, function()
    -- frame
    ui.drawRectFilled(vec2(0, 0), vec2(W, H), T.bg, 14)
    ui.drawRectFilled(vec2(0, 0), vec2(SIDE, H), T.side, 14)
    ui.drawRectFilled(vec2(SIDE - 14, 0), vec2(SIDE, H), T.side)
    -- brand
    textAt('玉長', vec2(20, 18), 26, T.accent, true)
    textAt('賽事系統', vec2(20, 52), 14, T.dim)
    -- nav
    local items = {}
    for _, n in ipairs(nav) do items[#items + 1] = n end
    if S.admin then items[#items + 1] = { 'admin', '管理員' } end
    for i, n in ipairs(items) do
      local y = 92 + (i - 1) * 44
      ui.setCursor(vec2(10, y))
      local active = page == n[1]
      if ui.invisibleButton('nav' .. n[1], vec2(SIDE - 20, 38)) then page = n[1] end
      if active then
        ui.drawRectFilled(vec2(10, y), vec2(SIDE - 10, y + 38), T.accentDim, 8)
        ui.drawRectFilled(vec2(10, y + 8), vec2(13, y + 30), T.accent, 2)
      elseif ui.itemHovered() then
        ui.drawRectFilled(vec2(10, y), vec2(SIDE - 10, y + 38), rgbm(1, 1, 1, 0.04), 8)
      end
      textAt(n[2], vec2(26, y + 9), 16, active and T.text or T.dim, active)
      if n[1] == 'duel' and S.invite and clock < S.invite.expires then
        ui.drawCircleFilled(vec2(SIDE - 26, y + 19), 5, T.accent, 12)
      end
    end
    -- connection state at bottom of sidebar
    local connected = gotHello
    ui.drawCircleFilled(vec2(22, H - 24), 5, connected and T.ok or T.bad, 12)
    textAt(connected and '已連線' or '連線中…', vec2(34, H - 34), 13, T.dim)
    textAt('Ctrl+M 關閉', vec2(SIDE + 20, H - 30), 12, T.dim)

    -- content
    ui.setCursor(vec2(SIDE + 20, 20))
    ui.childWindow('ACR_CONTENT', vec2(W - SIDE - 40, H - 60), false, function()
      local ok, err = pcall(pages[page])
      if not ok then text('此頁發生錯誤（請截圖給管理員）：' .. tostring(err), 13, T.bad) end
    end)
    -- toast
    if S.msg and clock < S.msgUntil then
      local m = measure(S.msg, 15, true)
      local x = SIDE + (W - SIDE - m.x - 32) / 2
      ui.drawRectFilled(vec2(x, H - 70), vec2(x + m.x + 32, H - 38), T.card, 16)
      textAt(S.msg, vec2(x + 16, H - 64), 15, S.msgColor or T.text, true)
    end
    if not gotHello then
      textAt('等待伺服器回應…' .. (S.pollError and ('  ' .. S.pollError) or ''), vec2(SIDE + 20, H - 52), 13, T.bad)
    end
  end)
end
