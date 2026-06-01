import "CoreLibs/graphics"
import "CoreLibs/ui"
import "CoreLibs/crank"

local gfx = playdate.graphics
local ui = playdate.ui
local geom = playdate.geometry
local datastore = playdate.datastore
local snd = playdate.sound

playdate.display.setRefreshRate(30)
math.randomseed(playdate.getSecondsSinceEpoch())

-- =========================================================
-- Constants / tuning
-- =========================================================

local SCREEN_W = 400
local SCREEN_H = 240

local STATE_TITLE = "title"
local STATE_PLAY = "play"
local STATE_GAMEOVER = "gameover"

-- Cat paw reach. The crank extends the paw; it always sags back, so the
-- player has to keep working the crank to stay extended.
local ARM_BASE_X = 34
local ARM_MIN_LENGTH = 24
local ARM_MAX_LENGTH = 340
local ARM_RETRACT_PER_FRAME = 1.1
local ARM_CRANK_MULTIPLIER = 3.2
local ARM_MOVE_SPEED = 4
local PAW_RADIUS = 11
local ARM_MIN_Y = 92
local ARM_MAX_Y = 168

-- Fish drawing size (half-extents of the body ellipse).
local FISH_A = 16 -- half length (nose to tail base)
local FISH_B = 8  -- half girth
local FISH_HIT_RADIUS = 13

-- The plate the fish flops around on (allowed range for the fish CENTER).
local PLATE_MIN_X = 276
local PLATE_MAX_X = 356
local PLATE_MIN_Y = 116
local PLATE_MAX_Y = 150

-- Win / lose state
local MAX_MISSES = 3
local TOUCH_BANNER_FRAMES = 22
local MISS_FLASH_FRAMES = 18
local FISH_TOUCHED_FRAMES = 10

-- Crank motion needed to count as an intentional "boop".
local TOUCH_CRANK_THRESHOLD = 0.6
local TOUCH_ENERGY_THRESHOLD = 4.0

local SAVE_KEY = "touch_da_fishy"

-- =========================================================
-- Mutable game state
-- =========================================================

local gameState = STATE_TITLE

local score = 0
local highScore = 0
local misses = 0

local touchBannerFrames = 0
local missFlashFrames = 0
local crankHintFrames = 0
local titlePulseFrames = 0

local arm = {
    y = 124,
    length = ARM_MIN_LENGTH,
    lastCrankChange = 0,
    crankEnergy = 0,
}

-- Fish on the plate. It cycles through flop "modes": it settles and idle-flops,
-- crouches as a tell ("wind"), hops in an arc to a new spot, and after a few
-- hops it does a big escape leap off the plate.
local fish = {
    mode = "settle",
    modeTimer = 0,
    modeDuration = 70,

    x = 316, y = 132,         -- logical resting center
    drawX = 316, drawY = 132, -- where it is actually drawn this frame (used for hit test)

    fromX = 316, fromY = 132,
    toX = 316, toY = 132,
    hopHeight = 22,
    spinDir = 1,

    flopsRemaining = 4,
    flopPhase = 0,
    angle = 0,
    tailFlap = 0,
    squashX = 1,
    squashY = 1,
    landSquash = 0,
    touchedFrames = 0,
    agitated = false,
}

-- Optional pre-rendered title art (used on title / game-over screens).
local titleBackground = gfx.image.new("title_background")

-- Asset-free sound effects via the synth. Guarded so the game still runs if
-- the sound API is ever unavailable.
local sfx = {}
local function initSound()
    if snd == nil then return end
    sfx.boop = snd.synth.new(snd.kWaveSquare)
    sfx.hop = snd.synth.new(snd.kWaveSine)
    sfx.escape = snd.synth.new(snd.kWaveSawtooth)
    sfx.over = snd.synth.new(snd.kWaveSawtooth)
end

local function play(s, note, vol, len)
    if s ~= nil then
        s:playNote(note, vol or 0.4, len or 0.08)
    end
end

-- =========================================================
-- Helpers
-- =========================================================

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    elseif value > maxValue then
        return maxValue
    end
    return value
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- 0 (easy) .. 1 (hard). Climbs over the first ~18 points.
local function difficulty()
    return clamp(score / 18, 0, 1)
end

local function getPawPosition()
    return ARM_BASE_X + arm.length, arm.y
end

-- Rotate a local-space point around the origin.
local function rotLocal(x, y, sinA, cosA)
    return x * cosA - y * sinA, x * sinA + y * cosA
end

local function drawPanel(x, y, w, h, radius)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(x, y, w, h, radius)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawRoundRect(x + 3, y + 3, w - 6, h - 6, math.max(2, radius - 2))
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawSpeechBubble(x, y, w, h)
    gfx.fillRoundRect(x, y, w, h, 8)
    gfx.fillTriangle(x + 30, y + h - 2, x + 52, y + h - 2, x + 42, y + h + 12)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawRoundRect(x + 3, y + 3, w - 6, h - 6, 6)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawHalftoneDots(x, y, count)
    for i = 0, count - 1 do
        local r = 3 + (i % 2)
        gfx.drawCircleAtPoint(x, y + (i * 26), r)
    end
end

-- =========================================================
-- Persistence
-- =========================================================

local function loadHighScore()
    local data = datastore.read(SAVE_KEY)
    if data ~= nil and data.highScore ~= nil then
        highScore = data.highScore
    end
end

local function saveHighScore()
    datastore.write({ highScore = highScore }, SAVE_KEY)
end

local function updateHighScoreIfNeeded()
    if score > highScore then
        highScore = score
        saveHighScore()
    end
end

-- =========================================================
-- Setup / reset
-- =========================================================

local function showCrankHint(frames)
    crankHintFrames = frames
    ui.crankIndicator:resetAnimation()
    ui.crankIndicator.clockwise = true
end

-- Pick a new flop target on the plate that is meaningfully different from
-- where the fish is now, so the player is forced to re-aim.
local function pickPlateTarget()
    local d = difficulty()
    for _ = 1, 8 do
        local tx = math.random(PLATE_MIN_X, PLATE_MAX_X)
        local ty = math.random(PLATE_MIN_Y, PLATE_MAX_Y)
        local moved = math.abs(tx - fish.x) + math.abs(ty - fish.y)
        if moved > lerp(28, 44, d) then
            return tx, ty
        end
    end
    -- Fallback: jump to the opposite side of the plate.
    local tx = (fish.x < (PLATE_MIN_X + PLATE_MAX_X) / 2) and PLATE_MAX_X or PLATE_MIN_X
    return tx, math.random(PLATE_MIN_Y, PLATE_MAX_Y)
end

local function enterSettle()
    local d = difficulty()
    fish.mode = "settle"
    fish.modeTimer = 0
    fish.modeDuration = math.floor(lerp(78, 30, d))
    fish.landSquash = 7
    fish.agitated = false
end

local function spawnFish()
    local d = difficulty()
    fish.x = math.random(PLATE_MIN_X, PLATE_MAX_X)
    fish.y = math.random(PLATE_MIN_Y, PLATE_MAX_Y)
    fish.drawX, fish.drawY = fish.x, fish.y
    fish.flopsRemaining = math.max(2, math.floor(lerp(5, 2, d) + 0.5))
    fish.flopPhase = math.random() * math.pi * 2
    fish.angle = 0
    fish.tailFlap = 0
    fish.squashX, fish.squashY = 1, 1
    fish.touchedFrames = 0
    fish.spinDir = (math.random() < 0.5) and -1 or 1
    enterSettle()
end

local function resetArm()
    arm.y = 124
    arm.length = ARM_MIN_LENGTH
    arm.lastCrankChange = 0
    arm.crankEnergy = 0
end

local function startRun()
    score = 0
    misses = 0
    touchBannerFrames = 0
    missFlashFrames = 0

    resetArm()
    spawnFish()
    showCrankHint(75)

    gameState = STATE_PLAY
end

-- =========================================================
-- Game events
-- =========================================================

local function handleTouchSuccess()
    score = score + 1
    updateHighScoreIfNeeded()

    touchBannerFrames = TOUCH_BANNER_FRAMES
    fish.touchedFrames = FISH_TOUCHED_FRAMES
    play(sfx.boop, "C6", 0.5, 0.07)

    -- Pull the paw back after a boop so the player has to crank out again.
    arm.length = clamp(arm.length - 40, ARM_MIN_LENGTH, ARM_MAX_LENGTH)

    spawnFish()
end

local function handleFishEscape()
    misses = misses + 1
    missFlashFrames = MISS_FLASH_FRAMES
    arm.length = ARM_MIN_LENGTH

    if misses >= MAX_MISSES then
        updateHighScoreIfNeeded()
        play(sfx.over, "A2", 0.5, 0.5)
        gameState = STATE_GAMEOVER
    else
        play(sfx.escape, "G3", 0.45, 0.25)
        spawnFish()
    end
end

-- =========================================================
-- Fish flop state machine
-- =========================================================

local function beginWind()
    fish.mode = "wind"
    fish.modeTimer = 0
    fish.modeDuration = 8
    fish.fromX, fish.fromY = fish.x, fish.y
    if fish.flopsRemaining > 0 then
        fish.toX, fish.toY = pickPlateTarget()
        fish.agitated = false
    else
        -- About to bolt: leap up and off to the right.
        fish.toX = SCREEN_W + 50
        fish.toY = math.random(-30, 50)
        fish.agitated = true
    end
end

local function beginHopOrEscape()
    local d = difficulty()
    fish.modeTimer = 0
    fish.fromX, fish.fromY = fish.x, fish.y
    if fish.flopsRemaining > 0 then
        fish.mode = "hop"
        fish.modeDuration = math.floor(lerp(16, 11, d))
        fish.hopHeight = lerp(18, 30, d) + math.random(0, 6)
        play(sfx.hop, "E4", 0.25, 0.05)
    else
        fish.mode = "escape"
        fish.modeDuration = math.floor(lerp(22, 15, d))
        fish.hopHeight = 70
        play(sfx.escape, "C4", 0.3, 0.12)
    end
end

local function updateFishFlop()
    fish.flopPhase = fish.flopPhase + 0.35
    fish.modeTimer = fish.modeTimer + 1

    if fish.landSquash > 0 then
        fish.landSquash = fish.landSquash - 1
    end

    local cx, cy = fish.x, fish.y
    local mode = fish.mode

    if mode == "settle" then
        -- Idle flopping in place: gentle tilt, flapping tail, little bounces.
        fish.angle = math.sin(fish.flopPhase) * 0.10
        fish.tailFlap = math.sin(fish.flopPhase * 1.6) * 0.5
        cy = fish.y - math.abs(math.sin(fish.flopPhase * 0.9)) * 2
        if fish.modeTimer >= fish.modeDuration then
            beginWind()
        end

    elseif mode == "wind" then
        -- Crouch + twitch: the tell before a hop or an escape.
        local lean = (fish.toX >= fish.x) and 0.18 or -0.18
        fish.angle = lean
        fish.tailFlap = math.sin(fish.flopPhase * 3.2) * 0.8
        if fish.modeTimer >= fish.modeDuration then
            beginHopOrEscape()
        end

    elseif mode == "hop" then
        local t = clamp(fish.modeTimer / fish.modeDuration, 0, 1)
        cx = lerp(fish.fromX, fish.toX, t)
        cy = lerp(fish.fromY, fish.toY, t) - fish.hopHeight * math.sin(math.pi * t)
        local arch = (0.7 + 0.5 * difficulty()) * fish.spinDir
        fish.angle = math.sin(math.pi * t) * arch
        fish.tailFlap = math.sin(fish.flopPhase * 3.0) * 0.9
        if t >= 1 then
            fish.x, fish.y = fish.toX, fish.toY
            cx, cy = fish.x, fish.y
            fish.flopsRemaining = fish.flopsRemaining - 1
            enterSettle()
        end

    elseif mode == "escape" then
        local t = clamp(fish.modeTimer / fish.modeDuration, 0, 1)
        cx = lerp(fish.fromX, fish.toX, t)
        cy = lerp(fish.fromY, fish.toY, t) - fish.hopHeight * math.sin(math.pi * t * 0.8)
        fish.angle = t * math.pi * 1.6 * fish.spinDir
        fish.tailFlap = math.sin(fish.flopPhase * 3.4) * 1.0
        fish.x, fish.y = cx, cy
        if t >= 1 or cx > SCREEN_W + 30 or cy < -40 then
            handleFishEscape()
            return
        end
    end

    -- Squash & stretch from the most recent landing.
    if fish.landSquash > 0 then
        local s = fish.landSquash / 7
        fish.squashY = lerp(1, 0.65, s)
        fish.squashX = lerp(1, 1.25, s)
    elseif mode == "wind" then
        fish.squashY, fish.squashX = 0.8, 1.12
    else
        fish.squashY, fish.squashX = 1, 1
    end

    fish.drawX, fish.drawY = cx, cy
end

-- =========================================================
-- Update logic (paw)
-- =========================================================

local function updateAim()
    if playdate.buttonIsPressed(playdate.kButtonUp) then
        arm.y = arm.y - ARM_MOVE_SPEED
    end
    if playdate.buttonIsPressed(playdate.kButtonDown) then
        arm.y = arm.y + ARM_MOVE_SPEED
    end
    arm.y = clamp(arm.y, ARM_MIN_Y, ARM_MAX_Y)
end

local function updateArmFromCrank()
    local crankChange = 0
    local acceleratedChange = 0

    if playdate.isCrankDocked() then
        showCrankHint(1)
    else
        crankChange, acceleratedChange = playdate.getCrankChange()
        arm.length = arm.length + (crankChange * ARM_CRANK_MULTIPLIER)
    end

    -- The paw sags back every frame so the crank stays the centerpiece.
    arm.length = arm.length - ARM_RETRACT_PER_FRAME
    arm.length = clamp(arm.length, ARM_MIN_LENGTH, ARM_MAX_LENGTH)

    -- Blend in motion history so fast bursts still register as a boop.
    arm.crankEnergy = arm.crankEnergy * 0.82 + math.abs(acceleratedChange) * 0.18
    arm.lastCrankChange = crankChange
end

local function canTouchFish()
    return arm.lastCrankChange > TOUCH_CRANK_THRESHOLD or arm.crankEnergy > TOUCH_ENERGY_THRESHOLD
end

local function checkTouch()
    if not canTouchFish() then
        return
    end
    if fish.touchedFrames > 0 then
        return
    end

    local pawX, pawY = getPawPosition()
    local dx = pawX - fish.drawX
    local dy = pawY - fish.drawY
    local reach = PAW_RADIUS + FISH_HIT_RADIUS
    if (dx * dx + dy * dy) <= (reach * reach) then
        handleTouchSuccess()
    end
end

local function updateFrameCounters()
    if touchBannerFrames > 0 then touchBannerFrames = touchBannerFrames - 1 end
    if missFlashFrames > 0 then missFlashFrames = missFlashFrames - 1 end
    if crankHintFrames > 0 then crankHintFrames = crankHintFrames - 1 end
    if fish.touchedFrames > 0 then fish.touchedFrames = fish.touchedFrames - 1 end
    titlePulseFrames = (titlePulseFrames + 1) % 60
end

local function updatePlayState()
    updateAim()
    updateArmFromCrank()
    updateFishFlop()
    if gameState == STATE_PLAY then
        checkTouch()
    end
    updateFrameCounters()
end

-- =========================================================
-- Drawing
-- =========================================================

local function drawCountertop()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 206, SCREEN_W, 34)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    for x = 10, SCREEN_W, 26 do
        gfx.drawLine(x, 216, x + 10, 232)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawPlate()
    -- Plate seen slightly from above: outer rim, inner dish, a little shine.
    gfx.setColor(gfx.kColorBlack)
    gfx.fillEllipseInRect(252, 150, 136, 46) -- plate base shadow band
    gfx.setColor(gfx.kColorWhite)
    gfx.fillEllipseInRect(248, 96, 144, 80)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawEllipseInRect(248, 96, 144, 80)
    gfx.drawEllipseInRect(266, 108, 108, 56)
    gfx.setLineWidth(1)
    gfx.drawLine(286, 116, 300, 112)
end

local function drawCat()
    -- Simple outlined cat head at the left, matching the title art.
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(18, 120, 20)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawCircleAtPoint(18, 120, 20)
    -- Ears
    gfx.drawLine(4, 104, 8, 86)
    gfx.drawLine(8, 86, 20, 100)
    gfx.drawLine(18, 99, 30, 86)
    gfx.drawLine(30, 86, 34, 104)
    gfx.setLineWidth(1)
    -- Face
    gfx.fillCircleAtPoint(12, 116, 2)
    gfx.fillCircleAtPoint(24, 116, 2)
    gfx.drawLine(14, 124, 18, 127)
    gfx.drawLine(18, 127, 22, 124)
end

local function drawPaw()
    local pawX, pawY = getPawPosition()

    gfx.setColor(gfx.kColorBlack)
    -- Foreleg reaching toward the plate.
    gfx.setLineWidth(11)
    gfx.drawLine(ARM_BASE_X, arm.y, pawX - 6, pawY)
    gfx.setLineWidth(1)

    -- Main paw pad.
    gfx.fillCircleAtPoint(pawX, pawY, PAW_RADIUS)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(pawX - 1, pawY + 3, 4)
    gfx.setColor(gfx.kColorBlack)

    -- Toes / claws.
    gfx.fillCircleAtPoint(pawX - 8, pawY - 8, 4)
    gfx.fillCircleAtPoint(pawX - 1, pawY - 11, 4)
    gfx.fillCircleAtPoint(pawX + 7, pawY - 8, 4)
    gfx.drawLine(pawX - 7, pawY - 14, pawX - 10, pawY - 18)
    gfx.drawLine(pawX, pawY - 16, pawX - 1, pawY - 20)
    gfx.drawLine(pawX + 7, pawY - 14, pawX + 10, pawY - 18)
end

-- Draws the flopping fish centered at (cx, cy), rotated by `angle`, with the
-- body squashed by (sqX, sqY) and the tail flapped by `tailFlap` radians.
local function drawFish(cx, cy, angle, sqX, sqY, tailFlap, isTouched)
    local sinA = math.sin(angle)
    local cosA = math.cos(angle)
    local a = FISH_A * sqX
    local b = FISH_B * sqY

    -- Body as a rotated ellipse polygon.
    local N = 14
    local coords = {}
    for i = 0, N - 1 do
        local th = (i / N) * 2 * math.pi
        local lx = math.cos(th) * a
        local ly = math.sin(th) * b
        local rx, ry = rotLocal(lx, ly, sinA, cosA)
        coords[#coords + 1] = cx + rx
        coords[#coords + 1] = cy + ry
    end
    local body = geom.polygon.new(table.unpack(coords))
    body:close()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillPolygon(body)

    -- Tail: triangle behind the body, whipped by tailFlap around its base.
    local baseLx, baseLy = -a * 0.55, 0
    local function tailPoint(lx, ly)
        -- flap around the tail base, then rotate with the body.
        local rdx = lx - baseLx
        local rdy = ly - baseLy
        local fs, fc = math.sin(tailFlap), math.cos(tailFlap)
        local fx = baseLx + rdx * fc - rdy * fs
        local fy = baseLy + rdx * fs + rdy * fc
        local gx, gy = rotLocal(fx, fy, sinA, cosA)
        return cx + gx, cy + gy
    end
    local b1x, b1y = rotLocal(baseLx, baseLy, sinA, cosA)
    local t1x, t1y = tailPoint(-a * 1.5, -b * 1.1)
    local t2x, t2y = tailPoint(-a * 1.5, b * 1.1)
    gfx.fillTriangle(cx + b1x, cy + b1y, t1x, t1y, t2x, t2y)

    -- Dorsal fin on top.
    local function loc(lx, ly)
        local rx, ry = rotLocal(lx, ly, sinA, cosA)
        return cx + rx, cy + ry
    end
    local f1x, f1y = loc(-a * 0.15, -b * 0.8)
    local f2x, f2y = loc(a * 0.2, -b * 0.8)
    local f3x, f3y = loc(0, -b * 1.9)
    gfx.fillTriangle(f1x, f1y, f2x, f2y, f3x, f3y)

    -- Eye near the head end.
    local ex, ey = loc(a * 0.55, -b * 0.3)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(ex, ey, 2)
    gfx.setColor(gfx.kColorBlack)
    if not isTouched then
        gfx.fillCircleAtPoint(ex, ey, 1)
    end

    -- "X" eye and dizzy stars when freshly booped.
    if isTouched then
        gfx.setLineWidth(1)
        gfx.drawLine(ex - 2, ey - 2, ex + 2, ey + 2)
        gfx.drawLine(ex - 2, ey + 2, ex + 2, ey - 2)
        gfx.drawCircleAtPoint(cx, cy - FISH_B - 10, 2)
        gfx.drawCircleAtPoint(cx + 9, cy - FISH_B - 6, 1)
        gfx.drawCircleAtPoint(cx - 9, cy - FISH_B - 6, 1)
    end
end

-- Little agitation ticks shown when the fish is about to bolt.
local function drawAgitation(cx, cy)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(cx - 18, cy - 16, cx - 22, cy - 22)
    gfx.drawLine(cx + 18, cy - 16, cx + 22, cy - 22)
    gfx.drawLine(cx, cy - FISH_B - 12, cx, cy - FISH_B - 18)
end

local function drawHUD()
    -- Slim single top bar.
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(8, 6, SCREEN_W - 16, 22, 6)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("SCORE " .. tostring(score), 18, 11)
    gfx.drawTextAligned("BEST " .. tostring(highScore), 200, 11, kTextAlignment.center)
    gfx.drawTextAligned("MISSES " .. tostring(misses) .. "/" .. tostring(MAX_MISSES), SCREEN_W - 18, 11, kTextAlignment.right)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    -- Slim single bottom hint.
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("CRANK = REACH", 14, 214)
    gfx.drawTextAligned("UP/DOWN = AIM", SCREEN_W - 16, 214, kTextAlignment.right)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawTouchBanner()
    if touchBannerFrames <= 0 then return end
    gfx.setColor(gfx.kColorBlack)
    drawSpeechBubble(119, 40, 162, 30)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TOUCHED DA FISHY!", 200, 48, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawPlayfield()
    local invertScreen = missFlashFrames > 0

    gfx.clear(gfx.kColorWhite)

    if invertScreen then
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    end

    drawCountertop()
    drawPlate()
    drawCat()
    drawPaw()

    if fish.agitated then
        drawAgitation(fish.drawX, fish.drawY)
    end
    drawFish(fish.drawX, fish.drawY, fish.angle, fish.squashX, fish.squashY, fish.tailFlap, fish.touchedFrames > 0)

    drawHUD()
    drawTouchBanner()

    if crankHintFrames > 0 or playdate.isCrankDocked() then
        ui.crankIndicator:draw(346, 36)
    end

    if invertScreen then
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
end

local function drawTitleScreen()
    if titleBackground ~= nil then
        titleBackground:draw(0, 0)
    else
        gfx.clear(gfx.kColorWhite)
        drawPanel(52, 58, 296, 100, 12)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        gfx.drawTextAligned("TOUCH DA FISHY", 200, 86, kTextAlignment.center)
        gfx.drawTextAligned("PRESS A TO START", 200, 126, kTextAlignment.center)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
    ui.crankIndicator:draw(344, 78)
end

local function drawGameOverScreen()
    gfx.clear(gfx.kColorWhite)
    drawPanel(52, 34, 296, 160, 12)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("FISHY GOT AWAY", 200, 56, kTextAlignment.center)
    gfx.drawTextAligned("FINAL SCORE " .. tostring(score), 200, 102, kTextAlignment.center)
    gfx.drawTextAligned("BEST SCORE " .. tostring(highScore), 200, 122, kTextAlignment.center)
    gfx.drawTextAligned("PRESS A TO PLAY AGAIN", 200, 156, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    drawHalftoneDots(80, 80, 3)
end

-- =========================================================
-- Playdate callbacks
-- =========================================================

function playdate.update()
    gfx.clear(gfx.kColorWhite)

    if gameState == STATE_TITLE then
        if playdate.buttonJustPressed(playdate.kButtonA) then
            startRun()
        end
        updateFrameCounters()
        drawTitleScreen()

    elseif gameState == STATE_PLAY then
        updatePlayState()
        drawPlayfield()

    elseif gameState == STATE_GAMEOVER then
        if playdate.buttonJustPressed(playdate.kButtonA) then
            startRun()
        end
        updateFrameCounters()
        drawGameOverScreen()
    end

end

function playdate.crankDocked()
    if gameState == STATE_PLAY then
        showCrankHint(90)
    else
        showCrankHint(45)
    end
end

function playdate.crankUndocked()
    showCrankHint(45)
end

initSound()
loadHighScore()
