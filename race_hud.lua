-- CSP online script: Ctrl+M race menu + HUD. Talks to ac_plugin.py through hidden "ACR|" chat lines.
local visible, tab = false, 'practice'
local gotHello = false
local state = {
  routes = {}, route = nil, laps = 1, admin = false, roster = {}, invite = nil,
  lobby = nil, ready = false, hud = nil, result = nil, msg = nil, msgAt = 0, go = nil, gate = nil,
  records = nil, board = {}, boardRoute = nil,
}
local adminVals = { invite_seconds = '30', countdown_seconds = '5', limit_seconds = '900', time = '18:30' }

-- palette
local C = {
  accent = rgbm(1, 0.62, 0.15, 1), dim = rgbm(1, 1, 1, 0.55), ok = rgbm(0.35, 0.9, 0.5, 1),
  bad = rgbm(1, 0.4, 0.35, 1), panel = rgbm(0.06, 0.07, 0.09, 0.92), line = rgbm(1, 0.62, 0.15, 0.8),
}
local W, H = 600, 620

local function send(...) ac.sendChatMessage('ACR|' .. table.concat({ ... }, '|')) end

local function split(s, sep)
  local out = {}
  if not s or s == '' or s == '-' then return out end
  for part in (s .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
  return out
end

local function flash(text, color) state.msg, state.msgColor, state.msgAt = text, color or C.dim, os.clock() end

local function handle(message)
  local at = message:find('ACR|', 1, true)
  if not at then return false end
  local f = split(message:sub(at + 4), '|')
  local kind = f[1]
  gotHello = true
  if kind == 'routes' then
    state.routes = split(f[2], ',')
    state.route = state.route or state.routes[1]
  elseif kind == 'admin' then state.admin = f[2] == '1'
  elseif kind == 'roster' then
    state.roster = {}
    for _, row in ipairs(split(f[2], ';')) do
      local p = split(row, ':')
      if #p >= 3 then state.roster[#state.roster + 1] = { slot = p[1], name = p[2], status = p[3] } end
    end
  elseif kind == 'invited' then
    state.invite = { slot = f[2], name = f[3], route = f[4], expires = os.clock() + (tonumber(f[5]) or 30) }
    visible, tab = true, 'duel'
  elseif kind == 'lobby' then
    state.lobby = { id = f[2], route = f[3], laps = f[4] }
    state.gate = vec2((tonumber(f[5]) + tonumber(f[7])) / 2, (tonumber(f[6]) + tonumber(f[8])) / 2)
    state.ready, state.result, state.hud = false, nil, nil
  elseif kind == 'go' then state.go = os.clock() + (tonumber(f[2]) or 5)
  elseif kind == 'hud' then state.hud = { time = tonumber(f[2]) or 0, laps = f[3], sector = f[4], gap = f[5] }
  elseif kind == 'result' then
    state.result = { id = f[2], status = f[3], best = f[4], won = f[5] == 'True' }
    state.lobby, state.hud, state.gate = nil, nil, nil
    visible, tab = true, 'records'
    send('records')
  elseif kind == 'records' then
    local p = split(f[2], ':')
    state.records = { runs = p[1], done = p[2], best = {} }
    local rest = table.concat(p, ':', 3)
    for _, row in ipairs(split(rest, ';')) do
      local r = split(row, ':')
      if #r == 2 then state.records.best[#state.records.best + 1] = r end
    end
  elseif kind == 'board' then
    state.boardRoute, state.board = f[2], {}
    for _, row in ipairs(split(f[3], ';')) do state.board[#state.board + 1] = split(row, ':') end
  elseif kind == 'ok' then flash('✓ ' .. (f[2] or ''), C.ok)
  elseif kind == 'error' then flash('✕ ' .. (f[2] or ''), C.bad)
  elseif kind == 'declined' then flash((f[2] or '') .. ' 拒絕了邀請', C.bad)
  elseif kind == 'invite_expired' then flash('邀請已逾時', C.dim)
  end
  return true
end

-- channel 1: chat (hidden); channel 2: HTTP mailbox on the server (port 8766)
ac.onChatMessage(function(message) return handle(message) end)

local pollTimer, polling = 0, false
local function poll(dt)
  pollTimer = pollTimer + dt
  if polling or pollTimer < 1 then return end
  pollTimer, polling = 0, true
  local car = ac.getCar(0)
  local url = string.format('http://%s:8766/acr/%d', ac.getServerIP(), car.sessionID)
  web.get(url, function(err, response)
    polling = false
    state.pollError = err and tostring(err) or nil
    if response and response.body then
      for line in response.body:gmatch('[^\n]+') do handle(line) end
    end
  end)
end

local helloTimer, speedTimer, comboHeld = 3, 0, false
function script.update(dt)
  poll(dt)
  -- keep greeting the server until it answers (first messages can be lost while joining)
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
  if state.hud or state.lobby then
    speedTimer = speedTimer + dt
    if speedTimer >= 2 then
      speedTimer = 0
      send('spd', string.format('%.1f', ac.getCar(0).speedKmh))
    end
  end
end

-- widgets ---------------------------------------------------------------
local FONT = 'Microsoft JhengHei UI'
local function dtext(text, size, color)
  ui.pushDWriteFont(FONT)
  ui.dwriteText(text, size or 18, color or rgbm.colors.white)
  ui.popDWriteFont()
end

local function header(text) dtext(text, 24, C.accent); ui.offsetCursorY(2) end
local function label(text) dtext(text, 17, C.dim) end

local function bigButton(text, color)
  if color then ui.pushStyleColor(ui.StyleColor.Button, color) end
  local clicked = ui.button(text, vec2(ui.availableSpaceX(), 48))
  if color then ui.popStyleColor() end
  return clicked
end

local function routePicker()
  label('路線')
  if #state.routes == 0 then
    dtext('尚未設定路線', 18, C.bad)
    if state.admin then label('到「管理」分頁設定起點與終點') else label('請管理員設定路線') end
    return false
  end
  for _, r in ipairs(state.routes) do
    if ui.selectable(r, state.route == r) then state.route = r end
  end
  ui.offsetCursorY(4)
  label('圈數')
  ui.setNextItemWidth(ui.availableSpaceX())
  state.laps = ui.slider('##laps', state.laps, 1, 10, '%.0f 圈')
  return true
end

local function lobbyPanel()
  if not state.lobby then return end
  local car = ac.getCar(0)
  ui.separator()
  header('準備中  ' .. state.lobby.route)
  label('場次 ' .. state.lobby.id .. '  ·  ' .. state.lobby.laps .. ' 圈')
  if state.gate and car then
    local d = vec2(car.position.x, car.position.z):distance(state.gate)
    dtext(string.format('距起點 %.0f m', d))
    label('飛馳起跑：沿正確方向通過起點線即開始計時')
  end
  if not state.ready then
    if bigButton('準備好了', rgbm(0.15, 0.45, 0.25, 1)) then send('ready'); state.ready = true end
  else dtext('已準備，等待對手…', 18, C.ok) end
  if ui.button('取消', vec2(ui.availableSpaceX(), 24)) then send('cancel'); state.lobby = nil end
end

-- tabs ------------------------------------------------------------------
local function practiceTab()
  if routePicker() and not state.lobby then
    ui.offsetCursorY(6)
    if bigButton('開始練習', rgbm(0.75, 0.42, 0.08, 1)) then send('practice', state.route, math.floor(state.laps)) end
  end
end

local function duelTab()
  local inv = state.invite
  if inv and os.clock() < inv.expires then
    header('收到挑戰')
    dtext(string.format('%s 邀請你跑 %s', inv.name, inv.route))
    label(string.format('剩 %.0f 秒', inv.expires - os.clock()))
    ui.columns(2, false)
    if bigButton('接受', rgbm(0.15, 0.45, 0.25, 1)) then send('accept'); state.invite = nil end
    ui.nextColumn()
    if bigButton('拒絕', rgbm(0.45, 0.15, 0.15, 1)) then send('decline'); state.invite = nil end
    ui.columns(1)
    ui.separator()
  end
  if not routePicker() then return end
  ui.separator()
  label('在線車手')
  ui.sameLine(ui.availableSpaceX() - 60)
  if ui.button('重新整理') then send('roster') end
  if #state.roster == 0 then label('目前沒有其他車手') end
  for _, p in ipairs(state.roster) do
    local racing = p.status == 'racing'
    dtext(p.name)
    ui.sameLine(ui.windowWidth() - 160)
    if racing then dtext('比賽中', 18, C.dim)
    elseif ui.button('邀請##' .. p.slot, vec2(80, 0)) then
      send('invite', p.slot, state.route, math.floor(state.laps))
      flash('已邀請 ' .. p.name, C.ok)
    end
  end
end

local function recordsTab()
  local r = state.result
  if r then
    header(r.won and '勝利！' or (r.status == 'finished' and '完賽' or '未完賽'))
    dtext('最快圈  ' .. r.best .. ' s')
    label('賽事編號 ' .. r.id)
    ui.columns(2, false)
    if bigButton('再跑一次') then send('practice') end
    ui.nextColumn()
    if bigButton('返回自由跑') then state.result = nil end
    ui.columns(1)
    ui.separator()
  end
  local rec = state.records
  if not rec then label('載入中…'); return end
  header('我的紀錄')
  dtext(string.format('出賽 %s 場  ·  有效完賽 %s 場', rec.runs, rec.done))
  for _, row in ipairs(rec.best) do
    dtext(row[1]); ui.sameLine(ui.windowWidth() - 160); dtext(row[2] .. ' s', 18, C.accent)
  end
end

local function boardTab()
  if not routePicker() then return end
  if state.boardRoute ~= state.route then send('board', state.route); state.boardRoute = state.route end
  ui.separator()
  header('排行榜  ' .. (state.route or ''))
  if #state.board == 0 then label('還沒有有效成績') end
  for i, row in ipairs(state.board) do
    dtext(string.format('%d', i), 18, i == 1 and C.accent or C.dim)
    ui.sameLine(30); dtext(row[1] or '')
    ui.sameLine(ui.windowWidth() - 160); dtext((row[2] or '') .. ' s')
  end
end

local function adminTab()
  header('賽事設定')
  for _, k in ipairs({ { 'invite_seconds', '邀請時限 (秒)' }, { 'countdown_seconds', '倒數 (秒)' }, { 'limit_seconds', '完賽時限 (秒)' } }) do
    ui.setNextItemWidth(120)
    adminVals[k[1]] = ui.inputText(k[2] .. '##' .. k[1], adminVals[k[1]])
    ui.sameLine(ui.windowWidth() - 80)
    if ui.button('套用##' .. k[1], vec2(60, 0)) then send('set', k[1], adminVals[k[1]]) end
  end
  ui.setNextItemWidth(120)
  adminVals.time = ui.inputText('時間 HH:MM', adminVals.time)
  ui.sameLine(ui.windowWidth() - 80)
  if ui.button('套用##time', vec2(60, 0)) then send('set', 'time', adminVals.time) end
  label('原版伺服器：時間於下次重啟生效')
  ui.separator()
  header('路線閘門')
  ui.setNextItemWidth(160)
  adminVals.routeName = ui.inputText('路線名稱', adminVals.routeName or state.route or 'east-full')
  label('停在線上、車頭朝正確行駛方向，然後按：')
  local w = (ui.availableSpaceX() - 16) / 3
  for i, g in ipairs({ { 'start', '起點' }, { 'checkpoint', '+檢查點' }, { 'finish', '終點' } }) do
    if i > 1 then ui.sameLine() end
    if ui.button(g[2], vec2(w, 30)) then send('gate', adminVals.routeName, g[1]); send('hello') end
  end
end

local tabs = {
  { 'practice', '練習', practiceTab }, { 'duel', '單挑', duelTab },
  { 'records', '紀錄', recordsTab }, { 'board', '排行', boardTab },
}

-- drawing ---------------------------------------------------------------
local loadedAt = os.clock()
function script.drawUI()
  local screen = ui.windowSize()
  if os.clock() - loadedAt < 12 then
    ui.toolWindow('ACR_LOADED', vec2(screen.x / 2 - 210, 90), vec2(420, 44), true, false, function()
      dtext('比賽選單已載入 · 按 Ctrl+M 開啟', 20, C.accent)
    end)
  end

  if state.hud then
    ui.toolWindow('ACR_HUD', vec2(screen.x / 2 - 150, 24), vec2(300, 78), true, false, function()
      ui.drawRectFilled(vec2(0, 0), vec2(300, 78), C.panel, 6)
      ui.pushFont(ui.Font.Huge)
      local t = state.hud.time
      dtext(string.format('%d:%06.3f', math.floor(t / 60), t % 60), 40, C.accent)
      ui.popFont()
      dtext(string.format('圈 %s  ·  分段 %s  ·  %.0f km/h', state.hud.laps, state.hud.sector, ac.getCar(0).speedKmh))
    end)
  end

  if state.go and os.clock() < state.go then
    ui.toolWindow('ACR_GO', vec2(screen.x / 2 - 60, screen.y / 3), vec2(120, 90), true, false, function()
      ui.pushFont(ui.Font.Huge)
      dtext(string.format('%d', math.ceil(state.go - os.clock())), 64, C.accent)
      ui.popFont()
    end)
  end

  if not visible then return end
  ui.toolWindow('ACR_MENU', vec2(40, screen.y / 2 - H / 2), vec2(W, H), false, true, function()
    ui.drawRectFilled(vec2(0, 0), vec2(W, H), C.panel, 8)
    ui.drawRectFilled(vec2(0, 0), vec2(W, 3), C.line)
    ui.offsetCursorY(6)
    dtext('玉長賽事', 30, C.accent)
    ui.sameLine(W - 150)
    label('Ctrl+M 關閉')
    ui.pushFont(ui.Font.Title)
    ui.tabBar('acr_tabs', function()
      for _, t in ipairs(tabs) do ui.tabItem(t[2], function() tab = t[1]; t[3]() end) end
      if state.admin then ui.tabItem('管理', function() tab = 'admin'; adminTab() end) end
    end)
    lobbyPanel()
    ui.popFont()
    if not gotHello then
      ui.separator()
      dtext('等待伺服器回應…' .. (state.pollError and ('  ' .. state.pollError) or ''), 16, C.bad)
    end
    if state.msg and os.clock() - state.msgAt < 6 then
      ui.separator()
      ui.textColored(state.msg, state.msgColor)
    end
  end)
end
