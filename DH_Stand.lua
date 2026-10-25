--[[
    DH Stand — Da Hood multi-bot stand (GUI controlled)
    Prefix (internal): dhstand:!
    Bots listen to the controller; GUI sends commands (bots never need to type chat).
    Formations: teleport + hold (do not follow).
    Summon: stand glue behind controller in a horizontal line.
]]

-- ===================== CONFIG =====================
local PREFIX = "dhstand:!"
local ControllerName = nil          -- set automatically when you open GUI / press Setup as host
local MySlot = 1                    -- assigned by !setup (1..N)
local BotCountHint = 8              -- used for square spacing if unknown
local SUMMON_BACK = 4
local SUMMON_SPACING = 3.2
local SUMMON_HEIGHT = 1.0
local FLOAT_HEIGHT = 12
local LINE_SPACING = 3.0
local DEFAULT_AUTODROP = 20000       -- !autodrop default per drop tick
local DROP_INTERVAL = 1.15          -- seconds between drops
local WEBHOOK_URL = ""              -- set in GUI; Discord webhook
local COMMAND_POLL = false          -- optional HTTP poll for multi-device (set CommandServerURL)
local CommandServerURL = ""         -- raw JSON endpoint returning {cmd="setup", args={}}

-- Da Hood locations (edit if your copy uses different coords)
local LOCATIONS = {
    bank       = CFrame.new(-446, 22, -285),
    uphill     = CFrame.new( 472, 48, -640),
    casino     = CFrame.new(-947, 21, -220),
    ["admin base"] = CFrame.new(-687, 42, -512),
    adminbase  = CFrame.new(-687, 42, -512),
    admin      = CFrame.new(-687, 42, -512),
}

local FLY_ANIM_ID = "rbxassetid://3541044388"
local HOVER_ANIM_ID = "rbxassetid://973771746"
local Emotes = {
    Floss = "rbxassetid://10714340543",
    ["Yungblud Happier Jump"] = "rbxassetid://15609995579",
    ["take the L"] = "rbxassetid://118343267142519",
    darktriad = "rbxassetid://131564504226925",
}
-- ==================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local MainEvent = ReplicatedStorage:FindFirstChild("MainEvent")
task.spawn(function()
    if not MainEvent then
        pcall(function() MainEvent = ReplicatedStorage:WaitForChild("MainEvent", 12) end)
    end
end)

-- state
local Mode = "idle"           -- idle | summon | setup | location | line | float
local HoldCF = nil            -- static formation CFrame (stay here)
local GlueActive = false
local GlueConn = nil
local GlueTarget = nil        -- Player for summon glue
local DanceTrack = nil
local DanceId = nil
local DanceOn = false
local FloatOn = false
local AutodropOn = false
local AutodropConn = nil
local DropAmountEach = DEFAULT_AUTODROP  -- per-bot drop amount
local TargetTotalDrop = nil              -- optional shared total (amount command)
local ContinueWithoutController = true
local KnownBots = {}          -- [name] = true (local registry + chat announce)
local Gui = nil
local IsHost = false          -- this client owns the control GUI
local LastCmdId = 0

getgenv().DH_STAND = getgenv().DH_STAND or {}
getgenv().DH_STAND.Slot = MySlot
getgenv().DH_STAND.Version = "1.0"

-- ---------- utils ----------
local function notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title or "DH Stand", Text = text or "", Duration = 4 })
    end)
end

local function getRoot(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
        or (char:FindFirstChildOfClass("Humanoid") and char:FindFirstChildOfClass("Humanoid").RootPart)
end

local function getSelfRoot()
    local char = LocalPlayer.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    return hum.RootPart or char:FindFirstChild("HumanoidRootPart")
end

local function SetPhysicsRepRootPart(selfRoot, targetPart)
    if not sethiddenproperty or not selfRoot or not targetPart then return end
    pcall(function()
        sethiddenproperty(selfRoot, "PhysicsRepRootPart", targetPart)
        if InstanceHandle then
            pcall(function()
                sethiddenproperty(selfRoot, "PhysicsRepRootRef", InstanceHandle.new(targetPart))
            end)
        end
    end)
end

local function resetVel(r)
    if not r then return end
    r.AssemblyLinearVelocity = Vector3.zero
    r.AssemblyAngularVelocity = Vector3.zero
end

local function FindPlayer(name)
    if not name or name == "" then return nil end
    local q = name:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == q or (p.DisplayName and p.DisplayName:lower() == q) then return p end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1, #q) == q or (p.DisplayName and p.DisplayName:lower():sub(1, #q) == q) then
            return p
        end
    end
    return nil
end

local function GetController()
    if ControllerName then
        local p = FindPlayer(ControllerName)
        if p then return p end
    end
    return nil
end

local function IsController(p)
    if not p then return false end
    if ControllerName and p.Name:lower() == tostring(ControllerName):lower() then return true end
    return false
end

-- ---------- Discord webhook ----------
local function webhook(content, embed)
    if not WEBHOOK_URL or WEBHOOK_URL == "" then return end
    task.spawn(function()
        pcall(function()
            local body = {
                content = content,
                embeds = embed and { embed } or nil,
                username = "DH Stand",
            }
            local req = (syn and syn.request) or (http and http.request) or request or http_request
            if req then
                req({
                    Url = WEBHOOK_URL,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(body),
                })
            else
                HttpService:PostAsync(WEBHOOK_URL, HttpService:JSONEncode(body), Enum.HttpContentType.ApplicationJson)
            end
        end)
    end)
end

local function webhookEmbed(title, desc, color)
    webhook(nil, {
        title = title,
        description = desc,
        color = color or 5793266,
        timestamp = DateTime.now():ToIsoDate(),
    })
end

-- ---------- chat send (controller GUI → bots) ----------
local function sendCommand(line)
    local msg = PREFIX .. line
    -- broadcast table for same-environment tools
    getgenv().DH_STAND.LastCommand = { line = line, t = tick(), from = LocalPlayer.Name }
    pcall(function()
        local channels = TextChatService:FindFirstChild("TextChannels")
        local ch = channels and (channels:FindFirstChild("RBXGeneral") or channels:GetChildren()[1])
        if ch and ch.SendAsync then
            ch:SendAsync(msg)
            return
        end
    end)
    pcall(function()
        local chat = game:GetService("Chat")
        if chat and chat.SubmitChatMessage then
            chat:SubmitChatMessage(msg)
        end
    end)
    -- legacy
    pcall(function()
        local rs = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        local say = rs and rs:FindFirstChild("SayMessageRequest")
        if say then say:FireServer(msg, "All") end
    end)
end

-- ---------- glue (from stand) ----------
local function stopGlue()
    GlueActive = false
    if GlueConn then GlueConn:Disconnect() GlueConn = nil end
    local r = getSelfRoot()
    if r then
        r.CanCollide = true
        SetPhysicsRepRootPart(r, r)
        resetVel(r)
    end
    GlueTarget = nil
end

local function startGlueToCF(getDest, targetPlayer)
    stopGlue()
    GlueActive = true
    GlueTarget = targetPlayer
    GlueConn = RunService.Heartbeat:Connect(function()
        if not GlueActive then return end
        local selfRoot = getSelfRoot()
        if not selfRoot then return end
        local dest = getDest(selfRoot)
        local tRoot = targetPlayer and targetPlayer.Character and getRoot(targetPlayer.Character)
        if tRoot then
            SetPhysicsRepRootPart(selfRoot, tRoot)
            selfRoot.CanCollide = false
        else
            SetPhysicsRepRootPart(selfRoot, selfRoot)
        end
        if dest then
            resetVel(selfRoot)
            selfRoot.CFrame = dest
        end
    end)
end

-- Static hold (formations / location) — teleport and STAY, do not follow
local function holdAt(cf)
    Mode = "location"
    HoldCF = cf
    stopGlue()
    startGlueToCF(function()
        return HoldCF
    end, nil)
end

local function stopHold()
    HoldCF = nil
    if Mode == "location" or Mode == "setup" or Mode == "line" then
        Mode = "idle"
    end
    stopGlue()
end

-- ---------- dances / float ----------
local function stopDance()
    DanceOn = false
    DanceId = nil
    pcall(function() if DanceTrack then DanceTrack:Stop() end end)
    DanceTrack = nil
end

local function playDance(id)
    id = id or Emotes.Floss
    DanceOn = true
    DanceId = id
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
    pcall(function()
        if DanceTrack then DanceTrack:Stop() end
        local a = Instance.new("Animation")
        a.AnimationId = id
        DanceTrack = animator:LoadAnimation(a)
        DanceTrack.Looped = true
        DanceTrack.Priority = Enum.AnimationPriority.Action4
        DanceTrack:Play(0.1, 1, 1)
    end)
end

local function ensureDance()
    if DanceOn and DanceId then
        if not DanceTrack or not DanceTrack.IsPlaying then
            playDance(DanceId)
        end
    end
end

local floatConn = nil
local function setFloat(on)
    FloatOn = on
    if floatConn then floatConn:Disconnect() floatConn = nil end
    if not on then return end
    floatConn = RunService.Heartbeat:Connect(function()
        if not FloatOn then return end
        local r = getSelfRoot()
        if not r then return end
        -- hover in place relative to current hold / summon offset
        local base = HoldCF and HoldCF.Position or r.Position
        local pos = Vector3.new(base.X, base.Y + (HoldCF and 0 or 0) + (HoldCF and FLOAT_HEIGHT * 0 or FLOAT_HEIGHT), base.Z)
        if HoldCF then
            pos = HoldCF.Position + Vector3.new(0, FLOAT_HEIGHT, 0)
        end
        resetVel(r)
        r.CFrame = CFrame.new(pos) * (HoldCF and HoldCF.Rotation or r.CFrame.Rotation)
    end)
end

-- ---------- wallet / cash drop ----------
local function equipWallet()
    local char = LocalPlayer.Character
    local bag = LocalPlayer:FindFirstChild("Backpack")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local function findWallet(parent)
        if not parent then return nil end
        for _, t in ipairs(parent:GetChildren()) do
            if t:IsA("Tool") and t.Name:lower():find("wallet") then return t end
        end
        return nil
    end
    local w = findWallet(char) or findWallet(bag)
    if not w then return false end
    pcall(function()
        if w.Parent == bag then
            hum:UnequipTools()
            w.Parent = char
        else
            hum:EquipTool(w)
        end
    end)
    return true
end

local function getCash()
    -- DataFolder / leaderstats variants
    local ok, val = pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        if ls then
            local c = ls:FindFirstChild("Cash") or ls:FindFirstChild("Money")
            if c then return tonumber(c.Value) or 0 end
        end
        local df = LocalPlayer:FindFirstChild("DataFolder") or LocalPlayer:FindFirstChild("Data")
        if df then
            local c = df:FindFirstChild("Currency") or df:FindFirstChild("Cash") or df:FindFirstChild("Money")
            if c then return tonumber(c.Value) or 0 end
        end
        return 0
    end)
    return ok and val or 0
end

local function dropCash(amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return end
    equipWallet()
    -- Common Da Hood drop remotes (try several)
    pcall(function()
        if MainEvent then
            MainEvent:FireServer("DropMoney", amount)
        end
    end)
    pcall(function()
        if MainEvent then
            MainEvent:FireServer("DropCash", amount)
        end
    end)
    pcall(function()
        local inv = ReplicatedStorage:FindFirstChild("MainRemotes") or ReplicatedStorage
        local r = inv:FindFirstChild("DropMoney")
        if r then r:FireServer(amount) end
    end)
end

local function startAutodrop()
    AutodropOn = true
    if AutodropConn then AutodropConn:Disconnect() end
    AutodropConn = RunService.Heartbeat:Connect(function()
        if not AutodropOn then return end
        -- allow continue after controller left
        if not ContinueWithoutController then
            local c = GetController()
            if not c then return end
        end
        -- rate limit via attribute
        local last = getgenv().DH_STAND._lastDrop or 0
        if tick() - last < DROP_INTERVAL then return end
        getgenv().DH_STAND._lastDrop = tick()
        local each = DropAmountEach
        if each > 0 then
            dropCash(each)
        end
    end)
    notify("DH Stand", "Autodrop ON — " .. tostring(DropAmountEach) .. " each")
end

local function stopAutodrop()
    AutodropOn = false
    if AutodropConn then AutodropConn:Disconnect() AutodropConn = nil end
    notify("DH Stand", "Autodrop OFF")
end

-- ---------- formations ----------
local function squareOffset(slot, total)
    total = math.max(total, 1)
    local side = math.ceil(math.sqrt(total))
    local i = (slot - 1) % total
    local row = math.floor(i / side)
    local col = i % side
    local spacing = 4.5
    local cx = (side - 1) * spacing * 0.5
    local cz = (side - 1) * spacing * 0.5
    return Vector3.new(col * spacing - cx, 0, row * spacing - cz)
end

local function doSetup(totalBots)
    totalBots = tonumber(totalBots) or BotCountHint
    MySlot = MySlot or 1
    getgenv().DH_STAND.Slot = MySlot
    local c = GetController()
    local baseCF
    if c and c.Character and getRoot(c.Character) then
        baseCF = getRoot(c.Character).CFrame
    else
        local r = getSelfRoot()
        baseCF = r and r.CFrame or CFrame.new()
    end
    local off = squareOffset(MySlot, totalBots)
    local dest = baseCF * CFrame.new(off)
    Mode = "setup"
    holdAt(dest)
    notify("DH Stand", "Setup square slot " .. MySlot)
end

local function doLocation(place)
    place = (place or ""):lower():gsub("_", " ")
    local cf = LOCATIONS[place] or LOCATIONS[place:gsub(" ", "")]
    if not cf then
        notify("DH Stand", "Unknown place: " .. tostring(place))
        return
    end
    -- slight slot offset so bots don't stack
    local ang = ((MySlot or 1) - 1) * (math.pi * 2 / 12)
    local dest = cf * CFrame.new(math.cos(ang) * 3, 0, math.sin(ang) * 3)
    Mode = "location"
    holdAt(dest)
    notify("DH Stand", "Location → " .. place)
end

local function doSummon()
    local c = GetController()
    if not c or not c.Character then
        notify("DH Stand", "No controller")
        return
    end
    Mode = "summon"
    HoldCF = nil
    FloatOn = false
    startGlueToCF(function()
        local tRoot = c.Character and getRoot(c.Character)
        if not tRoot then return nil end
        -- horizontal line behind controller (stando-style)
        local slot = MySlot or 1
        -- center the line around controller back
        local index = slot - 1
        local x = (index - (BotCountHint - 1) * 0.5) * SUMMON_SPACING
        -- if we don't know total, use slot-based offset from center-ish
        x = (slot - 1 - 3.5) * SUMMON_SPACING
        local pos = tRoot.Position
            - tRoot.CFrame.LookVector * SUMMON_BACK
            + tRoot.CFrame.RightVector * x
            + Vector3.new(0, SUMMON_HEIGHT, 0)
        return CFrame.new(pos, pos + tRoot.CFrame.LookVector)
    end, c)
    notify("DH Stand", "Summon (glue line)")
end

local function doSingleFile()
    local c = GetController()
    if not c or not c.Character then return end
    local tRoot = getRoot(c.Character)
    if not tRoot then return end
    local slot = MySlot or 1
    local pos = tRoot.Position
        - tRoot.CFrame.LookVector * (SUMMON_BACK + (slot - 1) * LINE_SPACING)
        + Vector3.new(0, SUMMON_HEIGHT, 0)
    local dest = CFrame.new(pos, pos + tRoot.CFrame.LookVector)
    Mode = "line"
    holdAt(dest) -- stay in single file (static), not follow
    notify("DH Stand", "Single file line")
end

local function doLeave()
    webhookEmbed("Bot left", LocalPlayer.Name .. " leaving", 15158332)
    pcall(function() LocalPlayer:Kick("DH Stand leave") end)
end

local function doRejoin()
    webhookEmbed("Bot rejoining", LocalPlayer.Name .. " teleporting back", 3447003)
    pcall(function()
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    end)
end

-- ---------- amount distribution ----------
-- Controller sets total; each bot drops total/numBots
local function setAmountTotal(total, botCount)
    total = tonumber(total) or 0
    botCount = math.max(tonumber(botCount) or BotCountHint, 1)
    DropAmountEach = math.floor(total / botCount)
    if DropAmountEach < 1 and total > 0 then DropAmountEach = 1 end
    notify("DH Stand", "Each drops " .. tostring(DropAmountEach) .. " (total " .. tostring(total) .. " / " .. botCount .. ")")
end

-- ---------- command handler ----------
local function handleCommand(fromPlayer, body)
    if not body or body == "" then return end
    body = body:match("^%s*(.-)%s*$")
    local args = {}
    for w in body:gmatch("%S+") do args[#args + 1] = w end
    local cmd = args[1] and args[1]:lower()
    if not cmd then return end

    -- only accept from controller (or self if host testing)
    if fromPlayer and not IsController(fromPlayer) and fromPlayer ~= LocalPlayer then
        -- allow host to command self
        if not (IsHost and fromPlayer == LocalPlayer) then
            return
        end
    end

    if cmd == "setup" then
        local n = tonumber(args[2]) or BotCountHint
        BotCountHint = n
        -- assign slots by sorted bot names that announced
        local names = {}
        for name in pairs(KnownBots) do names[#names + 1] = name end
        if #names == 0 then
            -- fallback: all players except controller
            for _, p in ipairs(Players:GetPlayers()) do
                if not IsController(p) then names[#names + 1] = p.Name end
            end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        local my = LocalPlayer.Name
        for i, nme in ipairs(names) do
            if nme:lower() == my:lower() then MySlot = i break end
        end
        getgenv().DH_STAND.Slot = MySlot
        BotCountHint = math.max(#names, n)
        doSetup(BotCountHint)

    elseif cmd == "location" then
        local place = table.concat(args, " ", 2)
        doLocation(place)

    elseif cmd == "wallet" then
        equipWallet()

    elseif cmd == "autodrop" then
        if args[2] == "off" then
            stopAutodrop()
        else
            if not tonumber(args[2]) then
                DropAmountEach = DEFAULT_AUTODROP
            else
                DropAmountEach = tonumber(args[2])
            end
            startAutodrop()
        end

    elseif cmd == "amount" then
        local total = tonumber(args[2])
        local bots = tonumber(args[3]) or BotCountHint
        if total then
            setAmountTotal(total, bots)
            startAutodrop()
            webhookEmbed("Amount set", string.format("Total **%s** across **%s** bots → **%s** each\nBy: %s",
                tostring(total), tostring(bots), tostring(DropAmountEach), fromPlayer and fromPlayer.Name or "?"), 15844367)
        end

    elseif cmd == "summon" then
        doSummon()

    elseif cmd == "line" or cmd == "singlefile" then
        doSingleFile()

    elseif cmd == "stop" or cmd == "idle" then
        stopAutodrop()
        stopHold()
        stopGlue()
        setFloat(false)
        Mode = "idle"

    elseif cmd == "dance" then
        if args[2] == "off" then
            stopDance()
        else
            local key = args[2] and args[2]:lower()
            if key == "floss" then playDance(Emotes.Floss)
            elseif key == "happier" or key == "jump" then playDance(Emotes["Yungblud Happier Jump"])
            elseif key == "takel" or key == "l" then playDance(Emotes["take the L"])
            elseif key == "dark" or key == "darktriad" then playDance(Emotes.darktriad)
            else playDance(Emotes.Floss) end
        end

    elseif cmd == "float" then
        if args[2] == "off" then setFloat(false) else setFloat(true) end

    elseif cmd == "leave" then
        doLeave()

    elseif cmd == "rejoin" then
        doRejoin()

    elseif cmd == "slot" and args[2] then
        local n = tonumber(args[2])
        if n then MySlot = math.floor(n) getgenv().DH_STAND.Slot = MySlot end

    elseif cmd == "bots" and args[2] then
        BotCountHint = tonumber(args[2]) or BotCountHint

    elseif cmd == "ping" then
        -- presence announce
        KnownBots[LocalPlayer.Name] = true
    end
end

local function parsePrefix(msg)
    if not msg then return nil end
    local lower = msg:lower()
    local p = PREFIX:lower()
    if lower:sub(1, #p) == p then
        return msg:sub(#PREFIX + 1)
    end
    -- also accept bare !setup style from GUI notes
    if msg:sub(1, 1) == "!" then
        return msg:sub(2)
    end
    return nil
end

local function onChatted(player, message)
    local body = parsePrefix(message)
    if not body then return end
    -- first message from someone claiming control via GUI sets controller if unset
    if not ControllerName and player then
        -- don't auto-steal; only GUI host sets controller
    end
    handleCommand(player, body)
end

for _, p in ipairs(Players:GetPlayers()) do
    p.Chatted:Connect(function(m) onChatted(p, m) end)
end
Players.PlayerAdded:Connect(function(p)
    p.Chatted:Connect(function(m) onChatted(p, m) end)
    webhookEmbed("Player joined", p.Name .. " joined the server", 5763719)
    task.defer(function()
        if Gui and Gui:FindFirstChild("RefreshBots") then
            pcall(function() Gui.RefreshBots() end)
        end
    end)
end)
Players.PlayerRemoving:Connect(function(p)
    KnownBots[p.Name] = nil
    webhookEmbed("Player left", p.Name .. " left the server", 15158332)
    if IsController(p) and not ContinueWithoutController then
        -- pause autodrop only if configured
    end
end)

-- announce self as bot
KnownBots[LocalPlayer.Name] = true
task.spawn(function()
    task.wait(2)
    -- soft presence so setup can sort slots
    pcall(function() sendCommand("ping") end)
end)

-- anti-afk
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.zero)
    end)
end)
task.spawn(function()
    while task.wait(2) do
        pcall(function()
            if MainEvent then MainEvent:FireServer("RequestAFKDisplay", true) end
        end)
        ensureDance()
    end
end)

-- optional HTTP command poll (multi-device without relying on in-game chat delivery)
task.spawn(function()
    while task.wait(1.25) do
        if not COMMAND_POLL or not CommandServerURL or CommandServerURL == "" then continue end
        pcall(function()
            local req = (syn and syn.request) or request or http_request
            local res
            if req then
                res = req({ Url = CommandServerURL, Method = "GET" })
                res = res and res.Body
            else
                res = HttpService:GetAsync(CommandServerURL)
            end
            if not res then return end
            local data = HttpService:JSONDecode(res)
            if type(data) == "table" and data.id and data.id ~= LastCmdId and data.cmd then
                LastCmdId = data.id
                handleCommand(GetController() or LocalPlayer, tostring(data.cmd) .. (data.args and (" " .. table.concat(data.args, " ")) or ""))
            end
        end)
    end
end)

-- watch getgenv bus
task.spawn(function()
    local last = 0
    while task.wait(0.2) do
        local lc = getgenv().DH_STAND and getgenv().DH_STAND.LastCommand
        if lc and lc.t and lc.t ~= last and lc.from then
            last = lc.t
            if lc.from ~= LocalPlayer.Name then
                -- only process if from controller
                if ControllerName and lc.from:lower() == ControllerName:lower() then
                    handleCommand(FindPlayer(lc.from) or LocalPlayer, lc.line)
                end
            end
        end
    end
end)

-- ---------- GUI ----------
local function createGui()
    if Gui then Gui:Destroy() end
    IsHost = true
    ControllerName = LocalPlayer.Name

    Gui = Instance.new("ScreenGui")
    Gui.Name = "DH_StandGui"
    Gui.ResetOnSpawn = false
    Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    pcall(function() Gui.Parent = game:GetService("CoreGui") end)
    if not Gui.Parent then Gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local SIDE = 72
    local PANEL_W, PANEL_H = 260, 380

    local shell = Instance.new("Frame")
    shell.Size = UDim2.new(0, SIDE, 0, PANEL_H)
    shell.Position = UDim2.new(0, 12, 0.5, -PANEL_H / 2)
    shell.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    shell.BorderSizePixel = 0
    shell.Parent = Gui
    Instance.new("UICorner", shell).CornerRadius = UDim.new(0, 10)

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0, 0, 0, PANEL_H)
    panel.Position = UDim2.new(0, SIDE + 6, 0, 0)
    panel.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.ClipsDescendants = true
    panel.Parent = shell
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, -12, 1, -12)
    page.Position = UDim2.new(0, 6, 0, 6)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 4
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.Parent = panel

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 6)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = page

    local openTabName, animating = nil, false
    local tabButtons = {}

    local function clearPage()
        for _, c in ipairs(page:GetChildren()) do
            if not c:IsA("UIListLayout") then c:Destroy() end
        end
    end

    local function addLabel(text)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 18)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.GothamBold
        l.TextSize = 12
        l.TextColor3 = Color3.fromRGB(160, 160, 175)
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Text = text
        l.Parent = page
        return l
    end

    local function addBtn(text, fn, color)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, 30)
        b.BackgroundColor3 = color or Color3.fromRGB(40, 42, 55)
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(235, 235, 245)
        b.Text = text
        b.Parent = page
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        b.MouseButton1Click:Connect(function()
            pcall(fn)
        end)
        return b
    end

    local function addBox(placeholder)
        local t = Instance.new("TextBox")
        t.Size = UDim2.new(1, 0, 0, 28)
        t.BackgroundColor3 = Color3.fromRGB(32, 34, 44)
        t.BorderSizePixel = 0
        t.Font = Enum.Font.Gotham
        t.TextSize = 12
        t.TextColor3 = Color3.fromRGB(230, 230, 240)
        t.PlaceholderText = placeholder or ""
        t.PlaceholderColor3 = Color3.fromRGB(110, 110, 125)
        t.Text = ""
        t.ClearTextOnFocus = false
        t.Parent = page
        Instance.new("UICorner", t).CornerRadius = UDim.new(0, 6)
        return t
    end

    local function fire(cmd)
        sendCommand(cmd)
        -- also run locally so host bot acts too
        handleCommand(LocalPlayer, cmd)
    end

    local amountBox, webhookBox, botsLabel

    local function buildMain()
        clearPage()
        addLabel("commands")
        addBtn("setup (square)", function()
            local n = #Players:GetPlayers() - 1
            if n < 1 then n = BotCountHint end
            fire("bots " .. n)
            fire("setup " .. n)
        end, Color3.fromRGB(50, 90, 160))
        addBtn("summon (glue line)", function() fire("summon") end, Color3.fromRGB(50, 120, 90))
        addBtn("single file line", function() fire("line") end)
        addBtn("stop / idle", function() fire("stop") end, Color3.fromRGB(120, 50, 50))
        addLabel("location")
        for _, place in ipairs({ "bank", "uphill", "casino", "admin base" }) do
            addBtn(place, function() fire("location " .. place) end)
        end
        addLabel("cash")
        addBtn("wallet (all)", function() fire("wallet") end)
        addBtn("autodrop 20k", function() fire("autodrop") end, Color3.fromRGB(40, 130, 70))
        addBtn("autodrop off", function() fire("autodrop off") end)
        amountBox = addBox("total amount e.g. 25000000")
        addBtn("set amount (split)", function()
            local total = tonumber(amountBox.Text)
            if not total then notify("DH Stand", "Enter a number") return end
            local bots = math.max(#Players:GetPlayers() - 1, 1)
            fire("amount " .. tostring(total) .. " " .. tostring(bots))
        end, Color3.fromRGB(140, 100, 40))
        addLabel("cash each: " .. tostring(DropAmountEach))
    end

    local function buildActions()
        clearPage()
        addLabel("animation")
        addBtn("dance floss", function() fire("dance floss") end)
        addBtn("dance happier", function() fire("dance happier") end)
        addBtn("dance take L", function() fire("dance takel") end)
        addBtn("dance darktriad", function() fire("dance dark") end)
        addBtn("dance off", function() fire("dance off") end)
        addBtn("float on", function() fire("float") end, Color3.fromRGB(60, 80, 140))
        addBtn("float off", function() fire("float off") end)
        addLabel("session")
        addBtn("leave all bots", function() fire("leave") end, Color3.fromRGB(140, 40, 40))
        addBtn("rejoin all bots", function() fire("rejoin") end, Color3.fromRGB(40, 100, 140))
        addLabel("controller left → keep drop")
        addBtn(ContinueWithoutController and "keep drop: ON" or "keep drop: OFF", function(btn)
            ContinueWithoutController = not ContinueWithoutController
            -- rebuild to refresh label
            buildActions()
        end)
    end

    local function buildBots()
        clearPage()
        addLabel("players in server")
        local ctrl = GetController()
        for _, p in ipairs(Players:GetPlayers()) do
            local tag = ""
            if IsController(p) then tag = " [CONTROLLER]" end
            if KnownBots[p.Name] then tag = tag .. " [BOT]" end
            if p == LocalPlayer then tag = tag .. " [YOU]" end
            addLabel(p.Name .. tag)
        end
        addBtn("refresh", function() buildBots() end)
        addBtn("announce bots (ping)", function() fire("ping") end)
    end

    local function buildSettings()
        clearPage()
        addLabel("discord webhook")
        webhookBox = addBox("https://discord.com/api/webhooks/...")
        if WEBHOOK_URL ~= "" then webhookBox.Text = WEBHOOK_URL end
        addBtn("save webhook", function()
            WEBHOOK_URL = webhookBox.Text:match("^%s*(.-)%s*$") or ""
            notify("DH Stand", WEBHOOK_URL ~= "" and "Webhook saved" or "Webhook cleared")
            webhookEmbed("Webhook connected", "DH Stand notifications active on **" .. LocalPlayer.Name .. "**", 5763719)
        end)
        addLabel("you are controller: " .. tostring(ControllerName))
        addBtn("claim controller", function()
            ControllerName = LocalPlayer.Name
            IsHost = true
            notify("DH Stand", "You are controller")
        end)
        addLabel("slot: " .. tostring(MySlot))
        local slotBox = addBox("slot number")
        addBtn("set my slot", function()
            local n = tonumber(slotBox.Text)
            if n then MySlot = math.floor(n) getgenv().DH_STAND.Slot = MySlot notify("DH Stand", "Slot " .. MySlot) end
        end)
    end

    local pages = {
        Main = buildMain,
        Actions = buildActions,
        Bots = buildBots,
        Settings = buildSettings,
    }

    local function openTab(name)
        if animating then return end
        if openTabName == name then
            animating = true
            TweenService:Create(panel, TweenInfo.new(0.15), { Size = UDim2.new(0, 0, 0, PANEL_H) }):Play()
            task.delay(0.16, function()
                clearPage()
                panel.Visible = false
                openTabName = nil
                animating = false
            end)
            for _, btn in pairs(tabButtons) do btn.BackgroundTransparency = 0.75 end
            return
        end
        openTabName = name
        panel.Visible = true
        clearPage()
        if pages[name] then pages[name]() end
        for n, btn in pairs(tabButtons) do
            btn.BackgroundTransparency = (n == name) and 0.15 or 0.75
        end
        animating = true
        panel.Size = UDim2.new(0, 0, 0, PANEL_H)
        TweenService:Create(panel, TweenInfo.new(0.18), { Size = UDim2.new(0, PANEL_W, 0, PANEL_H) }):Play()
        task.delay(0.2, function() animating = false end)
    end

    local tabNames = { "Main", "Actions", "Bots", "Settings" }
    for i, name in ipairs(tabNames) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -8, 0, 40)
        b.Position = UDim2.new(0, 4, 0, 8 + (i - 1) * 48)
        b.BackgroundColor3 = Color3.fromRGB(35, 38, 50)
        b.BackgroundTransparency = 0.75
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.TextColor3 = Color3.fromRGB(230, 230, 240)
        b.Text = name
        b.Parent = shell
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        tabButtons[name] = b
        b.MouseButton1Click:Connect(function() openTab(name) end)
    end

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -8, 0, 36)
    title.Position = UDim2.new(0, 4, 1, -44)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 10
    title.TextColor3 = Color3.fromRGB(120, 120, 140)
    title.Text = "DH STAND"
    title.Parent = shell

    -- drag
    do
        local dragging, dragStart, startPos
        shell.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startPos = shell.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local d = input.Position - dragStart
                shell.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
    end

    notify("DH Stand", "GUI ready — you are controller")
    webhookEmbed("Controller online", LocalPlayer.Name .. " opened DH Stand GUI", 5763719)
end

-- public
getgenv().DHStand_OpenGui = createGui
getgenv().DHStand_Send = function(line) sendCommand(line) handleCommand(LocalPlayer, line) end

createGui()
print("[DH Stand] loaded — GUI on side. Controller:", LocalPlayer.Name)
print("[DH Stand] Commands: setup, location <bank|uphill|casino|admin base>, wallet, autodrop, amount <total>, summon, line, dance, float, leave, rejoin, stop")
