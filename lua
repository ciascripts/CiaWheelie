-- ============================================================
-- CiaWheelie v1
-- W/S speed control, angle hold, saved return point,
-- adjustable teleport timer, floating menu toggle, and optional Anti-AFK.
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

            if owner
                and owner:IsA("ObjectValue")
                and owner.Value == lp then
                return obj
            end
        end
    end

    local char = lp.Character

    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        local seat = hum and hum.SeatPart

        if seat
            and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
            return seat:FindFirstAncestorOfClass("Model")
        end
    end

    return nil
end

-- ============================================================
-- SETTINGS AND STARTING POINT
-- ============================================================

-- Enable while moving at the desired speed and wheelie angle.
-- W accelerates; S brakes.
-- Speed is held approximately using feedback.
-- Orientation, including heading, is locked.
-- Input simulation availability depends on the environment.
-- Stop the old freeze script and respawn before using this.

local returnInterval = 1
local settingsRevision = 0
local savedStart, savedStartBody
local startLabel

local SPEED_TOLERANCE = 0.75
local SPEED_RELEASE = 0.15
local CONTROL_INTERVAL = 0.05

local function intervalFromRatio(ratio)
    return math.floor(
        (0.1 + math.clamp(ratio, 0, 1) * 9.9) * 10 + 0.5
    ) / 10
end

local function saveStartingPoint(root)
    savedStart = root.Position
    savedStartBody = root
    settingsRevision = settingsRevision + 1

    if startLabel then
        startLabel.Text = string.format(
            "Start saved: %.1f, %.1f, %.1f",
            savedStart.X,
            savedStart.Y,
            savedStart.Z
        )
    end
end

-- ============================================================
-- W / S INPUT CONTROL
-- ============================================================

local virtualInput
local heldKey

local function releaseSpeedKey()
    if not heldKey then
        return true
    end

    local ok, err = pcall(function()
        virtualInput:SendKey(false, heldKey, false)
    end)

    if ok then
        heldKey = nil
    end

    return ok, err
end

local function setSpeedKey(key)
    if key == heldKey then
        return
    end

    local ok, err = releaseSpeedKey()

    if not ok then
        error("Key release failed: " .. tostring(err))
    end

    if key then
        heldKey = key
        virtualInput:SendKey(true, key, false)
    end
end

local function chooseSpeedKey(speedError, currentKey)
    if speedError > SPEED_TOLERANCE then
        return Enum.KeyCode.W
    end

    if speedError < -SPEED_TOLERANCE then
        return Enum.KeyCode.S
    end

    if currentKey == Enum.KeyCode.W
        and speedError > SPEED_RELEASE then
        return Enum.KeyCode.W
    end

    if currentKey == Enum.KeyCode.S
        and speedError < -SPEED_RELEASE then
        return Enum.KeyCode.S
    end

    return nil
end

-- ============================================================
-- WHEELIE STATE
-- ============================================================

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
        warn(
            "[CiaWheelie v1] Key release failed: "
            .. tostring(err)
        )

        showStatus(
            "Key release failed. Tap W/S manually; stop script."
        )
        return
    end

    showStatus(
        type(message) == "string"
            and message
            or "Wheelie OFF"
    )
end

local function getBody(scooter, seat)
    if seat and seat:IsDescendantOf(scooter) then
        return seat
    end

    if scooter.PrimaryPart then
        return scooter.PrimaryPart
    end

    local best, mass = nil, -1

    for _, part in ipairs(scooter:GetDescendants()) do
        if part:IsA("BasePart") and not part.Anchored then
            local assemblyRoot = part.AssemblyRootPart

            if assemblyRoot
                and not assemblyRoot.Anchored
                and part.AssemblyMass > mass then
                best, mass = part, part.AssemblyMass
            end
        end
    end

    return best
end

-- ============================================================
-- ACTIVATE / DEACTIVATE
-- ============================================================

setWheelie = function(state)
    stopMotion()

    if not state then
        return
    end

    if heldKey then
        return
    end

    if UserInputService:GetFocusedTextBox() then
        showStatus("Close chat/text entry, then enable.")
        return
    end

    local ok, result = pcall(function()
        return virtualInput
            or UserInputService:CreateVirtualInput()
    end)

    if not ok or not result then
        showStatus(
            "W/S input simulation unavailable in this environment."
        )

        warn(
            "[CiaWheelie v1] CreateVirtualInput unavailable: "
            .. tostring(result)
        )
        return
    end

    virtualInput = result
    wheelieActive = true

    showStatus("Waiting for your scooter...")

    local scooter, root, char, hum, capturedSeat
    local travel, direction, targetSpeed, lockedRotation
    local activeRevision = settingsRevision
    local controlElapsed = CONTROL_INTERVAL
    local elapsed = 0
    local retry = 0.25

    local function step(dt)
        if UserInputService:GetFocusedTextBox() then
            stopMotion(
                "Stopped for text entry. Enable again when ready."
            )
            return
        end

        if not holding then
            retry = retry + dt

            if retry < 0.25 then
                return
            end

            retry = 0
            char = lp.Character
            hum = char and char:FindFirstChildOfClass("Humanoid")

            if not hum or hum.Health <= 0 then
                showStatus("Waiting for your character...")
                return
            end

            scooter = findScooter()

            if not scooter then
                showStatus(
                    "Scooter not found. Ride your scooter first."
                )
                return
            end

            local seat = hum.SeatPart
            root = getBody(scooter, seat)

            if not root then
                showStatus(
                    "No movable body found. Respawn your scooter."
                )
                return
            end

            local assemblyRoot = root.AssemblyRootPart

            if root.Anchored
                or (assemblyRoot and assemblyRoot.Anchored) then
                showStatus(
                    "Body anchored. Stop old script; respawn scooter."
                )
                return
            end

            local velocity = root.AssemblyLinearVelocity
            travel = Vector3.new(velocity.X, 0, velocity.Z)

            if travel.Magnitude < 0.5 then
                showStatus(
                    "Armed: start moving. Captures angle as you move."
                )
                return
            end

            capturedSeat =
                seat
                and seat:IsDescendantOf(scooter)
                and seat
                or nil

            targetSpeed = travel.Magnitude
            direction = travel.Unit
            lockedRotation = root.CFrame.Rotation

            if savedStartBody ~= root or not savedStart then
                saveStartingPoint(root)
            end

            activeRevision = settingsRevision
            dt = 0
            holding = true

            showStatus(string.format(
                "W/S target %.1f studs/s; return every %.1fs",
                targetSpeed,
                returnInterval
            ))
        end

        if not scooter:IsDescendantOf(workspace)
            or not root:IsDescendantOf(scooter)
            or lp.Character ~= char
            or hum.Health <= 0 then
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

            local velocity = root.AssemblyLinearVelocity

            local speed = Vector3.new(
                velocity.X,
                0,
                velocity.Z
            ):Dot(direction)

            setSpeedKey(
                chooseSpeedKey(targetSpeed - speed, heldKey)
            )

            local action =
                heldKey == Enum.KeyCode.W
                and "W: accelerate"
                or (
                    heldKey == Enum.KeyCode.S
                    and "S: brake"
                    or "Coasting"
                )

            showStatus(string.format(
                "%s | %.1f / %.1f studs/s\nReturn every %.1fs",
                action,
                speed,
                targetSpeed,
                returnInterval
            ))
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
            targetPosition = savedStart
        end

        local target =
            CFrame.new(targetPosition) * lockedRotation

        local correction =
            target * root.CFrame:Inverse()

        scooter:PivotTo(
            correction * scooter:GetPivot()
        )

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

local focusConn =
    UserInputService.WindowFocusReleased:Connect(function()
        stopMotion("Stopped: window lost focus.")
    end)

local textConn =
    UserInputService.TextBoxFocused:Connect(function()
        stopMotion("Stopped for text entry.")
    end)

local characterConn =
    lp.CharacterRemoving:Connect(function()
        stopMotion("Stopped: character respawned.")
    end)

-- ============================================================
-- GUI SETUP
-- ============================================================

local playerGui = lp:WaitForChild("PlayerGui")

for _, oldName in ipairs({
    "EZMOD_Wheelie",
    "CiaWheelie"
}) do
    local previousGui = playerGui:FindFirstChild(oldName)

    if previousGui then
        previousGui:Destroy()
    end
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

local function label(
    parent, text, x, y, w, h, size, color, bold
)
    local obj = Instance.new("TextLabel")
    obj.BackgroundTransparency = 1
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.Text = text
    obj.TextSize = size
    obj.TextColor3 = color or C.white
    obj.Font =
        bold and Enum.Font.GothamBold or Enum.Font.Gotham
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

-- ============================================================
-- MAIN WINDOW
-- ============================================================

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(380, 554)
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

    if not camera then
        return
    end

    local view = camera.ViewportSize

    scale.Scale = math.min(
        1,
        math.max(0.1, (view.X - 24) / 380),
        math.max(0.1, (view.Y - 24) / 554)
    )
end

local cameraConn

local function watchCamera()
    if cameraConn then
        cameraConn:Disconnect()
    end

    local camera = workspace.CurrentCamera

    if camera then
        cameraConn = camera:GetPropertyChangedSignal(
            "ViewportSize"
        ):Connect(fitWindow)
    end

    fitWindow()
end

table.insert(
    uiConnections,
    workspace:GetPropertyChangedSignal(
        "CurrentCamera"
    ):Connect(watchCamera)
)

watchCamera()

-- ============================================================
-- HEADER
-- ============================================================

local titleBar = Instance.new("TextButton", main)
titleBar.Size = UDim2.fromOffset(304, 72)
titleBar.Position = UDim2.fromOffset(16, 6)
titleBar.BackgroundTransparency = 1
titleBar.Text = ""
titleBar.AutoButtonColor = false

local logo = panel(titleBar, 4, 16, 42, 42)
logo.BackgroundColor3 = C.green

local logoText = label(
    logo, "CW",
    0, 0, 42, 42,
    16, C.base, true
)

logoText.TextXAlignment = Enum.TextXAlignment.Center

label(
    titleBar, "CiaWheelie",
    58, 17, 164, 25,
    22, C.white, true
)

label(
    titleBar, "PRECISION RIDE CONTROL",
    58, 43, 200, 14,
    9, C.muted, true
)

local version = label(
    titleBar, "v1",
    230, 20, 34, 21,
    12, C.green, true
)

version.TextXAlignment = Enum.TextXAlignment.Center

local closeBtn = button(
    main, "×",
    330, 24, 30, 30
)

closeBtn.TextSize = 23
closeBtn.TextColor3 = C.muted

closeBtn.Activated:Connect(function()
    gui:Destroy()
end)

label(
    main, "YOUR ANGLE. YOUR PACE.",
    20, 79, 230, 16,
    10, C.muted, true
)

local stateBadge = label(
    main, "READY",
    270, 79, 90, 16,
    10, C.muted, true
)

stateBadge.TextXAlignment = Enum.TextXAlignment.Right

-- ============================================================
-- MAIN TOGGLE AND STATUS
-- ============================================================

local wheelieBtn = button(
    main, "ENABLE AUTO WHEELIE",
    20, 106, 340, 48
)

wheelieBtn.BackgroundColor3 = C.green
wheelieBtn.TextColor3 = C.base
wheelieBtn.TextSize = 14

local statusCard = panel(
    main, 20, 166, 340, 60
)

infoText = label(
    statusCard, status,
    14, 9, 312, 42,
    11, C.muted, false
)

infoText.TextWrapped = true
infoText.TextYAlignment = Enum.TextYAlignment.Center

-- ============================================================
-- RETURN DELAY SLIDER
-- ============================================================

local sliderCard = panel(
    main, 20, 238, 340, 104
)

label(
    sliderCard, "RETURN TO START",
    14, 11, 205, 20,
    10, C.white, true
)

local intervalLabel = label(
    sliderCard, "1.0s",
    239, 8, 87, 26,
    21, C.green, true
)

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

label(
    sliderCard, "0.1s",
    14, 77, 45, 14,
    10, C.muted
)

local sliderHint = label(
    sliderCard, "DRAG TO ADJUST",
    95, 77, 150, 14,
    9, C.muted
)

sliderHint.TextXAlignment = Enum.TextXAlignment.Center

local maxLabel = label(
    sliderCard, "10s",
    279, 77, 47, 14,
    10, C.muted
)

maxLabel.TextXAlignment = Enum.TextXAlignment.Right

local function drawSlider()
    local ratio = (returnInterval - 0.1) / 9.9

    fill.Size = UDim2.fromScale(ratio, 1)
    knob.Position = UDim2.fromScale(ratio, 0.5)
    intervalLabel.Text = string.format("%.1fs", returnInterval)
end

local function setSliderAt(x)
    if sliderHit.AbsoluteSize.X <= 0 then
        return
    end

    local value = intervalFromRatio(
        (x - sliderHit.AbsolutePosition.X)
        / sliderHit.AbsoluteSize.X
    )

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
        setSliderAt(input.Position.X)
    end
end)

table.insert(
    uiConnections,
    UserInputService.InputChanged:Connect(function(input)
        if not sliderInput then
            return
        end

        if input == sliderInput
            or (
                sliderInput.UserInputType
                    == Enum.UserInputType.MouseButton1
                and input.UserInputType
                    == Enum.UserInputType.MouseMovement
            ) then
            setSliderAt(input.Position.X)
        end
    end)
)

table.insert(
    uiConnections,
    UserInputService.InputEnded:Connect(function(input)
        if input == sliderInput
            or input.UserInputType
                == Enum.UserInputType.MouseButton1 then
            sliderInput = nil
        end
    end)
)

drawSlider()

-- ============================================================
-- STARTING POINT BUTTON
-- ============================================================

local startBtn = button(
    main, "SET STARTING POINT HERE",
    20, 354, 340, 42
)

border(startBtn)

startBtn.Activated:Connect(function()
    local scooter = findScooter()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")

    local root =
        scooter and getBody(scooter, hum and hum.SeatPart)

    if not root then
        showStatus("Ride your scooter to save a start point.")
        return
    end

    saveStartingPoint(root)
    showStatus("Starting point saved. Return timer restarted.")
end)

startLabel = label(
    main,
    "Start point saves automatically when hold begins.",
    20, 405, 340, 18,
    10, C.muted
)

startLabel.TextXAlignment = Enum.TextXAlignment.Center

-- ============================================================
-- OPTIONAL ANTI-AFK (independent of the wheelie toggle)
-- Best effort: executor support and idle-timer behavior vary.
-- ============================================================

local antiAfkEnabled = false
local antiAfkConn
local antiAfkUser
local antiAfkDisposed = false

local antiAfkCard = panel(main, 20, 434, 340, 72)
label(antiAfkCard, "ANTI-AFK", 14, 10, 190, 18, 11, C.white, true)
local antiAfkHint = label(
    antiAfkCard, "Off", 14, 33, 224, 30, 10, C.muted
)
antiAfkHint.TextWrapped = true
local antiAfkBtn = button(antiAfkCard, "OFF", 254, 18, 72, 34)
border(antiAfkBtn)

local function drawAntiAfk(message, failed)
    antiAfkBtn.Text = antiAfkEnabled and "ON" or "OFF"
    antiAfkBtn.BackgroundColor3 = antiAfkEnabled and C.green or C.base
    antiAfkBtn.TextColor3 = antiAfkEnabled and C.base or C.muted
    antiAfkHint.Text = message
    antiAfkHint.TextColor3 = failed and C.amber or C.muted
end

local function setAntiAfk(state)
    if antiAfkConn then
        antiAfkConn:Disconnect()
        antiAfkConn = nil
    end
    antiAfkEnabled = false

    if not state or antiAfkDisposed then
        drawAntiAfk("Off")
        return
    end

    local ok, err = pcall(function()
        antiAfkUser = game:GetService("VirtualUser")
        antiAfkUser:CaptureController()
    end)
    if not ok then
        drawAntiAfk("Input unavailable; see console.", true)
        warn("[CiaWheelie] Anti-AFK unavailable: " .. tostring(err))
        return
    end

    antiAfkEnabled = true
    drawAntiAfk("On - waiting for idle")
    antiAfkConn = lp.Idled:Connect(function()
        if not antiAfkEnabled or antiAfkDisposed then return end
        if UserInputService:GetFocusedTextBox() then
            drawAntiAfk("On - paused during text entry")
            return
        end
        local camera = workspace.CurrentCamera
        if not camera then
            drawAntiAfk("On - waiting for camera")
            return
        end

        local sent, reason = pcall(function()
            antiAfkUser:CaptureController()
            antiAfkUser:ClickButton2(Vector2.new(0, 0), camera.CFrame)
        end)
        if not antiAfkEnabled or antiAfkDisposed then return end
        if sent then
            drawAntiAfk("On - idle input sent")
        else
            antiAfkEnabled = false
            if antiAfkConn then
                antiAfkConn:Disconnect()
                antiAfkConn = nil
            end
            drawAntiAfk("Input failed; see console.", true)
            warn("[CiaWheelie] Anti-AFK input failed: " .. tostring(reason))
        end
    end)
end

antiAfkBtn.Activated:Connect(function()
    setAntiAfk(not antiAfkEnabled)
end)
drawAntiAfk("Off - click to enable")

local footer = label(
    main,
    "W  ACCELERATE     /     S  BRAKE     /     ANGLE LOCK",
    20, 524, 340, 12,
    9, C.muted
)

footer.TextXAlignment = Enum.TextXAlignment.Center

-- ============================================================
-- GUI STATE
-- ============================================================

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

wheelieBtn.Activated:Connect(function()
    setWheelie(not wheelieActive)
end)

updateWheelieUI()

-- ============================================================
-- MOUSE / TOUCH WINDOW DRAGGING
-- ============================================================

local dragInput, dragStart, frameStart

local function dragTo(position)
    local delta = position - dragStart

    main.Position = UDim2.new(
        frameStart.X.Scale,
        frameStart.X.Offset + delta.X,
        frameStart.Y.Scale,
        frameStart.Y.Offset + delta.Y
    )
end

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
        dragStart = input.Position
        frameStart = main.Position
    end
end)

table.insert(
    uiConnections,
    UserInputService.InputChanged:Connect(function(input)
        if not dragInput then
            return
        end

        if input == dragInput
            or (
                dragInput.UserInputType
                    == Enum.UserInputType.MouseButton1
                and input.UserInputType
                    == Enum.UserInputType.MouseMovement
            ) then
            dragTo(input.Position)
        end
    end)
)

table.insert(
    uiConnections,
    UserInputService.InputEnded:Connect(function(input)
        if input == dragInput
            or input.UserInputType
                == Enum.UserInputType.MouseButton1 then
            dragInput = nil
        end
    end)
)

-- ============================================================
-- CLEANUP
-- ============================================================

gui.Destroying:Connect(function()
    antiAfkDisposed = true
    setAntiAfk(false)
    stopMotion()

    characterConn:Disconnect()
    focusConn:Disconnect()
    textConn:Disconnect()

    if cameraConn then
        cameraConn:Disconnect()
    end

    for _, connection in ipairs(uiConnections) do
        connection:Disconnect()
    end

    updateWheelieUI = function() end
    infoText, startLabel = nil, nil
end)

-- ============================================================
-- FLOATING SHOW / HIDE BUTTON
-- Hiding the menu does not stop the wheelie.
-- Closing with X stops the script and removes the GUI.
-- ============================================================

local menuToggle = button(
    gui, "CW",
    0, 0, 56, 56
)

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

    menuToggle.BackgroundColor3 =
        main.Visible and C.green or C.card

    menuToggle.TextColor3 =
        main.Visible and C.base or C.green
end)

print(
    "[CiaWheelie v1] Loaded — W/S speed hold, "
    .. "angle lock, saved return point, floating toggle"
)
