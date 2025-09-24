-- Physics handling for the jump king game
local physics = {}

-- Physics parameters (will be set from main)
local params = nil

-- Helper functions
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a,b,t) return a + (b-a)*t end

-- easeOutCubic
local function easeOutCubic(x)
  local t = 1 - (1 - x) ^ 3
  return t
end

-- Initialize physics module with parameters
function physics.init(gameParams)
  params = gameParams
  physics.g = -params.g_spec -- gravity in love coords (positive down)
end

-- Collision filter for player movement (handles one-way platforms)
function physics.playerFilter(item, other, player)
  if other.oneWay then
    -- For one-way platforms, only collide if player is above the platform AND moving downward
    local playerBottom = item.y + item.h
    local platformTop = other.y
    
    -- Only collide if:
    -- 1. Player's bottom edge is above or at the platform's top edge
    -- 2. Player is moving downward (vy >= 0) or standing still
    if playerBottom <= platformTop + 2 and player.vy >= 0 then
      return 'slide'
    else
      return nil  -- No collision - let player pass through
    end
  end
  return 'slide'
end

-- Handle horizontal movement
function physics.updateHorizontalMovement(player, dt, input_x)
  if player.onGround then
    -- Check if player is on ice
    local onIce = false
    if player.currentPlatform and player.currentPlatform.ice then
      onIce = true
    end
    
    if player.charging then
      -- While charging on the ground, player cannot move: quickly damp horizontal velocity to 0
      local frictionTime = params.friction_time * 0.5
      if onIce then
        frictionTime = frictionTime / params.ice_friction_mult  -- Divide to make it take longer on ice
      end
      player.vx = lerp(player.vx, 0, math.min(1, dt / frictionTime))
    else
      local targetVx = input_x * params.vx_max_ground
      local ax = params.ax_ground
      
      -- Reduce acceleration on ice
      if onIce then
        ax = ax * params.ice_acceleration_mult
      end
      
      if player.vx < targetVx then
        player.vx = math.min(player.vx + ax * dt, targetVx)
      elseif player.vx > targetVx then
        player.vx = math.max(player.vx - ax * dt, targetVx)
      end
    end
  else
    -- In air: no horizontal control
  end
end

-- Handle ground friction
function physics.updateGroundFriction(player, dt, input_x)
  if player.onGround then
    -- Check if on ice for reduced friction
    local onIce = false
    if player.currentPlatform and player.currentPlatform.ice then
      onIce = true
    end
    
    if onIce then
      -- On ice: always apply reduced friction regardless of input
      local iceFrictionTime = params.friction_time / params.ice_friction_mult
      player.vx = lerp(player.vx, player.vx * 0.98, math.min(1, dt / iceFrictionTime))
    elseif input_x == 0 then
      -- Normal ground with no input: apply normal friction
      local t = params.friction_time
      if t > 0 then
        player.vx = lerp(player.vx, 0, math.min(1, dt / t))
      end
    end
  end
end

-- Handle jump charging
function physics.updateCharging(player, dt, jumpHeld)
  if player.onGround and jumpHeld then
    player.charging = true
    player.t_charge = player.t_charge + dt
    player.t_charge = math.min(player.t_charge, params.t_max + 0.1)
  end
end

-- Handle jump execution
function physics.executeJump(player, jumpHeld, input_x)
  if player.charging and not jumpHeld then
    -- perform jump
    local t_charge = clamp(player.t_charge, params.t_min, params.t_max)
    local charge_ratio = clamp((t_charge - params.t_min) / (params.t_max - params.t_min), 0, 1)
    local power = easeOutCubic(charge_ratio)
    local v_jump = lerp(params.v_jump_min, params.v_jump_max, power)
    local i_x = input_x
    local v_x = i_x * v_jump * params.h_ratio

    -- Check if jumping from ice to preserve sliding momentum
    local onIce = false
    if player.currentPlatform and player.currentPlatform.ice then
      onIce = true
    end

    -- Apply: convert to LOVE coords (vy down positive)
    player.vy = -v_jump
    
    if onIce then
      -- On ice: add jump velocity to existing sliding velocity instead of replacing it
      player.vx = player.vx + v_x
    else
      -- Normal ground: replace velocity
      player.vx = v_x
    end
    
    player.onGround = false
    player.charging = false
    player.t_charge = 0
  end
end

-- Apply gravity
function physics.applyGravity(player, dt)
  player.vy = player.vy + physics.g * dt
end

-- Handle collision responses
function physics.handleCollisions(player, cols, len, checkpoints, currentCheckpoint, saveProgress)
  player.onGround = false
  player.currentPlatform = nil  -- Reset current platform

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
      player.currentPlatform = col.other  -- Track which platform player is standing on
      
      -- Reduce slide when landing (simulates impact absorption) - but not on ice
      if not col.other.ice and math.abs(player.vy) > params.landing_slide_min_fall then
        local slideReduction = math.min(params.landing_slide_max_reduction, math.abs(player.vy) / params.landing_slide_scale)
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
  
  return currentCheckpoint
end

-- Main physics update function
function physics.update(player, world, dt, jumpHeld, input_x, checkpoints, currentCheckpoint, saveProgress)
  -- Update horizontal movement
  physics.updateHorizontalMovement(player, dt, input_x)
  
  -- Update ground friction
  physics.updateGroundFriction(player, dt, input_x)
  
  -- Handle charging
  physics.updateCharging(player, dt, jumpHeld)
  
  -- Handle jump execution
  physics.executeJump(player, jumpHeld, input_x)
  
  -- Apply gravity
  physics.applyGravity(player, dt)
  
  -- Apply movement via bump
  local goalX = player.x + player.vx * dt
  local goalY = player.y + player.vy * dt

  local actualX, actualY, cols, len = world:move(player, goalX, goalY, function(item, other)
    return physics.playerFilter(item, other, player)
  end)

  -- Update position
  player.x = actualX
  player.y = actualY
  
  -- Handle collisions
  currentCheckpoint = physics.handleCollisions(player, cols, len, checkpoints, currentCheckpoint, saveProgress)
  
  return currentCheckpoint
end

return physics