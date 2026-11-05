-- 玉長賽事 v4 · CSP online script (Ctrl+M)
-- Layout rule: everything flows top-to-bottom (no absolute positioning), so nothing can overlap.
-- Requests: hidden "ACR|" chat lines. Replies: server HTTP mailbox (port 8766) + chat fallback.
local REPLAY_PORT, MAILBOX_PORT = 8765, 8766
local W, H, NAV_W = 660, 600, 150

-- state -----------------------------------------------------------------------
local visible, page = false, 'practice'
local gotHello, clock = false, 0
local S = {
  routes = {}, route = nil, laps = 1, admin = false, roster = {}, invite = nil, locked = {},
  lobby = nil, ready = false, hud = nil, result = nil, stats = nil, series = nil, go = nil, gate = nil,
  records = nil, board = {}, boardKey = nil, boardClass = '', classes = {}, weekly = nil,
  lobbies = {}, duelMode = 'duel', split = nil, msg = nil, msgColor = nil, msgUntil = 0,
  pollError = nil, routeName = 'east-full', wrongWay = 0,
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
local WF_PAD = (ui.WindowFlags and WF_PAD) or 0
local function pushVar(name, value)
  local id = ui.StyleVar and ui.StyleVar[name]
  if id then ui.pushStyleVar(id, value); return 1 end
  return 0
end

-- protocol ----------------------------------------------------------------------
local function send(...) ac.sendChatMessage('ACR|' .. table.concat({ ... }, '|')) end

local function split(s, sep)
  local out = {}
  if not s or s == '' or s == '-' then return out end
  for part in (s .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
  return out
end

local function flash(text, color) S.msg, S.msgColor, S.msgUntil = text, color or C.dim, clock + 5 end

local handlers = {}
handlers.routes = function(f)
  S.routes = split(f[2], ',')
  local found = false
  for _, r in ipairs(S.routes) do if r == S.route then found = true end end
  if not found then S.route = S.routes[1] end
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
  visible, page = true, 'duel'
end
handlers.lobby = function(f)
  S.lobby = { id = f[2], route = f[3], laps = f[4] }
  S.gate = vec2((tonumber(f[5]) + tonumber(f[7])) / 2, (tonumber(f[6]) + tonumber(f[8])) / 2)
  S.ready, S.hud, S.stats, S.split = false, nil, nil, nil
  if page ~= 'duel' then page = 'practice' end
end
handlers.go = function(f) S.go = clock + (tonumber(f[2]) or 5) end
handlers.hud = function(f)
  S.hud = { time = tonumber(f[2]) or 0, laps = tonumber(f[3]) or 0, sectors = tonumber(f[4]) or 0, gap = f[5],
            pos = f[6], of = f[7], totalLaps = f[8], cps = tonumber(f[9]) or 0 }
end
handlers.split = function(f) S.split = { label = f[2], time = f[3], delta = f[4], untilT = clock + 4 } end
handlers.stats = function(f)
  S.stats = { top = f[2], avg = f[3], moving = f[4], stops = f[5], wall = f[6], car = f[7], third = f[8], jump = f[9] == '1' }
end
handlers.series = function(f) S.series = { me = f[2], them = f[3], round = f[4], done = f[5] == '1' } end
handlers.result = function(f)
  S.result = { id = f[2], status = f[3], best = f[4], won = f[5] == 'True', port = f[6] or tostring(REPLAY_PORT) }
  S.lobby, S.hud, S.gate = nil, nil, nil
  visible, page = true, 'result'
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
handlers.lobbies = function(f)
  S.lobbies = {}
  for _, row in ipairs(split(f[2], ';')) do
    local p = split(row, '~')
    if #p >= 6 then S.lobbies[#S.lobbies + 1] = { host = p[1], hostName = p[2], route = p[3], laps = p[4], count = p[5], names = p[6] } end
  end
end
handlers.ok = function(f) flash('✓ ' .. (f[2] or ''), C.ok) end
handlers.error = function(f) flash('✕ ' .. (f[2] or ''), C.bad) end
handlers.declined = function(f) flash((f[2] or '') .. ' 拒絕了邀請', C.bad) end
handlers.invite_expired = function() flash('邀請已逾時', C.dim) end

local function handle(message)
  local at = message:find('ACR|', 1, true)
  if not at then return false end
  local f = split(message:sub(at + 4), '|')
  gotHello = true
  local h = handlers[f[1]]
  if h then pcall(h, f) end
  return true
end

ac.onChatMessage(function(message) return handle(message) end)

-- update ------------------------------------------------------------------------
local pollTimer, polling, helloTimer, speedTimer, comboHeld = 0, false, 3, 0, false
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
  poll(dt)
  if not gotHello then
    helloTimer = helloTimer + dt
    if helloTimer > 4 then helloTimer = 0; send('hello') end
  end
  local ctrl, m = ac.isKeyDown(ac.KeyIndex.Control), ac.isKeyDown(ac.KeyIndex.M)
  if ctrl and m and not comboHeld then
    visible = not visible
    if visible then send('roster'); send('records'); send('lobbies') end
  end
  comboHeld = ctrl and m
  local car = ac.getCar(0)
  if S.hud or S.lobby then
    speedTimer = speedTimer + dt
    if speedTimer >= 2 then speedTimer = 0; send('spd', string.format('%.1f', car.speedKmh)) end
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
  ui.dwriteText(s, size or 16, color or C.text)
  ui.popDWriteFont()
end
local function title(s, sub)
  txt(s, 24, C.text, true)
  if sub then txt(sub, 14, C.dim) end
  ui.offsetCursorY(10)
end
local function label(s) txt(s, 14, C.dim); ui.offsetCursorY(2) end
local function space(h) ui.offsetCursorY(h or 10) end

local styles = {
  normal = { C.btn, C.btnHi, C.text }, primary = { C.accent, C.accentHi, C.dark },
  ok = { C.okBtn, rgbm(0.22, 0.55, 0.33, 1), C.text }, bad = { C.badBtn, rgbm(0.6, 0.22, 0.22, 1), C.text },
  selected = { C.accentSoft, rgbm(0.96, 0.62, 0.16, 0.26), C.accent }, ghost = { rgbm(0, 0, 0, 0), C.btnHi, C.dim },
}
-- width: number, or nil = full available width
local function btn(id, text, width, height, style)
  local st = styles[style or 'normal']
  ui.pushStyleColor(ui.StyleColor.Button, st[1])
  ui.pushStyleColor(ui.StyleColor.ButtonHovered, st[2])
  ui.pushStyleColor(ui.StyleColor.ButtonActive, st[2])
  ui.pushStyleColor(ui.StyleColor.Text, st[3])
  local pushed = pushVar('FrameRounding', 8)
  local clicked = ui.button(text .. '##' .. id, vec2(width or ui.availableSpaceX(), height or 38))
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
  panel('lobbyp', 190, function()
    txt('準備中 · ' .. S.lobby.route, 20, C.accent, true)
    txt('場次 ' .. S.lobby.id .. ' · ' .. S.lobby.laps .. ' 圈 · 飛馳起跑', 14, C.dim)
    space(6)
    local arrow, dist = directionTo(S.gate)
    if arrow then txt(string.format('起點在 %s %.0f 公尺', arrow, dist), 17, C.text, true) end
    txt('倒數結束後才可以過起點線，提早過線算搶跑', 14, C.dim)
    space(8)
    local c = row('lb', { { S.ready and '已準備 · 等待其他人' or '準備好了', S.ready and 'normal' or 'ok' }, { '取消', 'bad' } }, 40)
    if c == 1 and not S.ready then send('ready'); S.ready = true end
    if c == 2 then send('cancel'); S.lobby = nil end
  end)
  return true
end

-- pages -----------------------------------------------------------------------
local pages = {}

pages.practice = function()
  title('練習', '單人計時 · 過起點自動開始，過終點自動結算')
  if lobbyPanel() then return end
  if routePicker('p') then
    if btn('startp', '③ 開始練習', nil, 46, 'primary') then send('practice', S.route, S.laps) end
  end
end

pages.duel = function()
  title('對戰', '單挑、三戰兩勝或多人房')
  local inv = S.invite
  if inv and clock < inv.expires then
    panel('inv', 120, function()
      txt(inv.name .. ' 向你發起挑戰', 20, C.accent, true)
      txt(string.format('%s · 剩 %.0f 秒', inv.route, inv.expires - clock), 14, C.dim)
      space(8)
      local c = row('ia', { { '接受', 'ok' }, { '拒絕', 'bad' } }, 40)
      if c == 1 then send('accept'); S.invite = nil end
      if c == 2 then send('decline'); S.invite = nil end
    end)
  end
  if lobbyPanel() then return end
  local modes = { { 'duel', '單挑' }, { 'bo3', '三戰兩勝' }, { 'multi', '多人房' } }
  local items = {}
  for _, m in ipairs(modes) do items[#items + 1] = { m[2], S.duelMode == m[1] and 'selected' or 'normal' } end
  local c = row('mode', items, 36)
  if c then S.duelMode = modes[c][1]; if S.duelMode == 'multi' then send('lobbies') end end
  space(8)
  if not routePicker('d') then return end
  if S.duelMode == 'multi' then
    if btn('host', '開一個多人房（目前路線）', nil, 40, 'primary') then send('host', S.route, S.laps) end
    space(6)
    label('房間列表')
    if #S.lobbies == 0 then txt('目前沒有房間', 15, C.dim) end
    local myName = ac.getDriverName and ac.getDriverName(0) or ''
    for i, l in ipairs(S.lobbies) do
      panel('lob' .. i, 104, function()
        txt(l.hostName .. ' 的房間 · ' .. l.route .. ' · ' .. l.laps .. ' 圈 · ' .. l.count .. '/8', 16, C.text, true)
        txt(l.names, 13, C.dim)
        space(4)
        if l.hostName == myName then
          local c2 = row('lh' .. i, { { '開始比賽', 'primary' }, { '解散', 'bad' } }, 34)
          if c2 == 1 then send('launch') end
          if c2 == 2 then send('leave') end
        else
          local c2 = row('lj' .. i, { { '加入', 'ok' }, { '離開', 'normal' } }, 34)
          if c2 == 1 then send('join', l.host) end
          if c2 == 2 then send('leave') end
        end
      end)
    end
    return
  end
  label('③ 選擇對手')
  if btn('refresh', '重新整理名單', nil, 30, 'ghost') then send('roster') end
  if #S.roster == 0 then txt('目前沒有其他車手在線', 15, C.dim) end
  for _, p in ipairs(S.roster) do
    listRow(p.name, function()
      if p.status == 'racing' then txt('比賽中', 15, C.dim)
      elseif btn('inv' .. p.slot, '邀請', nil, 32, 'primary') then send('invite', p.slot, S.route, S.laps, S.duelMode) end
    end)
    space(4)
  end
end

pages.result = function()
  local r = S.result
  if not r then title('本場結果', '完成一場後會顯示在這裡'); return end
  local head = S.stats and S.stats.jump and '搶跑 · 不列入排行' or (r.won and '🏆 勝利' or (r.status == 'finished' and '完賽' or '未完賽'))
  title(head, '賽事編號 ' .. r.id)
  if S.series then
    txt(string.format('三戰兩勝 · 你 %s : %s 對手 · 第 %s 局%s', S.series.me, S.series.them, S.series.round,
      S.series.done and '（系列賽結束）' or '（下一局已開房，請回起點）'), 16, C.accent, true)
    space(6)
  end
  panel('best', 86, function()
    label('最快圈')
    txt(r.best ~= '-' and (r.best .. ' 秒') or '—', 34, C.accent, true)
  end)
  if S.stats then
    panel('st', 190, function()
      listRow('最高速', S.stats.top .. ' km/h')
      listRow('行駛均速（3 km/h 以上）', S.stats.moving .. ' km/h')
      listRow('全程均速（含停車）', S.stats.avg .. ' km/h')
      listRow('停車次數', S.stats.stops)
      listRow('撞牆 / 撞車 / 第三方', S.stats.wall .. ' / ' .. S.stats.car .. ' / ' .. S.stats.third)
    end)
  end
  local third = S.stats and tonumber(S.stats.third or 0) > 0
  local c = row('ra', { { '看回放', 'primary' }, { third and '要求重跑' or '再跑 / 再戰', 'normal' }, { '上傳我的畫面', 'normal' } }, 42)
  if c == 1 then os.openURL(string.format('http://%s:%s/%s/index.html', ac.getServerIP(), r.port, r.id)) end
  if c == 2 then send(third and 'rerun' or 'rematch') end
  if c == 3 then os.openURL(string.format('http://%s:%d/upload/%s?name=%s', ac.getServerIP(), MAILBOX_PORT, r.id,
    ac.getDriverName and ac.getDriverName(0) or '')) end
  space(6)
  if btn('free', '關閉，回自由跑', nil, 34, 'ghost') then S.result = nil; visible = false end
end

pages.records = function()
  title('我的紀錄', '以 Steam ID 歸戶，改名也不會遺失')
  local rec = S.records
  if not rec then txt('載入中…', 15, C.dim); return end
  panel('rc', 70, function()
    listRow('出賽場數 / 有效完賽', rec.runs .. ' / ' .. rec.done)
  end)
  label('各路線個人最佳')
  if #rec.best == 0 then txt('還沒有有效完賽', 15, C.dim) end
  for _, row2 in ipairs(rec.best) do listRow(row2[1], row2[2] .. ' 秒', C.accent); space(4) end
end

local function boardList(list)
  if #list == 0 then txt('還沒有有效成績，跑一趟就上榜！', 15, C.dim) end
  for i, r in ipairs(list) do
    listRow((i <= 3 and ({ '🥇 ', '🥈 ', '🥉 ' })[i] or (i .. '.  ')) .. (r[1] or ''), (r[2] or '') .. ' 秒', i == 1 and C.accent or C.text, i <= 3)
    space(4)
  end
end

pages.board = function()
  title('排行榜', '每人只取最佳有效成績 · 搶跑與無效場次不列入')
  if #S.routes == 0 then txt('還沒有路線', 15, C.bad); return end
  label('路線')
  for i, r in ipairs(S.routes) do
    if btn('br' .. i, r, nil, 30, r == S.route and 'selected' or 'normal') then S.route = r end
    space(4)
  end
  if #S.classes > 0 then
    label('車級')
    local items = { { '全部', S.boardClass == '' and 'selected' or 'normal' } }
    for _, c in ipairs(S.classes) do items[#items + 1] = { c .. ' 級', S.boardClass == c and 'selected' or 'normal' } end
    local c = row('cls', items, 30)
    if c then S.boardClass = c == 1 and '' or S.classes[c - 1] end
  end
  local key = (S.route or '') .. '|' .. S.boardClass
  if S.boardKey ~= key then S.boardKey = key; S.board = {}; send('board', S.route, S.boardClass ~= '' and S.boardClass or '-') end
  space(8)
  boardList(S.board)
end

pages.weekly = function()
  title('每週挑戰', '每週一重置 · 只計本週成績')
  if not S.weekly then send('weekly'); S.weekly = { board = {} }; txt('載入中…', 15, C.dim); return end
  if not S.weekly.route then txt('管理員還沒設定本週挑戰', 15, C.dim); return end
  panel('wk', 76, function()
    txt(S.weekly.route .. (S.weekly.car and (' · 指定車：' .. S.weekly.car) or ' · 不限車'), 18, C.accent, true)
    txt('用「練習」跑這條路線即可參加', 14, C.dim)
  end)
  if btn('wkr', '重新整理', nil, 30, 'ghost') then send('weekly') end
  space(6)
  boardList(S.weekly.board)
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
  for i = 1, 30 do add('cp', 'AC_TIME_' .. i .. '_L', 'AC_TIME_' .. i .. '_R') end
  return hasStart and hasFinish, out
end

pages.route = function()
  title('路線設定', '所有車手都能建立路線 · 被鎖定的路線只有管理員能改')
  label('路線名稱（輸入新名稱就是新增，輸入現有名稱就是更新）')
  ui.setNextItemWidth(ui.availableSpaceX())
  S.routeName = ui.inputText('##rname', S.routeName)
  space(8)
  panel('auto', 110, function()
    txt('方法一：一鍵套用', 17, C.text, true)
    txt('使用地圖本身「開始計時／結束計時」的位置與分段', 14, C.dim)
    space(6)
    if btn('trk', '套用地圖計時線', nil, 40, 'primary') then
      local ok, parts = trackGates()
      if ok then
        send('gbegin', S.routeName)
        for _, part in ipairs(parts) do send('gadd', part) end
        send('gend', S.routeName)
      else flash('這張地圖沒有起終點計時線，請用方法二', C.bad) end
    end
  end)
  panel('manual', 130, function()
    txt('方法二：手動設定', 17, C.text, true)
    txt('把車停在線上、車頭朝正確行駛方向，依序按下（起點和終點都要設）', 14, C.dim)
    space(6)
    local c = row('man', { { '設為起點', 'normal' }, { '+ 檢查點', 'normal' }, { '設為終點', 'normal' } }, 38)
    if c then send('gate', S.routeName, ({ 'start', 'checkpoint', 'finish' })[c]); send('hello') end
  end)
end

pages.admin = function()
  title('管理員', '僅管理員名單內的 Steam ID 可用')
  label('賽事設定')
  for _, k in ipairs({ { 'invite_seconds', '邀請時限（秒）' }, { 'countdown_seconds', '起跑倒數（秒）' },
    { 'limit_seconds', '完賽時限（秒）' }, { 'time', '時間 HH:MM（重啟後生效）' } }) do
    listRow(k[2], function()
      ui.setNextItemWidth(ui.availableSpaceX() - 78)
      A[k[1]] = ui.inputText('##' .. k[1], A[k[1]])
      ui.sameLine(0, 6)
      if btn('ap' .. k[1], '套用', 72, 28) then send('set', k[1], A[k[1]]) end
    end)
    space(4)
  end
  space(8)
  label('目前選擇的路線：' .. (S.route or '（無）'))
  local c = row('rt', { { '鎖定路線', 'normal' }, { '解鎖路線', 'normal' }, { '設為本週挑戰', 'primary' } }, 36)
  if c and S.route then send('set', ({ 'lock', 'unlock', 'weekly' })[c], S.route) end
  space(10)
  label('裁判：輸入賽事編號判無效或恢復（排行榜同步更新）')
  if A.raceId == '' and S.result then A.raceId = S.result.id end
  ui.setNextItemWidth(ui.availableSpaceX())
  A.raceId = ui.inputText('##raceid', A.raceId)
  space(4)
  local c2 = row('jd', { { '判無效', 'bad' }, { '恢復有效', 'normal' } }, 34)
  if c2 then send('set', c2 == 1 and 'invalidate' or 'restore', A.raceId) end
end

local nav = {
  { 'practice', '練習' }, { 'duel', '對戰' }, { 'result', '本場結果' }, { 'records', '我的紀錄' },
  { 'board', '排行榜' }, { 'weekly', '每週挑戰' }, { 'route', '路線設定' },
}

-- windows ---------------------------------------------------------------------
local noticeLeft, lastDraw = 10, nil

local function hudWindow(screen)
  local h = S.hud
  ui.toolWindow('ACR_HUD', vec2(screen.x / 2 - 190, 16), vec2(380, 104), true, false, function()
    ui.drawRectFilled(vec2(0, 0), vec2(380, 104), C.bg, 12)
    ui.drawRectFilled(vec2(0, 0), vec2(380, 3), C.accent)
    ui.setCursor(vec2(18, 8))
    txt(string.format('%d:%06.3f', math.floor(h.time / 60), h.time % 60), 38, C.accent, true)
    ui.setCursor(vec2(20, 62))
    local parts = { string.format('第 %d/%s 圈', math.min(h.laps + 1, tonumber(h.totalLaps) or 1), h.totalLaps or '1') }
    if h.cps > 0 then parts[#parts + 1] = string.format('分段 %d/%d', h.sectors % h.cps, h.cps) end
    if h.of and tonumber(h.of) and tonumber(h.of) > 1 then parts[#parts + 1] = string.format('名次 %s/%s', h.pos, h.of) end
    parts[#parts + 1] = string.format('%.0f km/h', ac.getCar(0).speedKmh)
    txt(table.concat(parts, '   '), 15, C.text)
    if h.gap and h.gap ~= '' then
      ui.setCursor(vec2(250, 18))
      txt('落後 ' .. h.gap:gsub('^%+', '') .. ' 秒', 15, C.bad, true)
    elseif h.of and tonumber(h.of) and tonumber(h.of) > 1 then
      ui.setCursor(vec2(270, 18))
      txt('領先中', 15, C.ok, true)
    end
  end)
  if S.split and clock < S.split.untilT then
    local d = S.split.delta
    local color = d == '' and C.text or (d:sub(1, 1) == '-' and C.ok or C.bad)
    ui.toolWindow('ACR_SPLIT', vec2(screen.x / 2 - 130, 128), vec2(260, 60), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(260, 60), C.bg, 10)
      ui.setCursor(vec2(14, 6))
      txt(S.split.label .. '  ' .. S.split.time, 16, C.text, true)
      ui.setCursor(vec2(14, 30))
      txt(d == '' and '首次紀錄' or ('比個人最佳 ' .. d), 16, color, true)
    end)
  end
end

function script.drawUI()
  local screen = ui.windowSize()
  local dt = lastDraw and (clock - lastDraw) or 0
  lastDraw = clock
  if visible then noticeLeft = 0 end
  noticeLeft = noticeLeft - dt

  if noticeLeft > 0 then
    ui.toolWindow('ACR_LOADED', vec2(screen.x / 2 - 190, 70), vec2(380, 46), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(380, 46), C.bg, 10)
      ui.drawRectFilled(vec2(0, 0), vec2(4, 46), C.accent)
      ui.setCursor(vec2(20, 11))
      txt('玉長賽事已載入 · 按 Ctrl+M 開啟', 17, C.text, true)
    end)
  end

  if S.hud then hudWindow(screen) end

  if wrongTimer > 1.5 then
    ui.toolWindow('ACR_WRONG', vec2(screen.x / 2 - 150, screen.y * 0.22), vec2(300, 64), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(300, 64), C.badBtn, 12)
      ui.setCursor(vec2(70, 12))
      txt('⚠ 逆向行駛', 28, C.text, true)
    end)
  end

  if S.lobby and not visible then
    local arrow, dist = directionTo(S.gate)
    if arrow then
      ui.toolWindow('ACR_TOSTART', vec2(screen.x / 2 - 150, 16), vec2(300, 44), true, false, function()
        ui.drawRectFilled(vec2(0, 0), vec2(300, 44), C.bg, 10)
        ui.setCursor(vec2(16, 10))
        txt(string.format('起點 %s %.0f m', arrow, dist), 18, C.accent, true)
      end)
    end
  end

  if S.go and clock < S.go then
    local n = math.ceil(S.go - clock)
    ui.toolWindow('ACR_GO', vec2(screen.x / 2 - 70, screen.y * 0.28), vec2(140, 140), true, false, function()
      ui.drawCircleFilled(vec2(70, 70), 66, C.bg, 40)
      ui.drawCircle(vec2(70, 70), 66, C.accent, 40, 3)
      ui.setCursor(vec2(n >= 10 and 30 or 48, 26))
      txt(tostring(n), 72, C.accent, true)
    end)
  end

  if not visible then return end
  ui.toolWindow('ACR_MENU', vec2(60, math.max(20, screen.y / 2 - H / 2)), vec2(W, H), true, true, function()
    ui.drawRectFilled(vec2(0, 0), vec2(W, H), C.bg, 14)
    -- left navigation (its own scroll region)
    ui.pushStyleColor(ui.StyleColor.ChildBg, C.nav)
    ui.childWindow('ACR_NAV', vec2(NAV_W, H), false, WF_PAD, function()
      ui.offsetCursorY(10)
      txt('玉長賽事', 22, C.accent, true)
      space(14)
      local items = {}
      for _, n in ipairs(nav) do items[#items + 1] = n end
      if S.admin then items[#items + 1] = { 'admin', '管理員' } end
      for _, n in ipairs(items) do
        local badge = (n[1] == 'duel' and S.invite and clock < S.invite.expires) and '  ●' or ''
        if btn('nav' .. n[1], n[2] .. badge, nil, 38, page == n[1] and 'selected' or 'ghost') then
          page = n[1]
          if page == 'weekly' then send('weekly') end
          if page == 'board' then send('classes'); S.boardKey = nil end
        end
        space(4)
      end
      space(12)
      txt(gotHello and '● 已連線' or '● 連線中…', 13, gotHello and C.ok or C.bad)
      txt('Ctrl+M 關閉', 12, C.dim)
    end)
    ui.popStyleColor()
    ui.sameLine(0, 0)
    -- content
    ui.childWindow('ACR_BODY', vec2(W - NAV_W, H), false, WF_PAD, function()
      ui.offsetCursorY(8)
      if S.msg and clock < S.msgUntil then
        panel('toast', 40, function() txt(S.msg, 15, S.msgColor or C.text, true) end)
      end
      if not gotHello then
        txt('等待伺服器回應…' .. (S.pollError and ('  ' .. S.pollError) or ''), 13, C.bad)
        space(6)
      end
      local ok, err = pcall(pages[page])
      if not ok then txt('此頁發生錯誤（請截圖給管理員）：' .. tostring(err), 13, C.bad) end
    end)
  end)
end
