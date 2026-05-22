import "CoreLibs/graphics"
import "CoreLibs/ui"
import "CoreLibs/crank"
import "CoreLibs/timer"

local gfx = playdate.graphics
local ui = playdate.ui
local timer = playdate.timer
local datastore = playdate.datastore

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

-- Paw / reach behavior. The crank is the star: it extends the paw.
local ARM_BASE_X = 30
local ARM_MIN_LENGTH = 26
local ARM_MAX_LENGTH = 275
local ARM_RETRACT_PER_FRAME = 0.55
local ARM_CRANK_MULTIPLIER = 1.8
local ARM_MOVE_SPEED = 4
local PAW_RADIUS = 13

-- Fish behavior
local FISH_W = 62
local FISH_H = 32
local FISH_BASE_SPEED = 1.5
local FISH_SCORE_SPEED_BONUS = 0.12
local FISH_MISS_SPEED_BONUS = 0.08

-- Win / lose state
local MAX_MISSES = 3
local TOUCH_BANNER_FRAMES = 22
local MISS_FLASH_FRAMES = 20
local FISH_TOUCHED_FRAMES = 12

-- Crank motion needed to count as an intentional "touch"
local TOUCH_CRANK_THRESHOLD = 0.6
local TOUCH_ENERGY_THRESHOLD = 4.2

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
    y = 122,
    length = ARM_MIN_LENGTH,
    lastCrankChange = 0,
    crankEnergy = 0,
}

local fish = {
    x = 230,
    y = 150,
    targetX = 230,
    targetY = 150,
    speed = FISH_BASE_SPEED,
    bobPhase = 0,
    bobAmplitude = 3,
    flopTimer = 0,
    touchedFrames = 0,
    
}

-- Pre-rendered title art based on the source meme, converted to 1-bit.
local titleBackground = gfx.image.new("title_background")

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

local function getFishDrawY()
    local idleWiggle = math.sin(fish.bobPhase) * 1.5

    if fish.flopFrames > 0 then
        local flopProgress = fish.flopFrames / 14
        local bounce = math.sin(flopProgress * math.pi) * 10
        return fish.y - bounce + idleWiggle
    end

    return fish.y + idleWiggle
end

local function getPawPosition()
    return ARM_BASE_X + arm.length, arm.y
end

-- Circle-vs-rectangle overlap is enough for the paw and fish hitbox.
local function circleRectOverlap(cx, cy, radius, rx, ry, rw, rh)
    local closestX = clamp(cx, rx, rx + rw)
    local closestY = clamp(cy, ry, ry + rh)
    local dx = cx - closestX
    local dy = cy - closestY
    return (dx * dx + dy * dy) <= (radius * radius)
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

local function spawnFish()
    fish.x = math.random(170, 255)
    fish.y = math.random(108, 184)
    fish.targetX = fish.x
    fish.targetY = fish.y
    fish.speed = FISH_BASE_SPEED
    fish.bobPhase = math.random() * math.pi * 2
    fish.bobAmplitude = math.random(2, 4)
    fish.flopTimer = math.random(45, 90)
    fish.flopFrames = 0
    fish.touchedFrames = 0
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

    -- Pull the paw back slightly after a successful boop so the
    -- player has to crank again for the next fish.
    arm.length = clamp(arm.length - 10, ARM_MIN_LENGTH, ARM_MAX_LENGTH)

    spawnFish()
end

local function handleFishEscape()
    misses = misses + 1
    missFlashFrames = MISS_FLASH_FRAMES
    arm.length = ARM_MIN_LENGTH

    if misses >= MAX_MISSES then
        updateHighScoreIfNeeded()
        gameState = STATE_GAMEOVER
    else
        spawnFish()
    end
end

-- =========================================================
-- Update logic
-- =========================================================

local function updateAim()
    if playdate.buttonIsPressed(playdate.kButtonUp) then
        arm.y = arm.y - ARM_MOVE_SPEED
    end
    if playdate.buttonIsPressed(playdate.kButtonDown) then
        arm.y = arm.y + ARM_MOVE_SPEED
    end

    -- Keep the paw inside the bowl area so the playfield mirrors the title art.
    arm.y = clamp(arm.y, 96, 180)
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

    -- The paw slowly retracts every frame so the crank remains the
    -- centerpiece of the interaction.
    arm.length = arm.length - ARM_RETRACT_PER_FRAME
    arm.length = clamp(arm.length, ARM_MIN_LENGTH, ARM_MAX_LENGTH)

    -- Blend in a little motion history so fast crank bursts still count
    -- even if a single frame's delta is small.
    arm.crankEnergy = arm.crankEnergy * 0.82 + math.abs(acceleratedChange) * 0.18
    arm.lastCrankChange = crankChange
end

local function updateFish()
    fish.bobPhase = fish.bobPhase + 0.16

    if fish.flopFrames > 0 then
        fish.flopFrames = fish.flopFrames - 1

        fish.x = fish.x + (fish.targetX - fish.x) * 0.34
        fish.y = fish.y + (fish.targetY - fish.y) * 0.34
    else
        fish.flopTimer = fish.flopTimer - 1

        if fish.flopTimer <= 0 then
            fish.targetX = math.random(155, 285)
            fish.targetY = math.random(104, 184)
            fish.flopFrames = math.random(6, 10)
            fish.flopTimer = math.random(22, 48)
        end
    end
end

local function canTouchFish()
    return arm.lastCrankChange > TOUCH_CRANK_THRESHOLD or arm.crankEnergy > TOUCH_ENERGY_THRESHOLD
end

local function checkTouch()
    if not canTouchFish() then
        return
    end

    local pawX, pawY = getPawPosition()
    local fishY = getFishDrawY()

    local fishRectX = fish.x
    local fishRectY = fishY - (FISH_H / 2)

    if circleRectOverlap(pawX, pawY, PAW_RADIUS, fishRectX, fishRectY, FISH_W, FISH_H) then
        handleTouchSuccess()
    end
end

local function updateFrameCounters()
    if touchBannerFrames > 0 then
        touchBannerFrames = touchBannerFrames - 1
    end
    if missFlashFrames > 0 then
        missFlashFrames = missFlashFrames - 1
    end
    if crankHintFrames > 0 then
        crankHintFrames = crankHintFrames - 1
    end
    if fish.touchedFrames > 0 then
        fish.touchedFrames = fish.touchedFrames - 1
    end
    titlePulseFrames = (titlePulseFrames + 1) % 60
end

local function updatePlayState()
    updateAim()
    updateArmFromCrank()
    updateFish()
    checkTouch()
    updateFrameCounters()
end

-- =========================================================
-- Drawing
-- =========================================================

local function drawCountertop()
    gfx.fillRect(0, 200, SCREEN_W, 40)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    for x = 10, SCREEN_W, 26 do
        gfx.drawLine(x, 212, x + 10, 230)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawSidePlate()
    -- Removed for v0.2 fish readability pass.
    -- The upper-right plate competed visually with the fish target.
end

local function drawBowl()
    -- Large readable bowl outline instead of one solid black blob.
    -- This keeps the gameplay area grounded without competing with the fish.
    local bowlX = 40
    local bowlY = 112
    local bowlW = 280
    local bowlH = 112

    gfx.setColor(gfx.kColorBlack)

    -- Outer rim
    gfx.setLineWidth(3)
    gfx.drawEllipseInRect(bowlX, bowlY, bowlW, bowlH)

    -- Inner water/broth boundary
    gfx.setLineWidth(2)
    gfx.drawEllipseInRect(bowlX + 14, bowlY + 14, bowlW - 28, bowlH - 34)

    gfx.setLineWidth(1)

    -- A few simple dark broth marks, not a giant filled blob.
    for x = 96, 246, 38 do
        gfx.drawLine(x, 166, x + 16, 154)
        gfx.drawLine(x + 5, 176, x + 20, 162)
    end
end

local function drawFish(fishX, fishY, isTouched)
    local bodyX = fishX + 14
    local bodyY = fishY - FISH_H / 2
    local bodyW = FISH_W - 20
    local bodyH = FISH_H
    local tailX = fishX
    local tailMidY = fishY

    gfx.setColor(gfx.kColorBlack)

    -- Big readable tail.
    gfx.fillTriangle(
        tailX + 18, tailMidY,
        tailX, tailMidY - 14,
        tailX, tailMidY + 14
    )

    -- Bold body silhouette.
    gfx.fillEllipseInRect(bodyX, bodyY, bodyW, bodyH)

    -- White eye patch for contrast.
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(bodyX + bodyW - 10, fishY - 6, 7)

    -- Black pupil.
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(bodyX + bodyW - 9, fishY - 6, 3)

    -- Mouth / startled expression.
    gfx.drawLine(bodyX + bodyW - 3, fishY + 5, bodyX + bodyW + 5, fishY + 2)

    -- White highlight cut into the body so it does not read as a plain blob.
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(bodyX + 10, fishY - 7, bodyX + 26, fishY - 11)
    gfx.drawLine(bodyX + 9, fishY + 7, bodyX + 28, fishY + 12)

    -- Black fin accents.
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(bodyX + 16, fishY - 2, bodyX + 28, fishY - 11)
    gfx.drawLine(bodyX + 16, fishY + 2, bodyX + 28, fishY + 11)

    if isTouched then
        -- Shock marks when booped.
        gfx.drawLine(bodyX + bodyW + 6, fishY - 14, bodyX + bodyW + 15, fishY - 22)
        gfx.drawLine(bodyX + bodyW + 8, fishY, bodyX + bodyW + 20, fishY)
        gfx.drawLine(bodyX + bodyW + 6, fishY + 14, bodyX + bodyW + 15, fishY + 22)
    end

    gfx.setColor(gfx.kColorBlack)
end

local function drawPaw()
    local pawX, pawY = getPawPosition()

    -- Arm / foreleg reaching toward the fish.
    gfx.setLineWidth(10)
    gfx.drawLine(ARM_BASE_X, arm.y, pawX - 6, pawY)
    gfx.setLineWidth(2)
    gfx.drawLine(ARM_BASE_X - 2, arm.y - 7, pawX - 9, pawY - 7)
    gfx.drawLine(ARM_BASE_X - 2, arm.y + 7, pawX - 9, pawY + 7)
    gfx.setLineWidth(1)

    -- Main paw pad
    gfx.fillCircleAtPoint(pawX, pawY, PAW_RADIUS)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.fillCircleAtPoint(pawX - 1, pawY + 3, 4)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    -- Toes / claws
    gfx.fillCircleAtPoint(pawX - 8, pawY - 8, 4)
    gfx.fillCircleAtPoint(pawX - 1, pawY - 11, 4)
    gfx.fillCircleAtPoint(pawX + 7, pawY - 8, 4)
    gfx.drawLine(pawX - 7, pawY - 14, pawX - 10, pawY - 18)
    gfx.drawLine(pawX, pawY - 16, pawX - 1, pawY - 20)
    gfx.drawLine(pawX + 7, pawY - 14, pawX + 10, pawY - 18)
end

local function drawHUD()
    drawPanel(10, 8, 108, 28, 8)
    drawPanel(126, 8, 100, 28, 8)
    drawPanel(234, 8, 124, 28, 8)

    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("SCORE " .. tostring(score), 22, 15)
    gfx.drawText("BEST " .. tostring(highScore), 138, 15)
    gfx.drawText("MISSES " .. tostring(misses) .. "/" .. tostring(MAX_MISSES), 246, 15)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    drawPanel(12, 206, 198, 24, 8)
    drawPanel(218, 206, 170, 24, 8)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("CRANK = REACH / BOOP", 24, 212)
    gfx.drawText("UP/DOWN = AIM", 234, 212)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawTouchBanner()
    if touchBannerFrames <= 0 then
        return
    end

    drawSpeechBubble(120, 48, 162, 32)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TOUCHED DA FISHY!", 201, 57, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawPlayLogo()
    drawPanel(16, 42, 166, 52, 10)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TOUCH DA", 99, 54, kTextAlignment.center)
    gfx.drawTextAligned("FISHY", 99, 70, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    drawHalftoneDots(24, 66, 3)
end

local function drawPlayfield()
    local invertScreen = missFlashFrames > 0

    if titleBackground ~= nil then
        titleBackground:draw(0, 0)
        -- White wash over the title art so gameplay elements remain legible
        -- while still feeling like the same scene.
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
        gfx.setColor(gfx.kColorBlack)
    else
        gfx.clear(gfx.kColorWhite)
    end

    if invertScreen then
        gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    end

    drawCountertop()
    drawSidePlate()
    drawBowl()
    --drawPlayLogo()
    drawPaw()
    drawFish(fish.x, getFishDrawY(), fish.touchedFrames > 0)
    drawHUD()
    drawTouchBanner()

    if crankHintFrames > 0 or playdate.isCrankDocked() then
        ui.crankIndicator:draw(346, 44)
    end

    if invertScreen then
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
end

local function drawTitleOverlay()
    drawPanel(18, 10, 180, 78, 10)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TOUCH DA", 108, 24, kTextAlignment.center)
    gfx.drawTextAligned("FISHY", 108, 46, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    drawPanel(220, 12, 162, 52, 8)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("MEME MODE", 248, 20)
    gfx.drawText("CRANK TO BOOP", 234, 38)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    drawPanel(76, 188, 248, 26, 8)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    if titlePulseFrames < 30 then
        gfx.drawTextAligned("PRESS A TO START", 200, 195, kTextAlignment.center)
    else
        gfx.drawTextAligned("BOOP FISH WITH CRANK", 200, 195, kTextAlignment.center)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    drawHalftoneDots(24, 58, 3)
end

local function drawTitleScreen()
    if titleBackground ~= nil then
        titleBackground:draw(0, 0)
    else
        gfx.clear(gfx.kColorWhite)
    end

    drawTitleOverlay()
    ui.crankIndicator:draw(344, 78)
end

local function drawGameOverScreen()
    if titleBackground ~= nil then
        titleBackground:draw(0, 0)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
        gfx.setColor(gfx.kColorBlack)
    end

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

    timer.updateTimers()
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

loadHighScore()
