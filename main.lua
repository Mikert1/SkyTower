-- Requires: bump.lua on package.path (https://github.com/kikito/bump.lua)
local bump = require 'library/bump'
local physics = require 'physics'

-- Settings are in px, time in seconds.
local params = {
  -- Physics (spec values)
  g_spec = -3000,
  vx_max_ground = 220,
  ax_ground = 1600,
  vx_max_air = 120,
  air_accel_mult = 0.15,
  friction_time = 0.15,

  -- Collider
  player_w = 18,
  player_h = 40,

  -- Jump charge
  t_min = 0.05,
  t_max = 1.2,
  v_jump_min = 300,
  v_jump_max = 1200,
  h_ratio = 0.6,

  -- Wall knockback
  wall_knockback_min_speed = 50,
  wall_knockback_force = 0.3,
  wall_knockback_max = 200,

  -- Landing slide reduction
  landing_slide_min_fall = 100,
  landing_slide_max_reduction = 0.7,
  landing_slide_scale = 800,

  -- Ice platform settings
  ice_friction_mult = 0.1,
  ice_acceleration_mult = 0.5,

  enemy_speed = 200,
  enemy_radius = 12,

  -- Camera
  cam_smooth = 0.15,
  lookahead_fullcharge = 120,
  cam_anchor_below = 80,

  -- Display settings
  fixed_width = 950,
  base_height = 0,
}

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a,b,t) return a + (b-a)*t end

local function easeOutCubic(x)
  local t = 1 - (1 - x) ^ 3
  return t
end

local speedrunTimer = {
  startTime = nil,
  currentTime = 0,
  isRunning = false,
  bestTime = nil,
  completed = false
}

local countdown = {
  active = false,
  timeLeft = 3,
  startTime = nil
}

local finishDisplay = {
  active = false,
  timeLeft = 3,
  startTime = nil
}

local function startCountdown()
  countdown.active = true
  countdown.timeLeft = 3
  countdown.startTime = love.timer.getTime()
  speedrunTimer.isRunning = false
  speedrunTimer.completed = false
  speedrunTimer.currentTime = 0
end

local function startSpeedrunTimer()
  countdown.active = false
  speedrunTimer.startTime = love.timer.getTime()
  speedrunTimer.isRunning = true
  speedrunTimer.completed = false
  speedrunTimer.currentTime = 0
end

local function completeSpeedrun()
  if speedrunTimer.isRunning then
    speedrunTimer.isRunning = false
    speedrunTimer.completed = true
    
    if not speedrunTimer.bestTime or speedrunTimer.currentTime < speedrunTimer.bestTime then
      speedrunTimer.bestTime = speedrunTimer.currentTime
    end
    
    finishDisplay.active = true
    finishDisplay.timeLeft = 3
    finishDisplay.startTime = love.timer.getTime()
  end
end

local function formatTime(seconds)
  if not seconds then return "--:--.---" end
  
  local minutes = math.floor(seconds / 60)
  local secs = seconds % 60
  local milliseconds = math.floor((secs % 1) * 1000)
  secs = math.floor(secs)
  
  return string.format("%02d:%02d.%03d", minutes, secs, milliseconds)
end

local function loadBestTime()
  if love.filesystem.getInfo('besttime.dat') then
    local content = love.filesystem.read('besttime.dat')
    local bestTime = tonumber(content)
    if bestTime then
      speedrunTimer.bestTime = bestTime
    end
  end
end

local function saveBestTime()
  if speedrunTimer.bestTime then
    love.filesystem.write('besttime.dat', tostring(speedrunTimer.bestTime))
  end
end

local world

local player = {
  x = 200,
  y = 32,
  w = params.player_w,
  h = params.player_h,
  vx = 0,
  vy = 0,
  onGround = false,
  facing = 1,
  t_charge = 0,
  charging = false,
  lastPushTime = 0,
  pushInvincibilityTime = 0.5
}

local spawnPoint = {x = 200, y = 32}

local finishLine = nil

local platforms = {}
local movingPlatforms = {}

local enemies = {}

local cam = {x = 0, y = 0}

local function addPlatform(x,y,w,h,opts)
  opts = opts or {}
  local p = {
    x = x,
    y = y,
    w = w,
    h = h,
    oneWay = opts.oneWay or false,
    ice = opts.ice or false,
    id = #platforms + 1,
    fromTiled = opts.fromTiled or false,
    type = opts.type or nil,
    collidable = opts.collidable ~= false,
  }
  platforms[#platforms+1] = p
  
  if p.collidable then
    world:add(p, p.x, p.y, p.w, p.h)
  end
  return p
end

local function addFinish(x, y, w, h)
  finishLine = {x = x, y = y, w = w or 48, h = h or 24}
  return finishLine
end

local function addEnemy(platformId, startAngle)
  startAngle = startAngle or 0
  local platform = platforms[platformId]
  if not platform then return nil end
  
  local enemy = {
    platformId = platformId,
    platform = platform,
    angle = startAngle,
    speed = params.enemy_speed,
    radius = params.enemy_radius,
    x = 0,
    y = 0,
    active = true,
    perimeter = 0,
    segments = {}
  }
  
  local w, h = platform.w, platform.h
  local px, py = platform.x, platform.y
  
  enemy.segments = {
    {x1 = px, y1 = py, x2 = px + w, y2 = py, length = w},
    {x1 = px + w, y1 = py, x2 = px + w, y2 = py + h, length = h},
    {x1 = px + w, y1 = py + h, x2 = px, y2 = py + h, length = w},
    {x1 = px, y1 = py + h, x2 = px, y2 = py, length = h}
  }
  
  enemy.perimeter = 2 * (w + h)
  
  enemy.angle = startAngle
  
  table.insert(enemies, enemy)
  return enemy
end

local function updateEnemies(dt)
  for _, enemy in ipairs(enemies) do
    if enemy.active and enemy.platform then
      local distancePerSecond = enemy.speed
      local progressPerSecond = distancePerSecond / enemy.perimeter
      enemy.angle = enemy.angle + progressPerSecond * dt
      
      if enemy.angle >= 1 then
        enemy.angle = enemy.angle - 1
      elseif enemy.angle < 0 then
        enemy.angle = enemy.angle + 1
      end
      
      local totalDistance = enemy.angle * enemy.perimeter
      local currentDistance = 0
      
      for i, segment in ipairs(enemy.segments) do
        if totalDistance <= currentDistance + segment.length then
          local segmentProgress = (totalDistance - currentDistance) / segment.length
          enemy.x = segment.x1 + (segment.x2 - segment.x1) * segmentProgress
          enemy.y = segment.y1 + (segment.y2 - segment.y1) * segmentProgress
          break
        end
        currentDistance = currentDistance + segment.length
      end
    end
  end
end

local function checkEnemyCollisions()
  local currentTime = love.timer.getTime()
  
  for _, enemy in ipairs(enemies) do
    if enemy.active then
      if currentTime - player.lastPushTime < player.pushInvincibilityTime then
        return
      end
      
      local pushRadius = enemy.radius
      local dx = math.max(0, math.max(player.x - enemy.x, enemy.x - (player.x + player.w)))
      local dy = math.max(0, math.max(player.y - enemy.y, enemy.y - (player.y + player.h)))
      local distance = math.sqrt(dx * dx + dy * dy)
      
      if distance < pushRadius then
        local pushX = (player.x + player.w/2) - enemy.x
        local pushY = (player.y + player.h/2) - enemy.y
        local pushDistance = math.sqrt(pushX * pushX + pushY * pushY) / 1.3
        
        if pushDistance > 0 then
          pushX = pushX / pushDistance
          pushY = pushY / pushDistance
        else
          local platformCenterX = enemy.platform.x + enemy.platform.w/2
          local platformCenterY = enemy.platform.y + enemy.platform.h/2
          pushX = (player.x + player.w/2) - platformCenterX
          pushY = (player.y + player.h/2) - platformCenterY
          local fallbackDistance = math.sqrt(pushX * pushX + pushY * pushY)
          if fallbackDistance > 0 then
            pushX = pushX / fallbackDistance
            pushY = pushY / fallbackDistance
          else
            pushX = 1
            pushY = 0
          end
        end
        
        local pushForce = 400
        player.vx = pushX * pushForce
        player.vy = math.min(pushY * pushForce, -200)
        
        player.onGround = false
        
        player.lastPushTime = currentTime
        
        return
      end
    end
  end
end

local function checkFinishCollision()
  if finishLine and not speedrunTimer.completed then
    if player.x < finishLine.x + finishLine.w and
       player.x + player.w > finishLine.x and
       player.y < finishLine.y + finishLine.h and
       player.y + player.h > finishLine.y then
      completeSpeedrun()
      saveBestTime()
    end
  end
end

local function buildSampleLevel()
  platforms = {}
  world = bump.newWorld(64)

  addPlatform( -200, 900, 1200, 40)

  addPlatform(120, 700, 240, 16)
  addPlatform(420, 620, 220, 16)
  addPlatform(260, 520, 180, 14)

  addPlatform(200, 420, 48, 10)
  addPlatform(360, 360, 48, 10)
  addPlatform(240, 300, 36, 8)
  addPlatform(320, 240, 28, 8)

  for i=1,12 do
    local x = 160 + ((i-1) % 4) * 60
    local y = 120 - i * 90
    local w = (i % 4 == 0) and 40 or 22
    addPlatform(x, y, w, 8)
  end

  addPlatform(380, -160, 120, 10, {oneWay = true})
  addPlatform(240, -260, 120, 10, {oneWay = true})

  addPlatform(200, -520, 240, 18)
  
  addFinish(200, -560, 240, 24)

  world:add(player, player.x, player.y, player.w, player.h)
end

local sti_available, sti = pcall(require, 'library/sti')

local function loadTiledMap(filename)
  if not love.filesystem.getInfo(filename) then return false end

  platforms = {}
  movingPlatforms = {}
  world = bump.newWorld(64)

  local map
  if sti_available then
    map = sti(filename)
  else
    local chunk = love.filesystem.load(filename)
    if chunk then map = chunk() end
  end

  if not map then return false end

  if map.bump_init then
    map:bump_init(world)
  end

  for _,layer in ipairs(map.layers) do
    if layer.type == 'objectgroup' then
      local lname = (layer.name or ''):lower()
      for _,obj in ipairs(layer.objects) do
        local props = obj.properties or {}
        local oneway = props.oneWay or props.oneway or false
        local platform_type = props.platform_type or props.platformType or nil
        
        -- Only add collidable objects to bump world
        local shouldBeCollidable = props.collidable ~= false and props.visual_only ~= true

        if obj.name == "spawn" or obj.type == "spawn" or (obj.properties and obj.properties.spawn) then
            player.x = obj.x
            player.y = obj.y
            spawnPoint = {x = obj.x, y = obj.y}
            print("Spawn point set from Tiled at", obj.x, obj.y)
        
        elseif (obj.type and obj.type:lower() == 'finish') or obj.name == "finish" or props.finish then
          addFinish(obj.x, obj.y, obj.width, obj.height)
          print("Finish line set from Tiled at", obj.x, obj.y)

        else
          if (obj.width and obj.height and obj.width > 0 and obj.height > 0) or obj.polygon or obj.polyline or obj.points then
            local isMoving = props.moving or props.move or props.moving_platform
            if isMoving or obj.polyline or obj.polygon or obj.points then
              local path = {}
              if obj.polyline then
                for _,pt in ipairs(obj.polyline) do
                  table.insert(path, {x = obj.x + pt.x, y = obj.y + pt.y})
                end
              elseif obj.polygon then
                for _,pt in ipairs(obj.polygon) do
                  table.insert(path, {x = obj.x + pt.x, y = obj.y + pt.y})
                end
              elseif obj.points then
                for _,pt in ipairs(obj.points) do
                  table.insert(path, {x = obj.x + pt.x, y = obj.y + pt.y})
                end
              else
                if props.moveToX and props.moveToY then
                  table.insert(path, {x = obj.x, y = obj.y})
                  table.insert(path, {x = tonumber(props.moveToX), y = tonumber(props.moveToY)})
                end
              end

              if #path == 0 then table.insert(path, {x = obj.x, y = obj.y}) end

              local mp = {x = obj.x, y = obj.y, w = (obj.width or 32), h = (obj.height or 8), oneWay = oneway, moving = true, type = platform_type}
              mp.fromTiled = true
              mp.path = path
              mp.speed = tonumber(props.speed) or 60
              mp.loop = props.loop == nil and true or props.loop
              mp.nextIdx = 2
              mp.dir = 1
              mp.collidable = shouldBeCollidable
              
              movingPlatforms[#movingPlatforms+1] = mp
              platforms[#platforms+1] = mp
              
              if mp.collidable then
                world:add(mp, mp.x, mp.y, mp.w, mp.h)
              end

            else
              local isIce = props.ice or props.icy or props.slippery or false
              local p = addPlatform(obj.x, obj.y, obj.width, obj.height, {
                oneWay = oneway, 
                ice = isIce, 
                fromTiled = true,
                collidable = shouldBeCollidable
              })
              p.type = platform_type
              
              if props.enemy or props.has_enemy then
                local startAngle = tonumber(props.enemy_start_angle) or 0
                addEnemy(#platforms, math.rad(startAngle))
              end
            end
          end
        end
      end
    end
  end

  tilemap = map

  world:add(player, player.x, player.y, player.w, player.h)
  return true
end

local function resetToSpawn()
  player.x = spawnPoint.x
  player.y = spawnPoint.y
  player.vx = 0
  player.vy = 0
  player.onGround = false
  player.charging = false
  player.t_charge = 0
  world:update(player, player.x, player.y, player.w, player.h)
  
  finishDisplay.active = false
  startCountdown()
end

function love.load()
  love.window.setTitle('Vertical Precision Jumper - Prototype')
  love.window.setMode(800, 600, {resizable=true})
  love.graphics.setDefaultFilter('nearest', 'nearest', 0)

  physics.init(params)

  loadBestTime()

  font = love.graphics.newFont(12)
  timerFont = love.graphics.newFont(16)
  bigFont = love.graphics.newFont(72)
  love.graphics.setFont(font)

  local loaded = false
  if sti_available then
    local ok, err = pcall(function() loaded = loadTiledMap('maps/level1.lua') end)
    if not ok then
      print('STI load error:', err)
      loaded = false
    end
  else
    loaded = loadTiledMap('maps/level1.lua')
  end

  if not loaded then
    buildSampleLevel()
  end

  cam.x = params.fixed_width / 2
  cam.y = player.y
  
  startCountdown()
end

local scaleX, scaleY, offsetX, offsetY

local function calculateScale()
  local windowW, windowH = love.graphics.getDimensions()
  
  scaleX = windowW / params.fixed_width
  scaleY = scaleX
  
  local gameWidth = params.fixed_width
  local gameHeight = windowH / scaleY
  
  offsetX = 0
  offsetY = 0
  
  return gameWidth, gameHeight
end

function love.resize(w, h)
  calculateScale()
end

local function getHorizontalInput()
  local left = love.keyboard.isDown('left') or love.keyboard.isDown('a')
  local right = love.keyboard.isDown('right') or love.keyboard.isDown('d')
  if left and not right then return -1 end
  if right and not left then return 1 end
  return 0
end

function love.update(dt)
  if dt > 0.033 then dt = 0.033 end

  if countdown.active then
    local elapsed = love.timer.getTime() - countdown.startTime
    countdown.timeLeft = 3 - elapsed
    
    if countdown.timeLeft <= 0 then
      startSpeedrunTimer()
    end
    
    return
  end

  if finishDisplay.active then
    local elapsed = love.timer.getTime() - finishDisplay.startTime
    finishDisplay.timeLeft = 3 - elapsed
    
    if finishDisplay.timeLeft <= 0 then
      finishDisplay.active = false
    end
  end

  if speedrunTimer.isRunning then
    speedrunTimer.currentTime = love.timer.getTime() - speedrunTimer.startTime
  end

  if #movingPlatforms > 0 then
    for _,mp in ipairs(movingPlatforms) do
      if mp.path and #mp.path >= 1 then
        local target = mp.path[mp.nextIdx or 1]
        local dx = target.x - mp.x
        local dy = target.y - mp.y
        local dist = math.sqrt(dx*dx + dy*dy)
        if dist < 1 then
          mp.nextIdx = (mp.nextIdx or 1) + mp.dir
          if mp.nextIdx > #mp.path then
            if mp.loop then mp.nextIdx = 1 else mp.dir = -1; mp.nextIdx = #mp.path - 1 end
          elseif mp.nextIdx < 1 then
            if mp.loop then mp.nextIdx = #mp.path else mp.dir = 1; mp.nextIdx = 2 end
          end
          target = mp.path[mp.nextIdx]
          dx = target.x - mp.x; dy = target.y - mp.y; dist = math.sqrt(dx*dx + dy*dy)
        end
        if dist > 0 then
          local move = mp.speed * dt
          local t = math.min(1, move / dist)
          mp.x = mp.x + dx * t
          mp.y = mp.y + dy * t
          world:update(mp, mp.x, mp.y, mp.w, mp.h)
        end
      end
    end
  end

  local jumpHeld = love.keyboard.isDown('space')
  local input_x = getHorizontalInput()

  physics.update(player, world, dt, jumpHeld, input_x)

  checkFinishCollision()

  updateEnemies(dt)

  checkEnemyCollisions()

  if params.enable_auto_reset and player.y > params.auto_reset_y then
    resetToSpawn()
  end

  local screenW, screenH = love.graphics.getDimensions()
  local targetCamX = params.fixed_width / 2
  local targetCamY = player.y - params.cam_anchor_below

  local gameWidth, gameHeight = calculateScale()

  -- Camera Y bounds to prevent showing below map bottom
  local mapBottom = 3200
  local cameraBottomLimit = mapBottom - gameHeight / 2

  targetCamY = math.min(targetCamY, cameraBottomLimit)

  local smooth = params.cam_smooth
  cam.x = targetCamX
  
  -- Camera follows when on ground OR falling more than 5 pixels below camera
  local playerDistanceBelowCamera = (player.y - params.cam_anchor_below) - cam.y
  local shouldFollowCamera = player.onGround or playerDistanceBelowCamera > 5
  
  if shouldFollowCamera then
    cam.y = lerp(cam.y, targetCamY, math.min(1, dt / smooth))
  end

  world:update(player, player.x, player.y, player.w, player.h)
end

local function worldToScreenX(x) return x end
local function worldToScreenY(y)
  return y
end

params.show_debug_objects = false

function love.draw()
  local gameWidth, gameHeight = calculateScale()
  
  love.graphics.push()
  love.graphics.scale(scaleX, scaleY)
  love.graphics.translate(offsetX, offsetY)
  
  love.graphics.translate(params.fixed_width/2 - cam.x, gameHeight/2 - cam.y)

  -- Draw tilemap layers only in debug mode
  if tilemap and params.show_debug_objects then
    for _, layer in ipairs(tilemap.layers) do
      if layer.visible and layer.opacity > 0 then
        if layer.type == "objectgroup" then
          tilemap:drawLayer(layer)
        end
      end
    end
  end

  -- Draw platforms based on visibility rules
  for _,p in ipairs(platforms) do
    local shouldDraw = false
    
    if params.show_debug_objects then
      shouldDraw = true
    elseif not p.fromTiled then
      shouldDraw = true
    elseif p.fromTiled and p.collidable then
      shouldDraw = true
    end
    
    if shouldDraw then
      if p.ice then 
        love.graphics.setColor(0.7, 0.9, 1.0, 1)
      elseif p.oneWay then 
        love.graphics.setColor(0.6, 0.6, 0.8, 1)
      else 
        love.graphics.setColor(0.4, 0.4, 0.4, 1) 
      end
      love.graphics.rectangle('fill', p.x, p.y, p.w, p.h)
    end
  end

  -- Draw finish line based on visibility rules
  if finishLine then
    if params.show_debug_objects or not finishLine.fromTiled then
      love.graphics.setColor(0, 1, 0, 0.7)
      love.graphics.rectangle('fill', finishLine.x, finishLine.y, finishLine.w, finishLine.h)
      love.graphics.setColor(0, 1, 0, 1)
      love.graphics.rectangle('line', finishLine.x, finishLine.y, finishLine.w, finishLine.h)
    end
  end

  love.graphics.setColor(1, 0.9, 0.2, 1)
  love.graphics.rectangle('fill', player.x, player.y, player.w, player.h)

  love.graphics.setColor(1, 0, 0, 1)
  for _, enemy in ipairs(enemies) do
    if enemy.active then
      love.graphics.circle('fill', enemy.x, enemy.y, enemy.radius)
    end
  end

  love.graphics.pop()

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font)
  
  local meterW, meterH = 200, 18
  love.graphics.setColor(0.2,0.2,0.2)
  love.graphics.rectangle('fill', 20, 20, meterW, meterH)

  local ratio = 0
  if player.charging then
    local t_charge = clamp(player.t_charge, params.t_min, params.t_max)
    ratio = clamp((t_charge - params.t_min) / (params.t_max - params.t_min), 0, 1)
    ratio = easeOutCubic(ratio)
  end

  love.graphics.setColor(0.9, 0.3, 0.2)
  love.graphics.rectangle('fill', 20, 20, meterW * ratio, meterH)
  love.graphics.setColor(1,1,1)
  love.graphics.rectangle('line', 20, 20, meterW, meterH)
  
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font)
  love.graphics.print('Charge', 20, 42)

  local windowW, windowH = love.graphics.getDimensions()

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(timerFont)
  local timerText = 'Timer: ' .. formatTime(speedrunTimer.currentTime)
  local timerWidth = timerFont:getWidth(timerText)
  love.graphics.print(timerText, windowW/2 - timerWidth/2, 20)
  
  if speedrunTimer.bestTime then
    love.graphics.setColor(1, 1, 0, 1)
    local bestText = 'Best: ' .. formatTime(speedrunTimer.bestTime)
    local bestWidth = timerFont:getWidth(bestText)
    love.graphics.print(bestText, windowW/2 - bestWidth/2, 45)
  end

  if countdown.active then
    love.graphics.setFont(bigFont)
    love.graphics.setColor(1, 1, 1, 1)
    
    local countdownText
    if countdown.timeLeft > 2 then
      countdownText = "3"
    elseif countdown.timeLeft > 1 then
      countdownText = "2"
    elseif countdown.timeLeft > 0 then
      countdownText = "1"
    else
      countdownText = "START!"
    end
    
    local textWidth = bigFont:getWidth(countdownText)
    local textHeight = bigFont:getHeight()
    
    love.graphics.print(countdownText, windowW/2 - textWidth/2, windowH/2 - textHeight/2)
  end

  if finishDisplay.active then
    love.graphics.setFont(bigFont)
    
    local finishText
    local isNewBest = speedrunTimer.currentTime == speedrunTimer.bestTime
    
    if finishDisplay.timeLeft > 2 then
      love.graphics.setColor(0, 1, 0, 1)
      finishText = "FINISH!"
    elseif finishDisplay.timeLeft > 1 then
      if isNewBest then
        love.graphics.setColor(1, 1, 0, 1)
        finishText = "NEW BEST!"
      else
        love.graphics.setColor(0, 1, 0, 1)
        finishText = "COMPLETE!"
      end
    else
      love.graphics.setColor(1, 1, 1, 1)
      finishText = formatTime(speedrunTimer.currentTime)
    end
    
    local textWidth = bigFont:getWidth(finishText)
    local textHeight = bigFont:getHeight()
    
    love.graphics.print(finishText, windowW/2 - textWidth/2, windowH/2 - textHeight/2)
  end

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font)
  love.graphics.print('Controls: ←/A, →/D, Space (hold -> release to jump), R=restart', 20, windowH - 40)
end

function love.keypressed(key)
  if key == 'r' then
    player.x = spawnPoint.x
    player.y = spawnPoint.y
    player.vx = 0
    player.vy = 0
    player.onGround = false
    player.charging = false
    player.t_charge = 0
    world:update(player, player.x, player.y, player.w, player.h)
    
    countdown.active = false
    finishDisplay.active = false
    startSpeedrunTimer()
  end
end

function love.quit()
  saveBestTime()
end

_G.params = params
_G.player = player
_G.world = world
_G.platforms = platforms
_G.finishLine = finishLine