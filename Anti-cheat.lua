local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local PhysicsService = game:GetService("PhysicsService")

local AntiCheat = {}

--[[
    Ultimate Roblox Anti-Cheat (QB Style) - Server & Client

    IMPORTANT:  This is a FRAMEWORK, not a drop-in solution.  You MUST adapt
    it to your game.  Read the comments carefully!
]]

-- Configuration (Server & Client - Keep consistent!)
local Config = {
    FUNCTION_MONITORING_ENABLED = true,
    MAX_REPORTS_PER_PLAYER = 5,
    REPORT_THRESHOLD = 3,
    FUNCTION_MONITOR_INTERVAL = 60,
    MODULE_MONITOR_INTERVAL = 120,
    ML_CHECK_INTERVAL = 30,        -- Behavior analysis interval
    DETECTION_THRESHOLD = 0.8,     -- Threshold for behavior analysis
    BAN_DURATION = 2592000,          -- 1 month in seconds (30 days)
    WEBHOOK_URL = "",               -- Replace with your Discord webhook URL

	-- Anti-Silent-Aim (FPS Focused - Customize these!)
    AntiSilentAim = {
        MaxViewAngleDifference = 12,   -- Degrees
        MaxTargetSwitchRate = 7,      -- Switches per TargetSwitchTimeWindow
        TargetSwitchTimeWindow = 0.8, -- Seconds
        InputAnalysisWindow = 0.4,    -- Seconds
        SmoothnessThreshold = 0.99,  -- For input analysis (0-1)
        SnapThreshold = 5,            -- For input analysis (degrees)
        HitValidationEnabled = true,
		MaxRaycastDistance = 250,
		MovementAnalysisEnabled = true,
        UnrealisticMovementThreshold = 0.7, --  Arbitrary value; tune carefully
		HeadshotRatioThreshold = 0.6, -- 60% headshots is suspicious
		ProjectileOriginCheckEnabled = true,
		MaxProjectileOriginDistance = 2, -- Studs. From where it should originate
    },

    -- Remote Event Security (CRITICAL - Fill this out!)
    RemoteEventSecurity = {
        StrictWhitelistEnabled = true,
        WhitelistedRemoteEvents = {  -- **YOU MUST FILL THIS WITH YOUR GAME'S REMOTE EVENTS**
            -- Examples:
            --"MyGame:UpdateInventory",
            --"MyGame:PurchaseItem",
            --"MyGame:DealDamage",
            --"MyGame:FireWeapon",
        },
        ArgumentValidationEnabled = true,  -- Check argument types and values
        RateLimitingEnabled = true,      -- Limit how often remotes can be fired
        MaxRemoteEventsPerSecond = 5,   -- Example rate limit
        RateLimitTimeFrame = 1,         -- Seconds
		EnableDistanceCheck = true,     -- Check distance between player and target
        MaxRemoteDistance = 100,      -- Maximum allowed distance (adjust to your game)
    },
    OtherChecks = {
		GravityCheckEnabled = true,
		DefaultGravity = 196.2,
	}

}


-- Customize monitored functions here if FUNCTION_MONITORING_ENABLED is true
local MonitoredFunctions = {
    -- Example:  {func = game.Players.PlayerAdded, name = "PlayerAdded"}
}

-- Data Storage (Server)
local BannedPlayers = {}        -- {UserId = {BanTime, Reason, Duration}}
local PlayerReports = {}        -- {ReporterUserId = count, ReportedUserId = {Reports, Reasons}}
local FunctionHashes = {}       -- {FuncName = hash}
local ModuleHashes = {}         -- {ModuleName = hash}
local FunctionMonitors = {}     -- {FuncName = function}
local ModuleMonitors = {}       -- {ModuleName = ModuleScript}
local PlayerActivity = {}       -- {UserId = {activityType = value}}
local GameFunctions = {}        -- {FuncName = function}
local Metamethods = {}          -- {MetamethodName = {object, originalMetamethod}}
local FunctionHooks = {}        -- {FuncName = {originalFunc, hookedFunc}}
local ServerHandshake = {}     -- {PlayerUserId = checksum}
local PlayerData = {}           -- Server-side detailed player data

-- Data Storage (Client - Reduced for security)
local ClientBannedPlayers = {}      -- {UserId = {BanTime, Reason, Duration}}
local ClientFunctionProxies = {}    -- {func = proxy}
local ClientLastActionTimes = {}    -- {ActionName = timestamp}
local ClientAPIMonitoringHooks = {}  -- {HookID = hookedMetamethod}


----------------------- UTILITY FUNCTIONS (Shared - Optimized) -----------------------

local function generateHash(data)
    if type(data) == "string" then
        return HttpService:GenerateGUID(false) -- Using Roblox GUID as a reasonable hash
    elseif type(data) == "function" then
        return HttpService:GenerateGUID(false)
    else
        return tostring(data) -- Fallback for other types
    end
end

local function isFunctionTampered(func, originalHash)
    if typeof(func) ~= "function" then return false end
    return generateHash(string.dump(func)) ~= originalHash
end

local function serverCheckAndBan(player, reason)
    if not player or not player.UserId or BannedPlayers[player.UserId] then return end
    BannedPlayers[player.UserId] = { BanTime = os.time(), Reason = reason, Duration = Config.BAN_DURATION }
    print("Banning player " .. player.Name .. " (UserId: " .. player.UserId .. ") for: " .. reason)
    player:Kick("Banned for: " .. reason)

     if Config.WEBHOOK_URL ~= "" then --Server webhook
        local success, err = pcall(function()
            local banData = {
                PlayerId = player.UserId,
                PlayerName = player.Name,
                Reason = reason,
                BanTime = os.date("%Y-%m-%d %H:%M:%S", os.time()),
                DurationSeconds = Config.BAN_DURATION
            }
            HttpService:PostAsync(Config.WEBHOOK_URL, HttpService:JSONEncode(banData))
        end)
        if not success then
            warn("Failed to send ban data to webhook:", err)
        end
    end
    -- TODO: Implement DataStoreService ban (CRITICAL for persistent bans)
end


local function clientCheckAndBan(player, reason)
    if not player or not player.UserId or ClientBannedPlayers[player.UserId] then return end

    ClientBannedPlayers[player.UserId] = {
        BanTime = os.time(),
        Reason = reason,
        Duration = Config.BAN_DURATION
    }
    player:Kick("[Anti-Cheat] Banned: " .. reason) -- Consistent kick message
    print("Player " .. player.Name .. " banned for: " .. reason)

    if Config.WEBHOOK_URL ~= "" then --Client side, for errors
        local success, err = pcall(function()
            local banData = {
                PlayerId = player.UserId,
                PlayerName = player.Name,
                Reason = reason,
                BanTime = os.date("%Y-%m-%d %H:%M:%S", os.time()),
                DurationSeconds = Config.BAN_DURATION
            }
            HttpService:PostAsync(Config.WEBHOOK_URL, HttpService:JSONEncode(banData))
        end)
        if not success then
            warn("Failed to send ban data to webhook:", err)
        end
    end
end


local function deepFreeze(tableToFreeze)
    local mt = {
        __index = tableToFreeze,
        __newindex = function(t, k, v) error("Attempt to modify frozen table", 2) end,
        __metatable = false
    }
    setmetatable(tableToFreeze, mt)
    for k, v in pairs(tableToFreeze) do
        if type(v) == "table" then
            tableToFreeze[k] = deepFreeze(v)
        end
    end
    return tableToFreeze
end

local function secureHookFunction(originalFunc, hookFunc)
    -- In a real-world scenario, consider using a more robust hooking library.
    return function(...)
        hookFunc(...)
        return originalFunc(...)
    end
end

local function analyzePlayerBehavior(player)
    -- TODO: Implement machine learning or heuristic-based behavior analysis here.
    -- This is a placeholder.  You would need a system to track player actions
    -- (movement, shooting, etc.) and look for patterns indicative of cheating.
    return 0  -- Return a "suspicion score" (0 = not suspicious, 1 = very suspicious)
end

local function getPathValue(object, path)
    local parts = string.split(path, ".")
    local current = object
    for _, part in ipairs(parts) do
        if current and current[part] then
            current = current[part]
        else
            return nil
        end
    end
    return current
end

local function calculateJerk(acceleration1, acceleration2, deltaTime)
    if deltaTime <= 0 then return Vector3.new() end
    return (acceleration2 - acceleration1) / deltaTime
end


----------------------- MONITORING MODULES (Server) -----------------------

local function monitorFunction(func, funcName)
    if not func then return end
    local funcDump = string.dump(func)
    local originalHash = generateHash(funcDump)
    FunctionHashes[funcName] = originalHash
    FunctionMonitors[funcName] = func
end

local function checkFunctionTampering()
    for funcName, func in pairs(FunctionMonitors) do
        local originalHash = FunctionHashes[funcName]
        if isFunctionTampered(func, originalHash) then
            for _, player in ipairs(Players:GetPlayers()) do
                serverCheckAndBan(player, "Function Tampering Detected: " .. funcName)
            end
        end
    end
end

local function monitorModule(module, moduleName)
    if not module then return end
    local moduleSource = module:GetAttribute("Source") or ""  -- Use :GetAttribute
    if moduleSource == "" then return end
    local originalHash = generateHash(moduleSource)
    ModuleHashes[moduleName] = originalHash
    ModuleMonitors[moduleName] = module
end

local function checkModuleTampering()
    for moduleName, module in pairs(ModuleMonitors) do
        local originalHash = ModuleHashes[moduleName]
        local currentSource = module:GetAttribute("Source") or "" -- Use :GetAttribute
        if currentSource == "" then goto continue end
        local currentHash = generateHash(currentSource)
        if currentHash ~= originalHash then
            for _, player in ipairs(Players:GetPlayers()) do
                serverCheckAndBan(player, "Module Tampering Detected: " .. moduleName)
            end
        end
        ::continue::
    end
end

----------------------- METAMETHOD MONITORING (Server) -----------------------

local function hookMetamethod(object, metamethodName, banReason)
    if not object or not metamethodName then return end
    local mt = getmetatable(object)
    if not mt then return end
    local originalMetamethod = mt[metamethodName]
    if not originalMetamethod then return end

    local hookedMetamethod
    if metamethodName == "__index" then
        hookedMetamethod = function(t, k)
            local player = Players:GetPlayerFromCharacter(t)
            if player then
                serverCheckAndBan(player, banReason .. " (__index): " .. tostring(k))
            end
            return originalMetamethod(t, k)
        end
    elseif metamethodName == "__newindex" then
        hookedMetamethod = function(t, k, v)
            local player = Players:GetPlayerFromCharacter(t)
            if player then
                serverCheckAndBan(player, banReason .. " (__newindex): " .. tostring(k))
            end
            return originalMetamethod(t, k, v)
        end
    else
        hookedMetamethod = function(...)
            local player = Players:GetPlayerFromCharacter(object)
            if player then
                serverCheckAndBan(player, banReason .. " ("..metamethodName..")")
            end
            return originalMetamethod(...)
        end
    end

    mt[metamethodName] = hookedMetamethod
    Metamethods[metamethodName] = { object, originalMetamethod }
end

local function restoreMetamethods()
    for metamethodName, data in pairs(Metamethods) do
        local object, originalMetamethod = unpack(data)
        local mt = getmetatable(object)
        if mt then
            mt[metamethodName] = originalMetamethod
        end
    end
    Metamethods = {}
end

----------------------- PLAYER REPORTING (Server) -----------------------

local function reportPlayer(reporter, reportedPlayer, reason)
    if not reporter or not reportedPlayer or not reason then return end
    if reporter == reportedPlayer then return end  -- Prevent self-reporting
    if (PlayerReports[reporter.UserId] or 0) >= Config.MAX_REPORTS_PER_PLAYER then return end

    PlayerReports[reporter.UserId] = (PlayerReports[reporter.UserId] or 0) + 1  -- Increment report count
    if not PlayerReports[reportedPlayer.UserId] then
        PlayerReports[reportedPlayer.UserId] = { Reports = 1, Reasons = { reason } }
    else
        PlayerReports[reportedPlayer.UserId].Reports = PlayerReports[reportedPlayer.UserId].Reports + 1
        table.insert(PlayerReports[reportedPlayer.UserId].Reasons, reason)
    end

    if PlayerReports[reportedPlayer.UserId].Reports >= Config.REPORT_THRESHOLD then
        print("Player " .. reportedPlayer.Name .. " has reached the report threshold. Reviewing reports:", table.concat(PlayerReports[reportedPlayer.UserId].Reasons, ", "))
        -- TODO: Implement a review process (log, notify admins, etc.)
    end
end

----------------------- GAME FUNCTION MONITORING (Server) -----------------------

local function monitorGameFunctions()
    local functionsToMonitor = {
        Players.PlayerAdded,
        Players.PlayerRemoving,
        ReplicatedStorage.RemoteEvent.OnServerEvent,
        ReplicatedStorage.RemoteFunction.OnServerInvoke,
        Workspace.ChildAdded,
        Workspace.ChildRemoved,
        -- Add other core game functions as needed
    }
    for _, func in ipairs(functionsToMonitor) do
        local funcName = tostring(func)  -- More reliable string representation
        monitorFunction(func, funcName)
        GameFunctions[funcName] = func
    end
end

----------------------- SERVER-SIDE VALIDATION (Placeholder) -----------------------

-- **CRITICAL: YOU MUST IMPLEMENT SERVER-SIDE VALIDATION FOR ALL GAME ACTIONS**
local function validateAction(player, action, data)
    if not player or not action then return false end

    if action == "Move" then
        -- Example: Check if the player's movement speed is within limits.
        local speed = data.Speed
        if speed > 25 then  -- Example max speed
            serverCheckAndBan(player, "Invalid Move Speed")
            return false
        end
    elseif action == "ResourceChange" then
        -- Example: Check if a resource change (e.g., health, ammo) is valid.
        local resource = data.Resource
        local amount = data.Amount
        if resource == "Health" and amount > 100 then -- Example impossible health gain
            serverCheckAndBan(player, "Invalid Health Change")
            return false
        end
    elseif action == "PurchaseItem" then
        -- Example: Check if the player has enough currency and the item exists.
        -- **YOU MUST INTEGRATE THIS WITH YOUR GAME'S ECONOMY SYSTEM**
        local itemID = data.ItemID
        local cost = data.Cost
         -- Check if itemID is valid, player has enough currency, etc.
        if not data.HasEnoughCurrency then -- Replace with your game logic
            serverCheckAndBan(player,"Attempted Purchase Without Funds")
            return false
        end
    elseif action == "DealDamage" then
        -- Example: Check if damage dealt is within the weapon's limits,
        -- if the target is valid, etc.
        -- **YOU MUST INTEGRATE THIS WITH YOUR GAME'S COMBAT SYSTEM**
        local damage = data.Damage
        local weapon = data.Weapon
        local target = data.Target
        if not data.IsValidTarget or damage > data.MaxWeaponDamage then  -- Replace with your logic
             serverCheckAndBan(player,"Invalid Damage")
            return false;
        end
    end
    -- Add validation for ALL other game actions here!

    return true  -- Return true if the action is valid
end

----------------------- PLAYER ACTIVITY TRACKING (Server) -----------------------

local function trackPlayerActivity(player, activityType, value)
    if not player then return end
    PlayerActivity[player.UserId] = PlayerActivity[player.UserId] or {}
    PlayerActivity[player.UserId][activityType] = value
    -- TODO: Implement more detailed activity tracking (e.g., positions, actions)
    -- for use in behavior analysis.
end

----------------------- FUNCTION HOOKING (Server) -----------------------

local function hookFunction(func, hookFunction, funcName)
    if not func or not hookFunction or not funcName then return end
    local hookedFunc = secureHookFunction(func, hookFunction)
    FunctionHooks[funcName] = {func, hookedFunc}
    -- Avoid using _G for security.  Store hooks within the AntiCheat table.
    AntiCheat[funcName] = hookedFunc
end

local function restoreFunctionHooks()
    for funcName, data in pairs(FunctionHooks) do
        local originalFunc = data[1]
        -- Restore from AntiCheat table, not _G.
        AntiCheat[funcName] = originalFunc
    end
    FunctionHooks = {}  -- Clear after restoring
end


----------------------- CLIENT-SIDE FUNCTIONS -----------------------

local function monitorPotentiallyTamperedFunction(func, functionName, detectionReason)
    if typeof(func) ~= "function" then return end
    if ClientFunctionProxies[func] then
        return ClientFunctionProxies[func]
    end

    local original = func
    local proxy = newproxy(true)
    local meta = {
        __call = function(_, ...)
            if isFunctionTampered(original) then
                if Players.LocalPlayer then  -- Use full path
                    clientCheckAndBan(Players.LocalPlayer, detectionReason or ("Function Tampering Detected: " .. functionName))
                end
                error(detectionReason or ("Function Tampering Detected: " .. functionName), 2)
            end
            return original(...)
        end,
        __metatable = false,
    }
    setmetatable(proxy, meta)
    ClientFunctionProxies[func] = proxy
    return proxy
end



local function monitorGameFunctionsClient()
    local MONITORED_GAME_FUNCTIONS_KEYWORDS = {
        -- Example: "DealDamage", "ApplyForce", "GrantItem"
		-- Add more keywords related to functions that could be exploited.
    }
    for _, keyword in ipairs(MONITORED_GAME_FUNCTIONS_KEYWORDS) do
        for i, v in getgc() do
            if typeof(v) == "function" and islclosure(v) then
                local funcInfo = debug.info(v, "n")
                if funcInfo and funcInfo.name and string.find(funcInfo.name, keyword, 1, true) then
                    monitorPotentiallyTamperedFunction(v, funcInfo.name, "Game Function Tampering Detected: " .. funcInfo.name)
                end
            end
        end
    end
end

local function monitorPlayerModule()
    local PLAYER_MODULE_PATH_COMPONENT = "PlayerModule"
    for Index, PotentialFunction in next, getgc(true) do
        if typeof(PotentialFunction) == "function" then
            local ScriptInfo = debug.info(PotentialFunction, "s")
            if ScriptInfo and ScriptInfo.source then
                if string.find(ScriptInfo.source, PLAYER_MODULE_PATH_COMPONENT, 1, true) then
                    local Upvalues = debug.getupvalues(PotentialFunction)
                    for UpvalueIndex, UpvalueValue in ipairs(Upvalues) do
                        if typeof(UpvalueValue) == "function" then
                            warn("Anti-Cheat: Potential PlayerModule Tampering Detected in script:", ScriptInfo.source)
                            warn("Function:", PotentialFunction)
                            warn("Upvalue Index:", UpvalueIndex, ", Upvalue Type:", typeof(UpvalueValue))
                             if Players.LocalPlayer then  -- Use full path
                                clientCheckAndBan(Players.LocalPlayer, "PlayerModule Tampering Detected (Function Upvalue)")
                            end
                            error("Anti-Cheat: PlayerModule Hooked (Function Upvalue)", 2)
                            return
                        end
                    end
                end
            end
        end
    end
end

local function monitorApiCalls()
    local MONITORED_APIS = {
        FireServer = {parent = "RemoteEvent", eventNameContains = {}},
        InvokeServer = {parent = "RemoteFunction", eventNameContains = {}},
		SetAttribute = {parentTypes = {"BasePart", "Model", "DataModel"}, attributeNameContains = {}},
        GetAttribute = {parentTypes = {"BasePart", "Model", "DataModel"}, attributeNameContains = {}},
        SetNetworkOwnership = {parentTypes = {"BasePart", "Model"}},
    }
    for apiName, apiConfig in pairs(MONITORED_APIS) do
        local apiParentType = apiConfig.parentTypes
        local apiParent = apiConfig.parent
        local eventNameContains = apiConfig.eventNameContains
        local functionNameContains = apiConfig.functionNameContains

        if apiParent then
            local targetParent = ReplicatedStorage:FindFirstChild(apiParent) or game:GetService(apiParent)
            if targetParent then
                if apiName == "FireServer" or apiName == "OnServerEvent" or apiName == "OnClientEvent" then
                    for _, remote in pairs(targetParent:GetDescendants()) do
                        if remote:IsA("RemoteEvent") then
                            local hookId = apiName .. "_" .. remote:GetFullName()
                            if not ClientAPIMonitoringHooks[hookId] then
                                ClientAPIMonitoringHooks[hookId] = hookmetamethod(remote, "__namecall", function(self, ...)
                                    local method = getnamecallmethod()
                                    local args = {...}
                                    if method == apiName then
                                        local eventName = args[1] -- Assuming event name is the first argument
                                         local isNameMatch = #eventNameContains == 0
                                        for _, nameFilter in ipairs(eventNameContains) do
                                            if string.find(eventName, nameFilter, 1, true) then
                                                isNameMatch = true
                                                break
                                            end
                                        end
                                        if isNameMatch then
                                             if Players.LocalPlayer then  -- Use full path
                                                clientCheckAndBan(Players.LocalPlayer, "Suspicious API Call: " .. apiName .. " on " .. remote:GetFullName() .. (eventName and (" EventName: " .. eventName) or ""))
                                            end
                                            error("Anti-Cheat: Suspicious API Call: " .. apiName .. " on " .. remote:GetFullName() .. (eventName and (" EventName: " .. eventName) or ""), 2)
                                        end
                                    end
                                    return ClientAPIMonitoringHooks[hookId](self, ...)
                                end)
                            end
                        end
                    end
                elseif apiName == "InvokeServer" or apiName == "OnServerInvoke" or apiName == "OnClientInvoke" then
                    for _, remote in pairs(targetParent:GetDescendants()) do
                        if remote:IsA("RemoteFunction") then
                            local hookId = apiName .. "_" .. remote:GetFullName()
                            if not ClientAPIMonitoringHooks[hookId] then
                                 ClientAPIMonitoringHooks[hookId] = hookmetamethod(remote, "__namecall", function(self, ...)
                                    local method = getnamecallmethod()
                                    local args = {...}
                                    if method == apiName then
                                        local functionName = args[1] -- Assuming function name is the first arg
                                         local isNameMatch = #functionNameContains == 0
                                        for _, nameFilter in ipairs(functionNameContains) do
                                            if string.find(functionName, nameFilter, 1, true) then
                                                isNameMatch = true
                                                break
                                            end
                                        end
                                        if isNameMatch then
                                             if Players.LocalPlayer then  -- Use full path
                                                clientCheckAndBan(Players.LocalPlayer, "Suspicious API Call: " .. apiName .. " on " .. remote:GetFullName() .. (functionName and (" FunctionName: " .. functionName) or ""))
                                            end
                                            error("Anti-Cheat: Suspicious API Call: " .. apiName .. " on " .. remote:GetFullName() .. (functionName and (" FunctionName: " .. functionName) or ""), 2)
                                        end
                                    end
                                     return ClientAPIMonitoringHooks[hookId](self, ...)
                                end)
                            end
                        end
                    end
                end
             elseif apiParentType then
                for _, objectType in ipairs(apiParentType) do
                    local hookId = apiName .. "_" .. objectType
                    if not ClientAPIMonitoringHooks[hookId] then
                        ClientAPIMonitoringHooks[hookId] = hookmetamethod(game, "__namecall", function(self, ...)
                            local method = getnamecallmethod()
                            local args = {...}
                            if method == apiName and typeof(self) == objectType then
                                local attributeName = args[1] -- Assuming attribute name is the first arg
                                local isNameMatch = #apiConfig.attributeNameContains == 0
                                 for _, nameFilter in ipairs(apiConfig.attributeNameContains) do
                                    if string.find(attributeName, nameFilter, 1, true) then
                                        isNameMatch = true
                                        break
                                    end
                                end

                                if isNameMatch then
                                     if Players.LocalPlayer then  -- Use full path
                                        clientCheckAndBan(Players.LocalPlayer, "Suspicious API Call: " .. apiName .. " on " .. objectType .. (attributeName and (" AttributeName: " .. attributeName) or ""))
                                    end
                                    error("Anti-Cheat: Suspicious API Call: " .. apiName .. " on " .. objectType .. (attributeName and (" AttributeName: " .. attributeName) or ""), 2)
                                end
                            end
                            return ClientAPIMonitoringHooks[hookId](game, ...)
                        end)
                    end
                end
            end
        end
    end
end


local function monitorPlayerProperties()
    local MONITORED_PLAYER_PROPERTIES = {
        ["Humanoid.Health"] = {maxValue = 200, minValue = -100, banReason = "Impossible Health Value"},
        ["Humanoid.WalkSpeed"] = {maxValue = 50, minValue = 0, banReason = "Impossible WalkSpeed"},
		-- Add more properties to monitor (e.g., JumpPower, Camera properties).
    }
     if not Players.LocalPlayer or not Players.LocalPlayer.Character or not Players.LocalPlayer.Character:FindFirstChild("Humanoid") then return end

    for propertyPath, config in pairs(MONITORED_PLAYER_PROPERTIES) do
        local propertyValue = getPathValue(Players.LocalPlayer, propertyPath)  -- Use full path
        if propertyValue ~= nil then
            if config.maxValue ~= nil and propertyValue > config.maxValue then
                clientCheckAndBan(Players.LocalPlayer, config.banReason or ("Property Check Failed: " .. propertyPath .. " exceeds max value"))
                error("Anti-Cheat: Property Check Failed: " .. propertyPath .. " exceeds max value", 2)

            elseif config.minValue ~= nil and propertyValue < config.minValue then
                clientCheckAndBan(Players.LocalPlayer, config.banReason or ("Property Check Failed: " .. propertyPath .. " below min value"))
                 error("Anti-Cheat: Property Check Failed: " .. propertyPath .. " below min value", 2)
            end
        end
    end
end

local function inputRateLimiting()
    local INPUT_RATE_LIMITS = {
        ["JumpAction"] = {maxRate = 5, banReason = "Excessive Jump Rate"},
        ["AttackAction"] = {maxRate = 10, banReason = "Excessive Attack Rate"},
		-- Add more actions to rate-limit (e.g., specific weapon firing rates).
    }
    local INPUT_RATE_LIMIT_INTERVAL = 0.1  -- Seconds
    UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end

        for actionName, config in pairs(INPUT_RATE_LIMITS) do
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local actionKey = string.lower(input.KeyCode.Name) .. "Action"
                if actionKey == actionName:lower() then
                    local currentTime = os.clock()
                    local lastActionTime = ClientLastActionTimes[actionName] or 0
                    if (currentTime - lastActionTime) < INPUT_RATE_LIMIT_INTERVAL then
                         if Players.LocalPlayer then  -- Use full path
                            clientCheckAndBan(Players.LocalPlayer, config.banReason or ("Input Rate Limit Exceeded: " .. actionName))
                        end
                        error("Anti-Cheat: Input Rate Limit Exceeded: " .. actionName, 2)
                    else
                        ClientLastActionTimes[actionName] = currentTime
                    end
                end
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
                local actionMouseButton = "MouseButton1Action" --For mouse clicks
                if actionMouseButton == actionName:lower() then
                    local currentTime = os.clock()
                    local lastActionTime = ClientLastActionTimes[actionName] or 0
                    if (currentTime - lastActionTime) < INPUT_RATE_LIMIT_INTERVAL then
                         if Players.LocalPlayer then
                            clientCheckAndBan(Players.LocalPlayer, config.banReason or ("Input Rate Limit Exceeded: " .. actionName))
                        end
                        error("Anti-Cheat: Input Rate Limit Exceeded: " .. actionName, 2)
                    else
                        ClientLastActionTimes[actionName] = currentTime
                    end
                end
            end
            -- Add rate limiting for other input types as needed
        end
    end)
end

----------------------- HANDSHAKE (Improved) -----------------------

local function setupHandshake()
    local Remote = Instance.new("RemoteEvent")
    Remote.Name = "CharacterSoundEvent"  -- Use a consistent, less obvious name
    if not ReplicatedStorage:FindFirstChild("Remotes") then --Creates "Remotes" folder
        local remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end
    Remote.Parent = ReplicatedStorage:WaitForChild("Remotes")  -- Use WaitForChild

    local Handshake = {}

    local function __call(T, ...)
        local args = {...}
        if #args == 5 and args[1] == 887 then  -- Basic validation
            local sum = 0
            for i = 2, #args do
                sum = sum + args[i]
            end

            if T[1] == math.floor((sum/5)+0.5) then
                return T
            else
                warn("Invalid Handshake received!")
                return {}
            end
        end
        return T
    end

    -- Server-side Handshake Event
    Remote.OnServerEvent:Connect(function(player, method, newArgs)
        if method == "ðŸ’±AC" and newArgs then  -- Use a consistent, unique identifier
            if #newArgs == 5 then
                local checksum = 0
                for i = 1, #newArgs do
                    checksum += newArgs[i]
                end
                ServerHandshake[player.UserId] = checksum
            else
                warn("Invalid handshake data received from", player.Name)
            end
        end
    end)

    -- Client-side Handshake Event
     Remote.OnClientEvent:Connect(function(Method, _, NewArgs)
        if Method == "ðŸ’±AC" then  -- Consistent identifier
            if NewArgs then
                local checksum = 0
                for i = 1, #NewArgs do
                    Handshake[i] = NewArgs[i]
                    checksum = checksum + NewArgs[i]
                end
                Handshake[1] = math.floor((checksum/#NewArgs)+.5)
            end
        end
    end)

    -- Server Periodic Check
    task.spawn(function()
        while task.wait(5) do
            for _, player in pairs(Players:GetPlayers()) do
                if ServerHandshake[player.UserId] == nil then
                    serverCheckAndBan(player, "Failed Handshake")
                end
                ServerHandshake[player.UserId] = nil  -- Reset for the next check
            end
        end
    end)

    -- Client Periodic Handshake
    task.spawn(function()
        while task.wait(0.5) do  -- Frequent handshakes
            local args = {}
            for i = 1, 5 do
                args[i] = math.random(1000000, 100000000)  -- Larger range
            end
            Remote:FireServer("ðŸ’±AC", args)  -- Consistent identifier
        end
    end)

    setmetatable(Handshake, { __call = __call })
end

----------------------- INITIALIZATION (Server) -----------------------
local function logExploit(player, exploitType, details)
	if true then --Replace with Config setting if you add one
		local logMessage = string.format("Exploit Detected: Player=%s, Type=%s, Details=%s", player.Name, exploitType, details)
		print(logMessage)
         if Config.WEBHOOK_URL ~= "" then
            pcall(function()
                                local payload = { content = logMessage }
                HttpService:PostAsync(Config.WEBHOOK_URL, HttpService:JSONEncode(payload))
            end)
        end
	end
end


function AntiCheat.Initialize()
    -- Freeze critical tables (Server)
    deepFreeze(BannedPlayers)
    deepFreeze(PlayerReports)
    deepFreeze(FunctionHashes)
    deepFreeze(ModuleHashes)
    deepFreeze(FunctionMonitors)
    deepFreeze(ModuleMonitors)
    deepFreeze(PlayerActivity)
    deepFreeze(GameFunctions)
    deepFreeze(Metamethods)
    deepFreeze(FunctionHooks)
    deepFreeze(ServerHandshake) -- Freeze handshake data too

    monitorGameFunctions()

    for _, module in ipairs(game.ServerScriptService:GetDescendants()) do
        if module:IsA("ModuleScript") then
            monitorModule(module, module.Name)
        end
    end

    -- Hook Metamethods for existing players
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            hookMetamethod(player.Character, "__index", "Metamethod Tampering Detected")
            hookMetamethod(player.Character, "__newindex", "Metamethod Tampering Detected")
        end
    end

    -- Monitor new scripts/modules being added
    game.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("Script") or descendant:IsA("LocalScript") then
            for _, player in ipairs(Players:GetPlayers()) do
                serverCheckAndBan(player, "New Script Added: " .. descendant.Name)
            end
        elseif descendant:IsA("ModuleScript") then
            monitorModule(descendant, descendant.Name)
        end
    end)

    -- Periodic function tampering checks
    task.spawn(function()
        while true do
            task.wait(Config.FUNCTION_MONITOR_INTERVAL)
            checkFunctionTampering()
        end
    end)

    -- Periodic module tampering checks
    task.spawn(function()
        while true do
            task.wait(Config.MODULE_MONITOR_INTERVAL)
            checkModuleTampering()
        end
    end)

    -- Player connection handling
    game.Players.PlayerAdded:Connect(function(player)
        player.CharacterAdded:Connect(function(character)
            hookMetamethod(character, "__index", "Metamethod Tampering Detected")
            hookMetamethod(character, "__newindex", "Metamethod Tampering Detected")
        end)

        -- Behavior analysis loop (periodic)
        task.spawn(function()
            while player and player.Parent do -- Check if player is still in game
                task.wait(Config.ML_CHECK_INTERVAL)
                local behaviorScore = analyzePlayerBehavior(player) -- Placeholder function
                if behaviorScore >= Config.DETECTION_THRESHOLD then
                    serverCheckAndBan(player, "Unusual Behavior Detected")
                end
            end
        end)
    end)

    -- Player disconnection handling
    game.Players.PlayerRemoving:Connect(function(player)
        PlayerActivity[player.UserId] = nil
        PlayerReports[player.UserId] = nil
        ServerHandshake[player.UserId] = nil -- Clean up handshake data
        PlayerData[player] = nil -- Clear player-specific data
    end)

    -- Initialize function monitoring if enabled
    if Config.FUNCTION_MONITORING_ENABLED then
        for _, funcInfo in ipairs(MonitoredFunctions) do
            if funcInfo and funcInfo.func and funcInfo.name then
                monitorFunction(funcInfo.func, funcInfo.name)
            else
                warn("Invalid entry in MonitoredFunctions. Ensure each entry has 'func' and 'name'.")
            end
        end
    end

    print("Anti-Cheat Module Initialized.")
end


----------------------- START CLIENT-SIDE MONITORING -----------------------

local function initializeClientAntiCheat()
    local LocalPlayer = Players.LocalPlayer -- Get LocalPlayer once

    -- Periodic Monitoring (Client)
    local function monitorAllPeriodically()
        local MONITORING_LOOP_INTERVAL = 2
        task.spawn(function()
            while true do
                monitorGameFunctionsClient() -- Client-side game function monitoring
                monitorApiCalls()            -- Client-side API call monitoring
                monitorPlayerProperties()    -- Client-side property monitoring
                task.wait(MONITORING_LOOP_INTERVAL)
            end
        end)
    end

    -- PlayerModule Monitoring (Periodic - Client)
    local function monitorPlayerModulePeriodically()
        local PLAYER_MODULE_MONITOR_INTERVAL = 60
        task.spawn(function()
            while true do
                task.wait(PLAYER_MODULE_MONITOR_INTERVAL)
                monitorPlayerModule()       -- Client-side PlayerModule monitoring
            end
        end)
    end

    monitorAllPeriodically()
    monitorPlayerModulePeriodically()
    inputRateLimiting()
    setupHandshake()                  -- Start the handshake process
    print("Comprehensive Client-Side Anti-Cheat Initialized. Monitoring game for suspicious activity.")
end

----------------------- MAIN SERVER LOOP (Aggressive Checks) -----------------------

local function mainLoop()
    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        if not char then goto continue end
        local humanoid = char:FindFirstChild("Humanoid")
        local humanoidRootPart = char:FindFirstChild("HumanoidRootPart")
        if not humanoid or not humanoidRootPart then goto continue end

        local data = PlayerData[player]
        if not data then
            initializePlayerData(player) -- Initialize if data is missing (new player?)
            data = PlayerData[player]
            if not data then goto continue end -- Still no data? Something's wrong.
        end

        local currentTime = tick()
        local deltaTime = currentTime - data.LastUpdateTime
        data.LastUpdateTime = currentTime
        if deltaTime <= 0 then goto continue end -- Avoid division by zero

        checkNoClip(player, humanoidRootPart, data, deltaTime)
        checkSpeedAndJump(player, humanoid, humanoidRootPart, data, deltaTime)
        checkFly(player, humanoid, humanoidRootPart, data, deltaTime)
        checkTeleport(player, humanoidRootPart, data, deltaTime)
        checkGodMode(player, humanoid, data, deltaTime)
        checkSilentAim(player, humanoid, humanoidRootPart, data, deltaTime)

        ::continue:: -- Label for goto statement
    end

    -- Anti-Bypass Checks (Run periodically in main loop)
    if not AntiCheat.AntiBypass.CheckScriptIdentity() or not AntiCheat.AntiBypass.CheckFunctionIntegrity() or not AntiCheat.AntiBypass.CheckForHooks() then
        -- Handle bypass attempt - Log, investigate, but don't immediately ban (potential false positive)
        warn("Anti-bypass checks failed! Potential anti-cheat tampering detected.")
        -- Log this event to external service for review if possible.
    end
    checkMetatableHooks() -- Periodic metatable hook check
end


-- Initialize Player Data on Player Added (Server)
Players.PlayerAdded:Connect(function(player)
    initializePlayerData(player) -- Initialize player-specific data
    local function characterAdded(character)
        local humanoid = character:WaitForChild("Humanoid")
        humanoid.Died:Connect(function()
            -- Reset counters and states on death (optional, adjust as needed)
            local data = PlayerData[player]
            if data then
                data.NoClipCounter = 0
                data.SpeedCounter = 0
                data.JumpCounter = 0
                data.FlyCounter = 0
                data.TeleportCounter = 0
                data.LastJumpTime = 0
                data.IsInAir = false
                data.HeadshotCount = 0    -- Reset headshot count on death? (Game-specific decision)
                data.TotalShots = 0       -- Reset total shots?
            end
        end)
        humanoid.Damaged:Connect(function(damage)
            onHumanoidDamaged(humanoid, damage) -- Track damage events
        end)
    end

    if player.Character then
        characterAdded(player.Character) -- Handle character already loaded on join
    end
    player.CharacterAdded:Connect(characterAdded) -- Handle character spawning later

    -- Ban Check on Player Join (DataStoreService integration)
    local banStore = DataStoreService:GetDataStore("PlayerBans") -- Or your ban datastore name
    local success, banData = pcall(function()
        return banStore:GetAsync(tostring(player.UserId))
    end)

    if success and banData then
        if banData == -1 or banData > os.time() then -- -1 for permanent ban
            player:Kick("You are banned from this game. Ban expires: " .. (banData == -1 and "Never" or os.date("%c", banData)))
            return -- Stop further initialization for banned player
        end
    end
end)


-- Clear Player Data on Player Removing (Server)
Players.PlayerRemoving:Connect(clearPlayerData)

-- Start Main Server Loop (Heartbeat - High Frequency)
RunService.Heartbeat:Connect(mainLoop)

-- Initialize Server-Side Anti-Cheat
AntiCheat.Initialize()

-- Initialize Client-Side Anti-Cheat (Run this ONLY in a LocalScript)
if RunService:IsClient() then
    initializeClientAntiCheat()
    hookRemoteEvents() -- Hook remote events on the client too (for monitoring)
end


return AntiCheat -- Return the AntiCheat module (primarily for server-side use)
