-- ============================================================
-- CiaWheelie v1 — Auto Wheelie & Cruise Control
-- Black & White Style + MOBILE TOUCH + SPEED / ANGLE HOLD + LAG BACK
-- ============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local lp = Players.LocalPlayer

-- ============================================================
-- FIND SCOOTER
-- ============================================================
local function findScooter()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj:GetAttribute("MotorWatts") then
            local owner = obj:FindFirstChild("ScooterOwner", true)
            if owner and owner:IsA("ObjectValue") and owner.Value == lp then
                return obj
            end
        end
    end
    local char = lp.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        local seat = hum and hum.SeatPart
        if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
            return seat:FindFirstAncestorOfClass("Model")
        end
    end
    return nil
end

-- ============================================================
-- WHEELIE STATE
-- ============================================================
-- Enable while moving with the desired wheelie angle.
-- W accelerates; S brakes. Speed is held approximately using feedback.
-- Target is horizontal studs/second. Heading is held; pitch sways downward only.
-- Requires client control of scooter physics; server corrections can override it.
-- Disable the old freeze script and respawn the scooter before using this version.
local returnInterval = 1 -- slider range: 0.1 to 10 seconds
local settingsRevision = 0
local savedStart, savedStartBody
local startLabel

local function intervalFromRatio(ratio)
    return math.floor((0.1 + math.clamp(ratio, 0, 1) * 9.9) * 10 + 0.5) / 10
end

local function saveStartingPoint(root)
    savedStart = root.Position
    savedStartBody = root
    settingsRevision = settingsRevision + 1
    if startLabel then
        startLabel.Text = string.format("Start saved: %.1f, %.1f, %.1f",
            savedStart.X, savedStart.Y, savedStart.Z)
    end
end
local SPEED_TOLERANCE = 0.75 -- studs/s: begin correcting outside this range
local SPEED_RELEASE = 0.15   -- release the key near the target speed
local CONTROL_INTERVAL = 0.05 -- check speed 20 times/second
local MIN_WHEELIE_DEGREES = 5
local angleMin, angleMax = 15, 35
local swaySeconds = 2.5
local angleRevision = 0
local capturedStartDegrees
local refreshSwayUI = function() end
local rng = Random.new()

local function effectiveAngleBounds(startDegrees)
    local upper = math.min(angleMax, startDegrees)
    local lower = math.min(angleMin, upper)
    return math.max(MIN_WHEELIE_DEGREES, lower), math.max(MIN_WHEELIE_DEGREES, upper)
end

local function smoothBlend(t)
    t = math.clamp(t, 0, 1)
    return t * t * t * (t * (6 * t - 15) + 10)
end

-- Documented Roblox input simulation API; availability depends on the environment.
-- https://create.roblox.com/docs/reference/engine/classes/UserInputService#CreateVirtualInput
local virtualInput
local heldKey

local function releaseSpeedKey()
    if not heldKey then return true end
    local ok, err = pcall(function()
        virtualInput:SendKey(false, heldKey, false)
    end)
    if ok then heldKey = nil end
    return ok, err
end

local function setSpeedKey(key)
    if key == heldKey then return end
    local ok, err = releaseSpeedKey()
    if not ok then error("Key release failed: " .. tostring(err)) end
    if key then
        -- Record before sending so error cleanup also attempts a key-up.
        heldKey = key
        virtualInput:SendKey(true, key, false)
    end
end

local function chooseSpeedKey(speedError, currentKey)
    if speedError > SPEED_TOLERANCE then return Enum.KeyCode.W end
    if speedError < -SPEED_TOLERANCE then return Enum.KeyCode.S end
    if currentKey == Enum.KeyCode.W and speedError > SPEED_RELEASE then
        return Enum.KeyCode.W
    end
    if currentKey == Enum.KeyCode.S and speedError < -SPEED_RELEASE then
        return Enum.KeyCode.S
    end
    return nil
end

local wheelieActive = false
local holding = false
local motionConn = nil
local infoText
local status = "Raise your wheelie, then enable."
local updateWheelieUI = function() end
local setWheelie

local function showStatus(message)
    status = message
    updateWheelieUI()
end

local function stopMotion(message)
    if motionConn then
        motionConn:Disconnect()
        motionConn = nil
    end
    wheelieActive = false
    holding = false
    local released, err = releaseSpeedKey()
    if not released then
        warn("[CiaWheelie v1] Key release failed: " .. tostring(err))
        showStatus("Key release failed. Tap W/S manually; stop script.")
        return
    end
    showStatus(type(message) == "string" and message or "Wheelie OFF")
end

local function getBody(scooter, seat)
    if seat and seat:IsDescendantOf(scooter) then return seat end
    if scooter.PrimaryPart then return scooter.PrimaryPart end
    -- Custom controllers may never set Humanoid.SeatPart.
    -- Prefer the heaviest movable assembly when no explicit body is available.
    local best, mass = nil, -1
    for _, part in ipairs(scooter:GetDescendants()) do
        if part:IsA("BasePart") and not part.Anchored then
            local assemblyRoot = part.AssemblyRootPart
            if assemblyRoot and not assemblyRoot.Anchored
                and part.AssemblyMass > mass then
                best, mass = part, part.AssemblyMass
            end
        end
    end
    return best
end

setWheelie = function(state)
    stopMotion()
    if not state then return end
    if heldKey then return end -- Do not resume while a key-up is still failing.
    if UserInputService:GetFocusedTextBox() then
        showStatus("Close chat/text entry, then enable.")
        return
    end
    local ok, result = pcall(function()
        return virtualInput or UserInputService:CreateVirtualInput()
    end)
    if not ok or not result then
        showStatus("W/S input simulation unavailable in this environment.")
        warn("[CiaWheelie v1] CreateVirtualInput unavailable: " .. tostring(result))
        return
    end
    virtualInput = result
    wheelieActive = true
    showStatus("Waiting for your scooter...")

    local scooter, root, char, hum, capturedSeat
    local travel, direction, targetSpeed, lockedRotation
    local pitchAxis, startDegrees
    local currentAngle, fromAngle, toAngle
    local segmentTime, segmentDuration = 0, 1
    local activeAngleRevision = -1
    local activeRevision = settingsRevision
    local controlElapsed = CONTROL_INTERVAL
    local elapsed = 0
    local retry = 0.25

    local function step(dt)
        if UserInputService:GetFocusedTextBox() then
            stopMotion("Stopped for text entry. Enable again when ready.")
            return
        end
        if not holding then
            retry = retry + dt
            if retry < 0.25 then return end
            retry = 0
            char = lp.Character
            hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then
                showStatus("Waiting for your character...")
                return
            end
            scooter = findScooter()
            if not scooter then
                showStatus("Scooter not found. Ride your scooter first.")
                return
            end
            local seat = hum.SeatPart
            root = getBody(scooter, seat)
            if not root then
                showStatus("No movable body found. Respawn your scooter.")
                return
            end
            local assemblyRoot = root.AssemblyRootPart
            if root.Anchored or (assemblyRoot and assemblyRoot.Anchored) then
                showStatus("Body anchored. Stop old script; respawn scooter.")
                return
            end
            local velocity = root.AssemblyLinearVelocity
            travel = Vector3.new(velocity.X, 0, velocity.Z)
            if travel.Magnitude < 0.5 then
                showStatus("Armed: start moving. Captures angle as you move.")
                return
            end
            capturedSeat = seat and seat:IsDescendantOf(scooter) and seat or nil
            targetSpeed = travel.Magnitude
            direction = travel.Unit
            lockedRotation = root.CFrame.Rotation
            -- Infer the chassis forward axis from the captured travel direction.
            -- Supports chassis parts with either local X or Z along the scooter.
            local forward = lockedRotation.LookVector
            if math.abs(lockedRotation.RightVector:Dot(direction))
                > math.abs(forward:Dot(direction)) then
                forward = lockedRotation.RightVector
            end
            if forward:Dot(direction) < 0 then forward = -forward end
            local startPitch = math.asin(math.clamp(forward.Y, -1, 1))
            local minimumPitch = math.rad(MIN_WHEELIE_DEGREES)
            if startPitch <= minimumPitch then
                showStatus("Raise the wheelie above " .. MIN_WHEELIE_DEGREES .. " degrees to start.")
                return
            end
            startDegrees = math.deg(startPitch)
            capturedStartDegrees = startDegrees
            angleMax = math.min(angleMax, startDegrees)
            angleMin = math.min(angleMin, angleMax)
            -- Rotate around the chassis forward axis's horizontal perpendicular.
            -- This makes the requested pitch exact even with yaw misalignment.
            local horizontal = Vector3.new(forward.X, 0, forward.Z).Unit
            pitchAxis = horizontal:Cross(Vector3.new(0, 1, 0)).Unit
            local lower, upper = effectiveAngleBounds(startDegrees)
            currentAngle = math.clamp(startDegrees, lower, upper)
            activeAngleRevision = -1
            refreshSwayUI()
            if savedStartBody ~= root or not savedStart then
                saveStartingPoint(root)
            end
            activeRevision = settingsRevision
            dt = 0 -- Start the timer here, after capturing the initial position.
            holding = true
            showStatus(string.format("W/S target %.1f studs/s; return every %.1fs", targetSpeed, returnInterval))
        end

        if not scooter:IsDescendantOf(workspace)
            or not root:IsDescendantOf(scooter)
            or lp.Character ~= char or hum.Health <= 0 then
            stopMotion("Stopped: scooter or character removed.")
            return
        end
        if capturedSeat and hum.SeatPart ~= capturedSeat then
            stopMotion("Stopped: dismounted.")
            return
        end

        controlElapsed = controlElapsed + dt
        if controlElapsed >= CONTROL_INTERVAL then
            controlElapsed = 0
            -- Assembly velocity excludes the artificial snap-back displacement.
            local velocity = root.AssemblyLinearVelocity
            local speed = Vector3.new(velocity.X, 0, velocity.Z):Dot(direction)
            setSpeedKey(chooseSpeedKey(targetSpeed - speed, heldKey))
            local action = heldKey == Enum.KeyCode.W and "W: accelerate"
                or (heldKey == Enum.KeyCode.S and "S: brake" or "Coasting")
            local low, high = effectiveAngleBounds(startDegrees)
            showStatus(string.format("%s | %.1f / %.1f studs/s\nSway %.1f–%.1f° | return %.1fs", action, speed, targetSpeed, low, high, returnInterval))
        end

        if activeRevision ~= settingsRevision then
            elapsed = 0
            activeRevision = settingsRevision
        else
            elapsed = elapsed + dt
        end
        local targetPosition = root.Position
        if elapsed >= returnInterval then
            elapsed = 0
            -- Return to the exact saved XYZ position, retaining the wheelie rotation.
            targetPosition = savedStart
        end
        -- Pick new random angles and durations, then glide between them.
        -- The return timer never resets this sequence.
        local lower, upper = effectiveAngleBounds(startDegrees)
        if activeAngleRevision ~= angleRevision then
            currentAngle = math.clamp(currentAngle, lower, upper)
            fromAngle = currentAngle
            toAngle = rng:NextNumber(lower, upper)
            segmentTime = 0
            segmentDuration = swaySeconds * rng:NextNumber(0.7, 1.3)
            activeAngleRevision = angleRevision
        end
        segmentTime = segmentTime + dt
        local blend = smoothBlend(segmentTime / segmentDuration)
        currentAngle = math.clamp(fromAngle + (toAngle - fromAngle) * blend, lower, upper)
        if segmentTime >= segmentDuration then
            fromAngle = currentAngle
            toAngle = rng:NextNumber(lower, upper)
            segmentTime = 0
            segmentDuration = swaySeconds * rng:NextNumber(0.7, 1.3)
        end
        local dip = math.rad(startDegrees - currentAngle)
        local variedRotation = CFrame.fromAxisAngle(pitchAxis, -dip) * lockedRotation
        local target = CFrame.new(targetPosition) * variedRotation
        local correction = target * root.CFrame:Inverse()
        scooter:PivotTo(correction * scooter:GetPivot())
        -- Speed is controlled only through W/S, not by setting velocity.
        root.AssemblyAngularVelocity = Vector3.zero
    end

    motionConn = RunService.PreSimulation:Connect(function(dt)
        local ok, err = pcall(step, dt)
        if not ok then
            stopMotion("Error: " .. tostring(err))
            warn("[CiaWheelie v1] " .. tostring(err))
        end
    end)
end

local focusConn = UserInputService.WindowFocusReleased:Connect(function()
    stopMotion("Stopped: window lost focus.")
end)
local textConn = UserInputService.TextBoxFocused:Connect(function()
    stopMotion("Stopped for text entry.")
end)
local characterConn = lp.CharacterRemoving:Connect(function()
    stopMotion("Stopped: character respawned.")
end)

-- ============================================================
-- CiaWheelie v1 — responsive mouse / touch GUI
-- ============================================================
local playerGui = lp:WaitForChild("PlayerGui")
for _, oldName in ipairs({"EZMOD_Wheelie", "CiaWheelie"}) do
    local previousGui = playerGui:FindFirstChild(oldName)
    if previousGui then previousGui:Destroy() end
end
local gui = Instance.new("ScreenGui")
gui.Name = "CiaWheelie"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
local uiConnections = {}
local C = {
    base = Color3.fromRGB(13, 17, 22),
    card = Color3.fromRGB(22, 28, 35),
    border = Color3.fromRGB(43, 53, 64),
    white = Color3.fromRGB(240, 245, 248),
    muted = Color3.fromRGB(146, 161, 174),
    green = Color3.fromRGB(172, 255, 104),
    amber = Color3.fromRGB(255, 206, 110),
}
local function round(obj, radius)
    local corner = Instance.new("UICorner", obj)
    corner.CornerRadius = UDim.new(0, radius)
end
local function border(obj, color)
    local stroke = Instance.new("UIStroke", obj)
    stroke.Color = color or C.border
    stroke.Thickness = 1
    return stroke
end
local function label(parent, text, x, y, w, h, size, color, bold)
    local obj = Instance.new("TextLabel")
    obj.BackgroundTransparency = 1
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.Text = text
    obj.TextSize = size
    obj.TextColor3 = color or C.white
    obj.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    obj.TextXAlignment = Enum.TextXAlignment.Left
    obj.Parent = parent
    return obj
end
local function panel(parent, x, y, w, h)
    local obj = Instance.new("Frame")
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.BackgroundColor3 = C.card
    obj.BorderSizePixel = 0
    obj.Parent = parent
    round(obj, 12)
    return obj
end
local function button(parent, text, x, y, w, h)
    local obj = Instance.new("TextButton")
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.BackgroundColor3 = C.card
    obj.BorderSizePixel = 0
    obj.Text = text
    obj.Font = Enum.Font.GothamBold
    obj.TextSize = 13
    obj.TextColor3 = C.white
    obj.AutoButtonColor = true
    obj.Parent = parent
    round(obj, 10)
    return obj
end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(380, 470)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.fromScale(0.5, 0.5)
main.BackgroundColor3 = C.base
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
round(main, 20)
border(main)
local scale = Instance.new("UIScale", main)
local function fitWindow()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local view = camera.ViewportSize
    scale.Scale = math.min(1, math.max(0.1, (view.X - 24) / 380), math.max(0.1, (view.Y - 24) / 470))
end
local cameraConn
local function watchCamera()
    if cameraConn then cameraConn:Disconnect() end
    local camera = workspace.CurrentCamera
    if camera then cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindow) end
    fitWindow()
end
table.insert(uiConnections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))
watchCamera()

-- A separate drag area leaves the close button and controls unobstructed.
local titleBar = Instance.new("TextButton", main)
titleBar.Size = UDim2.fromOffset(304, 72)
titleBar.Position = UDim2.fromOffset(16, 6)
titleBar.BackgroundTransparency = 1
titleBar.Text = ""
titleBar.AutoButtonColor = false
local logo = panel(titleBar, 4, 16, 42, 42)
logo.BackgroundColor3 = C.green
local logoText = label(logo, "CW", 0, 0, 42, 42, 16, C.base, true)
logoText.TextXAlignment = Enum.TextXAlignment.Center
label(titleBar, "CiaWheelie", 58, 17, 164, 25, 22, C.white, true)
label(titleBar, "PRECISION RIDE CONTROL", 58, 43, 200, 14, 9, C.muted, true)
local version = label(titleBar, "v1", 230, 20, 34, 21, 12, C.green, true)
version.TextXAlignment = Enum.TextXAlignment.Center
local closeBtn = button(main, "×", 330, 24, 30, 30)
closeBtn.TextSize = 23
closeBtn.TextColor3 = C.muted
closeBtn.Activated:Connect(function() gui:Destroy() end)
label(main, "YOUR ANGLE. YOUR PACE.", 20, 79, 230, 16, 10, C.muted, true)
local stateBadge = label(main, "READY", 270, 79, 90, 16, 10, C.muted, true)
stateBadge.TextXAlignment = Enum.TextXAlignment.Right

local wheelieBtn = button(main, "ENABLE AUTO WHEELIE", 20, 106, 340, 48)
wheelieBtn.BackgroundColor3 = C.green
wheelieBtn.TextColor3 = C.base
wheelieBtn.TextSize = 14
local controls = Instance.new("ScrollingFrame", main)
controls.Position = UDim2.fromOffset(20, 166)
controls.Size = UDim2.fromOffset(344, 264)
controls.CanvasSize = UDim2.fromOffset(0, 608)
controls.BackgroundTransparency = 1
controls.BorderSizePixel = 0
controls.ScrollBarThickness = 3
controls.ScrollBarImageColor3 = C.green
controls.ScrollingDirection = Enum.ScrollingDirection.Y
controls.ElasticBehavior = Enum.ElasticBehavior.Never
local statusCard = panel(controls, 0, 0, 340, 60)
infoText = label(statusCard, status, 14, 9, 312, 42, 11, C.muted, false)
infoText.TextWrapped = true
infoText.TextYAlignment = Enum.TextYAlignment.Center

local sliderCard = panel(controls, 0, 72, 340, 104)
label(sliderCard, "RETURN TO START", 14, 11, 205, 20, 10, C.white, true)
local intervalLabel = label(sliderCard, "1.0s", 239, 8, 87, 26, 21, C.green, true)
intervalLabel.TextXAlignment = Enum.TextXAlignment.Right
local sliderHit = Instance.new("TextButton", sliderCard)
sliderHit.Position = UDim2.fromOffset(20, 37)
sliderHit.Size = UDim2.fromOffset(300, 34)
sliderHit.BackgroundTransparency = 1
sliderHit.Text = ""
sliderHit.AutoButtonColor = false
sliderHit.Active = true
local track = Instance.new("Frame", sliderHit)
track.Size = UDim2.new(1, 0, 0, 5)
track.Position = UDim2.fromScale(0, 0.5)
track.AnchorPoint = Vector2.new(0, 0.5)
track.BackgroundColor3 = C.border
track.BorderSizePixel = 0
round(track, 3)
local fill = Instance.new("Frame", track)
fill.BackgroundColor3 = C.green
fill.BorderSizePixel = 0
round(fill, 3)
local knob = Instance.new("Frame", track)
knob.Size = UDim2.fromOffset(20, 20)
knob.AnchorPoint = Vector2.new(0.5, 0.5)
knob.BackgroundColor3 = C.white
knob.BorderSizePixel = 0
round(knob, 10)
border(knob, C.green)
label(sliderCard, "0.1s", 14, 77, 45, 14, 10, C.muted)
local sliderHint = label(sliderCard, "DRAG TO ADJUST", 95, 77, 150, 14, 9, C.muted)
sliderHint.TextXAlignment = Enum.TextXAlignment.Center
local maxLabel = label(sliderCard, "10s", 279, 77, 47, 14, 10, C.muted)
maxLabel.TextXAlignment = Enum.TextXAlignment.Right
local function drawSlider()
    local ratio = (returnInterval - 0.1) / 9.9
    fill.Size = UDim2.fromScale(ratio, 1)
    knob.Position = UDim2.fromScale(ratio, 0.5)
    intervalLabel.Text = string.format("%.1fs", returnInterval)
end
local function setSliderAt(x)
    if sliderHit.AbsoluteSize.X <= 0 then return end
    local value = intervalFromRatio((x - sliderHit.AbsolutePosition.X) / sliderHit.AbsoluteSize.X)
    if value ~= returnInterval then
        returnInterval = value
        settingsRevision = settingsRevision + 1
    end
    drawSlider()
end
local sliderInput
sliderHit.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        sliderInput = input
        controls.ScrollingEnabled = false
        setSliderAt(input.Position.X)
    end
end)
table.insert(uiConnections, UserInputService.InputChanged:Connect(function(input)
    if not sliderInput then return end
    if input == sliderInput or (sliderInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement) then
        setSliderAt(input.Position.X)
    end
end))
table.insert(uiConnections, UserInputService.InputEnded:Connect(function(input)
    if input == sliderInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
        sliderInput = nil
        controls.ScrollingEnabled = true
    end
end))
drawSlider()

local swayCard = panel(controls, 0, 188, 340, 330)
label(swayCard, "RANDOM ANGLE SWAY", 14, 10, 300, 20, 11, C.white, true)
local capLabel = label(swayCard, "Maximum is capped at your starting angle.", 14, 31, 312, 18, 10, C.muted)
local sliderDraws = {}
local function addSettingSlider(y, title, minimum, maximum, getValue, setValue, format)
    label(swayCard, title, 14, y, 205, 18, 10, C.muted, true)
    local valueLabel = label(swayCard, "", 220, y, 106, 18, 12, C.green, true)
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    local hit = Instance.new("TextButton", swayCard)
    hit.Position = UDim2.fromOffset(20, y + 19)
    hit.Size = UDim2.fromOffset(300, 34)
    hit.BackgroundTransparency = 1
    hit.Text = ""
    local rail = Instance.new("Frame", hit)
    rail.Position = UDim2.fromScale(0, 0.5)
    rail.Size = UDim2.new(1, 0, 0, 4)
    rail.BackgroundColor3 = C.border
    rail.BorderSizePixel = 0
    round(rail, 2)
    local bar = Instance.new("Frame", rail)
    bar.BackgroundColor3 = C.green
    bar.BorderSizePixel = 0
    round(bar, 2)
    local dot = Instance.new("Frame", rail)
    dot.Size = UDim2.fromOffset(18, 18)
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.BackgroundColor3 = C.white
    dot.BorderSizePixel = 0
    round(dot, 9)
    local function draw()
        local hi = maximum()
        local ratio = math.clamp((getValue() - minimum) / math.max(0.001, hi - minimum), 0, 1)
        bar.Size = UDim2.fromScale(ratio, 1)
        dot.Position = UDim2.fromScale(ratio, 0.5)
        valueLabel.Text = string.format(format, getValue())
    end
    table.insert(sliderDraws, draw)
    local function move(x)
        if hit.AbsoluteSize.X <= 0 then return end
        local ratio = math.clamp((x - hit.AbsolutePosition.X) / hit.AbsoluteSize.X, 0, 1)
        local value = minimum + (maximum() - minimum) * ratio
        setValue(value)
        refreshSwayUI()
    end
    local activeInput
    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            activeInput = input
            controls.ScrollingEnabled = false
            move(input.Position.X)
        end
    end)
    table.insert(uiConnections, UserInputService.InputChanged:Connect(function(input)
        if activeInput and (input == activeInput or
            (activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement)) then
            move(input.Position.X)
        end
    end))
    table.insert(uiConnections, UserInputService.InputEnded:Connect(function(input)
        if activeInput and (input == activeInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
            activeInput = nil
            controls.ScrollingEnabled = true
        end
    end))
end
local function angleCeiling() return math.min(85, capturedStartDegrees or 85) end
local function rounded(value) return math.floor(value * 10 + 0.5) / 10 end
addSettingSlider(60, "MINIMUM ANGLE", 5, angleCeiling,
    function() return angleMin end,
    function(v)
        angleMin = math.clamp(rounded(v), 5, angleCeiling())
        angleMax = math.max(angleMax, angleMin)
        angleRevision = angleRevision + 1
    end, "%.1f°")
addSettingSlider(126, "MAXIMUM ANGLE", 5, angleCeiling,
    function() return angleMax end,
    function(v)
        angleMax = math.clamp(rounded(v), 5, angleCeiling())
        angleMin = math.min(angleMin, angleMax)
        angleRevision = angleRevision + 1
    end, "%.1f°")
addSettingSlider(192, "SWAY TRANSITION TIME", 0.5, function() return 5 end,
    function() return swaySeconds end,
    function(v)
        swaySeconds = math.clamp(rounded(v), 0.5, 5)
        angleRevision = angleRevision + 1
    end, "~%.1fs")
addSettingSlider(258, "SPEED TOLERANCE", 0.25, function() return 5 end,
    function() return SPEED_TOLERANCE end,
    function(v) SPEED_TOLERANCE = math.clamp(rounded(v), 0.25, 5) end,
    "+/-%.2f")
refreshSwayUI = function()
    for _, draw in ipairs(sliderDraws) do draw() end
    capLabel.Text = capturedStartDegrees
        and string.format("Start angle cap: %.1f° · minimum floor: 5°", capturedStartDegrees)
        or "Maximum is capped at your starting angle."
end
refreshSwayUI()

local startBtn = button(controls, "SET STARTING POINT HERE", 0, 530, 340, 42)
border(startBtn)
startBtn.Activated:Connect(function()
    local scooter = findScooter()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = scooter and getBody(scooter, hum and hum.SeatPart)
    if not root then showStatus("Ride your scooter to save a start point."); return end
    saveStartingPoint(root)
    showStatus("Starting point saved. Return timer restarted.")
end)
startLabel = label(controls, "Start point saves automatically when hold begins.", 0, 584, 340, 18, 10, C.muted)
startLabel.TextXAlignment = Enum.TextXAlignment.Center
local footer = label(main, "W  ACCELERATE     /     S  BRAKE     /     ANGLE SWAY", 20, 440, 340, 12, 9, C.muted)
footer.TextXAlignment = Enum.TextXAlignment.Center

updateWheelieUI = function()
    infoText.Text = status
    if holding then
        wheelieBtn.Text = "DISABLE AUTO WHEELIE"
        wheelieBtn.BackgroundColor3 = C.card
        wheelieBtn.TextColor3 = C.green
        stateBadge.Text = "● LIVE"
        stateBadge.TextColor3 = C.green
    elseif wheelieActive then
        wheelieBtn.Text = "CANCEL · WAITING FOR MOVEMENT"
        wheelieBtn.BackgroundColor3 = C.card
        wheelieBtn.TextColor3 = C.amber
        stateBadge.Text = "● ARMED"
        stateBadge.TextColor3 = C.amber
    else
        wheelieBtn.Text = "ENABLE AUTO WHEELIE"
        wheelieBtn.BackgroundColor3 = C.green
        wheelieBtn.TextColor3 = C.base
        stateBadge.Text = "READY"
        stateBadge.TextColor3 = C.muted
    end
end
wheelieBtn.Activated:Connect(function() setWheelie(not wheelieActive) end)
updateWheelieUI()

-- Mouse and touch header dragging, independently tracked from the slider.
local dragInput, dragStart, frameStart
local function dragTo(position)
    local delta = position - dragStart
    main.Position = UDim2.new(frameStart.X.Scale, frameStart.X.Offset + delta.X,
        frameStart.Y.Scale, frameStart.Y.Offset + delta.Y)
end
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragInput, dragStart, frameStart = input, input.Position, main.Position
    end
end)
table.insert(uiConnections, UserInputService.InputChanged:Connect(function(input)
    if not dragInput then return end
    if input == dragInput or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement) then
        dragTo(input.Position)
    end
end))
table.insert(uiConnections, UserInputService.InputEnded:Connect(function(input)
    if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragInput = nil
    end
end))
gui.Destroying:Connect(function()
    stopMotion()
    characterConn:Disconnect()
    focusConn:Disconnect()
    textConn:Disconnect()
    if cameraConn then cameraConn:Disconnect() end
    for _, connection in ipairs(uiConnections) do connection:Disconnect() end
    updateWheelieUI = function() end
    infoText, startLabel = nil, nil
    refreshSwayUI = function() end
end)
print("[CiaWheelie v1] Loaded — W/S speed hold, angle lock, saved return point")

-- Floating menu toggle: tap to show/hide without stopping the wheelie.
local menuToggle = button(gui, "CW", 0, 0, 56, 56)
menuToggle.Name = "MenuToggle"
menuToggle.AnchorPoint = Vector2.new(1, 0)
menuToggle.Position = UDim2.new(1, -16, 0, 80)
menuToggle.BackgroundColor3 = C.green
menuToggle.TextColor3 = C.base
menuToggle.TextSize = 17
menuToggle.ZIndex = 50
border(menuToggle, C.green)

menuToggle.Activated:Connect(function()
    main.Visible = not main.Visible
    menuToggle.BackgroundColor3 = main.Visible and C.green or C.card
    menuToggle.TextColor3 = main.Visible and C.base or C.green
end)
