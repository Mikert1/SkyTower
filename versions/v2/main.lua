-- main.lua
-- Vertical Precision Jumper (Love2D + Bump)
-- Implements the spec you gave: charge-release single jump, precise ledges, sparse checkpoints.
-- Requires: bump.lua on package.path (https://github.com/kikito/bump.lua)

local bump = require 'bump'

-- =====================
-- Tunable gameplay params (matching the spec)
-- All distances/velocities are in px, time in seconds.
local params = {
  -- Coordinate note: Love2D uses Y positive *down*. Your spec uses Y positive *up*.
  -- To preserve the feel & numbers exactly, vertical values in the spec are treated as "up-positive".
  -- Internally we convert: love_vy = -spec_vy, love_g = -spec_g.

  -- Physics (spec values)
  g_spec = -3000,            -- spec: Y positive up, gravity negative
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
  wall_knockback_min_speed = 50,    -- Minimum horizontal speed to trigger knockback
  wall_knockback_force = 0.3,       -- Multiplier for knockback force
  wall_knockback_max = 200,         -- Maximum knockback velocity
  
  -- Landing slide reduction
  landing_slide_min_fall = 100,     -- Minimum fall speed to reduce slide
  landing_slide_max_reduction = 0.7, -- Maximum slide reduction (0-1)
  landing_slide_scale = 800,        -- Fall speed that gives max reduction

  -- Camera
  cam_smooth = 0.15,
  lookahead_fullcharge = 120,
  cam_anchor_below = 80,

  -- Checkpoint save
  save_file = 'save.dat',

  -- Display settings
  fixed_width = 950,  -- Fixed game world width in pixels
  base_height = 0,  -- Minimum height
}

-- Convert to love coords
local g = -params.g_spec -- gravity in love coords (positive down)

-- easeOutCubic
local function easeOutCubic(x)
  local t = 1 - (1 - x) ^ 3
  return t
end

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a,b,t) return a + (b-a)*t end

-- bump world
local world

-- Entities
local player = {
  x = 200,
  y = 32, -- top-left coordinate in LOVE coords (y positive down)
  w = params.player_w,
  h = params.player_h,
  vx = 0,
  vy = 0,
  onGround = false,
  facing = 1,
  t_charge = 0,
  charging = false,
  lastCheckpoint = {x = 200, y = 32}
}

local platforms = {}
local checkpoints = {}
local movingPlatforms = {}
local currentCheckpoint = 1

-- Camera (center on player x, follow y with smoothing)
local cam = {x = 0, y = 0}

-- Level builder helpers
local function addPlatform(x,y,w,h,opts)
  opts = opts or {}
  local p = {
    x = x,
    y = y,
    w = w,
    h = h,
    oneWay = opts.oneWay or false,
    id = #platforms + 1,
    fromTiled = opts.fromTiled or false, -- NEW flag
    type = opts.type or nil,
  }
  platforms[#platforms+1] = p
  world:add(p, p.x, p.y, p.w, p.h)
  return p
end

local function addCheckpoint(x,y)
  local cp = {x=x, y=y, w=24, h=8, id = #checkpoints + 1}
  checkpoints[#checkpoints+1] = cp
  world:add(cp, cp.x, cp.y, cp.w, cp.h)
  return cp
end

-- Collision filter for player movement (handles one-way platforms)
local function playerFilter(item, other)
  if other.oneWay then
    -- one-way platform: allow pass-through while moving up (vy < 0), solid when moving down (vy >= 0)
    if player.vy < 0 then
      return 'cross'
    else
      return 'slide'
    end
  end
  return 'slide'
end

-- Save/load checkpoint index and player position
local function saveProgress(idx, playerPos)
  local saveData = {
    checkpoint = idx,
    playerX = playerPos and playerPos.x or player.x,
    playerY = playerPos and playerPos.y or player.y
  }
  
  -- Convert to string format for saving
  local saveString = saveData.checkpoint .. "," .. saveData.playerX .. "," .. saveData.playerY
  love.filesystem.write(params.save_file, saveString)
end

local function loadProgress()
  if love.filesystem.getInfo(params.save_file) then
    local content = love.filesystem.read(params.save_file)
    
    -- Parse the saved data
    local parts = {}
    for part in content:gmatch("[^,]+") do
      table.insert(parts, part)
    end
    
    if #parts >= 3 then
      local idx = tonumber(parts[1])
      local playerX = tonumber(parts[2])
      local playerY = tonumber(parts[3])
      
      -- Validate checkpoint exists
      if idx and checkpoints[idx] then
        return idx, {x = playerX, y = playerY}
      elseif playerX and playerY then
        -- Even if checkpoint is invalid, return position
        return 1, {x = playerX, y = playerY}
      end
    elseif #parts >= 1 then
      -- Old save format (just checkpoint index)
      local idx = tonumber(parts[1])
      if idx and checkpoints[idx] then
        return idx, nil
      end
    end
  end
  return 1, nil
end

-- Sample vertical level: tutorial + two sections
local function buildSampleLevel()
  platforms = {}
  checkpoints = {}
  world = bump.newWorld(64)

  -- Bigger floor so the level feels taller
  addPlatform( -200, 900, 1200, 40) -- ground (extended)

  -- Tutorial section (more spacing, bigger forgiving platforms)
  addPlatform(120, 700, 240, 16)
  addPlatform(420, 620, 220, 16)
  addPlatform(260, 520, 180, 14)

  addCheckpoint(260, 500)

  -- Mid section (wider spacing, introduce narrow ledges)
  addPlatform(200, 420, 48, 10)
  addPlatform(360, 360, 48, 10)
  addPlatform(240, 300, 36, 8)
  addPlatform(320, 240, 28, 8)

  addCheckpoint(300, 220)

  -- Long tricky ascent (larger vertical gaps, smaller precision ledges)
  -- spacing increased to create the "long fall" feel and require full-charge shots
  for i=1,12 do
    local x = 160 + ((i-1) % 4) * 60
    local y = 120 - i * 90
    local w = (i % 4 == 0) and 40 or 22
    addPlatform(x, y, w, 8)
    if i==6 then addCheckpoint(x, y - 20) end
  end

  -- A couple of one-way platforms placed higher
  addPlatform(380, -160, 120, 10, {oneWay = true})
  addPlatform(240, -260, 120, 10, {oneWay = true})

  -- Top area (end goal) - larger staging platform
  addPlatform(200, -520, 240, 18)
  addCheckpoint(200, -540)

  -- add player to world (checkpoints are already added by addCheckpoint)
  world:add(player, player.x, player.y, player.w, player.h)
end

-- Respawn to checkpoint
local function respawnToCheckpoint(idx)
  idx = idx or currentCheckpoint
  local cp = checkpoints[idx] or {x = player.lastCheckpoint.x, y = player.lastCheckpoint.y}
  player.x = cp.x
  player.y = cp.y - player.h - 2
  player.vx = 0
  player.vy = 0
  player.onGround = false
  world:update(player, player.x, player.y, player.w, player.h)
end

-- Attempt to load a Tiled map (Lua export) using STI if available, otherwise fallback to sample level
local sti_available, sti = pcall(require, 'sti')

local function loadTiledMap(filename)
  if not love.filesystem.getInfo(filename) then return false end

  -- create world
  platforms = {}
  checkpoints = {}
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

  -- If STI provides bump integration, initialize tile-layer collisions
  if map.bump_init then
    map:bump_init(world)
  end

  -- Parse object layers: platforms, checkpoints, moving platforms, spawn
  for _,layer in ipairs(map.layers) do
    if layer.type == 'objectgroup' then
      local lname = (layer.name or ''):lower()
      for _,obj in ipairs(layer.objects) do
        local props = obj.properties or {}
        local oneway = props.oneWay or props.oneway or false
        local platform_type = props.platform_type or props.platformType or nil

        if obj.name == "spawn" or obj.type == "spawn" or (obj.properties and obj.properties.spawn) then
            -- set spawn
            player.x = obj.x
            player.y = obj.y
            spawnPoint = {x = obj.x, y = obj.y}  -- Store spawn point
            player.lastCheckpoint = {x = obj.x, y = obj.y}
            print("Spawn point set from Tiled at", obj.x, obj.y)
        end
        -- Handle checkpoints (either by type or layer name or property)
        if (obj.type and obj.type:lower() == 'checkpoint') or lname:find('checkpoint') or props.checkpoint then
          if props.checkpoint_index then
            local idx = tonumber(props.checkpoint_index)
            addCheckpoint(obj.x, obj.y)
            checkpoints[#checkpoints].index = idx
            -- ensure sparse assignment: we keep order but record index
          else
            addCheckpoint(obj.x, obj.y)
          end

        else
          -- Treat as platform if it has size or polygon/polyline
          if (obj.width and obj.height and obj.width > 0 and obj.height > 0) or obj.polygon or obj.polyline or obj.points then
            -- If object has moving property or polyline path, create moving platform
            local isMoving = props.moving or props.move or props.moving_platform
            if isMoving or obj.polyline or obj.polygon or obj.points then
              -- collect path points
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
                -- fallback: two-point path using moveToX/moveToY properties
                if props.moveToX and props.moveToY then
                  table.insert(path, {x = obj.x, y = obj.y})
                  table.insert(path, {x = tonumber(props.moveToX), y = tonumber(props.moveToY)})
                end
              end

              -- Ensure path has at least a start point
              if #path == 0 then table.insert(path, {x = obj.x, y = obj.y}) end

              -- create moving platform entity
              local mp = {x = obj.x, y = obj.y, w = (obj.width or 32), h = (obj.height or 8), oneWay = oneway, moving = true, type = platform_type}
              mp.fromTiled = true
              mp.path = path
              mp.speed = tonumber(props.speed) or 60
              mp.loop = props.loop == nil and true or props.loop
              mp.nextIdx = 2
              mp.dir = 1

              movingPlatforms[#movingPlatforms+1] = mp
              platforms[#platforms+1] = mp
              world:add(mp, mp.x, mp.y, mp.w, mp.h)

            else
              -- static platform
                local p = addPlatform(obj.x, obj.y, obj.width, obj.height, {oneWay = oneway})
                p.type = platform_type

            end
          end
        end
      end
    end
  end

  -- keep a reference to the tilemap for drawing
  tilemap = map

  -- finally add player to world
  world:add(player, player.x, player.y, player.w, player.h)
  return true
end

-- Add a new reset to spawn function
local function resetToSpawn()
  player.x = spawnPoint.x
  player.y = spawnPoint.y
  player.vx = 0
  player.vy = 0
  player.onGround = false
  player.charging = false
  player.t_charge = 0
  world:update(player, player.x, player.y, player.w, player.h)
end

-- Initialization
function love.load()
  love.window.setTitle('Vertical Precision Jumper - Prototype')
  love.window.setMode(800, 600, {resizable=true})  -- Make it resizable
  love.graphics.setDefaultFilter('nearest', 'nearest', 0)

  -- Try to load a Tiled map (Lua export) from maps/level1.lua using STI (you said you have it in project)
  local loaded = false
  if sti_available then
    local ok, err = pcall(function() loaded = loadTiledMap('maps/level1.lua') end)
    if not ok then
      print('STI load error:', err)
      loaded = false
    end
  else
    -- still attempt to load the Lua-exported Tiled map directly
    loaded = loadTiledMap('maps/level1.lua')
  end

  if not loaded then
    buildSampleLevel()
  end

  local savedCheckpoint, savedPosition = loadProgress()
  currentCheckpoint = savedCheckpoint
  
  if savedPosition then
    -- Restore exact saved position
    player.x = savedPosition.x
    player.y = savedPosition.y
    player.lastCheckpoint = savedPosition
    world:update(player, player.x, player.y, player.w, player.h)
  else
    -- Fall back to checkpoint respawn
    if checkpoints[currentCheckpoint] then
      player.lastCheckpoint = {x = checkpoints[currentCheckpoint].x, y = checkpoints[currentCheckpoint].y}
    end
    respawnToCheckpoint(currentCheckpoint)
  end

  cam.x = params.fixed_width / 2  -- Center the camera X
  cam.y = player.y

  font = love.graphics.newFont(12)
end

-- Global variables for scaling
local scaleX, scaleY, offsetX, offsetY

local function calculateScale()
  local windowW, windowH = love.graphics.getDimensions()
  
  -- Calculate scale based on width (this keeps width consistent)
  scaleX = windowW / params.fixed_width
  scaleY = scaleX  -- Use same scale for Y to maintain aspect ratio
  
  -- Calculate viewport dimensions in game coordinates
  local gameWidth = params.fixed_width
  local gameHeight = windowH / scaleY
  
  -- Center the viewport
  offsetX = 0
  offsetY = 0
  
  return gameWidth, gameHeight
end

-- Handle window resize
function love.resize(w, h)
  calculateScale()
end

-- Input helpers
local function getHorizontalInput()
  local left = love.keyboard.isDown('left') or love.keyboard.isDown('a')
  local right = love.keyboard.isDown('right') or love.keyboard.isDown('d')
  if left and not right then return -1 end
  if right and not left then return 1 end
  return 0
end

-- Update
function love.update(dt)
  -- fixed timestep clamp
  if dt > 0.033 then dt = 0.033 end

  -- Update moving platforms (move along path and update bump world)
  if #movingPlatforms > 0 then
    for _,mp in ipairs(movingPlatforms) do
      if mp.path and #mp.path >= 1 then
        local target = mp.path[mp.nextIdx or 1]
        -- compute vector to target
        local dx = target.x - mp.x
        local dy = target.y - mp.y
        local dist = math.sqrt(dx*dx + dy*dy)
        if dist < 1 then
          -- advance waypoint
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

  -- Charge / jump input
  local jumpHeld = love.keyboard.isDown('space')
  local input_x = getHorizontalInput()

  -- Determine if onGround; we'll set it after movement collision resolution

  -- Horizontal control
  if player.onGround then
    if player.charging then
      -- While charging on the ground, player cannot move: quickly damp horizontal velocity to 0
      player.vx = lerp(player.vx, 0, math.min(1, dt / (params.friction_time * 0.5)))
    else
      local targetVx = input_x * params.vx_max_ground
      local ax = params.ax_ground
      if player.vx < targetVx then
        player.vx = math.min(player.vx + ax * dt, targetVx)
      elseif player.vx > targetVx then
        player.vx = math.max(player.vx - ax * dt, targetVx)
      end
    end
  else
    -- In air: no horizontal control (player cannot change horizontal velocity while airborne)
    -- Do nothing; vx remains whatever it was at jump release.
  end

  -- Friction when no input and on ground
  if player.onGround and input_x == 0 then
    -- reduce vx to zero within friction_time
    local t = params.friction_time
    if t > 0 then
      local needed = math.max(-player.vx/t, math.min(-player.vx/t, player.vx/t))
      -- simpler: exponential approach
      player.vx = lerp(player.vx, 0, math.min(1, dt / t))
    end
  end

  -- Charging
  if player.onGround and jumpHeld then
    player.charging = true
    player.t_charge = player.t_charge + dt
    player.t_charge = math.min(player.t_charge, params.t_max + 0.1)
  end

  -- Release detection (space up)
  if player.charging and not jumpHeld then
    -- perform jump
    local t_charge = clamp(player.t_charge, params.t_min, params.t_max)
    local charge_ratio = clamp((t_charge - params.t_min) / (params.t_max - params.t_min), 0, 1)
    local power = easeOutCubic(charge_ratio)
    local v_jump = lerp(params.v_jump_min, params.v_jump_max, power)
    local i_x = input_x
    local v_x = i_x * v_jump * params.h_ratio

    -- Apply: convert to LOVE coords (vy down positive)
    player.vy = -v_jump
    player.vx = v_x
    player.onGround = false
    player.charging = false
    player.t_charge = 0
  end

  -- Gravity
  player.vy = player.vy + g * dt

  -- Apply movement via bump
  local goalX = player.x + player.vx * dt
  local goalY = player.y + player.vy * dt

  local actualX, actualY, cols, len = world:move(player, goalX, goalY, function(item, other)
    return playerFilter(item, other)
  end)

  -- Update position & handle collisions
  player.x = actualX
  player.y = actualY
  player.onGround = false

  for i=1,len do
    local col = cols[i]
    
    -- Head collision - if hitting something above while moving up, immediately stop upward movement
    if col.normal.y > 0.7 and player.vy < 0 then
      -- Hit ceiling/object above while moving up
      player.vy = 0  -- Stop upward movement immediately
    end
    
    -- Wall knockback when hitting walls while jumping
    if col.normal.x ~= 0 and not player.onGround and math.abs(player.vx) > params.wall_knockback_min_speed then
      -- Hit a wall while moving horizontally in air
      local knockbackForce = math.min(params.wall_knockback_max, math.abs(player.vx) * params.wall_knockback_force)
      
      -- Instead of just applying knockback, reverse and reduce the velocity for a proper bounce
      player.vx = -player.vx * 0.6  -- Bounce back at 60% of original speed
      
      -- Optional: Add a small upward velocity component to make it feel more dynamic
      if player.vy > 0 then  -- Only if falling
        player.vy = player.vy * 0.9  -- Slightly reduce downward velocity
      end
    end
    
    -- If collision normal has a negative y (contact from above in LOVE coords), consider grounded
    if col.normal.y < -0.7 then
      player.onGround = true
      
      -- Reduce slide when landing (simulates impact absorption)
      if math.abs(player.vy) > params.landing_slide_min_fall then -- Only if falling with significant speed
        local slideReduction = math.min(params.landing_slide_max_reduction, math.abs(player.vy) / params.landing_slide_scale) -- More reduction for higher falls
        player.vx = player.vx * (1 - slideReduction)
      end
      
      player.vy = 0
    end

    -- Checkpoint trigger
    if col.other and col.other.w == 24 and col.other.h == 8 then
      -- simple heuristic: collision with checkpoint area
      for idx,cp in ipairs(checkpoints) do
        if cp == col.other then
          if currentCheckpoint ~= idx then
            currentCheckpoint = idx
            player.lastCheckpoint = {x = cp.x, y = cp.y}
            saveProgress(currentCheckpoint, {x = player.x, y = player.y})
          end
        end
      end
    end
  end

  -- Death (fall below world)
        if params.enable_auto_reset and player.y > params.auto_reset_y then
        respawnToCheckpoint(currentCheckpoint)
        end

  -- Camera follow (vertical smoothing + lookahead when full charge)
  local screenW, screenH = love.graphics.getDimensions()
  local targetCamX = params.fixed_width / 2  -- Fixed X position (center of screen)
  local targetCamY = player.y - params.cam_anchor_below

  -- Calculate game height for camera bounds
  local gameWidth, gameHeight = calculateScale()

  -- Set camera Y bounds (prevent showing below map bottom)
  local mapBottom = 2560  -- Adjust this to match your map's bottom Y coordinate
  local cameraBottomLimit = mapBottom - gameHeight / 2

  -- Clamp camera Y to not go below the map bottom
  targetCamY = math.min(targetCamY, cameraBottomLimit)

  local smooth = params.cam_smooth
  -- Keep X fixed, only smooth Y movement
  cam.x = targetCamX  -- No lerping for X, just set it directly
  
  -- Camera movement logic: follow when on ground OR when falling more than 5 pixels below camera
  local playerDistanceBelowCamera = (player.y - params.cam_anchor_below) - cam.y
  local shouldFollowCamera = player.onGround or playerDistanceBelowCamera > 5
  
  if shouldFollowCamera then
    cam.y = lerp(cam.y, targetCamY, math.min(1, dt / smooth))
  end
  -- When in air and not falling too far, camera stays where it was when player left the ground

  -- update world AABB for player
  world:update(player, player.x, player.y, player.w, player.h)
end

-- Drawing util: convert world (love coords) -> screen
local function worldToScreenX(x) return x end
local function worldToScreenY(y)
  -- Our world uses top-left (love coords), so it's the same
  return y
end

params.show_debug_objects = false

function love.draw()
  love.graphics.setFont(font)
  local gameWidth, gameHeight = calculateScale()
  
  -- Apply scaling transformation
  love.graphics.push()
  love.graphics.scale(scaleX, scaleY)
  love.graphics.translate(offsetX, offsetY)
  
  -- Camera translation (now in scaled coordinates)
  love.graphics.translate(params.fixed_width/2 - cam.x, gameHeight/2 - cam.y)

  -- 1) draw tilemap (STI) if available
  if tilemap and tilemap.draw then
    tilemap:draw()
  end

  -- 2) draw platforms (only those NOT from Tiled OR if debug enabled)
  for _,p in ipairs(platforms) do
    if params.show_debug_objects or not p.fromTiled then
      if p.oneWay then love.graphics.setColor(0.6, 0.6, 0.8, 1)
      else love.graphics.setColor(0.4, 0.4, 0.4, 1) end
      love.graphics.rectangle('fill', p.x, p.y, p.w, p.h)
    end
  end

  -- 3) draw player
  love.graphics.setColor(1, 0.9, 0.2, 1)
  love.graphics.rectangle('fill', player.x, player.y, player.w, player.h)

  -- landing indicator
  if player.onGround then
    love.graphics.setColor(0,0,0)
    love.graphics.print('OnGround', player.x - 10, player.y - 18)
  end

  love.graphics.pop()

  -- UI elements (drawn at native resolution, not scaled)
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
  love.graphics.print('Charge', 20, 42)

  love.graphics.setColor(1,1,1)
  love.graphics.print('Controls: ←/A, →/D, Space (hold -> release to jump), R=restart', 20, 70)
  love.graphics.print('Checkpoint: ' .. tostring(currentCheckpoint), 20, 90)
end

-- Key handlers
function love.keypressed(key)
  if key == 'r' then
    resetToSpawn()  -- Reset to spawn instead of checkpoint
    saveProgress(currentCheckpoint, {x = player.x, y = player.y})
  end

  -- quick debug: press 'n' to go to next checkpoint (designer helper)
  if key == 'n' then
    currentCheckpoint = math.min(#checkpoints, currentCheckpoint + 1)
    respawnToCheckpoint(currentCheckpoint)
    saveProgress(currentCheckpoint, {x = player.x, y = player.y})
  end
end

-- Add this function to save on game quit
function love.quit()
  saveProgress(currentCheckpoint, {x = player.x, y = player.y})
end

-- Expose some tuning values for quick test via console (optional)
_G.params = params
_G.player = player
_G.world = world
_G.platforms = platforms
_G.checkpoints = checkpoints

-- End of file
