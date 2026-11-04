-- CSP online script: Ctrl+M menu + race HUD. Talks to ac_plugin.py through hidden "ACR|" chat lines.
-- Delivered via csp_online_hud.ini; players with a compatible CSP get it automatically on join.
local visible, tab = false, 'practice'
local state = {
  routes = {}, route = nil, laps = 1, admin = false, roster = {}, invite = nil,
  lobby = nil, ready = false, hud = nil, result = nil, msg = '', go = nil, gate = nil,
}
local adminVals = { invite_seconds = '30', countdown_seconds = '5', limit_seconds = '900', time = '18:30' }

local function send(...) ac.sendChatMessage('ACR|' .. table.concat({ ... }, '|')) end

local function split(s, sep)
  local out = {}
  for part in string.gmatch(s, '([^' .. sep .. ']*)') do out[#out + 1] = part end
  return out
end

ac.onChatMessage(function(message)
  if message:sub(1, 4) ~= 'ACR|' then return false end
  local f = split(message:sub(5), '|')
  local kind = f[1]
  if kind == 'routes' then
    state.routes = f[2] == '-' and {} or split(f[2], ',')
    state.route = state.route or state.routes[1]
  elseif kind == 'admin' then state.admin = f[2] == '1'
  elseif kind == 'roster' then
    state.roster = {}
    if f[2] ~= '-' then
      for _, row in ipairs(split(f[2], ';')) do
        local p = split(row, ':')
        if #p >= 3 then state.roster[#state.roster + 1] = { slot = p[1], name = p[2], status = p[3] } end
      end
    end
  elseif kind == 'invited' then
    state.invite = { slot = f[2], name = f[3], route = f[4], expires = os.clock() + tonumber(f[5] or 30) }
    visible, tab = true, 'invite'
  elseif kind == 'lobby' then
    state.lobby = { id = f[2], route = f[3], laps = f[4] }
    state.gate = vec2((tonumber(f[5]) + tonumber(f[7])) / 2, (tonumber(f[6]) + tonumber(f[8])) / 2)
    state.ready, state.result, state.hud = false, nil, nil
  elseif kind == 'go' then state.go = os.clock() + tonumber(f[2] or 5)
  elseif kind == 'hud' then state.hud = { time = f[2], laps = f[3], sector = f[4], gap = f[5] }
  elseif kind == 'result' then
    state.result = { id = f[2], status = f[3], best = f[4], won = f[5] == 'True' }
    state.lobby, state.hud, state.gate = nil, nil, nil
    visible, tab = true, 'result'
  elseif kind == 'error' or kind == 'ok' or kind == 'declined' or kind == 'invite_expired' then
    state.msg = kind .. ' ' .. (f[2] or '')
  end
  return true -- hide protocol lines from chat
end)

local hello = false
local speedTimer = 0
function script.update(dt)
  if not hello then send('hello'); hello = true end
  -- report the game's own speedometer while a run is active, for server-side speed verification
  if state.hud or state.lobby then
    speedTimer = speedTimer + dt
    if speedTimer >= 2 then
      speedTimer = 0
      send('spd', string.format('%.1f', ac.getCar(0).speedKmh))
    end
  end
  local ctrl = ac.isKeyDown(ac.KeyIndex.Control)
  local m = ac.isKeyDown(ac.KeyIndex.M)
  if ctrl and m and not state.comboHeld then state.toggle = true end
  state.comboHeld = ctrl and m
  if state.toggle then
    state.toggle = false
    visible = not visible
    if visible then send('roster') end
  end
end

local function lobbyPanel()
  if not state.lobby then return end
  local car = ac.getCar(0)
  ui.separator()
  ui.text('場次 ' .. state.lobby.id .. '  路線 ' .. state.lobby.route .. '  圈數 ' .. state.lobby.laps)
  if state.gate and car then
    local d = vec2(car.position.x, car.position.z):distance(state.gate)
    ui.text(string.format('距起點 %.0f m（飛馳起跑，沿正確方向過線開始計時）', d))
  end
  if not state.ready then
    if ui.button('準備') then send('ready'); state.ready = true end
  else ui.text('已準備，等待對手…') end
  ui.sameLine()
  if ui.button('取消') then send('cancel'); state.lobby = nil end
end

local tabs = {
  practice = function()
    ui.text('路線')
    for _, r in ipairs(state.routes) do
      if ui.radioButton(r, state.route == r) then state.route = r end
    end
    if #state.routes == 0 then ui.text('尚未設定路線（管理員 → 設定閘門）') end
    state.laps = ui.slider('##laps', state.laps, 1, 10, '圈數 %.0f')
    if state.route and ui.button('快速練習') then send('practice', state.route, math.floor(state.laps)) end
  end,
  duel = function()
    if ui.button('重新整理') then send('roster') end
    for _, p in ipairs(state.roster) do
      ui.text(p.name .. (p.status == 'racing' and '（比賽中）' or ''))
      if p.status == 'free' and state.route then
        ui.sameLine()
        if ui.button('邀請##' .. p.slot) then send('invite', p.slot, state.route, math.floor(state.laps)) end
      end
    end
  end,
  invite = function()
    local inv = state.invite
    if not inv or os.clock() > inv.expires then ui.text('沒有待處理邀請'); return end
    ui.text(string.format('%s 邀請你單挑（%s），剩 %.0f 秒', inv.name, inv.route, inv.expires - os.clock()))
    if ui.button('接受') then send('accept'); state.invite = nil end
    ui.sameLine()
    if ui.button('拒絕') then send('decline'); state.invite = nil end
  end,
  result = function()
    local r = state.result
    if not r then ui.text('尚無結果'); return end
    ui.text('賽事編號 ' .. r.id)
    ui.text('狀態 ' .. r.status .. '   最快圈 ' .. r.best .. (r.won and '   勝利！' or ''))
    if ui.button('再跑一次') then send('practice') end
    ui.sameLine()
    if ui.button('返回自由跑') then state.result = nil end
  end,
  admin = function()
    for _, k in ipairs({ 'invite_seconds', 'countdown_seconds', 'limit_seconds' }) do
      adminVals[k] = ui.inputText(k, adminVals[k])
      ui.sameLine()
      if ui.button('套用##' .. k) then send('set', k, adminVals[k]) end
    end
    adminVals.time = ui.inputText('時間 HH:MM', adminVals.time)
    ui.sameLine()
    if ui.button('套用##time') then send('set', 'time', adminVals.time) end
    ui.text('設定路線閘門：開到線上、車頭朝正確方向後按')
    for _, g in ipairs({ 'start', 'checkpoint', 'finish' }) do
      if ui.button(g) and state.route then send('gate', state.route, g) end
      ui.sameLine()
    end
    ui.newLine()
  end,
}

local loadedAt = os.clock()
function script.drawUI()
  if os.clock() - loadedAt < 20 then
    ui.toolWindow('ACR_LOADED', vec2(24, 60), vec2(300, 40), false, function()
      ui.text('比賽選單已載入：按 Ctrl+M 開啟')
    end)
  end
  if state.hud then
    ui.toolWindow('ACR_HUD', vec2(24, 80), vec2(260, 90), false, function()
      ui.text(string.format('計時 %s s   圈 %s   分段 %s', state.hud.time, state.hud.laps, state.hud.sector))
      if state.hud.gap ~= '' then ui.text('對手差距（分段） ' .. state.hud.gap) end
      ui.text(string.format('車速 %.0f km/h', ac.getCar(0).speedKmh))
    end)
  end
  if state.go and os.clock() < state.go then
    ui.toolWindow('ACR_GO', vec2(ui.windowWidth() / 2 - 60, 160), vec2(120, 60), false, function()
      ui.text(string.format('倒數 %.0f', state.go - os.clock()))
    end)
  end
  if not visible then return end
  ui.toolWindow('ACR_MENU', vec2(24, 180), vec2(380, 360), true, function()
    local names = { practice = '快速練習', duel = '單挑', invite = '邀請', result = '我的紀錄' }
    for _, k in ipairs({ 'practice', 'duel', 'invite', 'result' }) do
      if ui.button(names[k]) then tab = k end
      ui.sameLine()
    end
    if state.admin and ui.button('管理員') then tab = 'admin' end
    ui.newLine()
    ui.separator()
    tabs[tab]()
    lobbyPanel()
    if state.msg ~= '' then ui.separator(); ui.text(state.msg) end
    ui.text('Ctrl+M 開關選單')
  end)
end
