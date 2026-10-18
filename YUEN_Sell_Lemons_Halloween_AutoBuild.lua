--[[
    YUEN | SELL LEMONS - HALLOWEEN 2026 EVENT ASSISTANT
    Build: October 2026

    Features:
      * Rayfield compact UI
      * Auto-drop candy by simulating the normal E key while the
        actual DROP CANDY ProximityPrompt is enabled and in range
      * Optional nearby coin-prompt helper (only prompts, not touch pickups)
      * Local visual highlights for likely Halloween coin pickup objects
      * Event purchase priorities, sticker checklist, and pack guide

    This script does NOT invoke RemoteEvents/RemoteFunctions, bypass currency
    checks, fabricate coins, auto-buy event purchases, or force interactions
    outside normal prompt range. It only sends ordinary E key input after
    checking the prompt's enabled state and activation distance.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local okVIM, VirtualInputManager = pcall(function()
    return game:GetService("VirtualInputManager")
end)
if not okVIM then VirtualInputManager = nil end
local LocalPlayer = Players.LocalPlayer

-- Main Sell Lemons place / universe IDs seen on public references.
-- This is a warning-only check so alternate game places are not blocked.
if game.PlaceId ~= 79268393072444 and game.GameId ~= 7395930870 then
    warn("[YUEN] Place ID differs from the main Sell Lemons reference. Continue only if you are in Sell Lemons.")
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- Original Sell Lemons module helpers used by the previous YUEN build.
-- Missing/renamed modules are skipped safely; Halloween helpers still load.
local function RequireModule(path)
    local obj = ReplicatedStorage
    for _, name in ipairs(path) do
        obj = obj:WaitForChild(name, 3)
        if not obj then
            warn("[YUEN] Missing module path: " .. table.concat(path, "."))
            return nil
        end
    end
    local ok, result = pcall(require, obj)
    if ok then return result end
    warn("[YUEN] Module load failed (" .. table.concat(path, ".") .. "): " .. tostring(result))
    return nil
end

local Tycoon = RequireModule({"Modules", "Tycoon", "Tycoon"})
local Analyzer = RequireModule({"Modules", "Tycoon", "Component", "TycoonAnalyzer"})
local Balances = RequireModule({"Modules", "Tycoon", "Component", "Client", "ClientTycoonBalances"})
local Balance = RequireModule({"Balance"})
local Huge = RequireModule({"Huge"})
local RebirthModule = RequireModule({"Modules", "Tycoon", "Component", "Client", "ClientTycoonRebirth"})
local EvolutionModule = RequireModule({"Modules", "Tycoon", "Component", "Client", "ClientTycoonEvolution"})
local AscensionModule = RequireModule({"Modules", "Tycoon", "Component", "Client", "ClientTycoonAscension"})
local PowerModule = RequireModule({"Modules", "Tycoon", "Component", "Client", "ClientTycoonPowers"})
local TycoonBalances = RequireModule({"Modules", "Tycoon", "Component", "TycoonBalances"})
local Config = RequireModule({"Config"})

local Running = true
local Settings = {
    -- Main tycoon automation from the previous YUEN build
    AutoPurchase = false,
    AutoUpgrade = false,
    AutoPower = false,
    AutoRebirth = false,
    AutoEvolution = false,
    AutoAscend = false,
    AntiAFK = false,
    RebirthMultiplier = 100,
    -- Halloween 2026 event helpers
    AutoDropCandy = false,
    AutoUseCoinPrompts = false,
    HighlightCoins = false,
    AutoBuildHalloween = false,
    DropDelay = 0.25,
}

local LastInputAt = 0
local LastPromptScanAt = 0
local LastHighlightRefreshAt = 0
local CandyPrompts = {}
local CoinPrompts = {}
local BuildPads = {}
local LastBuildScanAt = 0
local BuildBusy = false
local BuildAttempts = setmetatable({}, { __mode = "k" })
local HighlightFolder

local function Notify(title, content, duration)
    Rayfield:Notify({
        Title = title,
        Content = content,
        Duration = duration or 4,
    })
end

local ReportedErrors = {}

local function SafeRun(name, callback)
    local ok, err = pcall(callback)
    if not ok and not ReportedErrors[name] then
        ReportedErrors[name] = true
        warn("[YUEN] " .. name .. ": " .. tostring(err))
        Notify("YUEN Error", name .. " failed. Check the executor console.", 5)
    end
end

-- Standard Sell Lemons automation from the prior YUEN build.
local function GetLocalTycoon()
    if not Tycoon then return nil end
    local ok, result = pcall(function()
        return Tycoon.getLocal()
    end)
    return ok and result or nil
end

local function GetNextPurchase(tycoon)
    if not Analyzer or not Balance then return nil end
    local analyzer = tycoon:GetComponent(Analyzer)
    if not analyzer then return nil end
    local purchases = analyzer:GetPurchases()
    for _, name in ipairs(Balance.PurchaseOrder or {}) do
        local purchase = purchases[name]
        if purchase and purchase:IsEnabled() and not purchase:IsPurchased() then
            return purchase, analyzer
        end
    end
end

local function DoAutoPurchase()
    local tycoon = GetLocalTycoon()
    if not tycoon or not Balances then return end
    local balance = tycoon:GetComponent(Balances)
    if not balance then return end
    local purchase = GetNextPurchase(tycoon)
    if not purchase then return end
    if balance:GetCash() < purchase:GetPrice() then return end
    -- Uses the game's own purchase function; no currency bypass is attempted.
    purchase:TryPurchaseAsync()
end

local function DoAutoUpgrade()
    local tycoon = GetLocalTycoon()
    if not tycoon or not Analyzer or not Balances then return end
    local analyzer = tycoon:GetComponent(Analyzer)
    local balance = tycoon:GetComponent(Balances)
    if not analyzer or not balance then return end
    for name, earner in pairs(analyzer:GetEarners()) do
        if earner:IsEnabled() then
            local info = earner:GetNextUpgradeInfo()
            if info and not info.Max and info.Price <= balance:GetCash() then
                local ok, err = pcall(function()
                    earner:Upgrade(info.Count, true)
                end)
                if not ok then warn("[YUEN] Upgrade " .. name .. ": " .. tostring(err)) end
                task.wait(0.05)
            end
        end
    end
end

local function DoAutoPower()
    local tycoon = GetLocalTycoon()
    if not tycoon or not PowerModule or not Balances or not Huge or not Config then return end
    local powers = tycoon:GetComponent(PowerModule)
    local balance = tycoon:GetComponent(Balances)
    if not powers or not balance then return end
    local budget = Huge.multiply(balance:GetInvestors(), Huge.toHuge(0.5))
    for powerName in pairs(Config.Powers or {}) do
        local price = powers:GetUpgradePrice(powerName)
        if price and price <= budget then
            pcall(function() powers:UpgradeAsync(powerName) end)
            task.wait(0.1)
        end
    end
end

local function DoAutoRebirth()
    local tycoon = GetLocalTycoon()
    if not tycoon or not TycoonBalances or not RebirthModule or not Huge then return end
    local balance = tycoon:GetComponent(TycoonBalances)
    local rebirth = tycoon:GetComponent(RebirthModule)
    if not balance or not rebirth then return end
    local current = balance:GetInvestors()
    local potential = rebirth:GetPotentialInvestors()
    local multiplier = Huge.divide(potential, Huge.max(current, Huge.toHuge(100)))
    if multiplier >= Huge.toHuge(Settings.RebirthMultiplier) then
        rebirth:RebirthAsync()
    end
end

local function DoAutoEvolution()
    local tycoon = GetLocalTycoon()
    if not tycoon or not EvolutionModule then return end
    local evolution = tycoon:GetComponent(EvolutionModule)
    if not evolution then return end
    local progress = evolution:GetEvolutionProgress()
    if progress and progress >= 1 then evolution:EvolveAsync() end
end

local Ascending = false
local function DoAutoAscend()
    if Ascending then return end
    local tycoon = GetLocalTycoon()
    if not tycoon or not Analyzer or not Balances or not AscensionModule then return end
    local analyzer = tycoon:GetComponent(Analyzer)
    local balance = tycoon:GetComponent(Balances)
    local ascension = tycoon:GetComponent(AscensionModule)
    if not analyzer or not balance or not ascension then return end
    local purchases = analyzer:GetPurchases()
    local finalPurchase = purchases["StaircaseStepFinal"]
    if not finalPurchase then return end
    if not finalPurchase:IsPurchased() then
        if balance:GetCash() >= finalPurchase:GetPrice() then
            finalPurchase:TryPurchaseAsync()
        end
        return
    end
    Ascending = true
    local ok, err = pcall(function() ascension:AscendAsync() end)
    if not ok then warn("[YUEN] Ascend failed: " .. tostring(err)) end
    task.wait(3)
    Ascending = false
end

local function GetCharacterRoot()
    local character = LocalPlayer.Character
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart")
end

local function Lower(value)
    return string.lower(tostring(value or ""))
end

local function PromptText(prompt)
    local parentName = prompt.Parent and prompt.Parent.Name or ""
    return Lower(prompt.ActionText) .. " " .. Lower(prompt.ObjectText) .. " " .. Lower(parentName)
end

local function IsCandyPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local action = Lower(prompt.ActionText)
    local combined = PromptText(prompt)
    return action:find("drop candy", 1, true) ~= nil
        or (combined:find("candy", 1, true) and combined:find("drop", 1, true)) ~= nil
end

local function IsCoinPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local combined = PromptText(prompt)
    local hasCoin = combined:find("coin", 1, true) ~= nil
    local eventNamed = combined:find("spooky", 1, true) ~= nil
        or combined:find("pumpkin", 1, true) ~= nil
        or combined:find("halloween", 1, true) ~= nil
        or combined:find("event", 1, true) ~= nil
    return hasCoin and eventNamed
end

local function GetPromptPosition(prompt)
    local parent = prompt and prompt.Parent
    if not parent then return nil end
    if parent:IsA("Attachment") then
        return parent.WorldPosition
    elseif parent:IsA("BasePart") then
        return parent.Position
    elseif parent:IsA("Model") then
        local ok, pivot = pcall(function() return parent:GetPivot() end)
        if ok then return pivot.Position end
    end
    local part = parent:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function PromptIsInNormalRange(prompt)
    if not prompt or not prompt.Parent or not prompt.Enabled then return false end
    local root = GetCharacterRoot()
    local position = GetPromptPosition(prompt)
    if not root or not position then return false end
    local distance = (root.Position - position).Magnitude
    return distance <= (tonumber(prompt.MaxActivationDistance) or 0) + 0.25
end

local function RefreshPromptCache()
    CandyPrompts = {}
    CoinPrompts = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            if IsCandyPrompt(obj) then
                table.insert(CandyPrompts, obj)
            elseif IsCoinPrompt(obj) then
                table.insert(CoinPrompts, obj)
            end
        end
    end
    LastPromptScanAt = os.clock()
end

local function FindNearbyPrompt(promptList)
    local root = GetCharacterRoot()
    if not root then return nil end
    local bestPrompt, bestDistance
    for _, prompt in ipairs(promptList) do
        if PromptIsInNormalRange(prompt) then
            local position = GetPromptPosition(prompt)
            local distance = position and (root.Position - position).Magnitude or math.huge
            if not bestDistance or distance < bestDistance then
                bestPrompt, bestDistance = prompt, distance
            end
        end
    end
    return bestPrompt
end


local function SendNormalE(prompt)
    if not Running or not prompt or not PromptIsInNormalRange(prompt) then
        return false
    end
    if UserInputService:GetFocusedTextBox() then
        return false
    end

    local now = os.clock()
    if now - LastInputAt < Settings.DropDelay then
        return false
    end

    local okDown = pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    end)
    if not okDown then
        Notify("YUEN", "Normal key input failed in this executor. No remote fallback is used.", 5)
        Settings.AutoDropCandy = false
        Settings.AutoUseCoinPrompts = false
        return false
    end

    local hold = math.clamp(tonumber(prompt.HoldDuration) or 0, 0, 2)
    task.wait(math.max(0.04, hold + 0.03))
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
    LastInputAt = os.clock()
    return true
end

local function EnsureHighlightFolder()
    if HighlightFolder and HighlightFolder.Parent then return HighlightFolder end
    HighlightFolder = Workspace:FindFirstChild("YUEN_HalloweenCoinHighlights")
    if not HighlightFolder then
        HighlightFolder = Instance.new("Folder")
        HighlightFolder.Name = "YUEN_HalloweenCoinHighlights"
        HighlightFolder.Parent = Workspace
    end
    return HighlightFolder
end

local function ClearCoinHighlights()
    if HighlightFolder then
        for _, child in ipairs(HighlightFolder:GetChildren()) do
            child:Destroy()
        end
    end
end

local function NormalizeName(name)
    return Lower(name):gsub("[%s_%-]", "")
end

local function IsLikelyHalloweenCoinName(name)
    local n = NormalizeName(name)
    return n:find("spookycoin", 1, true) ~= nil
        or n:find("pumpkincoin", 1, true) ~= nil
        or n:find("eventcoin", 1, true) ~= nil
        or n:find("coinpickup", 1, true) ~= nil
        or n:find("halloweencoin", 1, true) ~= nil
end

local function FindCoinAdornee(obj)
    local cursor = obj
    for _ = 1, 4 do
        if not cursor or cursor == Workspace then break end
        if cursor:IsA("Model") and IsLikelyHalloweenCoinName(cursor.Name) then
            return cursor
        end
        if cursor:IsA("BasePart") and IsLikelyHalloweenCoinName(cursor.Name) then
            return cursor
        end
        cursor = cursor.Parent
    end
    return nil
end

local function RefreshCoinHighlights()
    ClearCoinHighlights()
    local folder = EnsureHighlightFolder()
    local seen = {}
    local count = 0

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("BasePart") then
            local target = FindCoinAdornee(obj)
            if target and not seen[target] then
                seen[target] = true
                local highlight = Instance.new("Highlight")
                highlight.Name = "YUEN_CoinMarker"
                highlight.Adornee = target
                highlight.FillTransparency = 0.65
                highlight.OutlineTransparency = 0
                highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                highlight.Parent = folder
                count += 1
            end
        end
    end

    LastHighlightRefreshAt = os.clock()
    return count
end


-- Halloween factory auto-builder.
-- The event guide describes purchase buttons on each player's plot. This helper
-- detects likely factory purchase pads and walks to them using normal humanoid
-- movement. The game itself still validates ownership, unlocks, and Spooky Coins;
-- this code does not call hidden purchase remotes or simulate free currency.
local FactoryItemKeywords = {
    "candydropper", "swirlspinner", "lemonzester", "conveyor",
    "caramelglazer", "candycannon", "candypacker", "packer1000",
    "candyupgrader", "candyupgrade"
}
local DecorationKeywords = {
    "trim", "welcomemat", "windows", "walls", "giantcandy",
    "haybales", "gravestone", "trickortreat", "decoration"
}
local PurchaseMarkerKeywords = {
    "button", "purchase", "buy", "build", "unlock", "pad"
}

local function HasKeyword(text, keywords)
    for _, keyword in ipairs(keywords) do
        if text:find(keyword, 1, true) then return true end
    end
    return false
end

local function ReadGuiText(root)
    local pieces = {}
    if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
        table.insert(pieces, root.Text or "")
    end
    local ok, descendants = pcall(function() return root:GetDescendants() end)
    if ok then
        for _, obj in ipairs(descendants) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                table.insert(pieces, obj.Text or "")
            end
        end
    end
    return table.concat(pieces, " ")
end

local function GetBuildContext(part)
    local names = {}
    local cursor = part
    local depth = 0
    while cursor and cursor ~= Workspace and depth < 7 do
        table.insert(names, tostring(cursor.Name))
        depth += 1
        cursor = cursor.Parent
    end
    table.insert(names, ReadGuiText(part))
    return NormalizeName(table.concat(names, " "))
end

local function HasForeignOwner(inst)
    local cursor = inst
    local depth = 0
    while cursor and cursor ~= Workspace and depth < 9 do
        local owner = cursor:FindFirstChild("Owner")
        if owner then
            if owner:IsA("ObjectValue") and owner.Value and owner.Value:IsA("Player") then
                if owner.Value ~= LocalPlayer then return true end
            elseif owner:IsA("StringValue") and owner.Value ~= "" then
                local namedPlayer = Players:FindFirstChild(owner.Value)
                if namedPlayer and namedPlayer ~= LocalPlayer then return true end
            end
        end
        local ownerAttribute = cursor:GetAttribute("Owner")
        if typeof(ownerAttribute) == "Instance" and ownerAttribute:IsA("Player") then
            if ownerAttribute ~= LocalPlayer then return true end
        elseif typeof(ownerAttribute) == "string" and ownerAttribute ~= "" then
            local namedPlayer = Players:FindFirstChild(ownerAttribute)
            if namedPlayer and namedPlayer ~= LocalPlayer then return true end
        end
        cursor = cursor.Parent
        depth += 1
    end
    return false
end

local function IsPurchasePrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local action = NormalizeName(prompt.ActionText)
    return action:find("buy", 1, true) ~= nil
        or action:find("build", 1, true) ~= nil
        or action:find("purchase", 1, true) ~= nil
        or action:find("unlock", 1, true) ~= nil
        or action:find("upgrade", 1, true) ~= nil
        or action:find("place", 1, true) ~= nil
end

local function IsButtonLike(part)
    local cursor = part
    local depth = 0
    while cursor and cursor ~= Workspace and depth < 3 do
        local name = NormalizeName(cursor.Name)
        if HasKeyword(name, PurchaseMarkerKeywords) then return true end
        if cursor:FindFirstChildOfClass("ClickDetector") then return true end
        local prompt = cursor:FindFirstChildWhichIsA("ProximityPrompt", true)
        if IsPurchasePrompt(prompt) then return true end
        depth += 1
        cursor = cursor.Parent
    end
    local guiText = NormalizeName(ReadGuiText(part))
    return guiText:find("buy", 1, true) ~= nil
        or guiText:find("purchase", 1, true) ~= nil
        or guiText:find("build", 1, true) ~= nil
        or guiText:find("unlock", 1, true) ~= nil
        or guiText:find("spookycoin", 1, true) ~= nil
end

local function IsLikelyFactoryPad(part)
    if not part:IsA("BasePart") or not part.Parent then return false end
    if not part.CanTouch and not part:FindFirstChildWhichIsA("ProximityPrompt", true) then
        return false
    end
    if HasForeignOwner(part) then return false end

    local context = GetBuildContext(part)
    if not HasKeyword(context, FactoryItemKeywords) then return false end
    if not IsButtonLike(part) then return false end
    if HasKeyword(context, DecorationKeywords) then return false end

    -- Ignore pads that visibly advertise that they are already owned/built.
    local visible = NormalizeName(ReadGuiText(part))
    if visible:find("purchased", 1, true)
        or visible:find("alreadybuilt", 1, true)
        or visible:find("owned", 1, true) then
        return false
    end
    return true, context
end

local function GetBuildRank(context)
    if context:find("candycannon", 1, true) and context:find("2x", 1, true)
        and not context:find("2.5x", 1, true) then return 1 end
    if context:find("swirlspinner", 1, true) then return 2 end
    if context:find("conveyor", 1, true) then return 3 end
    if context:find("caramelglazer", 1, true) then return 4 end
    if context:find("candycannon", 1, true) and context:find("2.5x", 1, true) then return 5 end
    if context:find("lemonzester", 1, true) then return 6 end
    if context:find("candypacker", 1, true) or context:find("packer1000", 1, true) then return 7 end
    if context:find("candydropper", 1, true) then return 8 end
    return 20
end

local function GetBuildGroup(part)
    local cursor = part
    local depth = 0
    while cursor and cursor ~= Workspace and depth < 4 do
        local name = NormalizeName(cursor.Name)
        if HasKeyword(name, PurchaseMarkerKeywords) and HasKeyword(name, FactoryItemKeywords) then
            return cursor
        end
        cursor = cursor.Parent
        depth += 1
    end
    -- Keep generic siblings separate; folders such as "PurchaseButtons" can
    -- contain the entire factory's button set and must not collapse to one target.
    return part
end

local function RefreshHalloweenBuildPads()
    BuildPads = {}
    local root = GetCharacterRoot()
    if not root then
        LastBuildScanAt = os.clock()
        return 0
    end

    local seenGroups = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local ok, context = IsLikelyFactoryPad(obj)
            if ok then
                local distance = (root.Position - obj.Position).Magnitude
                -- Prevent the auto-builder from navigating across the entire map.
                if distance <= 180 then
                    local group = GetBuildGroup(obj)
                    if not seenGroups[group] then
                        seenGroups[group] = true
                        table.insert(BuildPads, {
                            Part = obj,
                            Group = group,
                            Context = context,
                            Rank = GetBuildRank(context),
                            Distance = distance,
                            Label = tostring(group.Name ~= "" and group.Name or obj.Name),
                        })
                    elseif group == obj and not seenGroups[obj] then
                        seenGroups[obj] = true
                    end
                end
            end
        end
    end

    table.sort(BuildPads, function(a, b)
        if a.Rank == b.Rank then return a.Distance < b.Distance end
        return a.Rank < b.Rank
    end)
    LastBuildScanAt = os.clock()
    return #BuildPads
end

local function WaitForMove(humanoid, destination, timeout)
    if not Running or not Settings.AutoBuildHalloween or not humanoid or not humanoid.Parent then
        return false
    end
    local finished, reached = false, false
    local connection = humanoid.MoveToFinished:Connect(function(ok)
        finished = true
        reached = ok
    end)
    humanoid:MoveTo(destination)
    local deadline = os.clock() + timeout
    while Running and Settings.AutoBuildHalloween and humanoid.Parent
        and not finished and os.clock() < deadline do
        task.wait(0.1)
    end
    connection:Disconnect()
    return finished and reached
end

local function WalkToBuildPad(entry)
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local pad = entry and entry.Part
    if not humanoid or not root or not pad or not pad.Parent then return false end

    local destination = pad.Position + Vector3.new(0, math.max(2.5, pad.Size.Y / 2 + 1.5), 0)
    local path
    local pathOk = pcall(function()
        path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            WaypointSpacing = 4,
        })
        path:ComputeAsync(root.Position, destination)
    end)

    if pathOk and path and path.Status == Enum.PathStatus.Success then
        for _, waypoint in ipairs(path:GetWaypoints()) do
            if not Running or not Settings.AutoBuildHalloween or not pad.Parent then
                return false
            end
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
            end
            local timeout = math.clamp((root.Position - waypoint.Position).Magnitude / 7 + 3, 4, 10)
            if not WaitForMove(humanoid, waypoint.Position, timeout) then
                return false
            end
        end
        return true
    end

    -- If pathfinding cannot compute the plot route, try a normal MoveTo once.
    local timeout = math.clamp((root.Position - destination).Magnitude / 7 + 3, 4, 12)
    return WaitForMove(humanoid, destination, timeout)
end

local function UseBuildPrompt(entry)
    local pad = entry and entry.Part
    if not pad or not pad.Parent then return end
    local prompts = {}
    if pad:IsA("ProximityPrompt") then table.insert(prompts, pad) end
    for _, obj in ipairs(pad:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then table.insert(prompts, obj) end
    end
    local group = entry.Group
    if group and group ~= pad then
        for _, obj in ipairs(group:GetDescendants()) do
            if obj:IsA("ProximityPrompt") and not table.find(prompts, obj) then
                table.insert(prompts, obj)
            end
        end
    end
    for _, prompt in ipairs(prompts) do
        if IsPurchasePrompt(prompt) and PromptIsInNormalRange(prompt) then
            SendNormalE(prompt)
            return
        end
    end
end

local function GetNextBuildPad()
    local now = os.clock()
    for _, entry in ipairs(BuildPads) do
        local group = entry.Group or entry.Part
        local lastAttempt = BuildAttempts[group] or 0
        if entry.Part and entry.Part.Parent and now - lastAttempt > 20 then
            return entry
        end
    end
    return nil
end


local Window = Rayfield:CreateWindow({
    Name = "YUEN | Sell Lemons",
    LoadingTitle = "YUEN",
    LoadingSubtitle = "Halloween 2026 Assistant",
    ConfigurationSaving = { Enabled = false },
})

local FarmTab = Window:CreateTab("Farm", "leaf")
local ProgressTab = Window:CreateTab("Progress", "trending-up")
local EventTab = Window:CreateTab("Halloween", "ghost")
local GuideTab = Window:CreateTab("Event Guide", "book-open")
local StickerTab = Window:CreateTab("Sticker Sheet", "gallery-horizontal")
local UtilityTab = Window:CreateTab("Utility", "settings")

FarmTab:CreateLabel("YUEN  /  TYCOON AUTOMATION")
FarmTab:CreateToggle({
    Name = "Auto Purchase",
    CurrentValue = false,
    Callback = function(value) Settings.AutoPurchase = value end,
})
FarmTab:CreateToggle({
    Name = "Auto Upgrade",
    CurrentValue = false,
    Callback = function(value) Settings.AutoUpgrade = value end,
})
FarmTab:CreateToggle({
    Name = "Auto Power",
    CurrentValue = false,
    Callback = function(value) Settings.AutoPower = value end,
})

ProgressTab:CreateLabel("AUTOMATIC PROGRESSION")
ProgressTab:CreateToggle({
    Name = "Auto Rebirth (resets cash progress)",
    CurrentValue = false,
    Callback = function(value)
        Settings.AutoRebirth = value
        if value then Notify("YUEN", "Auto Rebirth enabled. This resets your cash progress.") end
    end,
})
ProgressTab:CreateSlider({
    Name = "Rebirth Investor Multiplier",
    Range = { 2, 10000 },
    Increment = 10,
    Suffix = "x",
    CurrentValue = 100,
    Callback = function(value) Settings.RebirthMultiplier = value end,
})
ProgressTab:CreateToggle({
    Name = "Auto Evolution",
    CurrentValue = false,
    Callback = function(value) Settings.AutoEvolution = value end,
})
ProgressTab:CreateToggle({
    Name = "Auto Ascend (resets run)",
    CurrentValue = false,
    Callback = function(value)
        Settings.AutoAscend = value
        if value then Notify("YUEN", "Auto Ascend enabled. This can reset your run.") end
    end,
})

EventTab:CreateLabel("YUEN  /  HALLOWEEN 2026")
EventTab:CreateParagraph({
    Title = "Event loop",
    Content = "Candy factory → giant pumpkin → Spooky Coins → sticker packs. Stand beside your Candy Dropper before enabling Auto Drop Candy.",
})

EventTab:CreateToggle({
    Name = "Auto Drop Candy (normal E input)",
    CurrentValue = false,
    Callback = function(value)
        Settings.AutoDropCandy = value
        if value then
            Notify("YUEN", "Auto-drop enabled. Stand within range of the DROP CANDY prompt.")
        end
    end,
})

EventTab:CreateSlider({
    Name = "Drop input interval",
    Range = { 0.15, 1.0 },
    Increment = 0.05,
    Suffix = "s",
    CurrentValue = 0.25,
    Callback = function(value)
        Settings.DropDelay = value
    end,
})

EventTab:CreateToggle({
    Name = "Auto Build Halloween Factory",
    CurrentValue = false,
    Callback = function(value)
        Settings.AutoBuildHalloween = value
        if value then
            local count = RefreshHalloweenBuildPads()
            Notify("YUEN", "Auto Build enabled. Detected " .. count .. " likely factory purchase pad(s). YUEN will walk to them; normal Spooky Coin and unlock requirements still apply.", 6)
        else
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if humanoid and root then humanoid:MoveTo(root.Position) end
            Notify("YUEN", "Auto Build disabled.")
        end
    end,
})

EventTab:CreateButton({
    Name = "Scan Halloween Build Pads",
    Callback = function()
        local count = RefreshHalloweenBuildPads()
        local names = {}
        for i = 1, math.min(4, #BuildPads) do
            table.insert(names, BuildPads[i].Label)
        end
        local details = #names > 0 and table.concat(names, ", ") or "No likely factory pads found nearby"
        Notify("YUEN Build Scan", tostring(count) .. " candidate(s): " .. details, 6)
    end,
})

EventTab:CreateToggle({
    Name = "Use Nearby Halloween Coin Prompts",
    CurrentValue = false,
    Callback = function(value)
        Settings.AutoUseCoinPrompts = value
        if value then
            Notify("YUEN", "This only uses nearby Halloween coin ProximityPrompts. Touch-only pickups are not auto-collected.")
        end
    end,
})

EventTab:CreateToggle({
    Name = "Highlight Halloween Coin Pickups",
    CurrentValue = false,
    Callback = function(value)
        Settings.HighlightCoins = value
        if value then
            local count = RefreshCoinHighlights()
            Notify("YUEN", "Marked " .. count .. " likely Halloween coin object(s). Names vary by game build.")
        else
            ClearCoinHighlights()
        end
    end,
})

EventTab:CreateButton({
    Name = "Refresh Event Prompts / Coin Markers",
    Callback = function()
        RefreshPromptCache()
        local highlights = 0
        if Settings.HighlightCoins then
            highlights = RefreshCoinHighlights()
        end
        Notify("YUEN", "Candy prompts: " .. #CandyPrompts .. " | coin prompts: " .. #CoinPrompts .. " | markers: " .. highlights, 5)
    end,
})

GuideTab:CreateLabel("BEST EARLY COIN ROUTE")
GuideTab:CreateParagraph({
    Title = "1 · Start earning",
    Content = "Use the Candy Dropper's DROP CANDY [E] prompt manually or enable Auto Drop Candy while standing in its normal activation range. Pick up visible golden pumpkin coins around the event zone when you see them.",
})
GuideTab:CreateParagraph({
    Title = "2 · Upgrade for output",
    Content = "Reported prices / effects: Candy Cannon ×2 firing speed — 1,000 Spooky Coins; Swirl Spinner — 2,500 (candy worth 8 every 2.4s); Conveyor — 20,000; Caramel Glazer — 50,000 (×2 candy value); Candy Cannon ×2.5 speed — 100,000; Lemon Zester — 130,000 (candy worth 20 every 2s).",
})
GuideTab:CreateParagraph({
    Title = "Suggested order",
    Content = "Start with manual candy drops and the 1,000-coin ×2 cannon upgrade. Add the Swirl Spinner for passive output, then save for the Conveyor and Caramel Glazer so the line can move and upgrade candy. The Lemon Zester is a later, expensive output upgrade. Prioritize income items over decorations.",
})
GuideTab:CreateParagraph({
    Title = "3 · Use the shared pumpkin",
    Content = "Candy landing in the giant pumpkin pays Spooky Coins and fills a server-wide meter. A current event guide reports multiplier tiers up to ×1.5 and a next target of 2,000 candy after the 1,000 threshold. A busy server helps fill the shared meter faster.",
})
GuideTab:CreateParagraph({
    Title = "Avoid low-value spending early",
    Content = "Reported decorations include Trim (350), Welcome Mat (550), Windows (1,000), Walls (1,500), Giant Candy (1,900), and Hay Bales (7,500). The guide says these are cosmetic and do not produce income.",
})

StickerTab:CreateLabel("20 UNIQUE STICKERS · JACK-O-MECH")
StickerTab:CreateParagraph({
    Title = "Reward requirement",
    Content = "Collect all 20 unique stickers to reach 20/20, then use the Jack-O-Mech Redeem prompt. Duplicates do not increase the unique-sticker counter.",
})
StickerTab:CreateParagraph({
    Title = "Legendary (2)",
    Content = "Legendary Alien Stand · Alien Stand Creation",
})
StickerTab:CreateParagraph({
    Title = "Epic (4)",
    Content = "The Cube · EARNest · Orchard · Broken Wings",
})
StickerTab:CreateParagraph({
    Title = "Rare (6)",
    Content = "Void Duster · Lemon Potion · Percy · The Waiter · Trapped · Alien Witch",
})
StickerTab:CreateParagraph({
    Title = "Common (8)",
    Content = "Stonks · Citchrus · Joe Zombien · Glorp Kitty · Candy Pike · Soul Void · Sewer Creep · Visitor",
})
StickerTab:CreateParagraph({
    Title = "Pack costs and strategy",
    Content = "Common: 1,000 Spooky Coins; Rare: 10,000; Epic: 100,000. Five Common Packs cost 5,000 and should satisfy the reported 'open 5 packs' badge task. The cited event guide says Common Packs cannot drop either Legendary sticker; it reports much better Legendary odds in Epic Packs than Rare Packs. Exact displayed in-game odds should take precedence over third-party tables.",
})
StickerTab:CreateParagraph({
    Title = "Odds warning",
    Content = "One newly published guide's Epic Pack percentages do not sum cleanly to 100%, so treat its exact rates as unverified. Do not assume a specific pack count guarantees the Jack-O-Mech.",
})

UtilityTab:CreateLabel("YUEN / LOCAL HELPERS")
UtilityTab:CreateToggle({
    Name = "Anti-AFK",
    CurrentValue = false,
    Callback = function(value) Settings.AntiAFK = value end,
})
UtilityTab:CreateButton({
    Name = "Re-scan Prompts",
    Callback = function()
        RefreshPromptCache()
        Notify("YUEN", "Found " .. #CandyPrompts .. " candy prompt(s) and " .. #CoinPrompts .. " likely coin prompt(s).", 5)
    end,
})

UtilityTab:CreateButton({
    Name = "Clear Coin Highlights",
    Callback = function()
        Settings.HighlightCoins = false
        ClearCoinHighlights()
        Notify("YUEN", "Local coin highlights cleared.")
    end,
})

UtilityTab:CreateButton({
    Name = "Unload YUEN",
    Callback = function()
        Running = false
        Settings.AutoPurchase = false
        Settings.AutoUpgrade = false
        Settings.AutoPower = false
        Settings.AutoRebirth = false
        Settings.AutoEvolution = false
        Settings.AutoAscend = false
        Settings.AntiAFK = false
        Settings.AutoDropCandy = false
        Settings.AutoUseCoinPrompts = false
        Settings.HighlightCoins = false
        Settings.AutoBuildHalloween = false
        ClearCoinHighlights()
        pcall(function() Rayfield:Destroy() end)
    end,
})

-- Single worker: cached prompts are refreshed periodically and only the nearest
-- matching prompt inside the normal Roblox activation distance receives E.
task.spawn(function()
    while Running do
        if os.clock() - LastPromptScanAt > 2 then
            RefreshPromptCache()
        end

        if os.clock() - LastInputAt >= Settings.DropDelay then
            local candyPrompt = Settings.AutoDropCandy and FindNearbyPrompt(CandyPrompts) or nil
            local coinPrompt = Settings.AutoUseCoinPrompts and FindNearbyPrompt(CoinPrompts) or nil
            if candyPrompt then
                SendNormalE(candyPrompt)
            elseif coinPrompt then
                SendNormalE(coinPrompt)
            end
        end

        if Settings.HighlightCoins and os.clock() - LastHighlightRefreshAt > 8 then
            RefreshCoinHighlights()
        end

        task.wait(0.05)
    end
end)

-- Auto-builder worker: walks to one detected Halloween factory purchase pad at a time.
-- No direct purchase remote is invoked; the game applies normal touch/prompt rules.
task.spawn(function()
    while Running do
        if Settings.AutoBuildHalloween and not BuildBusy then
            if os.clock() - LastBuildScanAt > 2.5 then
                RefreshHalloweenBuildPads()
            end
            local entry = GetNextBuildPad()
            if entry then
                BuildBusy = true
                task.spawn(function()
                    local group = entry.Group or entry.Part
                    local ok, err = pcall(function()
                        local arrived = WalkToBuildPad(entry)
                        if arrived and Running and Settings.AutoBuildHalloween then
                            UseBuildPrompt(entry)
                            task.wait(0.8)
                        end
                    end)
                    if not ok then warn("[YUEN] Auto Build: " .. tostring(err)) end
                    BuildAttempts[group] = os.clock()
                    BuildBusy = false
                    -- Refresh after each attempt so purchased/removed pads disappear from the list.
                    task.wait(0.5)
                    if Running and Settings.AutoBuildHalloween then
                        RefreshHalloweenBuildPads()
                    end
                end)
            end
        end
        task.wait(0.2)
    end
end)

-- Optional anti-idle helper. This does not alter game state or purchase logic.
LocalPlayer.Idled:Connect(function()
    if not Running or not Settings.AntiAFK then return end
    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end)

-- Main tycoon workers. All purchase/upgrade calls use game modules and their
-- ordinary methods; these loops do not send fabricated currency requests.
task.spawn(function()
    while Running do
        if Settings.AutoPurchase then SafeRun("Auto Purchase", DoAutoPurchase) end
        task.wait(0.25)
    end
end)

task.spawn(function()
    while Running do
        if Settings.AutoUpgrade then SafeRun("Auto Upgrade", DoAutoUpgrade) end
        task.wait(0.3)
    end
end)

task.spawn(function()
    while Running do
        if Settings.AutoPower then SafeRun("Auto Power", DoAutoPower) end
        task.wait(1)
    end
end)

task.spawn(function()
    while Running do
        if Settings.AutoRebirth then SafeRun("Auto Rebirth", DoAutoRebirth) end
        task.wait(1)
    end
end)

task.spawn(function()
    while Running do
        if Settings.AutoEvolution then SafeRun("Auto Evolution", DoAutoEvolution) end
        task.wait(1)
    end
end)

task.spawn(function()
    while Running do
        if Settings.AutoAscend then SafeRun("Auto Ascend", DoAutoAscend) end
        task.wait(1)
    end
end)

RefreshPromptCache()
Notify("YUEN", "Sell Lemons + Halloween 2026 loaded. Auto Build walks to detected event purchase pads; normal game currency and unlock checks remain active.", 5)
