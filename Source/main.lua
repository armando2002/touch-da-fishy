import "CoreLibs/graphics"
import "CoreLibs/ui"
import "CoreLibs/crank"

local gfx <const> = playdate.graphics
local ui <const> = playdate.ui
local geom <const> = playdate.geometry
local datastore <const> = playdate.datastore
local snd <const> = playdate.sound

playdate.display.setRefreshRate(30)
math.randomseed(playdate.getSecondsSinceEpoch())

-- =========================================================
-- Touch Da Fishy
--
-- The fish is skittish prey. While it flops with its head down it's
-- DISTRACTED and safe to sneak the paw closer; periodically it PEEKS (a short
-- warning) then goes ALERT and watches the paw. Move the paw (crank OR d-pad)
-- while it's ALERT and it bolts, snapping your paw all the way back. Reach it
-- while it's not watching to boop it. Score as many as you can in 60 seconds.
-- =========================================================

local SCREEN_W <const> = 400
local SCREEN_H <const> = 240

local STATE_TITLE <const> = "title"
local STATE_PLAY <const> = "play"
local STATE_GAMEOVER <const> = "gameover"

local ROUND_SECONDS <const> = 60
local ROUND_FRAMES <const> = ROUND_SECONDS * 30

-- Paw reach. No automatic sag now: the paw holds where you crank it, so
-- stopping is genuinely safe during an ALERT.
local ARM_BASE_X <const> = 34
local ARM_MIN_LENGTH <const> = 22
local ARM_MAX_LENGTH <const> = 360
local ARM_CRANK_MULTIPLIER <const> = 0.22 -- pixels of reach per degree of crank
local BUTTON_ADVANCE <const> = 4          -- d-pad / A: crank alternative (accessibility)
local BUTTON_RETRACT <const> = 6
local PAW_RADIUS <const> = 11
local PAW_Y <const> = 138                 -- the paw reaches along this fixed line

-- Any paw movement above this (degrees of crank, or a button press) counts as
-- "movement" the fish can see while it's ALERT.
local CRANK_MOVE_EPS <const> = 2.0

-- The fish notices you by MOVEMENT, not elapsed time. Suspicion (0..1) rises as
-- you move the paw and relaxes when you hold still. There is NO timed safe
-- window, so cranking faster just fills suspicion faster.
local SUSPICION_GAIN_EASY <const> = 0.0020 -- suspicion per degree of crank (early)
local SUSPICION_GAIN_HARD <const> = 0.0032 -- ... later (notices sooner)
local SUSPICION_RELAX <const> = 0.02       -- suspicion lost per still frame
local SUSPICION_PEEK <const> = 0.55        -- "?" warning band starts here; alert at 1.0

-- Fish (bigger than before so it reads on the small screen).
local FISH_A <const> = 20 -- half length
local FISH_B <const> = 11 -- half girth
local FISH_HIT_RADIUS <const> = 15
local CATCH_DIST <const> = PAW_RADIUS + FISH_HIT_RADIUS
local FISH_MIN_X <const> = 315
local FISH_MAX_X <const> = 362

local TOUCH_BANNER_FRAMES <const> = 20
local SPOOK_FRAMES <const> = 16
local BOLT_TIME_PENALTY <const> = 90 -- frames (3s) lost off the clock when startled
local CRANK_BOLT_RECOIL <const> = true -- bolt snaps paw fully back

local SAVE_KEY <const> = "touch_da_fishy"

-- =========================================================
-- State
-- =========================================================

local gameState = STATE_TITLE

local score = 0
local highScore = 0
local roundFramesLeft = ROUND_FRAMES

local touchBannerFrames = 0
local spookFrames = 0
local penaltyFrames = 0
local crankHintFrames = 0
local goFrames = 0

local flashEnabled = true -- accessibility: screen-flash feedback can be turned off

local arm = { length = ARM_MIN_LENGTH }

-- aware: "calm" (safe) -> "peek" (short warning) -> "alert" (watching; don't move)
--        "bolt" (startled, flipping away)
local fish = {
    x = 330, y = PAW_Y, baseX = 330,
    aware = "calm",
    awareTimer = 0,
    awareDuration = 60,
    flopPhase = 0,
    angle = 0,
    tailFlap = 0,
    squashX = 1, squashY = 1,
    bob = 0,
    boltSpin = 0,
    suspicion = 0,
    seenMovement = 0,
    wasAlert = false,
}

local titleBackground = gfx.image.new("title_background")

-- =========================================================
-- Sound (soft triangle voices + envelopes)
-- =========================================================

local sfx = {}
local function initSound()
    if snd == nil then return end
    sfx.boop = snd.synth.new(snd.kWaveTriangle)
    sfx.boop2 = snd.synth.new(snd.kWaveTriangle)
    sfx.alert = snd.synth.new(snd.kWaveSine)
    sfx.startle = snd.synth.new(snd.kWaveTriangle)
    sfx.over = snd.synth.new(snd.kWaveTriangle)
    for _, name in ipairs({ "boop", "boop2", "alert", "startle", "over" }) do
        local s = sfx[name]
        if s ~= nil and s.setADSR ~= nil then
            s:setADSR(0.004, 0.10, 0, 0.08)
        end
    end
end

local function play(s, note, vol, len)
    if s ~= nil then s:playNote(note, vol or 0.3, len or 0.08) end
end

local function playCatchChime()
    play(sfx.boop, "E5", 0.26, 0.13)
    play(sfx.boop2, "B5", 0.18, 0.13)
end

-- =========================================================
-- Helpers
-- =========================================================

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function lerp(a, b, t) return a + (b - a) * t end

-- 0 (easy) .. 1 (hard), climbs as you score.
local function difficulty() return clamp(score / 15, 0, 1) end

local function pawTipX() return ARM_BASE_X + arm.length end

local function rotLocal(x, y, s, c) return x * c - y * s, x * s + y * c end

-- =========================================================
-- Persistence
-- =========================================================

local function loadHighScore()
    local data = datastore.read(SAVE_KEY)
    if data ~= nil and data.highScore ~= nil then highScore = data.highScore end
end

local function saveHighScore()
    datastore.write({ highScore = highScore }, SAVE_KEY)
end

local function updateHighScoreIfNeeded()
    if score > highScore then highScore = score saveHighScore() end
end

-- =========================================================
-- Fish awareness state machine
-- =========================================================

local function randRange(a, b)
    if a > b then a, b = b, a end
    return math.random(math.floor(a), math.floor(b))
end

local function enterCalm()
    fish.aware = "calm"
    fish.suspicion = 0
    fish.wasAlert = false
end

local function relocateFish()
    fish.baseX = randRange(FISH_MIN_X, FISH_MAX_X)
    fish.x = fish.baseX
end

local function enterBolt()
    fish.aware = "bolt"
    fish.awareTimer = 0
    fish.awareDuration = 20
    fish.suspicion = 0
    fish.boltSpin = (math.random() < 0.5) and -1 or 1
    spookFrames = SPOOK_FRAMES
    penaltyFrames = 24
    roundFramesLeft = math.max(0, roundFramesLeft - BOLT_TIME_PENALTY)
    play(sfx.startle, "G3", 0.24, 0.18)
    if CRANK_BOLT_RECOIL then arm.length = ARM_MIN_LENGTH end
end

local function spawnFish(firstGrace)
    relocateFish()
    fish.y = PAW_Y
    fish.flopPhase = math.random() * math.pi * 2
    fish.angle = 0
    fish.tailFlap = 0
    fish.squashX, fish.squashY = 1, 1
    enterCalm(firstGrace or 0)
end

-- =========================================================
-- Round flow
-- =========================================================

local function showCrankHint(frames)
    crankHintFrames = frames
    ui.crankIndicator:resetAnimation()
    ui.crankIndicator.clockwise = true
end

local function startRound()
    score = 0
    roundFramesLeft = ROUND_FRAMES
    arm.length = ARM_MIN_LENGTH
    touchBannerFrames = 0
    spookFrames = 0
    goFrames = 30
    spawnFish(35) -- a little grace on the very first fish
    showCrankHint(70)
    gameState = STATE_PLAY
end

local function endRound()
    updateHighScoreIfNeeded()
    play(sfx.over, "A3", 0.30, 0.4)
    gameState = STATE_GAMEOVER
end

local function handleBoop()
    score = score + 1
    updateHighScoreIfNeeded()
    touchBannerFrames = TOUCH_BANNER_FRAMES
    playCatchChime()
    arm.length = ARM_MIN_LENGTH
    spawnFish(8)
end

-- =========================================================
-- Update
-- =========================================================

local function updateFishAwareness()
    fish.flopPhase = fish.flopPhase + 0.35

    if fish.aware == "bolt" then
        fish.awareTimer = fish.awareTimer + 1
        local t = clamp(fish.awareTimer / fish.awareDuration, 0, 1)
        fish.angle = t * math.pi * 2 * fish.boltSpin
        fish.bob = -math.sin(math.pi * t) * 26
        fish.tailFlap = math.sin(fish.flopPhase * 3.4)
        if t >= 1 then relocateFish() fish.bob = 0 enterCalm() end
        return
    end

    -- Suspicion rises with movement, relaxes when still. No timed safe window.
    local gain = lerp(SUSPICION_GAIN_EASY, SUSPICION_GAIN_HARD, difficulty())
    if (fish.seenMovement or 0) > 0 then
        fish.suspicion = clamp(fish.suspicion + fish.seenMovement * gain, 0, 1.15)
    else
        fish.suspicion = math.max(0, fish.suspicion - SUSPICION_RELAX)
    end

    if fish.suspicion >= 1.0 then
        if not fish.wasAlert then play(sfx.alert, "C5", 0.16, 0.06) end
        fish.wasAlert = true
        fish.aware = "alert"
        fish.angle, fish.tailFlap, fish.bob = 0, 0, 0
        fish.squashX, fish.squashY = 1, 1
    elseif fish.suspicion >= SUSPICION_PEEK then
        fish.wasAlert = false
        fish.aware = "peek"
        fish.angle = lerp(fish.angle, -0.05, 0.3)
        fish.tailFlap = math.sin(fish.flopPhase * 2.5) * 0.3
        fish.bob = 0
    else
        fish.wasAlert = false
        fish.aware = "calm"
        fish.angle = math.sin(fish.flopPhase) * 0.12
        fish.tailFlap = math.sin(fish.flopPhase * 1.7) * 0.55
        fish.bob = -math.abs(math.sin(fish.flopPhase * 0.9)) * 2
        fish.squashX, fish.squashY = 1, 1
    end
end

local function updatePawAndDetectMovement()
    local crankChange = 0
    if not playdate.isCrankDocked() then
        crankChange = playdate.getCrankChange()
    else
        showCrankHint(1)
    end

    local btnUp = playdate.buttonIsPressed(playdate.kButtonUp) or playdate.buttonIsPressed(playdate.kButtonA)
    local btnDown = playdate.buttonIsPressed(playdate.kButtonDown)
    fish.seenMovement = math.abs(crankChange) + (btnUp and 16 or 0) + (btnDown and 16 or 0)

    -- While the fish is bolting, your paw is "caught" — it stays pulled back and
    -- cranking does nothing. The startle has to actually cost you progress.
    if fish.aware == "bolt" then return end

    -- How much the paw wants to move this frame, and whether that's "visible".
    local move = crankChange * ARM_CRANK_MULTIPLIER
    if btnUp then move = move + BUTTON_ADVANCE end
    if btnDown then move = move - BUTTON_RETRACT end

    local visibleMovement = (math.abs(crankChange) > CRANK_MOVE_EPS) or btnUp or btnDown

    if fish.aware == "alert" and visibleMovement then
        enterBolt()
        return
    end

    arm.length = clamp(arm.length + move, ARM_MIN_LENGTH, ARM_MAX_LENGTH)
end

local function checkBoop()
    if fish.aware == "bolt" then return end
    local dx = pawTipX() - fish.x
    local dy = PAW_Y - (fish.y + fish.bob)
    if (dx * dx + dy * dy) <= (CATCH_DIST * CATCH_DIST) then
        handleBoop()
    end
end

local function tickCounters()
    if touchBannerFrames > 0 then touchBannerFrames = touchBannerFrames - 1 end
    if spookFrames > 0 then spookFrames = spookFrames - 1 end
    if crankHintFrames > 0 then crankHintFrames = crankHintFrames - 1 end
    if goFrames > 0 then goFrames = goFrames - 1 end
    if penaltyFrames > 0 then penaltyFrames = penaltyFrames - 1 end
end

local function updatePlay()
    updatePawAndDetectMovement()
    updateFishAwareness()
    if gameState == STATE_PLAY then checkBoop() end

    roundFramesLeft = roundFramesLeft - 1
    if roundFramesLeft <= 0 then
        roundFramesLeft = 0
        endRound()
    end
    tickCounters()
end

-- =========================================================
-- Drawing
-- =========================================================

local function drawCountertop()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 206, SCREEN_W, 34)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    for x = 10, SCREEN_W, 26 do gfx.drawLine(x, 216, x + 10, 232) end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawPlate()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillEllipseInRect(244, 186, 144, 34)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillEllipseInRect(228, 84, 168, 120)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3)
    gfx.drawEllipseInRect(228, 84, 168, 120)
    gfx.setLineWidth(2)
    gfx.drawEllipseInRect(252, 100, 120, 88)
    gfx.drawLine(270, 116, 292, 108)
    gfx.setLineWidth(1)
end

local function drawCat()
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(18, 120, 20)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawCircleAtPoint(18, 120, 20)
    gfx.drawLine(4, 104, 8, 86); gfx.drawLine(8, 86, 20, 100)
    gfx.drawLine(18, 99, 30, 86); gfx.drawLine(30, 86, 34, 104)
    gfx.setLineWidth(1)
    gfx.fillCircleAtPoint(12, 116, 2); gfx.fillCircleAtPoint(24, 116, 2)
    gfx.drawLine(14, 124, 18, 127); gfx.drawLine(18, 127, 22, 124)
end

local function drawPaw()
    local px, py = pawTipX(), PAW_Y
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(11)
    gfx.drawLine(ARM_BASE_X, py, px - 6, py)
    gfx.setLineWidth(1)
    gfx.fillCircleAtPoint(px, py, PAW_RADIUS)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(px - 1, py + 3, 4)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(px - 8, py - 8, 4)
    gfx.fillCircleAtPoint(px - 1, py - 11, 4)
    gfx.fillCircleAtPoint(px + 7, py - 8, 4)
end

local function drawFish(cx, cy, angle, sqX, sqY, tailFlap, aware)
    local s, c = math.sin(angle), math.cos(angle)
    local a, b = FISH_A * sqX, FISH_B * sqY

    local coords = {}
    local N = 14
    for i = 0, N - 1 do
        local th = (i / N) * 2 * math.pi
        local rx, ry = rotLocal(math.cos(th) * a, math.sin(th) * b, s, c)
        coords[#coords + 1] = cx + rx
        coords[#coords + 1] = cy + ry
    end
    local body = geom.polygon.new(table.unpack(coords))
    body:close()
    gfx.setColor(gfx.kColorBlack)
    gfx.fillPolygon(body)

    -- tail
    local blx, bly = -a * 0.55, 0
    local function tail(lx, ly)
        local rdx, rdy = lx - blx, ly - bly
        local fs, fc = math.sin(tailFlap), math.cos(tailFlap)
        local fx = blx + rdx * fc - rdy * fs
        local fy = bly + rdx * fs + rdy * fc
        local gx, gy = rotLocal(fx, fy, s, c)
        return cx + gx, cy + gy
    end
    local b1x, b1y = rotLocal(blx, bly, s, c)
    local t1x, t1y = tail(-a * 1.5, -b * 1.1)
    local t2x, t2y = tail(-a * 1.5, b * 1.1)
    gfx.fillTriangle(cx + b1x, cy + b1y, t1x, t1y, t2x, t2y)

    local function loc(lx, ly) local rx, ry = rotLocal(lx, ly, s, c) return cx + rx, cy + ry end
    -- dorsal fin
    local f1x, f1y = loc(-a * 0.15, -b * 0.8)
    local f2x, f2y = loc(a * 0.2, -b * 0.8)
    local f3x, f3y = loc(0, -b * 1.9)
    gfx.fillTriangle(f1x, f1y, f2x, f2y, f3x, f3y)

    -- eye: closed when calm, wide and looking toward the paw when wary
    local ex, ey = loc(a * 0.5, -b * 0.35)
    if aware == "calm" then
        gfx.setColor(gfx.kColorWhite)
        gfx.setLineWidth(2)
        gfx.drawLine(ex - 3, ey, ex + 3, ey) -- relaxed/closed eye
        gfx.setLineWidth(1)
    else
        gfx.setColor(gfx.kColorWhite)
        gfx.fillCircleAtPoint(ex, ey, 3)
        gfx.setColor(gfx.kColorBlack)
        gfx.fillCircleAtPoint(ex - 1, ey, 1) -- pupil glances toward the cat
    end
end

local function drawAwarenessTell(cx, cy)
    local label
    if fish.aware == "peek" then label = "?"
    elseif fish.aware == "alert" then label = "!"
    else return end
    local bx, by = cx - 9, cy - FISH_B - 30
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(bx, by, 18, 20, 4)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(bx, by, 18, 20, 4)
    gfx.drawText(label, bx + 6, by + 3)
end

local function drawHUD()
    local secs = math.ceil(roundFramesLeft / 30)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(8, 6, SCREEN_W - 16, 22, 6)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("TIME " .. tostring(secs), 18, 11)
    if penaltyFrames > 0 then gfx.drawText("-3s", 92, 11) end
    gfx.drawTextAligned("SCORE " .. tostring(score), 200, 11, kTextAlignment.center)
    gfx.drawTextAligned("BEST " .. tostring(highScore), SCREEN_W - 18, 11, kTextAlignment.right)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    if fish.aware == "alert" then
        gfx.drawTextAligned("FREEZE — IT SEES YOU", 200, 214, kTextAlignment.center)
    else
        gfx.drawText("CRANK / \u{2191} = REACH", 14, 214)
        gfx.drawTextAligned("TOUCH IT WHILE IT FLOPS", SCREEN_W - 16, 214, kTextAlignment.right)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawSpeechBubble(x, y, w, h)
    gfx.fillRoundRect(x, y, w, h, 8)
    gfx.fillTriangle(x + 30, y + h - 2, x + 52, y + h - 2, x + 42, y + h + 12)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawRoundRect(x + 3, y + 3, w - 6, h - 6, 6)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawBanner()
    if touchBannerFrames <= 0 then return end
    gfx.setColor(gfx.kColorBlack)
    drawSpeechBubble(119, 36, 162, 30)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TOUCHED DA FISHY!", 200, 44, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawPlayfield()
    gfx.clear(gfx.kColorWhite)

    -- Gentle, non-flashing spook feedback: a small screen shake, plus a thin
    -- border pulse ONLY if the player hasn't disabled flashing.
    local ox, oy = 0, 0
    if spookFrames > 0 then
        local k = spookFrames
        ox = ((k % 2) == 0) and 3 or -3
        oy = ((k % 3) == 0) and 2 or -2
    end
    gfx.setDrawOffset(ox, oy)

    drawCountertop()
    drawPlate()
    drawCat()
    drawPaw()
    drawFish(fish.x, fish.y + fish.bob, fish.angle, fish.squashX, fish.squashY, fish.tailFlap, fish.aware)
    drawAwarenessTell(fish.x, fish.y + fish.bob)

    gfx.setDrawOffset(0, 0)

    drawHUD()
    drawBanner()

    if spookFrames > SPOOK_FRAMES - 3 and flashEnabled then
        gfx.setColor(gfx.kColorBlack)
        gfx.setLineWidth(6)
        gfx.drawRect(0, 0, SCREEN_W, SCREEN_H)
        gfx.setLineWidth(1)
    end

    if goFrames > 0 then
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRoundRect(160, 96, 80, 36, 8)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        gfx.drawTextAligned("GO!", 200, 106, kTextAlignment.center)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end

    if crankHintFrames > 0 or playdate.isCrankDocked() then
        ui.crankIndicator:draw(330, 40)
    end
end

local function drawPanel(x, y, w, h, r)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(x, y, w, h, r)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawRoundRect(x + 3, y + 3, w - 6, h - 6, math.max(2, r - 2))
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawTitle()
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

local function drawGameOver()
    gfx.clear(gfx.kColorWhite)
    drawPanel(52, 40, 296, 150, 12)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawTextAligned("TIME'S UP!", 200, 60, kTextAlignment.center)
    gfx.drawTextAligned("YOU TOUCHED " .. tostring(score) .. " FISHY", 200, 100, kTextAlignment.center)
    gfx.drawTextAligned("BEST " .. tostring(highScore), 200, 122, kTextAlignment.center)
    gfx.drawTextAligned("PRESS A TO PLAY AGAIN", 200, 158, kTextAlignment.center)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- =========================================================
-- System menu (accessibility + restart)
-- =========================================================

local function initMenu()
    local menu = playdate.getSystemMenu()
    if menu == nil then return end
    menu:addCheckmarkMenuItem("Screen flash", flashEnabled, function(v) flashEnabled = v end)
    menu:addMenuItem("Restart", function()
        if gameState ~= STATE_TITLE then startRound() end
    end)
end

-- =========================================================
-- Callbacks
-- =========================================================

function playdate.update()
    if gameState == STATE_TITLE then
        if playdate.buttonJustPressed(playdate.kButtonA) then startRound() end
        tickCounters()
        drawTitle()
    elseif gameState == STATE_PLAY then
        updatePlay()
        drawPlayfield()
    elseif gameState == STATE_GAMEOVER then
        if playdate.buttonJustPressed(playdate.kButtonA) then startRound() end
        tickCounters()
        drawGameOver()
    end
end

function playdate.crankDocked() showCrankHint(60) end
function playdate.crankUndocked() showCrankHint(40) end

function playdate.gameWillTerminate() updateHighScoreIfNeeded() end
function playdate.deviceWillSleep() updateHighScoreIfNeeded() end

initSound()
initMenu()
loadHighScore()
