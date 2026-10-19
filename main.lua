-- AstralX hub: [STANDS] Anime Astral Simulator. One window (MacLib), every feature.
-- The whole UI is built first: once the game's modules are required, building UI from this thread fails.

-- Singleton: tear down previous runs (including the old separate roll hub) so windows and loops never stack.
for _, name in ipairs({ "AstralX", "AstralXRoll" }) do
    local previous = getgenv()[name]
    if previous and previous.Unload then
        pcall(previous.Unload)
    end
    getgenv()[name] = nil
end

-- Remove windows left behind by runs that died before registering their Unload.
pcall(function()
    local hosts = { gethui and gethui(), game:GetService("CoreGui"), game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui") }
    for _, host in ipairs(hosts) do
        for _, root in ipairs(host:GetChildren()) do
            if root:IsA("ScreenGui") then
                local stale = root.Name == "AstralXUI" or root.Name == "AstralXBest"
                if not stale then
                    for _, d in ipairs(root:GetDescendants()) do
                        if d:IsA("TextLabel") and (d.Text == "AstralX" or d.Text == "AstralX Roll") then
                            stale = true
                            break
                        end
                    end
                end
                if stale then
                    root:Destroy()
                end
            end
        end
    end
end)

local State = {
    Running = true,
    -- farm
    AutoQuest = false,
    ClickDelay = 0.06,
    Offset = Vector3.new(0, 0, 6),
    -- gamemodes
    AutoTimeTrial = false,
    TrialKey = "Highest open",
    AutoRaid = false,
    RaidKey = "World6",
    AutoGate = false,
    AutoDefense = false,
    DefenseKey = "Best", -- a DefenseConfig key, or "Best": the highest defense with a key that we can solo
    DefenseLeaveWave = 0, -- leave once this wave is reached (0 = play to the end)
    -- fully auto raid/defense: runs the chosen modes in turn and farms a mode's key when none has one
    FullAuto = false,
    FullAutoModes = {}, -- ["Raid:World6"] / ["Defense:World8"] = true
    FullAutoOrder = "High", -- "High": highest world first; "Low": lowest first
    FullAutoSoloOnly = true, -- skip modes the solo estimate says we cannot finish
    FullAutoFarm = true, -- farm the missing key from world enemies
    -- passive rolls (pets, swords, shadows, titans, grimoire slots, player): own loops, not the game's auto roll
    AutoPassivePet = false,
    AutoPassiveSword = false,
    AutoPassiveShadow = false,
    AutoPassiveTitan = false,
    AutoPassiveGrimoire = false,
    AutoPassivePlayer = false,
    PassiveTarget = "Divine", -- stop once the current passive reaches this rarity (the server keeps the best)
    PassivePetRarities = {}, -- [pet rarity] = true: only pets of these rarities are rolled (empty = none)
    PassivePetEquippedOnly = true,
    -- boosts
    AutoPotion = false,
    -- roll
    AutoCollect = false,
    CollectReturn = true,
    AutoStar = false,
    StarKey = "World1",
    StarDelay = 0.3,
    AutoGacha = false,
    AutoUpgrade = false,
    UpgradeKeys = {}, -- [systemKey] = true
    UpgradeInterval = 5,
    -- progression
    ProgressInterval = 5,
    AutoUpgrade2 = false,
    Upgrade2Keys = {}, -- [systemKey] = true
    AutoRange = false,
    AutoProgression = false,
    ProgressionKeys = {}, -- [worldKey] = true
    AutoRankUp = false,
    AutoPromotion = false,
    AutoClaim = false,
    AutoRelic = false,
    -- accessories
    AutoAccEquip = false,
    AccScoreMode = "Total",
    AutoCurse = false,
    CurseTarget = "Legendary",
    CurseReserve = 0,
    AutoEquipBest = false,
    EquipBestStat = "Power",
    -- server-side automations: a toggle only marks its flag dirty, the sync loop sends it once
    FlagDirty = {}, -- [flag] = true
    Actions = {}, -- button handlers, filled in by the logic section
    -- info panels (see makePanel)
    PanelAccessories = false,
    PanelUpgrades = false,
    PanelProgress = false,
    PanelTokens = false,
    -- discord webhook
    WebhookUrl = "",
    WebhookPing = "",
    WebhookDrops = false,
    WebhookMinRarity = "Mythical",
    WebhookSummary = false,
    WebhookInterval = 30, -- minutes
    WebhookEvents = false, -- raid/defense finished, key obtained, world unlocked
    LastStatus = "", -- latest character-activity line (setStatus)
    GachaKeys = {}, -- [gachaKey] = true
    GachaDelay = 0,
    GachaMode = "Rodizio", -- "Rodizio": every selected gacha in turn; "Meta": a few at a time until the target
    GachaTarget = "Secret",
    GachaBatch = 3,
    AutoGrimoire = false,
    GrimoireSlots = { Slot1 = true, Slot2 = true }, -- [slotKey] = true
    GrimoireTarget = "Astral",
    -- sell
    AutoSell = false,
    SellMaxRarity = "Common",
    SellKeepShiny = true,
    SellInterval = 15,
    BestPanel = true,
    -- alerts
    AlertsEnabled = true,
    AlertMinRarity = "Mythical",
    -- misc
    AntiAfk = true,
    -- scheduler: only one character-controlling feature runs at a time
    Owner = nil, -- feature currently allowed to act
    StepBusy = {}, -- [feature] = true while one of its steps is executing
    Priority = { Gate = 1, TimeTrial = 2, Raid = 3, Defense = 4, KeyFarm = 5, Collect = 6, Star = 7, Quest = 8 }, -- lower runs first
}

local FEATURE_ORDER = { "Gate", "TimeTrial", "Raid", "Defense", "KeyFarm", "Collect", "Star", "Quest" } -- default order, breaks ties
local FEATURE_LABELS = {
    Gate = "Auto Gate", TimeTrial = "Auto Time Trial", Raid = "Auto Raid", Defense = "Auto Defense",
    KeyFarm = "Farm de chave (Full Auto)", Collect = "Auto Coletar", Star = "Auto Star", Quest = "Auto Quest",
}
local priorityStatus

local Webhook = {} -- filled in by the webhook block below; alertHit calls Webhook.drop
local Panels = { toggles = {} } -- info panels: Panels[id] = panel, Panels.toggles[id] = the tab toggle that shows it
local connections = {}
local unloadHooks = {} -- functions run on unload (restore hooks)
local alertLog, alertLines = nil, {}
local statusHandles = {} -- farm / trial / raid status paragraphs
local starStatus, gachaStatus, grimoireStatus, sellStatus, upgradeStatus, progressStatus, accessoryStatus

local function updateBody(handle, text)
    if handle then
        pcall(function()
            handle:UpdateBody(text)
        end)
    end
end

local function setStatus(text)
    State.LastStatus = text -- the webhook summary reports the latest activity line
    for _, handle in ipairs(statusHandles) do
        updateBody(handle, text)
    end
end

local function setStar(text)
    updateBody(starStatus, text)
end

local function setGacha(text)
    updateBody(gachaStatus, text)
end

local function setSell(text)
    updateBody(sellStatus, text)
end

local function setUpgrade(text)
    updateBody(upgradeStatus, text)
end

-- Progression and accessory loops each own one status line; the paragraph shows them all.
local progressLines, accessoryLines = {}, {}

local function setLine(store, handle, name, text)
    store[name] = text
    local keys = {}
    for key in pairs(store) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do
        lines[#lines + 1] = store[key]
    end
    updateBody(handle, table.concat(lines, "\n"))
end

local function setProgress(name, text)
    setLine(progressLines, progressStatus, name, text)
end

local function setAccessory(name, text)
    setLine(accessoryLines, accessoryStatus, name, text)
end

-- Static lists (key, display name). Gachas: only token-costing ones can be rolled this way.
local TRIAL_OPTIONS = { "Highest open", "Insane", "Hard", "Medium", "Easy" }
local RAIDS = {
    { "World0", "Timeless Raid" }, { "World1", "Ninja Raid" }, { "World1Aldedo", "Tomb Raid" },
    { "World6", "InfinityCastle" }, { "World7", "Clover Raid" }, { "World10", "Soul Raid" },
    { "World12", "Sins Raid" }, { "World16", "Owl Suppression" }, { "World19", "Holy Grail War" },
    { "World20", "Alvarez War" }, { "World21MaxTac", "MaxTac Call" }, { "SanctuaryPast", "Sanctuary of the Past" },
    { "SanctuaryPresent", "Sanctuary of the Present" }, { "SanctuaryFuture", "Sanctuary of the Future" },
    { "LegacyRaid", "Legacy Raid" },
}
local STARS = {
    { "World1", "Ninja Village" }, { "World2", "Namek City" }, { "World3", "Wano Island" },
    { "World4", "Titan Wall" }, { "World5", "Solo city" }, { "World6", "Slayer Village" },
    { "World7", "Clover Island" }, { "World8", "Summer Art Online" }, { "World9", "Fire City" },
    { "World10", "Hueco World" }, { "World11", "Cursed School" }, { "World12", "Lion Kingdom" },
    { "World13", "Z City" }, { "World14", "Tempest Federation" }, { "World15", "Zaban City" },
    { "World16", "Tokyo Ward" }, { "World17", "Kingdom of Lugunica" }, { "World18", "New Leaf Village" },
    { "World19", "Fuyuki City" }, { "World20", "Magnolia Town" }, { "World21", "Night City" },
    { "World22", "Morioh Town" },
}
local GACHAS = {
    { "World0", "Cosmic Scale" }, { "World1", "DOUJUTSU" }, { "World1TailedBeasts", "Young Tailed Beasts" },
    { "World2", "RACES" }, { "World2DivineTechniques", "Divine Techniques" }, { "World3", "HAKIS" },
    { "World3DemonFruits", "Demon Fruits" }, { "World4", "FAMILY" }, { "World4HumanityArsenal", "HUMANITY ARSENAL" },
    { "World5", "HUNTER CLASS" }, { "World5Monarchs", "POWERFUL MONARCHS" }, { "World6", "DEMON MOONS" },
    { "World6Nichirin", "NICHIRIN SAYA" }, { "World7", "MAGIC ATTRIBUTES" }, { "World7MagicSquads", "MAGIC SQUAD" },
    { "World8", "RACES SAO" }, { "World8AincradSpoils", "AINCRAD SPOILS" }, { "World9", "BATTALION" },
    { "World9FlameCore", "FLAME CORES" }, { "World10", "SOUL ARTIFACTS" }, { "World10Bankai", "BANKAI" },
    { "World11", "INNATE TECHNIQUES" }, { "World11Shikigami", "SHADOW SHIKIGAMI" }, { "World12", "LEGENDARY ORDERS" },
    { "World12LegendaryWeapons", "LEGENDARY WEAPONS" }, { "World13", "HERO ARSENAL" },
    { "World13FightingStyles", "FIGHTING STYLES" }, { "World14", "SPIRITS" }, { "World15", "HUNTER BADGES" },
    { "World16", "CCG EXTERMINATION" }, { "World17", "RELICS OF THE OTHERWORLD" }, { "World18", "Scientific Ninja Tool" },
    { "World19", "Mystic Code" }, { "World20", "Classic Emblem" }, { "World21", "Cyberware" },
    { "World22", "Iconic Weapons" }, { "World23", "Chibi Gods of Destruction" },
}
local SELL_RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical" }
-- Shared by the on-screen alerts and the webhook, so it must exist before either section is built.
local ALERT_RARITIES = { "Epic", "Legendary", "Mythical", "Crafted", "Secret", "Divine", "Astral", "Exclusive", "Limited" }

local function buildOptions(list)
    local options, labelToKey = {}, {}
    for _, entry in ipairs(list) do
        local label = ("%s - %s"):format(entry[1], entry[2])
        options[#options + 1] = label
        labelToKey[label] = entry[1]
    end
    return options, labelToKey
end
local raidOptions, raidLabelToKey = buildOptions(RAIDS)
local starOptions, starLabelToKey = buildOptions(STARS)
local gachaOptions, gachaLabelToKey = buildOptions(GACHAS)

-- UI (MacLib) ---------------------------------------------------------------

local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

local Window = MacLib:Window({
    Title = "AstralX",
    Subtitle = "[STANDS] Anime Astral Simulator",
    Size = UDim2.fromOffset(900, 780),
    DragStyle = 1,
    DisabledWindowControls = {},
    ShowUserInfo = false,
    Keybind = Enum.KeyCode.RightControl,
    AcrylicBlur = false,
})

MacLib:SetFolder("AstralX") -- configs live in workspace/AstralX/settings/<name>.json

-- MacLib's config loader has two gaps: it sets slider and input values without running their Callback (State
-- keeps the old value while the UI shows the new one), and it skips toggles saved as off (loading a config
-- never turns anything off). After every successful load, close both so a config fully defines the hub.
do
    local HttpService = game:GetService("HttpService")
    local baseLoadConfig = MacLib.LoadConfig
    function MacLib:LoadConfig(path)
        local ok, err = baseLoadConfig(self, path)
        if ok then
            local saved = {}
            pcall(function()
                for _, object in ipairs(HttpService:JSONDecode(readfile(self.Folder .. "/settings/" .. path .. ".json")).objects) do
                    saved[object.flag] = object
                end
            end)
            task.delay(0.6, function() -- after MacLib's own task.spawn'ed loads
                for flag, option in pairs(self.Options) do
                    local callback = option.Settings and option.Settings.Callback
                    if option.Class == "Toggle" and saved[flag] and saved[flag].state == false then
                        pcall(option.UpdateState, option, false)
                    elseif callback and option.Class == "Slider" and option.Value ~= nil then
                        pcall(callback, option.Value)
                    elseif callback and option.Class == "Input" and option.Text ~= nil then
                        pcall(callback, option.Text)
                    end
                end
            end)
        end
        return ok, err
    end
end

local tabGroup = Window:TabGroup()
local farmTab = tabGroup:Tab({ Name = "Farm", Image = "rbxassetid://18821914323" })
local trialTab = tabGroup:Tab({ Name = "Time Trial", Image = "rbxassetid://18821914323" })
local raidTab = tabGroup:Tab({ Name = "Raid / Gate", Image = "rbxassetid://18821914323" })
-- defense / solo tabs and the solo paragraph, kept in one table (the main chunk is close to Luau's 200 locals)
local extraTabs = {
    defense = tabGroup:Tab({ Name = "Defense", Image = "rbxassetid://18821914323" }),
    solo = tabGroup:Tab({ Name = "Solo (DPS)", Image = "rbxassetid://18821914323" }),
    full = tabGroup:Tab({ Name = "Full Auto", Image = "rbxassetid://18821914323" }),
    passive = tabGroup:Tab({ Name = "Passivas", Image = "rbxassetid://18821914323" }),
    passiveLines = {}, -- one status line per passive system (setLine)
}
local rollTab = tabGroup:Tab({ Name = "Star", Image = "rbxassetid://18821914323" })
local gachaTab = tabGroup:Tab({ Name = "Gacha", Image = "rbxassetid://18821914323" })
local sellTab = tabGroup:Tab({ Name = "Sell", Image = "rbxassetid://18821914323" })
local upgradeTab = tabGroup:Tab({ Name = "Upgrade", Image = "rbxassetid://18821914323" })
local progressTab = tabGroup:Tab({ Name = "Progressao", Image = "rbxassetid://18821914323" })
local accessoryTab = tabGroup:Tab({ Name = "Acessorios", Image = "rbxassetid://18821914323" })
local alertTab = tabGroup:Tab({ Name = "Alertas", Image = "rbxassetid://18821914323" })
local priorityTab = tabGroup:Tab({ Name = "Prioridade", Image = "rbxassetid://18821914323" })
local miscTab = tabGroup:Tab({ Name = "Misc", Image = "rbxassetid://10734950309" })
local webhookTab = tabGroup:Tab({ Name = "Webhook", Image = "rbxassetid://10734950309" })
local configTab = tabGroup:Tab({ Name = "Config", Image = "rbxassetid://10734950309" })

local function addStatus(tab, header, hint)
    local section = tab:Section({ Side = "Right" })
    section:Header({ Text = "Status" })
    local handle = section:Paragraph({ Header = header, Body = "Parado." })
    if hint then
        section:SubLabel({ Text = hint })
    end
    return handle
end

-- Farm
local farmSection = farmTab:Section({ Side = "Left" })
farmSection:Header({ Text = "Auto Quest" })
farmSection:Toggle({
    Name = "Auto Quest",
    Default = false,
    Callback = function(value)
        State.AutoQuest = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoQuest")
farmSection:Slider({
    Name = "Delay do click",
    Default = State.ClickDelay,
    Minimum = 0.03,
    Maximum = 0.5,
    DisplayMethod = "Value",
    Precision = 2,
    Callback = function(value)
        State.ClickDelay = value
    end,
}, "ClickDelay")
farmSection:SubLabel({ Text = "Cadeia das quests de mundo: mata, coleta, compra e troca de mundo." })
farmSection:Header({ Text = "Itens no chao" })
farmSection:Toggle({
    Name = "Auto Coletar Itens",
    Default = false,
    Callback = function(value)
        State.AutoCollect = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoCollect")
farmSection:Toggle({
    Name = "Voltar ao mundo anterior",
    Default = true,
    Callback = function(value)
        State.CollectReturn = value
    end,
}, "CollectReturn")
farmSection:SubLabel({ Text = "Pega corvos, balls e commandments que aparecem em qualquer mundo, trocando de mundo sozinho. Pausa o Auto Quest." })
statusHandles[#statusHandles + 1] = addStatus(farmTab, "Atividade", "Mostra Auto Quest, Time Trial, Raid e Gate.")

-- Time Trial
local trialSection = trialTab:Section({ Side = "Left" })
trialSection:Header({ Text = "Auto Time Trial" })
trialSection:Dropdown({
    Name = "Dificuldade",
    Multi = false,
    Required = true,
    Options = TRIAL_OPTIONS,
    Default = 1,
    Callback = function(value)
        State.TrialKey = value
    end,
}, "TrialKey")
trialSection:Toggle({
    Name = "Auto Time Trial",
    Default = false,
    Callback = function(value)
        State.AutoTimeTrial = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoTimeTrial")
trialSection:SubLabel({ Text = "Entra quando a dificuldade abrir e limpa todas as salas. Pausa o Auto Quest." })
statusHandles[#statusHandles + 1] = addStatus(trialTab, "Time Trial")

-- Raid / Gate
local raidDefault = 1
for index, label in ipairs(raidOptions) do
    if label:find("^World6 ") then
        raidDefault = index
    end
end
local raidSection = raidTab:Section({ Side = "Left" })
raidSection:Header({ Text = "Auto Raid" })
raidSection:Dropdown({
    Name = "Raid",
    Search = true,
    Multi = false,
    Required = true,
    Options = raidOptions,
    Default = raidDefault,
    Callback = function(value)
        State.RaidKey = raidLabelToKey[value] or State.RaidKey
    end,
}, "RaidKey")
raidSection:Toggle({
    Name = "Auto Raid",
    Default = false,
    Callback = function(value)
        State.AutoRaid = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoRaid")
raidSection:Header({ Text = "Auto Gate" })
raidSection:Toggle({
    Name = "Auto Gate",
    Default = false,
    Callback = function(value)
        State.AutoGate = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoGate")
raidSection:SubLabel({ Text = "Raid gasta 1 chave. Gate e gratis e tem prioridade. Se voce ja estiver dentro, ele assume." })
statusHandles[#statusHandles + 1] = addStatus(raidTab, "Raid / Gate")

-- Defense
do
local DEFENSES = {
    { "Best", "Melhor que eu solo (com chave)" }, { "World4", "Titan Wall Defense" }, { "World8", "Beach Defense" },
    { "World13", "Hero Defense" }, { "World18", "New Leaf Defense" }, { "World21", "Militech Convoy" },
    { "World23", "Capsule Defense" },
}
local defenseOptions, defenseLabelToKey = buildOptions(DEFENSES)
local defenseSection = extraTabs.defense:Section({ Side = "Left" })
defenseSection:Header({ Text = "Auto Defense" })
defenseSection:Dropdown({
    Name = "Defense",
    Multi = false,
    Required = true,
    Options = defenseOptions,
    Default = 1,
    Callback = function(value)
        State.DefenseKey = defenseLabelToKey[value] or "Best"
    end,
}, "DefenseKey")
defenseSection:Slider({
    Name = "Sair na wave (0 = ate o fim)",
    Default = State.DefenseLeaveWave,
    Minimum = 0,
    Maximum = 100,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.DefenseLeaveWave = math.floor(value)
    end,
}, "DefenseLeaveWave")
defenseSection:Toggle({
    Name = "Auto Defense",
    Default = false,
    Callback = function(value)
        State.AutoDefense = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "AutoDefense")
defenseSection:SubLabel({ Text = "Cria a defense sozinho (gasta 1 chave), ataca os inimigos ate o fim (ou a wave escolhida) e repete. 'Melhor' escolhe a defense mais alta com chave que a aba Solo diz que voce completa." })
statusHandles[#statusHandles + 1] = addStatus(extraTabs.defense, "Defense")

-- Solo
local soloSection = extraTabs.solo:Section({ Side = "Left" })
soloSection:Header({ Text = "O que eu solo com meu DPS" })
extraTabs.soloText = soloSection:Paragraph({ Header = "Defenses e Raids", Body = "Medindo DPS..." })
soloSection:Button({
    Name = "Zerar pico de DPS",
    Callback = function()
        if State.Actions.resetDps then
            State.Actions.resetDps()
        end
    end,
})
soloSection:SubLabel({ Text = "DPS = dano dos ultimos 5s (igual ao contador do jogo); usa o maior valor medido. Ataque algo para medir. Vida da wave = vida base x escala^(wave-1), verificado na Defense; nas Raids o numero de inimigos por wave e estimado." })

-- Full Auto
local fullOptions, fullLabelToMode = {}, {}
for _, entry in ipairs(RAIDS) do
    local label = ("Raid: %s (%s)"):format(entry[2], entry[1])
    fullOptions[#fullOptions + 1] = label
    fullLabelToMode[label] = "Raid:" .. entry[1]
end
for index = 2, #DEFENSES do -- skip "Best"
    local entry = DEFENSES[index]
    local label = ("Defense: %s (%s)"):format(entry[2], entry[1])
    fullOptions[#fullOptions + 1] = label
    fullLabelToMode[label] = "Defense:" .. entry[1]
end
local fullSection = extraTabs.full:Section({ Side = "Left" })
fullSection:Header({ Text = "Fully Auto Raid / Defense" })
fullSection:Dropdown({
    Name = "Modos (varios)",
    Search = true,
    Multi = true,
    Required = false,
    Options = fullOptions,
    Default = {},
    Callback = function(value)
        State.FullAutoModes = {}
        for label, enabled in pairs(value) do
            if enabled and fullLabelToMode[label] then
                State.FullAutoModes[fullLabelToMode[label]] = true
            end
        end
    end,
}, "FullAutoModes")
fullSection:Dropdown({
    Name = "Ordem",
    Multi = false,
    Required = true,
    Options = { "Mundo mais alto primeiro", "Mundo mais baixo primeiro" },
    Default = 1,
    Callback = function(value)
        State.FullAutoOrder = value:find("baixo") and "Low" or "High"
    end,
}, "FullAutoOrder")
fullSection:Toggle({
    Name = "So os que eu solo (aba Solo)",
    Default = true,
    Callback = function(value)
        State.FullAutoSoloOnly = value
    end,
}, "FullAutoSoloOnly")
fullSection:Toggle({
    Name = "Farmar a chave quando faltar",
    Default = true,
    Callback = function(value)
        State.FullAutoFarm = value
    end,
}, "FullAutoFarm")
fullSection:Toggle({
    Name = "Fully Auto Raid / Defense",
    Default = false,
    Callback = function(value)
        State.FullAuto = value
        if not value then
            setStatus("Parado.")
        end
    end,
}, "FullAuto")
fullSection:SubLabel({ Text = "Roda o primeiro modo marcado que tiver chave (pela Raid/Defense do hub, na wave de saida da aba Defense). Sem chave em nenhum: vai ao mundo da chave e mata os inimigos que a dropam (maior chance primeiro) ate conseguir. Enquanto ligado, escolhe a Raid e a Defense sozinho." })
statusHandles[#statusHandles + 1] = addStatus(extraTabs.full, "Full Auto")

-- Passivas
local passiveSection = extraTabs.passive:Section({ Side = "Left" })
passiveSection:Header({ Text = "Auto Roll de Passivas" })
passiveSection:Dropdown({
    Name = "Parar na raridade",
    Multi = false,
    Required = true,
    Options = { "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine" },
    Default = 6, -- Divine (top)
    Callback = function(value)
        State.PassiveTarget = value
    end,
}, "PassiveTarget")
for _, entry in ipairs({
    { "AutoPassivePet", "Pets (PetPassiveToken)" },
    { "AutoPassiveSword", "Espada equipada (BreathToken)" },
    { "AutoPassiveShadow", "Shadow equipada (ShadowPassiveToken)" },
    { "AutoPassiveTitan", "Titan equipado (TitanPassiveToken)" },
    { "AutoPassiveGrimoire", "Slots do Grimoire (GrimoirePassiveToken)" },
    { "AutoPassivePlayer", "Passiva do jogador (PassiveToken)" },
}) do
    local flag = entry[1]
    passiveSection:Toggle({
        Name = entry[2],
        Default = false,
        Callback = function(value)
            State[flag] = value
            if not value then
                setLine(extraTabs.passiveLines, extraTabs.passiveStatus, flag, entry[2]:match("^[^%(]+") .. ": parado.")
            end
        end,
    }, flag)
end
passiveSection:Header({ Text = "Filtro dos pets" })
passiveSection:Dropdown({
    Name = "Raridades de pet permitidas",
    Multi = true,
    Required = false,
    Options = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine", "Astral", "Crafted", "Exclusive", "Limited" },
    Default = {},
    Callback = function(value)
        State.PassivePetRarities = {}
        for rarity, enabled in pairs(value) do
            if enabled then
                State.PassivePetRarities[rarity] = true
            end
        end
    end,
}, "PassivePetRarities")
passiveSection:Toggle({
    Name = "So pets equipados",
    Default = true,
    Callback = function(value)
        State.PassivePetEquippedOnly = value
    end,
}, "PassivePetEquippedOnly")
passiveSection:SubLabel({ Text = "Gira cada alvo ate a passiva chegar na raridade escolhida (o servidor so troca por uma melhor). Pets: so os das raridades marcadas; nenhuma marcada = nao gira pet. Independente do auto roll do jogo." })
extraTabs.passiveStatus = addStatus(extraTabs.passive, "Passivas")
end

-- Star
local starSection = rollTab:Section({ Side = "Left" })
starSection:Header({ Text = "Auto Star" })
starSection:Dropdown({
    Name = "Star",
    Search = true,
    Multi = false,
    Required = true,
    Options = starOptions,
    Default = 1,
    Callback = function(value)
        State.StarKey = starLabelToKey[value] or State.StarKey
    end,
}, "StarSelect")
starSection:Toggle({
    Name = "Auto Roll Star",
    Default = false,
    Callback = function(value)
        State.AutoStar = value
        if not value then
            setStar("Parado.")
        end
    end,
}, "AutoStar")
starSection:Slider({
    Name = "Delay entre aberturas",
    Default = State.StarDelay,
    Minimum = 0,
    Maximum = 3,
    DisplayMethod = "Value",
    Precision = 1,
    Callback = function(value)
        State.StarDelay = value
    end,
}, "StarDelay")
starSection:SubLabel({ Text = "Troca de mundo e fica em cima da estacao da Star (o servidor exige). Pausa o Auto Quest." })
starStatus = addStatus(rollTab, "Star")

-- Gacha
local gachaSection = gachaTab:Section({ Side = "Left" })
gachaSection:Header({ Text = "Auto Gacha" })
gachaSection:Dropdown({
    Name = "Gachas (varios)",
    Search = true,
    Multi = true,
    Required = false,
    Options = gachaOptions,
    Default = {},
    Callback = function(value)
        State.GachaKeys = {}
        for label, enabled in pairs(value) do
            if enabled and gachaLabelToKey[label] then
                State.GachaKeys[gachaLabelToKey[label]] = true
            end
        end
    end,
}, "GachaSelect")
do
local GACHA_MODES = { ["Rodizio (todos)"] = "Rodizio", ["Meta por raridade"] = "Meta" }
gachaSection:Dropdown({
    Name = "Modo",
    Multi = false,
    Required = true,
    Options = { "Rodizio (todos)", "Meta por raridade" },
    Default = 1,
    Callback = function(value)
        State.GachaMode = GACHA_MODES[value] or "Rodizio"
    end,
}, "GachaMode")
gachaSection:Dropdown({
    Name = "Meta: raridade alvo",
    Multi = false,
    Required = true,
    Options = { "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine", "Astral" },
    Default = 5, -- Secret
    Callback = function(value)
        State.GachaTarget = value
    end,
}, "GachaTarget")
gachaSection:Slider({
    Name = "Meta: gachas por vez",
    Default = State.GachaBatch,
    Minimum = 1,
    Maximum = 6,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.GachaBatch = math.max(1, math.floor(value))
    end,
}, "GachaBatch")
gachaSection:SubLabel({ Text = "Meta: gira os primeiros N gachas marcados (ordem de mundo) ate a melhor raridade de cada um chegar no alvo; o que chega no alvo ou fica sem token da lugar ao proximo." })
end
gachaSection:Toggle({
    Name = "Auto Roll Gacha",
    Default = false,
    Callback = function(value)
        State.AutoGacha = value
        if not value then
            setGacha("Parado.")
        end
    end,
}, "AutoGacha")
gachaSection:Slider({
    Name = "Delay entre rolls",
    Default = State.GachaDelay,
    Minimum = 0,
    Maximum = 3,
    DisplayMethod = "Value",
    Precision = 2,
    Callback = function(value)
        State.GachaDelay = value
    end,
}, "GachaDelay")
gachaSection:SubLabel({ Text = "Todos os marcados rodam em revezamento (o servidor so aceita um por vez). Funciona de qualquer lugar." })
local bestToggle = gachaSection:Toggle({
    Name = "Painel do Best",
    Default = true,
    Callback = function(value)
        State.BestPanel = value
    end,
}, "BestPanel")
Panels.toggles.Tokens = gachaSection:Toggle({
    Name = "Painel de tokens",
    Default = false,
    Callback = function(value)
        State.PanelTokens = value
    end,
}, "PanelTokens")
gachaStatus = addStatus(gachaTab, "Gacha")

-- Grimoire
do
local GRIMOIRE_RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine", "Astral" }
local grimoireSection = gachaTab:Section({ Side = "Left" })
grimoireSection:Header({ Text = "Auto Grimoire" })
grimoireSection:Dropdown({
    Name = "Parar na raridade",
    Multi = false,
    Required = true,
    Options = GRIMOIRE_RARITIES,
    Default = #GRIMOIRE_RARITIES,
    Callback = function(value)
        State.GrimoireTarget = value
    end,
}, "GrimoireTarget")
for _, slotKey in ipairs({ "Slot1", "Slot2" }) do
    grimoireSection:Toggle({
        Name = "Rolar " .. slotKey,
        Default = true,
        Callback = function(value)
            State.GrimoireSlots[slotKey] = value or nil
        end,
    }, "Grimoire" .. slotKey)
end
grimoireSection:Toggle({
    Name = "Auto Roll Grimoire",
    Default = false,
    Callback = function(value)
        State.AutoGrimoire = value
        if not value then
            updateBody(grimoireStatus, "Parado.")
        end
    end,
}, "AutoGrimoire")
grimoireSection:SubLabel({ Text = "Rola os slots marcados em revezamento (o servidor trava 1 roll por vez, nem o outro slot entra durante o giro) ate a raridade escolhida. Independente do auto roll do jogo. Funciona de qualquer lugar." })
grimoireStatus = addStatus(gachaTab, "Grimoire")
end

-- Sell
local sellSection = sellTab:Section({ Side = "Left" })
sellSection:Header({ Text = "Auto Sell (apagar pets)" })
sellSection:Dropdown({
    Name = "Raridade maxima",
    Multi = false,
    Required = true,
    Options = SELL_RARITIES,
    Default = 1,
    Callback = function(value)
        State.SellMaxRarity = value
    end,
}, "SellMaxRarity")
sellSection:Toggle({
    Name = "Manter pets shiny",
    Default = true,
    Callback = function(value)
        State.SellKeepShiny = value
    end,
}, "SellKeepShiny")
sellSection:Slider({
    Name = "Intervalo (s)",
    Default = State.SellInterval,
    Minimum = 3,
    Maximum = 120,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.SellInterval = value
    end,
}, "SellInterval")
sellSection:Toggle({
    Name = "Auto Sell",
    Default = false,
    Callback = function(value)
        State.AutoSell = value
        if not value then
            setSell("Parado.")
        end
    end,
}, "AutoSell")
sellSection:SubLabel({ Text = "Apaga pets ate a raridade escolhida. Nunca apaga equipados nem trancados." })
sellSection:Header({ Text = "Auto-delete do servidor" })
sellSection:Button({
    Name = "Aplicar em todas as Stars",
    Callback = function()
        if State.Actions.applyAutoDelete then
            State.Actions.applyAutoDelete()
        end
    end,
})
sellSection:Button({
    Name = "Remover das Stars",
    Callback = function()
        if State.Actions.clearAutoDelete then
            State.Actions.clearAutoDelete()
        end
    end,
})
sellSection:SubLabel({ Text = "Grava no jogo (o mesmo Delete do menu da Star) as raridades ate a escolhida: o pet e apagado na hora do hatch, sem encher o inventario. Respeita 'Manter pets shiny'. Remover so tira o que estiver em Delete." })
sellStatus = addStatus(sellTab, "Sell")

do
-- Upgrade systems (UpgradesConfig.Systems): key, display name, currency
local UPGRADES = {
    { "World0", "Upgrades", "TrialShard" }, { "World3", "Upgrades", "Yen" },
    { "World6", "Castle Upgrades", "CastleCoin" }, { "World9", "Fire City Upgrades", "DungeonCoin" },
    { "World10", "Hueco World Upgrades", "HuecoCoin" }, { "World13", "Z City Upgrades", "PunchCoin" },
    { "World17", "Sanctuary Upgrades", "SanctuaryCoin" }, { "World20", "Magnolia Upgrades", "FairyCoin" },
}
local UPGRADES2 = { -- Upgrades2Config.Systems
    { "Haki", "Haki Specializations" }, { "Science", "Scientific Modifications" },
    { "World0", "Professions" }, { "Hunter", "Hunter Specialization" }, { "Bizarre", "Bizarre Modifications" },
}
local CURSE_RARITIES = { "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine" }
local ACC_SCORE_MODES = { "Total", "Damage", "Yen", "Power" }
local upgrade2Options, upgrade2LabelToKey = {}, {}
for _, entry in ipairs(UPGRADES2) do
    local label = ("%s - %s"):format(entry[1], entry[2])
    upgrade2Options[#upgrade2Options + 1] = label
    upgrade2LabelToKey[label] = entry[1]
end
local progressionOptions, progressionLabelToKey = {}, {}
for index = 1, 23 do
    local label = "World" .. index
    progressionOptions[#progressionOptions + 1] = label
    progressionLabelToKey[label] = label
end
local upgradeOptions, upgradeLabelToKey = {}, {}
for _, entry in ipairs(UPGRADES) do
    local label = ("%s - %s (%s)"):format(entry[1], entry[2], entry[3])
    upgradeOptions[#upgradeOptions + 1] = label
    upgradeLabelToKey[label] = entry[1]
end

-- Upgrade
local upgradeSection = upgradeTab:Section({ Side = "Left" })
upgradeSection:Header({ Text = "Auto Upgrade" })
upgradeSection:Dropdown({
    Name = "Sistemas (varios)",
    Search = true,
    Multi = true,
    Required = false,
    Options = upgradeOptions,
    Default = {},
    Callback = function(value)
        State.UpgradeKeys = {}
        for label, enabled in pairs(value) do
            if enabled and upgradeLabelToKey[label] then
                State.UpgradeKeys[upgradeLabelToKey[label]] = true
            end
        end
    end,
}, "UpgradeSelect")
upgradeSection:Toggle({
    Name = "Auto Upgrade",
    Default = false,
    Callback = function(value)
        State.AutoUpgrade = value
        if not value then
            setUpgrade("Parado.")
        end
    end,
}, "AutoUpgrade")
upgradeSection:Slider({
    Name = "Intervalo (s)",
    Default = State.UpgradeInterval,
    Minimum = 1,
    Maximum = 60,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.UpgradeInterval = value
    end,
}, "UpgradeInterval")
upgradeSection:SubLabel({ Text = "Compra o maximo possivel de cada upgrade dos sistemas marcados, com a moeda do proprio sistema. Funciona de qualquer lugar." })
Panels.toggles.Upgrades = upgradeSection:Toggle({
    Name = "Painel de upgrades",
    Default = false,
    Callback = function(value)
        State.PanelUpgrades = value
    end,
}, "PanelUpgrades")
upgradeStatus = addStatus(upgradeTab, "Upgrade")

-- Progressao
local progressSection = progressTab:Section({ Side = "Left" })
progressSection:Header({ Text = "Upgrades 2" })
progressSection:Dropdown({
    Name = "Sistemas (varios)",
    Multi = true,
    Required = false,
    Options = upgrade2Options,
    Default = {},
    Callback = function(value)
        State.Upgrade2Keys = {}
        for label, enabled in pairs(value) do
            if enabled and upgrade2LabelToKey[label] then
                State.Upgrade2Keys[upgrade2LabelToKey[label]] = true
            end
        end
    end,
}, "Upgrade2Select")
progressSection:Toggle({
    Name = "Auto Upgrades 2",
    Default = false,
    Callback = function(value)
        State.AutoUpgrade2 = value
        if not value then
            setProgress("1_u2", "Upgrades 2: parado.")
        end
    end,
}, "AutoUpgrade2")
progressSection:SubLabel({ Text = "Haki, Science, Professions, Hunter, Bizarre. Cada upgrade usa o proprio contador (kills, rolls, waves...)." })
progressSection:Header({ Text = "Range e Progression" })
progressSection:Toggle({
    Name = "Auto Range Upgrade",
    Default = false,
    Callback = function(value)
        State.AutoRange = value
        if not value then
            setProgress("2_range", "Range: parado.")
        end
    end,
}, "AutoRange")
progressSection:Dropdown({
    Name = "Progressions (varios)",
    Search = true,
    Multi = true,
    Required = false,
    Options = progressionOptions,
    Default = {},
    Callback = function(value)
        State.ProgressionKeys = {}
        for label, enabled in pairs(value) do
            if enabled and progressionLabelToKey[label] then
                State.ProgressionKeys[progressionLabelToKey[label]] = true
            end
        end
    end,
}, "ProgressionSelect")
progressSection:Toggle({
    Name = "Auto Progression",
    Default = false,
    Callback = function(value)
        State.AutoProgression = value
        if not value then
            setProgress("3_prog", "Progression: parado.")
        end
    end,
}, "AutoProgression")
progressSection:Header({ Text = "Rank e extras" })
-- Rank up and promotion are server-side automations: the toggle sets the game's own flag (no polling loop).
-- New flag names, so configs saved by older versions (both off) do not switch the server flags off.
progressSection:Toggle({
    Name = "Auto Rank Up (servidor)",
    Default = false,
    Callback = function(value)
        State.AutoRankUp = value
        State.FlagDirty.AutoRankUp = true
    end,
}, "SrvAutoRankUp")
progressSection:Toggle({
    Name = "Auto Promotion (servidor)",
    Default = false,
    Callback = function(value)
        State.AutoPromotion = value
        State.FlagDirty.AutoPromotion = true
    end,
}, "SrvAutoPromotion")
progressSection:Toggle({
    Name = "Auto Claim (achievements, global quests, battlepass)",
    Default = false,
    Callback = function(value)
        State.AutoClaim = value
    end,
}, "AutoClaim")
progressSection:Toggle({
    Name = "Auto Relic Upgrade (max)",
    Default = false,
    Callback = function(value)
        State.AutoRelic = value
    end,
}, "AutoRelic")
progressSection:Slider({
    Name = "Intervalo geral (s)",
    Default = State.ProgressInterval,
    Minimum = 1,
    Maximum = 60,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.ProgressInterval = value
    end,
}, "ProgressInterval")
progressSection:SubLabel({ Text = "O servidor valida cada pedido, entao nada e comprado sem requisito. Relic: precisa ter relics (nao testado)." })
Panels.toggles.Progress = progressSection:Toggle({
    Name = "Painel de progressao",
    Default = false,
    Callback = function(value)
        State.PanelProgress = value
    end,
}, "PanelProgress")
progressStatus = addStatus(progressTab, "Progressao")

-- Acessorios
local accessorySection = accessoryTab:Section({ Side = "Left" })
accessorySection:Header({ Text = "Equipar melhor" })
accessorySection:Dropdown({
    Name = "Criterio",
    Multi = false,
    Required = true,
    Options = ACC_SCORE_MODES,
    Default = 1,
    Callback = function(value)
        State.AccScoreMode = value
    end,
}, "AccScoreMode")
accessorySection:Toggle({
    Name = "Auto Equipar Melhor Acessorio",
    Default = false,
    Callback = function(value)
        State.AutoAccEquip = value
        if not value then
            setAccessory("1_equip", "Equipar: parado.")
        end
    end,
}, "AutoAccEquip")
accessorySection:SubLabel({ Text = "Compara os multiplicadores (Damage, Yen, Power) por slot e equipa o maior. Ignora skins." })
accessorySection:Header({ Text = "Equip Best do jogo" })
accessorySection:Dropdown({
    Name = "Stat",
    Multi = false,
    Required = true,
    Options = { "Power", "Yen", "Damage", "XP", "Drop", "Luck", "Kill", "ShinyChance" },
    Default = 1,
    Callback = function(value)
        State.EquipBestStat = value
    end,
}, "EquipBestStat")
accessorySection:Toggle({
    Name = "Auto Equip Best (loadout inteiro)",
    Default = false,
    Callback = function(value)
        State.AutoEquipBest = value
        if not value then
            setAccessory("3_best", "Equip Best: parado.")
        end
    end,
}, "AutoEquipBest")
accessorySection:SubLabel({ Text = "Usa o Equip Best do servidor (pets, acessorios e o resto) pelo stat escolhido, a cada intervalo geral. Nao ligue junto com o Auto Equipar acima." })
accessorySection:Header({ Text = "Curse" })
accessorySection:Dropdown({
    Name = "Raridade alvo",
    Multi = false,
    Required = true,
    Options = CURSE_RARITIES,
    Default = 4, -- Legendary
    Callback = function(value)
        State.CurseTarget = value
    end,
}, "CurseTarget")
accessorySection:Slider({
    Name = "Reservar CursesCoin",
    Default = State.CurseReserve,
    Minimum = 0,
    Maximum = 100000,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(value)
        State.CurseReserve = value
    end,
}, "CurseReserve")
accessorySection:Toggle({
    Name = "Auto Roll Curse (equipados)",
    Default = false,
    Callback = function(value)
        State.AutoCurse = value
        if not value then
            setAccessory("2_curse", "Curse: parado.")
        end
    end,
}, "AutoCurse")
accessorySection:SubLabel({ Text = "Rola 10 CursesCoin por tentativa nos acessorios equipados ate chegar na raridade alvo. O servidor so troca a curse por uma melhor." })
Panels.toggles.Accessories = accessorySection:Toggle({
    Name = "Painel de acessorios",
    Default = false,
    Callback = function(value)
        State.PanelAccessories = value
    end,
}, "PanelAccessories")
accessoryStatus = addStatus(accessoryTab, "Acessorios")

end

-- Webhook
do
    local webhookSection = webhookTab:Section({ Side = "Left" })
    webhookSection:Header({ Text = "Discord" })
    webhookSection:Input({
        Name = "Webhook URL",
        Placeholder = "https://discord.com/api/webhooks/...",
        AcceptedCharacters = "All",
        Callback = function(value)
            State.WebhookUrl = value
        end,
    }, "WebhookUrl")
    webhookSection:Input({
        Name = "ID para marcar (opcional)",
        Placeholder = "ID numerico do usuario",
        AcceptedCharacters = "All",
        Callback = function(value)
            State.WebhookPing = value
        end,
    }, "WebhookPing")
    webhookSection:Button({
        Name = "Enviar teste",
        Callback = function()
            Webhook.test()
        end,
    })
    webhookSection:Header({ Text = "Drops raros" })
    webhookSection:Toggle({
        Name = "Enviar drops raros",
        Default = false,
        Callback = function(value)
            State.WebhookDrops = value
        end,
    }, "WebhookDrops")
    webhookSection:Dropdown({
        Name = "A partir da raridade",
        Multi = false,
        Required = true,
        Options = ALERT_RARITIES,
        Default = 3, -- Mythical
        Callback = function(value)
            State.WebhookMinRarity = value
        end,
    }, "WebhookMinRarity")
    webhookSection:Header({ Text = "Eventos" })
    webhookSection:Toggle({
        Name = "Enviar eventos (raid/defense, chaves, mundos)",
        Default = false,
        Callback = function(value)
            State.WebhookEvents = value
        end,
    }, "WebhookEvents")
    webhookSection:Header({ Text = "Resumo periodico" })
    webhookSection:Toggle({
        Name = "Enviar resumo",
        Default = false,
        Callback = function(value)
            State.WebhookSummary = value
        end,
    }, "WebhookSummary")
    webhookSection:Slider({
        Name = "Intervalo (min)",
        Default = State.WebhookInterval,
        Minimum = 1,
        Maximum = 240,
        DisplayMethod = "Value",
        Precision = 0,
        Callback = function(value)
            State.WebhookInterval = value
        end,
    }, "WebhookInterval")
    webhookSection:SubLabel({ Text = "A URL fica salva em texto puro na config. Nao compartilhe o arquivo da config." })
    addStatus(webhookTab, "Webhook", "Fila com limite de envio. Erros aparecem no console (F9).")
end

-- Config
configTab:InsertConfigSection("Left")

-- Prioridade
local prioritySection = priorityTab:Section({ Side = "Left" })
prioritySection:Header({ Text = "Ordem das funcoes" })
local PRIORITY_OPTIONS = { "1", "2", "3", "4", "5", "6", "7", "8" }
for index, feature in ipairs(FEATURE_ORDER) do
    prioritySection:Dropdown({
        Name = FEATURE_LABELS[feature],
        Multi = false,
        Required = true,
        Options = PRIORITY_OPTIONS,
        Default = index,
        Callback = function(value)
            State.Priority[feature] = tonumber(value) or index
        end,
    }, "Priority" .. feature)
end
prioritySection:SubLabel({ Text = "1 = maior prioridade. Empate: segue a ordem da lista. Gacha, pocoes, sell e alertas rodam sempre, sem disputar." })
priorityStatus = addStatus(priorityTab, "Em execucao", "Quem esta ativo agora e a fila das funcoes ligadas.")

-- Alertas
local alertSection = alertTab:Section({ Side = "Left" })
alertSection:Header({ Text = "Drops raros" })
alertSection:Toggle({
    Name = "Notificar drops raros",
    Default = true,
    Callback = function(value)
        State.AlertsEnabled = value
    end,
}, "AlertsEnabled")
alertSection:Dropdown({
    Name = "A partir da raridade",
    Multi = false,
    Required = true,
    Options = ALERT_RARITIES,
    Default = 3, -- Mythical: tudo acima de Legendary
    Callback = function(value)
        State.AlertMinRarity = value
    end,
}, "AlertMinRarity")
alertSection:SubLabel({ Text = "Vale para gacha, pets, espadas, titans, itens e qualquer outro drop do jogo, venha de onde vier." })
alertLog = addStatus(alertTab, "Ultimos drops raros", "Os 8 mais recentes. A notificacao tambem aparece na tela.")

-- Misc
local miscSection = miscTab:Section({ Side = "Left" })
miscSection:Header({ Text = "Boosts" })
miscSection:Toggle({
    Name = "Auto Use Boosts (servidor)",
    Default = false,
    Callback = function(value)
        State.AutoPotion = value
        State.FlagDirty.AutoPotion = true
    end,
}, "SrvAutoPotion")
miscSection:SubLabel({ Text = "Liga o Auto Use Boosts do proprio jogo: o servidor usa a proxima pocao quando a ativa acaba." })
miscSection:Header({ Text = "Geral" })
miscSection:Button({
    Name = "Resgatar todos os codigos",
    Callback = function()
        if State.Actions.redeemCodes then
            State.Actions.redeemCodes()
        end
    end,
})
miscSection:Toggle({
    Name = "Anti AFK",
    Default = true,
    Callback = function(value)
        State.AntiAfk = value
    end,
}, "AntiAfk")

-- Real tab icons: Lucide spritesheets (asset id + 48px rect). MacLib only takes a plain image, so the
-- icon is applied to each tab's TabImage after the tabs exist.
do
    local LUCIDE = {
        Farm = { 16898613777, 710, 967 }, -- sword
        ["Time Trial"] = { 16898613869, 918, 0 }, -- timer
        ["Raid / Gate"] = { 16898613777, 967, 759 }, -- swords
        Star = { 16898613777, 967, 147 }, -- star
        Gacha = { 16898613044, 918, 710 }, -- dices
        Sell = { 16898613044, 869, 612 }, -- coins
        Alertas = { 16898612819, 820, 257 }, -- bell
        Prioridade = { 16898613509, 710, 918 }, -- list-ordered
        Misc = { 16898613777, 771, 257 }, -- settings
        -- Standalone Lucide images (no spritesheet rect): the tabs added after the spritesheet icons were picked.
        Upgrade = { 93136954756149 }, -- arrow-big-up
        Progressao = { 81819858538839 }, -- trending-up
        Acessorios = { 127843403295538 }, -- crown
        Webhook = { 112812457747322 }, -- webhook
        Config = { 126116963775616 }, -- save
    }
    pcall(function()
        local host = gethui and gethui()
        local roots = host and host:GetChildren() or {}
        for index = #roots, 1, -1 do
            local root = roots[index]
            if root:IsA("ScreenGui") and root.Name ~= "AstralXBest" then
                local patched = 0
                for _, d in ipairs(root:GetDescendants()) do
                    if d.Name == "TabSwitcherName" and LUCIDE[d.Text] then
                        local image = d.Parent:FindFirstChild("TabImage")
                        if image then
                            local icon = LUCIDE[d.Text]
                            image.Image = "rbxassetid://" .. icon[1]
                            image.ImageRectSize = icon[2] and Vector2.new(48, 48) or Vector2.zero
                            image.ImageRectOffset = icon[2] and Vector2.new(icon[2], icon[3]) or Vector2.zero
                            patched += 1
                        end
                    end
                end
                if patched > 0 then
                    break
                end
            end
        end
    end)
end

farmTab:Select()

local function unload()
    State.Running = false
    State.Owner = nil
    for key, value in pairs(State) do
        if type(value) == "boolean" and key:sub(1, 4) == "Auto" then
            State[key] = false
        end
    end
    for _, c in ipairs(connections) do
        c:Disconnect()
    end
    for _, restore in ipairs(unloadHooks) do
        pcall(restore)
    end
    pcall(function()
        Window:Unload()
    end)
end

getgenv().AstralX = {
    State = State,
    MacLib = MacLib,
    Unload = unload,
}

-- Runs one step of a scheduled feature, flagging it busy so the scheduler never hands control over mid-step.
local function runStep(feature, step)
    -- Handover: the scheduler already named us owner, but the previous owner may still be inside a step.
    while State.Running and State.Owner == feature do
        local otherBusy = false
        for name in pairs(State.StepBusy) do
            if name ~= feature then
                otherBusy = true
            end
        end
        if not otherBusy then
            break
        end
        task.wait(0.05)
    end
    if State.Owner ~= feature then
        return
    end
    State.StepBusy[feature] = true
    local ok, err = xpcall(step, debug.traceback)
    State.StepBusy[feature] = nil
    if not ok then
        warn("[AstralX] " .. feature .. ":", err)
        task.wait(1.5)
    end
end

-- Background feature that never touches the character: runs `step` over and over while State[flag] is on.
-- The step paces itself (task.wait inside); an error is logged and retried after 2s. Every pass also yields
-- at least one frame, so a step that returns early can never spin the thread and freeze the client.
local function startLoop(flag, step)
    task.spawn(function()
        while State.Running do
            if State[flag] then
                local ok, err = xpcall(step, debug.traceback)
                if not ok then
                    warn("[AstralX] " .. flag .. ":", err)
                    task.wait(2)
                end
                task.wait()
            else
                task.wait(0.4)
            end
        end
    end)
end

-- Character feature: runs `step` only while the scheduler names one of `owners` as State.Owner.
-- Same one-frame yield per pass: a step that bails out instantly (world locked, no token) must still let the
-- scheduler tick and hand control to someone else.
local function startOwnedLoop(step, ...)
    local owners = { ... }
    task.spawn(function()
        while State.Running do
            local owner = State.Owner
            if owner and table.find(owners, owner) then
                runStep(owner, step)
                task.wait()
            else
                task.wait(0.2)
            end
        end
    end)
end

-- Best panel (own ScreenGui, independent of the MacLib window) ------------------
-- Built here, before any require, with a fixed pool of slots; later only properties change.

local gachaNameByKey = {}
for _, entry in ipairs(GACHAS) do
    gachaNameByKey[entry[1]] = entry[2]
end

local RARITY_COLORS = {
    Common = Color3.fromRGB(190, 190, 190), Uncommon = Color3.fromRGB(110, 220, 110),
    Rare = Color3.fromRGB(80, 160, 255), Epic = Color3.fromRGB(180, 90, 255),
    Legendary = Color3.fromRGB(255, 190, 40), Mythical = Color3.fromRGB(255, 70, 90),
    Secret = Color3.fromRGB(255, 255, 255), Divine = Color3.fromRGB(255, 240, 150),
    Astral = Color3.fromRGB(100, 255, 240), Limited = Color3.fromRGB(255, 120, 220),
}
local BEST_COLUMNS, BEST_CELL = 5, Vector2.new(92, 124)

local bestGui = Instance.new("ScreenGui")
bestGui.Name = "AstralXBest"
bestGui.ResetOnSpawn = false
bestGui.DisplayOrder = 998
bestGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
do
    local host = gethui and gethui()
    if not host or host:IsA("ScreenGui") then
        host = game:GetService("CoreGui")
    end
    local ok = pcall(function()
        bestGui.Parent = host
    end)
    if not ok or bestGui.Parent == nil then
        bestGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end
end

local BEST_WIDTH = BEST_COLUMNS * BEST_CELL.X + 24
local bestFrame = Instance.new("Frame")
bestFrame.Size = UDim2.fromOffset(BEST_WIDTH, 330)
bestFrame.Position = UDim2.new(1, -BEST_WIDTH - 20, 0, 120)
bestFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
bestFrame.BackgroundTransparency = 0.08
bestFrame.BorderSizePixel = 0
bestFrame.Parent = bestGui
Instance.new("UICorner", bestFrame).CornerRadius = UDim.new(0, 10)

local bestTitle = Instance.new("TextLabel")
bestTitle.Size = UDim2.new(1, -40, 0, 30)
bestTitle.Position = UDim2.fromOffset(12, 0)
bestTitle.BackgroundTransparency = 1
bestTitle.Font = Enum.Font.GothamBold
bestTitle.TextSize = 14
bestTitle.TextXAlignment = Enum.TextXAlignment.Left
bestTitle.TextColor3 = Color3.fromRGB(235, 235, 245)
bestTitle.Text = "Melhor de cada Gacha"
bestTitle.Parent = bestFrame

local bestClose = Instance.new("TextButton")
bestClose.Size = UDim2.fromOffset(22, 22)
bestClose.Position = UDim2.new(1, -30, 0, 4)
bestClose.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
bestClose.Font = Enum.Font.GothamBold
bestClose.TextSize = 13
bestClose.TextColor3 = Color3.fromRGB(235, 235, 245)
bestClose.Text = "x"
bestClose.Parent = bestFrame
Instance.new("UICorner", bestClose).CornerRadius = UDim.new(0, 6)

local bestScroll = Instance.new("ScrollingFrame")
bestScroll.Position = UDim2.fromOffset(6, 34)
bestScroll.Size = UDim2.new(1, -12, 1, -40)
bestScroll.BackgroundTransparency = 1
bestScroll.BorderSizePixel = 0
bestScroll.ScrollBarThickness = 3
bestScroll.CanvasSize = UDim2.new()
bestScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
bestScroll.Parent = bestFrame
local bestGrid = Instance.new("UIGridLayout")
bestGrid.CellSize = UDim2.fromOffset(BEST_CELL.X - 4, BEST_CELL.Y - 4)
bestGrid.CellPadding = UDim2.fromOffset(4, 4)
bestGrid.SortOrder = Enum.SortOrder.LayoutOrder
bestGrid.Parent = bestScroll

local bestSlots = {}
for i = 1, #GACHAS do
    local cell = Instance.new("Frame")
    cell.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
    cell.BorderSizePixel = 0
    cell.LayoutOrder = i
    cell.Visible = false
    cell.Parent = bestScroll
    Instance.new("UICorner", cell).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Color = RARITY_COLORS.Common
    stroke.Parent = cell

    local icon = Instance.new("ImageLabel")
    icon.Size = UDim2.fromOffset(60, 60)
    icon.Position = UDim2.new(0.5, -30, 0, 4)
    icon.BackgroundTransparency = 1
    icon.ScaleType = Enum.ScaleType.Fit
    icon.Parent = cell

    local function label(y, size, bold)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -6, 0, size + 4)
        l.Position = UDim2.fromOffset(3, y)
        l.BackgroundTransparency = 1
        l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
        l.TextSize = size
        l.TextColor3 = Color3.fromRGB(220, 220, 230)
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Parent = cell
        return l
    end
    bestSlots[i] = {
        cell = cell,
        stroke = stroke,
        icon = icon,
        item = label(66, 11, true),
        rarity = label(80, 11, true),
        gacha = label(96, 10, false),
    }
    bestSlots[i].gacha.TextColor3 = Color3.fromRGB(150, 150, 165)
end

do -- drag by the title area
    local UserInputService = game:GetService("UserInputService")
    local dragging, dragStart, startPos
    connections[#connections + 1] = bestTitle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, bestFrame.Position
        end
    end)
    connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            bestFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end
connections[#connections + 1] = bestClose.MouseButton1Click:Connect(function()
    State.BestPanel = false
    pcall(function()
        bestToggle:UpdateState(false)
    end)
end)
unloadHooks[#unloadHooks + 1] = function()
    bestGui:Destroy()
end

-- Info panels: same look as the best panel, built here (before any require) with a fixed pool of cells.
-- Panels[id].render(entries, title) fills them; entry = { icon, line1, line2, line3, color }.
do
    local UserInputService = game:GetService("UserInputService")

    local function makePanel(id, title, poolSize, columns, position)
        local width = columns * BEST_CELL.X + 24
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromOffset(width, 250)
        frame.Position = position
        frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
        frame.BackgroundTransparency = 0.08
        frame.BorderSizePixel = 0
        frame.Visible = false
        frame.Parent = bestGui
        Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

        local titleLabel = Instance.new("TextLabel")
        titleLabel.Size = UDim2.new(1, -40, 0, 30)
        titleLabel.Position = UDim2.fromOffset(12, 0)
        titleLabel.BackgroundTransparency = 1
        titleLabel.Font = Enum.Font.GothamBold
        titleLabel.TextSize = 14
        titleLabel.TextXAlignment = Enum.TextXAlignment.Left
        titleLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
        titleLabel.Text = title
        titleLabel.Parent = frame

        local close = Instance.new("TextButton")
        close.Size = UDim2.fromOffset(22, 22)
        close.Position = UDim2.new(1, -30, 0, 4)
        close.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
        close.Font = Enum.Font.GothamBold
        close.TextSize = 13
        close.TextColor3 = Color3.fromRGB(235, 235, 245)
        close.Text = "x"
        close.Parent = frame
        Instance.new("UICorner", close).CornerRadius = UDim.new(0, 6)

        local scroll = Instance.new("ScrollingFrame")
        scroll.Position = UDim2.fromOffset(6, 34)
        scroll.Size = UDim2.new(1, -12, 1, -40)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 3
        scroll.CanvasSize = UDim2.new()
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.Parent = frame
        local grid = Instance.new("UIGridLayout")
        grid.CellSize = UDim2.fromOffset(BEST_CELL.X - 4, BEST_CELL.Y - 4)
        grid.CellPadding = UDim2.fromOffset(4, 4)
        grid.SortOrder = Enum.SortOrder.LayoutOrder
        grid.Parent = scroll

        local slots = {}
        for i = 1, poolSize do
            local cell = Instance.new("Frame")
            cell.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
            cell.BorderSizePixel = 0
            cell.LayoutOrder = i
            cell.Visible = false
            cell.Parent = scroll
            Instance.new("UICorner", cell).CornerRadius = UDim.new(0, 8)
            local stroke = Instance.new("UIStroke")
            stroke.Thickness = 1.5
            stroke.Color = RARITY_COLORS.Common
            stroke.Parent = cell

            local icon = Instance.new("ImageLabel")
            icon.Size = UDim2.fromOffset(60, 60)
            icon.Position = UDim2.new(0.5, -30, 0, 4)
            icon.BackgroundTransparency = 1
            icon.ScaleType = Enum.ScaleType.Fit
            icon.Parent = cell

            local function label(y, size, bold)
                local l = Instance.new("TextLabel")
                l.Size = UDim2.new(1, -6, 0, size + 4)
                l.Position = UDim2.fromOffset(3, y)
                l.BackgroundTransparency = 1
                l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
                l.TextSize = size
                l.TextColor3 = Color3.fromRGB(220, 220, 230)
                l.TextTruncate = Enum.TextTruncate.AtEnd
                l.Parent = cell
                return l
            end
            slots[i] = { cell = cell, stroke = stroke, icon = icon, l1 = label(66, 11, true), l2 = label(80, 11, true), l3 = label(96, 10, false) }
            slots[i].l3.TextColor3 = Color3.fromRGB(150, 150, 165)
        end

        local panel = { frame = frame }
        function panel.render(entries, titleText)
            titleLabel.Text = titleText or title
            for i, slot in ipairs(slots) do
                local entry = entries[i]
                slot.cell.Visible = entry ~= nil
                if entry then
                    slot.icon.Image = entry.icon or ""
                    slot.l1.Text = entry.line1 or ""
                    slot.l2.Text = entry.line2 or ""
                    slot.l3.Text = entry.line3 or ""
                    slot.l2.TextColor3 = entry.color or RARITY_COLORS.Common
                    slot.stroke.Color = entry.color or RARITY_COLORS.Common
                end
            end
        end

        local dragging, dragStart, startPos
        connections[#connections + 1] = titleLabel.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, dragStart, startPos = true, input.Position, frame.Position
            end
        end)
        connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end)
        connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        connections[#connections + 1] = close.MouseButton1Click:Connect(function()
            State["Panel" .. id] = false
            local toggle = Panels.toggles[id]
            if toggle then
                pcall(function()
                    toggle:UpdateState(false)
                end)
            end
        end)
        Panels[id] = panel
    end

    -- Left column: accessories and tokens; right column: upgrades and progression. All draggable.
    makePanel("Accessories", "Acessorios equipados", 12, 3, UDim2.fromOffset(10, 60))
    makePanel("Tokens", "Tokens de Gacha", #GACHAS, 5, UDim2.fromOffset(10, 320))
    makePanel("Upgrades", "Upgrades", 60, 5, UDim2.new(1, -514, 0, 60))
    makePanel("Progress", "Progressao", 50, 5, UDim2.new(1, -514, 0, 320))
end

-- Logic ---------------------------------------------------------------------

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")

local Library = require(RS.SimpleWorld.Library)
local WorldController = require(RS.SimpleWorld.Library.Client.WorldController)
local TeleportController = require(RS.SimpleWorld.Library.Client.TeleportController)
local QuestConfig = Library.getConfig("QuestConfig")
local EnemyConfig = Library.getConfig("EnemyConfig")
local PlayerData = Library.getPackage("DataContainer").New("PlayerData")
local ClickBridge = Library.getBridge("Click")
local ClickController = require(Library.Client.ClickController)

-- Goes through the game's own click path so the attack animation, sound and combo play; falls back to the bare remote.
local function doClick()
    local ok = pcall(ClickController.RequestClick, ClickController)
    if not ok then
        ClickBridge:Fire()
    end
end
local CollectBridge = Library.getBridge("QuestCollect")
local ChangeWorldBridge = Library.getBridge("RequestChangeWorld")
local BuyWorldBridge = Library.getBridge("BuyWorld")

local LocalPlayer = Players.LocalPlayer

local STALL_SECONDS = 40
local SKIP_SECONDS = 60
local lastProgress = {} -- [EnemyId] = {count, time}
local skipUntil = {} -- [EnemyId] = time
local function getRoot()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and hum.Health > 0 then
        return root
    end
    return nil
end

local function getQuestState()
    local data = PlayerData.Data
    local progress = type(data.QuestProgress) == "table" and data.QuestProgress or {}
    return QuestConfig:BuildState(tonumber(data.QuestIndex) or 1, progress)
end

-- "World 4 Quest" -> 4
local function getQuestWorld(state)
    local n = tostring(state.QuestName or ""):match("World (%-?%d+)")
    return n and tonumber(n)
end

-- Polls predicate every 0.25s. Gives up early when the script stops or, with `owner`, as soon as the scheduler
-- hands control to another feature, so a long wait (teleport, pickup) never delays a raid or gate.
local function waitUntil(predicate, timeout, owner)
    local deadline = os.clock() + timeout
    while os.clock() < deadline and State.Running and (owner == nil or State.Owner == owner) do
        if predicate() then
            return true
        end
        task.wait(0.25)
    end
    return predicate()
end

-- Moves to worldId through the game's own teleport. Returns true once there, or false plus a reason:
-- "loading", "locked" (and buy is off), "no_token", "buy_failed", "timeout".
-- buy = true spends a WorldToken to unlock the world first (the quest chain needs that).
local function travelToWorld(worldId, owner, report, buy)
    if WorldController:GetCurrentWorld() == worldId then
        return true
    end
    if TeleportController:IsLoading() then
        task.wait(1)
        return false, "loading"
    end
    if not TeleportController:IsWorldUnlocked(worldId) then
        if not buy then
            report(("Mundo %d ainda esta bloqueado."):format(worldId))
            return false, "locked"
        end
        if (tonumber(PlayerData.Data.WorldToken) or 0) < 1 then
            report(("Mundo %d bloqueado e sem WorldToken."):format(worldId))
            return false, "no_token"
        end
        report(("Comprando mundo %d"):format(worldId))
        BuyWorldBridge:Fire(worldId)
        if not waitUntil(function()
            return TeleportController:IsWorldUnlocked(worldId)
        end, 6, owner) then
            return false, "buy_failed"
        end
    end
    report(("Indo para o mundo %d..."):format(worldId))
    ChangeWorldBridge:Fire(worldId)
    if not waitUntil(function()
        return WorldController:GetCurrentWorld() == worldId
    end, 20, owner) then
        return false, "timeout"
    end
    waitUntil(function()
        return getRoot() ~= nil and not TeleportController:IsLoading()
    end, 20, owner)
    task.wait(1.5) -- enemies and stations stream in right after the character
    return true
end

local function findEnemy(worldId, enemyId)
    local world = workspace.Worlds:FindFirstChild(tostring(worldId))
    local enemies = world and world:FindFirstChild("Enemies")
    local info = EnemyConfig:GetEnemy(enemyId)
    local root = getRoot()
    if not (enemies and info and root) then
        return nil
    end
    local best, bestDist
    for _, enemy in ipairs(enemies:GetChildren()) do
        if enemy.Name == info.Name and enemy:GetAttribute("EnemyDead") == false then
            local d = (enemy:GetPivot().Position - root.Position).Magnitude
            if not bestDist or d < bestDist then
                best, bestDist = enemy, d
            end
        end
    end
    return best
end

-- Set when the quest chain cannot move (all done, or the next world is locked with no WorldToken); until then
-- Quest does not ask for the character, so a lower-priority feature can use it.
local questIdleUntil = 0

local function collect(state)
    local index = tonumber(PlayerData.Data.QuestIndex)
    setStatus("Coletando " .. tostring(state.QuestName))
    CollectBridge:Fire()
    waitUntil(function()
        return tonumber(PlayerData.Data.QuestIndex) ~= index
    end, 6, "Quest")
    table.clear(lastProgress)
    table.clear(skipUntil)
end

local function pickRequirement(state, worldId)
    local now = os.clock()
    local fallback
    for _, req in ipairs(state.Requirements) do
        if req.Current < req.Required then
            local last = lastProgress[req.EnemyId]
            if not last or last.count ~= req.Current then
                lastProgress[req.EnemyId] = { count = req.Current, time = now }
                skipUntil[req.EnemyId] = nil
            elseif now - last.time > STALL_SECONDS and not skipUntil[req.EnemyId] then
                skipUntil[req.EnemyId] = now + SKIP_SECONDS
            end

            local enemy = findEnemy(worldId, req.EnemyId)
            if enemy then
                if (skipUntil[req.EnemyId] or 0) <= now then
                    return req, enemy
                end
                fallback = fallback or { req, enemy }
            end
        end
    end
    if fallback then
        return fallback[1], fallback[2]
    end
    return nil
end

local function questStep()
    if not getRoot() then
        setStatus("Aguardando respawn...")
        task.wait(1)
        return
    end

    local state = getQuestState()
    if not state.HasQuest then
        setStatus("Todas as quests de mundo concluidas.")
        questIdleUntil = os.clock() + 60
        return
    end

    if state.Complete then
        collect(state)
        return
    end

    local questWorld = getQuestWorld(state)
    if not questWorld then
        setStatus("Mundo da quest desconhecido: " .. tostring(state.QuestName))
        questIdleUntil = os.clock() + 30
        return
    end

    local arrived, reason = travelToWorld(questWorld, "Quest", setStatus, true)
    if not arrived then
        if reason == "no_token" then
            questIdleUntil = os.clock() + 30
        end
        return
    end

    local req, enemy = pickRequirement(state, questWorld)
    local root = getRoot()
    if req and enemy and root then
        setStatus(("[%s] %s %d/%d"):format(state.QuestName, req.EnemyName, req.Current, req.Required))
        root.CFrame = CFrame.new(enemy:GetPivot().Position + State.Offset)
        doClick()
        task.wait(State.ClickDelay)
        return
    end

    setStatus("Esperando inimigos respawnarem...")
    task.wait(1)
end

-- Auto potions are the game's own AutoUseBoosts setting (see the server flags block): no client loop.

-- Auto Time Trial: join the chosen difficulty when it opens, clear every room, then hand control back.
local TimeTrialJoinBridge = Library.getBridge("TimeTrialJoin")
local TimeTrialController = require(Library.Client.TimeTrialController)
local TRIAL_KEYS = { "Insane", "Hard", "Medium", "Easy" } -- highest first
local trialState

-- Live controller state (OpenTrialKeys, InTrial, ActiveKey...) lives in an upvalue table.
local function getTrialState()
    if trialState then
        return trialState
    end
    for _, fn in pairs(TimeTrialController) do
        if type(fn) == "function" then
            local ok, ups = pcall(debug.getupvalues, fn)
            if ok then
                for _, up in pairs(ups) do
                    if type(up) == "table" and rawget(up, "OpenTrialKeys") ~= nil then
                        trialState = up
                        return up
                    end
                end
            end
        end
    end
    return nil
end

local function isTrialKeyOpen(open, key)
    for k, v in pairs(open) do
        if k == key or v == key then
            return true
        end
    end
    return false
end

local function pickTrialKey(open)
    if State.TrialKey ~= "Highest open" then
        return isTrialKeyOpen(open, State.TrialKey) and State.TrialKey or nil
    end
    for _, key in ipairs(TRIAL_KEYS) do
        if isTrialKeyOpen(open, key) then
            return key
        end
    end
    return nil
end

local function trialFight(st)
    local arena = workspace:FindFirstChild("TimeTrialArenas")
    arena = arena and arena:FindFirstChild(tostring(st.ActiveKey))
    local enemies = arena and arena:FindFirstChild("Enemies")
    local root = getRoot()
    if not (enemies and root) then
        task.wait(0.5)
        return
    end
    for _, enemy in ipairs(enemies:GetChildren()) do
        if enemy:GetAttribute("EnemyDead") == false then
            root.CFrame = CFrame.new(enemy:GetPivot().Position + State.Offset)
            doClick()
            task.wait(State.ClickDelay)
            return
        end
    end
    task.wait(0.2)
end

local function trialStep()
    local st = getTrialState()
    if not st then
        setStatus("Time Trial: estado indisponivel.")
        task.wait(5)
        return
    end
    if st.InTrial then
        local gui = LocalPlayer.PlayerGui:FindFirstChild("TrialGui")
        local room = gui and gui:FindFirstChild("Main") and gui.Main:FindFirstChild("Room")
        setStatus(("Time Trial %s: %s"):format(tostring(st.ActiveKey), room and room.Text or "..."))
        trialFight(st)
        return
    end
    if st.IsJoining then
        task.wait(0.5)
        return
    end
    local key = st.OpenTrialKeys and pickTrialKey(st.OpenTrialKeys)
    if key and getRoot() and not TeleportController:IsLoading() then
        setStatus("Entrando no Time Trial " .. key)
        TimeTrialJoinBridge:Fire("Join", key)
        waitUntil(function()
            return st.InTrial
        end, 12, "TimeTrial")
        return
    end
    task.wait(1)
end

startOwnedLoop(trialStep, "TimeTrial")

-- Auto Raid: create the chosen raid solo (spends its key), clear every wave, repeat.
local RaidConfig = Library.getConfig("RaidConfig")
local RaidJoinBridge = Library.getBridge("RaidJoin")
local RaidGateTeleportBridge = Library.getBridge("RaidGateTeleport")
local GATE_ANNOUNCE_TTL = 60 -- seconds a gate announcement stays joinable
local raid = {
    active = false,
    instanceKey = nil,
    wave = 0,
    total = 0,
    lastSeen = 0,
    label = "Raid",
    kind = "Raid", -- "Raid" or "Gate": which feature owns the raid we are in
    expectUntil = 0, -- gate instances are shared, so their key has no user id: accept one right after we teleport
    gate = nil, -- { key, at } from the latest gate announcement
}

connections[#connections + 1] = Library.getBridge("RaidMapReady"):Connect(function(instanceKey)
    if type(instanceKey) ~= "string" then
        return
    end
    if instanceKey:find("_" .. LocalPlayer.UserId .. "_", 1, true) or os.clock() < raid.expectUntil then
        raid.active, raid.instanceKey, raid.lastSeen = true, instanceKey, os.clock()
        raid.expectUntil = 0
    end
end)
connections[#connections + 1] = Library.getBridge("RaidAnnouncement"):Connect(function(payload)
    if type(payload) == "table" and payload.GateTeleport and type(payload.Key) == "string" then
        raid.gate = { key = payload.Key, at = os.clock(), rank = payload.GateRank or payload.Rank }
    end
end)
connections[#connections + 1] = Library.getBridge("RaidState"):Connect(function(payload)
    local s = type(payload) == "table" and payload or nil
    if s and raid.active then
        raid.lastSeen = os.clock()
        raid.wave = s.Wave or raid.wave
        raid.total = s.TotalWaves or raid.total
    end
end)
connections[#connections + 1] = Library.getBridge("RaidEnded"):Connect(function()
    raid.active, raid.instanceKey = false, nil
end)

-- Pick up a raid that is already running (e.g. after a script reload).
do
    local arenas = workspace:FindFirstChild("RaidArenas")
    for _, arena in ipairs(arenas and arenas:GetChildren() or {}) do
        if arena.Name:find("_" .. LocalPlayer.UserId .. "_", 1, true) then
            raid.active, raid.instanceKey, raid.lastSeen = true, arena.Name, os.clock()
        end
    end
end


local RaidController = require(Library.Client.RaidController)
local raidControllerState

-- The game's own raid state (InRaid, ActiveInstanceKey...) lives in an upvalue table.
local function getRaidControllerState()
    if raidControllerState then
        return raidControllerState
    end
    for _, fn in pairs(RaidController) do
        if type(fn) == "function" then
            local ok, ups = pcall(debug.getupvalues, fn)
            if ok then
                for _, up in pairs(ups) do
                    if type(up) == "table" and rawget(up, "InRaid") ~= nil and rawget(up, "ActiveKeys") ~= nil then
                        raidControllerState = up
                        return up
                    end
                end
            end
        end
    end
    return nil
end

-- Adopt a raid/gate we are already inside (joined by hand, or before the toggle was on).
local function adoptCurrentRaid()
    local arenas = workspace:FindFirstChild("RaidArenas")
    if not arenas then
        return false
    end
    local st = getRaidControllerState()
    if st and not st.InRaid then
        return false -- the game says we are not in a raid: never adopt a nearby arena of another player
    end
    local arena = st and st.ActiveInstanceKey and arenas:FindFirstChild(st.ActiveInstanceKey)
    if not arena then
        -- Fallback (controller state unavailable or key not streamed yet): the arena whose enemies are right next to us.
        local root = getRoot()
        local bestDist
        for _, candidate in ipairs(arenas:GetChildren()) do
            local enemies = candidate:FindFirstChild("Enemies")
            local first = enemies and enemies:GetChildren()[1]
            if first and root then
                local d = (first:GetPivot().Position - root.Position).Magnitude
                if d < 400 and (not bestDist or d < bestDist) then
                    arena, bestDist = candidate, d
                end
            end
        end
    end
    if not arena then
        return false
    end
    raid.active, raid.instanceKey, raid.lastSeen = true, arena.Name, os.clock()
    local key = st and st.ActiveKey or arena.Name:match("^(World%d+%a*)")
    raid.kind = arena.Name:find("_gate_", 1, true) and "Gate" or "Raid"
    raid.label = raid.kind .. " " .. tostring(key)
    return true
end

local function raidStep()
    if not raid.active and adoptCurrentRaid() then
        return
    end
    if raid.active then
        local arenas = workspace:FindFirstChild("RaidArenas")
        local arena = arenas and arenas:FindFirstChild(raid.instanceKey or "")
        if not arena or os.clock() - raid.lastSeen > 25 then
            raid.active, raid.instanceKey = false, nil -- raid ended without us hearing about it
            return
        end
        local enemies = arena:FindFirstChild("Enemies")
        local root = getRoot()
        setStatus(("%s: wave %d/%d"):format(raid.label, raid.wave, raid.total))
        if enemies and root then
            for _, enemy in ipairs(enemies:GetChildren()) do
                if enemy:GetAttribute("EnemyDead") == false then
                    root.CFrame = CFrame.new(enemy:GetPivot().Position + State.Offset)
                    doClick()
                    task.wait(State.ClickDelay)
                    return
                end
            end
        end
        task.wait(0.2)
        return
    end

    -- Gates are free and short-lived, so they take priority over creating a keyed raid.
    local gate = raid.gate
    if State.Owner == "Gate" and gate and os.clock() - gate.at < GATE_ANNOUNCE_TTL and getRoot() and not TeleportController:IsLoading() then
        raid.gate = nil
        raid.label = "Gate " .. gate.key
        raid.kind = "Gate"
        setStatus("Entrando no Gate " .. gate.key)
        raid.expectUntil = os.clock() + 20
        RaidGateTeleportBridge:Fire(gate.key)
        waitUntil(function()
            return raid.active
        end, 20) -- no owner check: once teleporting, the gate must be adopted even if control moved
        raid.expectUntil = 0
        if not raid.active then
            task.wait(2)
        end
        return
    end
    if State.Owner ~= "Raid" then
        setStatus("Aguardando um Gate...")
        task.wait(1)
        return
    end

    raid.label = "Raid " .. tostring(State.RaidKey)
    raid.kind = "Raid"
    local info = RaidConfig:GetRaid(State.RaidKey)
    if not info then
        setStatus("Raid invalida: " .. tostring(State.RaidKey))
        task.wait(3)
        return
    end
    local cost = info.Cost
    if type(cost) == "table" and (tonumber(PlayerData.Data[cost.ItemId]) or 0) < (cost.Amount or 1) then
        setStatus(("Sem chave: %s x%d"):format(tostring(cost.ItemId), cost.Amount or 1))
        task.wait(5)
        return
    end
    if not getRoot() or TeleportController:IsLoading() then
        task.wait(1)
        return
    end
    setStatus("Criando raid " .. tostring(State.RaidKey))
    RaidJoinBridge:Fire("Create", State.RaidKey)
    waitUntil(function()
        return raid.active
    end, 15)
    if not raid.active then
        task.wait(3)
    end
end

startOwnedLoop(raidStep, "Gate", "Raid")
startOwnedLoop(questStep, "Quest")

-- DPS, solo estimates and Auto Defense ---------------------------------------
-- DPS: the game's own counter sums the local player's EnemyHit damage over the last 5s; same here, keeping
-- the session peak because the value drops to 0 whenever nothing is being hit.
-- Wave health (verified in Titan Wall Defense): enemy base Health x WaveHealthScaling^(wave - 1).
local defense = { wave = 0, total = 0, idleUntil = 0 }
do
local BigNum = Library.getUtil("BigNum")
local FormatUtil = Library.getUtil("FormatUtil")
local DefenseConfig = Library.getConfig("DefenseConfig")
local DefenseController = require(Library.Client.DefenseController)
local DefenseJoinBridge = Library.getBridge("DefenseJoin")
local DefenseLeaveBridge = Library.getBridge("DefenseLeave")
local DPS_WINDOW = 5
local hits = {} -- { time, BigNum damage }
local dpsNow, dpsPeak = BigNum.Zero, BigNum.Zero

local function addHit(amount)
    local value = BigNum.TryFrom(amount)
    if value and BigNum.IsPositive(value) then
        hits[#hits + 1] = { os.clock(), value }
    end
end

-- Same filter as DpsController.OnEnemyHit: a4 marks the local player's hits; a batch arrives as {{enemy, dmg}}.
connections[#connections + 1] = Library.getBridge("EnemyHit"):Connect(function(a1, a2, a3, a4)
    if a4 ~= true then
        return
    end
    if type(a1) == "table" then
        if a3 == true then
            for _, entry in ipairs(a1) do
                if type(entry) == "table" then
                    addHit(entry[2])
                end
            end
        end
        return
    end
    addHit(a2)
end)

State.Actions.resetDps = function()
    dpsPeak = BigNum.Zero
end

task.spawn(function()
    while State.Running do
        local cutoff = os.clock() - DPS_WINDOW
        local kept, sum = {}, BigNum.Zero
        for _, hit in ipairs(hits) do
            if hit[1] >= cutoff then
                kept[#kept + 1] = hit
                sum = BigNum.Add(sum, hit[2])
            end
        end
        hits = kept
        dpsNow = BigNum.Div(sum, DPS_WINDOW)
        dpsPeak = BigNum.Max(dpsPeak, dpsNow)
        task.wait(0.5)
    end
end)

local function log10(value)
    local ok, result = pcall(BigNum.Log10, value)
    return ok and tonumber(result) or nil
end

-- Highest wave whose whole health dies inside the wave time limit at `dpsLog` (log10 of DPS), and the seconds
-- the last wave takes. baseLog = log10 of the summed health of one wave at wave 1.
local function maxWave(baseLog, scaling, totalWaves, timeLimit, dpsLog)
    if not (baseLog and dpsLog) then
        return 0, nil
    end
    local step = math.log10(math.max(scaling, 1.000001))
    local wave = math.floor((dpsLog + math.log10(timeLimit) - baseLog) / step) + 1
    wave = math.clamp(wave, 0, totalWaves)
    local seconds = wave > 0 and 10 ^ (baseLog + (wave - 1) * step - dpsLog) or nil
    return wave, seconds
end

-- log10 of one wave's health at wave 1: every enemy type once, scaled to EnemiesPerWave when it differs.
local function waveBaseLog(info)
    local sum, types = BigNum.Zero, 0
    for _, enemy in pairs(info.Enemies or {}) do
        if enemy.Health then
            sum = BigNum.Add(sum, enemy.Health)
            types += 1
        end
    end
    if types == 0 then
        return nil
    end
    local perWave = tonumber(info.EnemiesPerWave) or types
    return (log10(sum) or 0) + math.log10(perWave / types)
end

local function defenseKeys()
    local keys = {}
    for key, info in pairs(DefenseConfig:GetAllDefenses()) do
        keys[#keys + 1] = type(key) == "string" and key or info.Key
    end
    table.sort(keys, function(a, b)
        return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0)
    end)
    return keys
end

local function keyCount(info)
    local cost = info.Cost
    return cost and tonumber(PlayerData.Data[cost.ItemId]) or 0, cost and (tonumber(cost.Amount) or 1) or 0
end

-- [key] = { wave, seconds, total, keys, unlocked } for every defense, at the peak DPS.
function defense.estimates()
    local dpsLog = log10(dpsPeak)
    local out = {}
    for _, key in ipairs(defenseKeys()) do
        local info = DefenseConfig:GetDefense(key)
        if info then
            local wave, seconds = maxWave(waveBaseLog(info), info.WaveHealthScaling or 1, info.TotalWaves or 1, info.WaveTimeLimit or 300, dpsLog)
            local have, need = keyCount(info)
            out[key] = {
                name = info.Name or key, wave = wave, seconds = seconds, total = info.TotalWaves or 1,
                have = have, need = need, unlocked = TeleportController:IsWorldUnlocked(info.WorldId),
            }
        end
    end
    return out
end

-- "Best": the highest-world defense with a key, in an unlocked world, that the estimate says we finish.
function defense.pickKey()
    if State.DefenseKey ~= "Best" then
        local info = DefenseConfig:GetDefense(State.DefenseKey)
        if not info then
            return nil
        end
        local have, need = keyCount(info)
        return have >= need and State.DefenseKey or nil
    end
    local estimates = defense.estimates()
    local keys = defenseKeys()
    for index = #keys, 1, -1 do
        local e = estimates[keys[index]]
        if e and e.unlocked and e.have >= e.need and e.wave >= e.total then
            return keys[index]
        end
    end
    return nil
end

-- The game's own defense state (InDefense, IsJoining, ActiveInstanceKey...) lives in an upvalue table.
function defense.state()
    if defense.controllerState then
        return defense.controllerState
    end
    for _, fn in pairs(DefenseController) do
        if type(fn) == "function" then
            local ok, ups = pcall(debug.getupvalues, fn)
            if ok then
                for _, up in pairs(ups) do
                    -- ActiveInstanceKey is nil outside a defense, so match on the two flags that always exist
                    if type(up) == "table" and type(rawget(up, "InDefense")) == "boolean" and type(rawget(up, "IsJoining")) == "boolean" then
                        defense.controllerState = up
                        return up
                    end
                end
            end
        end
    end
    return nil
end

connections[#connections + 1] = Library.getBridge("DefenseState"):Connect(function(payload)
    if type(payload) == "table" then
        defense.wave = tonumber(payload.Wave) or defense.wave
        defense.total = tonumber(payload.TotalWaves) or defense.total
    end
end)
connections[#connections + 1] = Library.getBridge("DefenseEnded"):Connect(function()
    defense.wave = 0
end)

local function defenseStep()
    local st = defense.state()
    if not st then
        setStatus("Defense: estado indisponivel.")
        task.wait(5)
        return
    end
    if st.InDefense then
        if State.DefenseLeaveWave > 0 and defense.wave >= State.DefenseLeaveWave then
            setStatus(("Defense: wave %d atingida, saindo."):format(defense.wave))
            DefenseLeaveBridge:Fire()
            waitUntil(function()
                return not st.InDefense
            end, 15)
            return
        end
        local arenas = workspace:FindFirstChild("DefenseArenas")
        local arena = arenas and arenas:FindFirstChild(tostring(st.ActiveInstanceKey))
        local enemies = arena and arena:FindFirstChild("Enemies")
        local root = getRoot()
        setStatus(("Defense %s: wave %d/%d"):format(tostring(st.ActiveKey), defense.wave, defense.total))
        if enemies and root then
            local best, bestDist
            for _, enemy in ipairs(enemies:GetChildren()) do
                if enemy:GetAttribute("EnemyDead") == false then
                    local d = (enemy:GetPivot().Position - root.Position).Magnitude
                    if not bestDist or d < bestDist then
                        best, bestDist = enemy, d
                    end
                end
            end
            if best then
                root.CFrame = CFrame.new(best:GetPivot().Position + State.Offset)
                doClick()
                task.wait(State.ClickDelay)
                return
            end
        end
        task.wait(0.2)
        return
    end
    if st.IsJoining or TeleportController:IsLoading() or not getRoot() then
        task.wait(0.5)
        return
    end
    local key = defense.pickKey()
    if not key then
        setStatus(State.DefenseKey == "Best" and "Defense: nenhuma com chave que eu complete (veja a aba Solo)."
            or "Defense: sem chave para " .. tostring(State.DefenseKey))
        defense.idleUntil = os.clock() + 30
        return
    end
    setStatus("Criando defense " .. key)
    DefenseJoinBridge:Fire("Create", key)
    waitUntil(function()
        return st.InDefense
    end, 20)
    if not st.InDefense then
        defense.idleUntil = os.clock() + 10
    end
end

startOwnedLoop(defenseStep, "Defense")

-- Solo tab: what the peak DPS finishes, refreshed every 2s.
local RaidConfigSolo = Library.getConfig("RaidConfig")

-- Raid estimate at the peak DPS (enemy count per wave is a guess: every type once): info, wave, seconds.
function defense.raidEstimate(key)
    local info = RaidConfigSolo:GetRaid(key)
    if not (info and info.Enemies) then
        return info, 0, nil
    end
    local wave, seconds = maxWave(waveBaseLog(info), info.WaveHealthScaling or 1, info.TotalWaves or 1, info.WaveTimeLimit or 300, log10(dpsPeak))
    return info, wave, seconds
end

function defense.hasDps()
    return BigNum.IsPositive(dpsPeak)
end

-- Formatted DPS for the webhook: now, peak.
function defense.dpsText()
    return FormatUtil.Number(dpsNow, 2), FormatUtil.Number(dpsPeak, 2)
end

-- Key stock of a raid or defense: have, need, itemId, worldId, total waves, solo wave estimate.
function defense.modeInfo(kind, key)
    if kind == "Raid" then
        local info, wave = defense.raidEstimate(key)
        if not info then
            return nil
        end
        local have, need = keyCount(info)
        return { have = have, need = need, item = info.Cost and info.Cost.ItemId, world = info.WorldId, total = info.TotalWaves or 1, wave = wave, name = info.Name or key }
    end
    local e = defense.estimates()[key]
    local info = DefenseConfig:GetDefense(key)
    if not (e and info) then
        return nil
    end
    return { have = e.have, need = e.need, item = info.Cost and info.Cost.ItemId, world = info.WorldId, total = e.total, wave = e.wave, name = e.name }
end
local function fmtSeconds(seconds)
    if not seconds then
        return "-"
    end
    return seconds < 1 and "<1s" or ("%ds"):format(math.floor(seconds + 0.5))
end

local function soloLine(name, wave, total, seconds, have, unlocked)
    local verdict = wave >= total and ("SOLA tudo (%d/%d, ultima wave %s)"):format(total, total, fmtSeconds(seconds))
        or wave > 0 and ("ate wave %d/%d"):format(wave, total)
        or "nao passa da wave 1"
    local extra = (not unlocked and "  [mundo bloqueado]" or "") .. ("  chaves: %d"):format(have)
    return ("%s: %s%s"):format(name, verdict, extra)
end

task.spawn(function()
    while State.Running do
        local ok, err = pcall(function()
            local lines = {
                ("DPS agora: %s | pico: %s"):format(FormatUtil.Number(dpsNow, 2), FormatUtil.Number(dpsPeak, 2)),
            }
            if not BigNum.IsPositive(dpsPeak) then
                lines[#lines + 1] = "Sem DPS medido ainda: ataque algo (Auto Quest, raid, defense)."
            else
                lines[#lines + 1] = ""
                lines[#lines + 1] = "DEFENSES"
                local estimates = defense.estimates()
                for _, key in ipairs(defenseKeys()) do
                    local e = estimates[key]
                    if e then
                        lines[#lines + 1] = soloLine(e.name, e.wave, e.total, e.seconds, e.have, e.unlocked)
                    end
                end
                lines[#lines + 1] = ""
                lines[#lines + 1] = "RAIDS (estimado)"
                local dpsLog = log10(dpsPeak)
                local raids = {}
                for key in pairs(RaidConfigSolo:GetAllRaids()) do
                    raids[#raids + 1] = key
                end
                table.sort(raids)
                for _, key in ipairs(raids) do
                    local info, wave, seconds = defense.raidEstimate(key)
                    if info and info.Enemies then
                        local have = keyCount(info)
                        lines[#lines + 1] = soloLine(info.Name or key, wave, info.TotalWaves or 1, seconds, have, TeleportController:IsWorldUnlocked(info.WorldId or 0))
                    end
                end
            end
            local text = table.concat(lines, "\n")
            getgenv().AstralX.SoloText = text -- MacLib only builds a tab's content once it is opened
            updateBody(extraTabs.soloText, text)
        end)
        if not ok then
            warn("[AstralX] solo:", err)
        end
        task.wait(2)
    end
end)
end

-- Fully auto raid/defense --------------------------------------------------------
-- A planner picks the first selected mode (in world order) that has a key and hands it to the hub's own Raid or
-- Defense feature (featureOn below switches those on for it). With no key anywhere it targets the first eligible
-- mode's key: KeyFarm goes to a world whose enemies drop it and kills them, highest drop chance first.
defense.full = { choice = nil, farm = nil } -- a field, not a local: the main chunk is at the 200-local limit
do
local dropCache = {} -- [itemId] = { { name, chance, world } } sorted by chance

local function droppers(itemId)
    if dropCache[itemId] then
        return dropCache[itemId]
    end
    local list = {}
    local ok, all = pcall(EnemyConfig.GetAllEnemies, EnemyConfig)
    for id, entry in pairs(ok and type(all) == "table" and all or {}) do
        local drop = type(entry) == "table" and type(entry.Drops) == "table" and entry.Drops[itemId]
        if drop then
            local info = EnemyConfig:GetEnemy(id)
            list[#list + 1] = {
                name = info and info.Name or tostring(id),
                chance = tonumber(type(drop) == "table" and drop.Chance or drop) or 0,
                world = tonumber(entry.World or entry.WorldId),
            }
        end
    end
    table.sort(list, function(a, b)
        return a.chance > b.chance
    end)
    dropCache[itemId] = list
    return list
end

local function orderedModes()
    local list = {}
    for mode in pairs(State.FullAutoModes) do
        local kind, key = mode:match("^(%a+):(.+)$")
        local info = kind and defense.modeInfo(kind, key)
        if info then
            list[#list + 1] = { kind = kind, key = key, info = info }
        end
    end
    table.sort(list, function(a, b)
        local wa, wb = a.info.world or 0, b.info.world or 0
        if wa == wb then
            return a.key < b.key
        end
        if State.FullAutoOrder == "Low" then
            return wa < wb
        end
        return wa > wb
    end)
    return list
end

-- Before any DPS is measured the solo filter would reject everything, so it only applies once there is a value.
local function eligible(mode)
    if not TeleportController:IsWorldUnlocked(mode.info.world or 0) then
        return false
    end
    if State.FullAutoSoloOnly and defense.hasDps() and mode.info.wave < mode.info.total then
        return false
    end
    return true
end

local function inMode()
    local st = defense.state()
    return raid.active or (st ~= nil and (st.InDefense or st.IsJoining)) or State.StepBusy.Raid or State.StepBusy.Defense
end

local function plan()
    if inMode() then
        return -- keep the current choice until that raid/defense (or its creation) is over
    end
    local candidates = {}
    for _, mode in ipairs(orderedModes()) do
        if eligible(mode) then
            candidates[#candidates + 1] = mode
        end
    end
    for _, mode in ipairs(candidates) do
        if mode.info.have >= mode.info.need then
            defense.full.choice, defense.full.farm = mode, nil
            if mode.kind == "Raid" then
                State.RaidKey = mode.key
            else
                State.DefenseKey = mode.key
            end
            return
        end
    end
    defense.full.choice = nil
    local target = State.FullAutoFarm and candidates[1]
    if target and target.info.item then
        if not (defense.full.farm and defense.full.farm.item == target.info.item) then
            defense.full.farm = { item = target.info.item, need = target.info.need, name = target.info.name, droppers = droppers(target.info.item) }
        end
    else
        defense.full.farm = nil
        setStatus(next(State.FullAutoModes) and "Full Auto: nenhum modo marcado disponivel (chave, mundo ou solo)." or "Full Auto: marque ao menos um modo.")
    end
end

task.spawn(function()
    while State.Running do
        if State.FullAuto then
            local ok, err = pcall(plan)
            if not ok then
                warn("[AstralX] fullAuto:", err)
            end
        else
            defense.full.choice, defense.full.farm = nil, nil
        end
        task.wait(1)
    end
end)

local function keyFarmStep()
    local farm = defense.full.farm
    if not farm then
        task.wait(0.5)
        return
    end
    local have = tonumber(PlayerData.Data[farm.item]) or 0
    if have >= farm.need then
        defense.full.farm = nil
        return
    end
    local target
    for _, d in ipairs(farm.droppers) do
        if d.world and TeleportController:IsWorldUnlocked(d.world) then
            target = d.world
            break
        end
    end
    if not target then
        setStatus(("Full Auto: nenhum mundo liberado dropa %s."):format(farm.item))
        task.wait(5)
        return
    end
    local arrived = travelToWorld(target, "KeyFarm", setStatus, false)
    if not arrived then
        return
    end
    local worlds = workspace:FindFirstChild("Worlds")
    local world = worlds and worlds:FindFirstChild(tostring(target))
    local enemies = world and world:FindFirstChild("Enemies")
    local root = getRoot()
    if enemies and root then
        for _, d in ipairs(farm.droppers) do
            if d.world == target then
                local best, bestDist
                for _, enemy in ipairs(enemies:GetChildren()) do
                    if enemy.Name == d.name and enemy:GetAttribute("EnemyDead") == false then
                        local dist = (enemy:GetPivot().Position - root.Position).Magnitude
                        if not bestDist or dist < bestDist then
                            best, bestDist = enemy, dist
                        end
                    end
                end
                if best then
                    setStatus(("Full Auto: farmando %s (%s) no mundo %d: %s, %s%% | tem %d/%d"):format(
                        farm.item, farm.name, target, d.name, tostring(d.chance), have, farm.need))
                    root.CFrame = CFrame.new(best:GetPivot().Position + State.Offset)
                    doClick()
                    task.wait(State.ClickDelay)
                    return
                end
            end
        end
    end
    setStatus(("Full Auto: esperando inimigos que dropam %s respawnarem (mundo %d)."):format(farm.item, target))
    task.wait(0.5)
end

startOwnedLoop(keyFarmStep, "KeyFarm")
end

-- A feature runs when its own toggle is on, or (Raid / Defense) when Full Auto picked a mode of that kind.
function defense.featureOn(name, feature)
    if State[feature.flag] then
        return true
    end
    if not State.FullAuto then
        return false
    end
    -- already inside a raid/defense (joined by hand or by the game's own auto start): Full Auto finishes it
    if name == "Raid" and raid.active and raid.kind == "Raid" then
        return true
    end
    local st = name == "Defense" and defense.state()
    if st and (st.InDefense or st.IsJoining) then
        return true
    end
    local choice = defense.full.choice
    return choice ~= nil and choice.kind == name
end

connections[#connections + 1] = LocalPlayer.Idled:Connect(function()
    if State.AntiAfk then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end)


-- Roll + Sell logic ---------------------------------------------------------

local OpenEggBridge = Library.getBridge("OpenEgg")
local NotEnoughYenBridge = Library.getBridge("NotEnoughYen")
local InventoryFullBridge = Library.getBridge("InventoryFull")
local GachaRollBridge = Library.getBridge("GachaRoll")
local GachaResultBridge = Library.getBridge("GachaResult")
local DeletePetsBridge = Library.getBridge("DeletePets")
local GachaConfig = Library.getConfig("GachaConfig")
local PetsData = require(RS.SimpleWorld.Library.Config.PetsData)

local rollStats = { starOpens = 0, starPets = 0, gachaRolls = {}, sold = 0 }

-- Star (egg)

local starEvents = {} -- OpenEgg / error replies
connections[#connections + 1] = OpenEggBridge:Connect(function(key, payload)
    starEvents[#starEvents + 1] = { key = key, payload = payload }
end)
connections[#connections + 1] = NotEnoughYenBridge:Connect(function()
    starEvents[#starEvents + 1] = { error = "not_enough_yen" }
end)
connections[#connections + 1] = InventoryFullBridge:Connect(function()
    starEvents[#starEvents + 1] = { error = "inventory_full" }
end)

-- Star cannot open while broke, with a full inventory or in a locked world. Instead of holding the character
-- while it waits, it backs off until this time, and the scheduler lets Quest (or anything else) run meanwhile.
local starBlockedUntil = 0
local STAR_BACKOFF_SECONDS = 30

local function starStep()
    local key = State.StarKey
    local worldId = tonumber(key:match("%d+"))
    if not (worldId and getRoot()) then
        task.wait(1)
        return
    end
    local arrived, reason = travelToWorld(worldId, "Star", setStar, false)
    if not arrived then
        if reason == "locked" then
            starBlockedUntil = os.clock() + STAR_BACKOFF_SECONDS
        end
        return
    end

    local worlds = workspace:FindFirstChild("Worlds")
    local world = worlds and worlds:FindFirstChild(tostring(worldId))
    local systems = world and world:FindFirstChild("Systems")
    local station = systems and systems:FindFirstChild("EggStation")
    local root = getRoot()
    if not (station and root) then
        setStar("Estacao da Star nao carregada, aguardando...")
        task.wait(1)
        return
    end
    -- The server only accepts the open while we stand inside the station zone.
    if (root.Position - station.Position).Magnitude > 3 then
        root.CFrame = CFrame.new(station.Position + Vector3.new(0, 2, 0))
        task.wait(1.5)
    end

    table.clear(starEvents)
    OpenEggBridge:Fire(key, {})
    local reply
    waitUntil(function()
        reply = starEvents[1]
        return reply ~= nil
    end, 6, "Star")
    if not reply then
        setStar("Sem resposta do servidor, tentando de novo...")
        task.wait(1)
        return
    end

    local payload = reply.payload
    if reply.error == "not_enough_yen" then
        setStar(("Yen insuficiente para %s. Tentando de novo em %ds."):format(key, STAR_BACKOFF_SECONDS))
        starBlockedUntil = os.clock() + STAR_BACKOFF_SECONDS
    elseif reply.error == "inventory_full" then
        setStar(("Inventario de pets cheio (use o Auto Sell). Tentando de novo em %ds."):format(STAR_BACKOFF_SECONDS))
        starBlockedUntil = os.clock() + STAR_BACKOFF_SECONDS
    elseif type(payload) == "table" and payload.Error then
        if payload.Error == "not_near" then
            root.CFrame = CFrame.new(station.Position + Vector3.new(0, 2, 0))
            task.wait(1.5)
        elseif payload.Error == "busy" then
            task.wait(0.5) -- previous open still resolving server-side
        else
            setStar("Erro: " .. tostring(payload.Error))
            task.wait(2)
        end
    elseif type(payload) == "table" then
        rollStats.starOpens += 1
        rollStats.starPets += #payload
        setStar(("%s: %d aberturas, %d pets"):format(key, rollStats.starOpens, rollStats.starPets))
        task.wait(State.StarDelay)
    end
end

startOwnedLoop(starStep, "Star")

-- Gacha

local gachaReplies = {}
connections[#connections + 1] = GachaResultBridge:Connect(function(success, info, payload)
    gachaReplies[#gachaReplies + 1] = { success = success, info = info, payload = payload }
end)

local function gachaCost(key)
    local gacha = GachaConfig.Gachas[key]
    local cost = gacha and gacha.ItemCost
    if type(cost) == "table" and cost.ItemId then
        return cost.ItemId, cost.Amount or 1
    end
    return nil
end

local function affordableKeys()
    local keys, lacking = {}, 0
    local data = PlayerData.Data
    for key in pairs(State.GachaKeys) do
        local itemId, amount = gachaCost(key)
        if itemId and (tonumber(data[itemId]) or 0) >= amount then
            keys[#keys + 1] = key
        else
            lacking += 1
        end
    end
    table.sort(keys)
    return keys, lacking
end

local gachaCursor = 0
local lastGachaUi = 0
-- slots: Gacha Slots from the last reply. best: [key] = best rarity the server keeps (fresher than PlayerData).
-- active: the gachas the target mode is working on right now, in order.
local gachaMeta = { slots = 1, best = {}, active = {} }

-- Target mode: the gacha is done once its best rarity reaches the target (or its own top rarity, if lower).
function gachaMeta.isDone(key)
    local data = PlayerData.Data
    local rarity = gachaMeta.best[key]
        or (type(data.EquippedGachas) == "table" and data.EquippedGachas[key])
        or (type(data.ActiveGachas) == "table" and data.ActiveGachas[key])
    local goal = GachaConfig:GetRarityIndex(State.GachaTarget)
    local top = GachaConfig:GetTopRarity(key)
    if top then
        goal = math.min(goal, GachaConfig:GetRarityIndex(top))
    end
    return rarity ~= nil and GachaConfig:GetRarityIndex(rarity) >= goal, rarity
end

function gachaMeta.canAfford(key)
    local itemId, amount = gachaCost(key)
    return itemId ~= nil and (tonumber(PlayerData.Data[itemId]) or 0) >= amount
end

-- Keeps up to State.GachaBatch selected gachas that are below the target and affordable. A gacha leaves the
-- set as soon as it is done or out of tokens, and the next one in world order takes its place.
function gachaMeta.refill()
    local active = {}
    for _, key in ipairs(gachaMeta.active) do
        if State.GachaKeys[key] and not gachaMeta.isDone(key) and gachaMeta.canAfford(key) then
            active[#active + 1] = key
        end
    end
    local candidates, done, broke = {}, 0, 0
    for key in pairs(State.GachaKeys) do
        candidates[#candidates + 1] = key
    end
    table.sort(candidates, function(a, b)
        local wa, wb = tonumber(a:match("%d+")) or 99, tonumber(b:match("%d+")) or 99
        if wa ~= wb then
            return wa < wb
        end
        return a < b
    end)
    for _, key in ipairs(candidates) do
        if gachaMeta.isDone(key) then
            done += 1
        elseif not gachaMeta.canAfford(key) then
            broke += 1
        elseif #active < State.GachaBatch and not table.find(active, key) then
            active[#active + 1] = key
        end
    end
    gachaMeta.active = active
    return active, done, broke, #candidates
end

local function gachaStep()
    local keys, lacking, metaDone, metaTotal
    if State.GachaMode == "Meta" then
        keys, metaDone, lacking, metaTotal = gachaMeta.refill()
        if #keys == 0 then
            setGacha(metaTotal == 0 and "Escolha ao menos um gacha."
                or ("Meta %s: %d/%d prontos, %d sem tokens."):format(State.GachaTarget, metaDone, metaTotal, lacking))
            task.wait(2)
            return
        end
    else
        keys, lacking = affordableKeys()
        if #keys == 0 then
            setGacha(next(State.GachaKeys) and "Sem tokens para os gachas escolhidos." or "Escolha ao menos um gacha.")
            task.wait(2)
            return
        end
    end

    -- One request spins as many gachas as the player has Gacha Slots (payload.SlotCount, from Promotion
    -- ranks); extra keys come back Skipped no_slot and overlapping requests are rate_limited. So each request
    -- carries the next SlotCount keys of the rotation.
    local rolling = {}
    for _ = 1, math.min(gachaMeta.slots, #keys) do
        gachaCursor = gachaCursor % #keys + 1
        rolling[#rolling + 1] = keys[gachaCursor]
    end

    table.clear(gachaReplies)
    GachaRollBridge:Fire(rolling)
    local reply
    local deadline = os.clock() + 12
    repeat
        reply = gachaReplies[1]
        if reply then
            break
        end
        task.wait() -- one frame: the reply is picked up as soon as it arrives
    until os.clock() >= deadline or not State.Running
    if not reply then
        setGacha("Sem resposta do servidor, tentando de novo...")
        task.wait(1)
        return
    end

    if reply.success then
        local payload = reply.payload
        if type(payload) == "table" and tonumber(payload.SlotCount) then
            gachaMeta.slots = math.max(1, math.floor(payload.SlotCount))
        end
        local gachas = type(payload) == "table" and payload.Gachas or {}
        for key, info in pairs(gachas) do
            rollStats.gachaRolls[key] = (rollStats.gachaRolls[key] or 0) + (info.RollCount or 1)
            if type(info.ActiveRarity) == "string" then
                gachaMeta.best[key] = info.ActiveRarity
            end
        end
        local lines = {}
        if metaTotal then
            lines[1] = ("Meta %s: %d/%d prontos"):format(State.GachaTarget, metaDone, metaTotal)
        end
        for _, key in ipairs(keys) do
            local suffix = metaTotal and (" (" .. tostring(select(2, gachaMeta.isDone(key)) or "-") .. ")") or ""
            lines[#lines + 1] = ("%s: %d rolls%s"):format(key, rollStats.gachaRolls[key] or 0, suffix)
        end
        if lacking > 0 then
            lines[#lines + 1] = ("(%d sem tokens)"):format(lacking)
        end
        if os.clock() - lastGachaUi > 0.5 then -- the label only needs a few updates per second
            lastGachaUi = os.clock()
            setGacha(table.concat(lines, "\n"))
        end
        -- the server keeps the roll locked for the whole spin; asking earlier only earns roll_locked
        local spin = type(payload) == "table" and tonumber(payload.SpinDuration) or 0
        task.wait(math.max(spin, State.GachaDelay, 0.05))
    elseif reply.info == "rate_limited" or reply.info == "roll_locked" then
        gachaCursor = gachaCursor - #rolling -- retry the same gachas
        task.wait(0.1)
    else
        setGacha("Roll recusado: " .. tostring(reply.info))
        task.wait(2)
    end
end

startLoop("AutoGacha", gachaStep)

-- Grimoire
do
local GrimoireConfig = Library.getConfig("GrimoireConfig")
local GrimoireRollBridge = Library.getBridge("GrimoireRoll")
local GrimoireResultBridge = Library.getBridge("GrimoireResult")
local grimoireReplies = {}
connections[#connections + 1] = GrimoireResultBridge:Connect(function(success, info, payload)
    grimoireReplies[#grimoireReplies + 1] = { success = success, info = info, payload = payload }
end)

local grimoireKeys = {}
for key in pairs(GrimoireConfig.Grimoires) do
    grimoireKeys[#grimoireKeys + 1] = key
end
table.sort(grimoireKeys)

local grimoireRolls = 0
local lastGrimoireUi = 0

-- The server holds one roll lock per player for the whole spin (a second request, even for the other slot,
-- comes back roll_locked), so the slots cannot roll at the same instant. Rotate through them instead.
local grimoireCursor = 0

-- Next enabled slot (of any grimoire) still below the target rarity, in rotation, or nil.
local function nextGrimoireSlot()
    local targetIndex = GrimoireConfig:GetRarityIndex(State.GrimoireTarget)
    local active = PlayerData.Data.ActiveGrimoires or {}
    local candidates = {}
    for _, key in ipairs(grimoireKeys) do
        local slots = type(active[key]) == "table" and active[key] or {}
        for _, slotKey in ipairs({ "Slot1", "Slot2" }) do
            if State.GrimoireSlots[slotKey] and GrimoireConfig:GetSlot(key, slotKey) then
                local rarity = slots[slotKey]
                if type(rarity) ~= "string" or GrimoireConfig:GetRarityIndex(rarity) < targetIndex then
                    candidates[#candidates + 1] = { key, slotKey }
                end
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    grimoireCursor = grimoireCursor % #candidates + 1
    return candidates[grimoireCursor][1], candidates[grimoireCursor][2]
end

local function grimoireStep()
    local key, slotKey = nextGrimoireSlot()
    if not key then
        updateBody(grimoireStatus, ("Meta %s atingida nos slots marcados (%d rolls)."):format(State.GrimoireTarget, grimoireRolls))
        task.wait(2)
        return
    end

    table.clear(grimoireReplies)
    GrimoireRollBridge:Fire(key, slotKey)
    local reply
    local deadline = os.clock() + 8
    repeat
        reply = grimoireReplies[1]
        if reply then
            break
        end
        task.wait()
    until os.clock() >= deadline or not State.Running
    if not reply then
        updateBody(grimoireStatus, "Sem resposta do servidor, tentando de novo...")
        task.wait(1)
        return
    end

    if reply.success then
        grimoireRolls += 1
        local payload = type(reply.payload) == "table" and reply.payload or {}
        if os.clock() - lastGrimoireUi > 0.5 then
            lastGrimoireUi = os.clock()
            updateBody(grimoireStatus, ("%s %s: %s\n%d rolls"):format(key, slotKey, tostring(payload.ActiveRarity or payload.RolledRarity or "?"), grimoireRolls))
        end
        -- the server hands out the next roll only after the spin ends
        task.wait(math.max(0.05, (tonumber(payload.SpinDuration) or 0) + 0.1, State.GachaDelay))
    elseif reply.info == "rate_limited" or reply.info == "roll_locked" then
        grimoireCursor = grimoireCursor - 1 -- retry the same slot
        task.wait(0.1)
    elseif reply.info == "not_enough_items" then
        updateBody(grimoireStatus, "Sem GrimoireToken suficiente.")
        task.wait(3)
    else
        updateBody(grimoireStatus, "Roll recusado: " .. tostring(reply.info))
        task.wait(2)
    end
end

startLoop("AutoGrimoire", grimoireStep)
end

-- Passive rolls ------------------------------------------------------------------
-- Every system answers <Result>(success, reason, payload) and keeps the better passive (payload.Replaced /
-- IsUpgrade), so rolling until the target cannot lower anything. Each system has its own server cooldown
-- (pets ~0.5s, swords ~2s, player = payload.SpinDuration): on rate_limited the wait grows, on success it shrinks.
do
local PetsDataPassive = require(RS.SimpleWorld.Library.Config.PetsData)
local GrimoireConfigPassive = Library.getConfig("GrimoireConfig")
local RETRY = { rate_limited = true, roll_locked = true, processing = true }

local function rarityOf(passive)
    if type(passive) == "table" then
        return passive.Rarity
    end
    return nil
end

local function systemDef(flag, label, configName, request, result, targets)
    local config = Library.getConfig(configName)
    return {
        flag = flag, label = label, config = config, request = Library.getBridge(request),
        result = Library.getBridge(result), targets = targets, cache = {}, cursor = 0, delay = 0.5, rolls = 0,
    }
end

-- targets() returns { { key, label, arg, current } }: arg is what the request is fired with (nil = no argument).
local SYSTEMS = {
    systemDef("AutoPassivePet", "Pets", "PetPassiveConfig", "PetPassiveRollRequest", "PetPassiveResult", function(sys)
        local data = PlayerData.Data
        local list = {}
        local pool = State.PassivePetEquippedOnly and (data.EquippedPets or {}) or (data.Pets or {})
        for uid in pairs(pool) do
            local pet = data.Pets and data.Pets[uid]
            local info = pet and PetsDataPassive[pet.PetId]
            if info and State.PassivePetRarities[info.Rarity] then
                list[#list + 1] = {
                    key = uid, label = ("%s (%s)"):format(tostring(info.Name or pet.PetId), info.Rarity),
                    arg = { SystemKey = sys.config.SystemKey, PetUniqueId = uid },
                    current = sys.cache[uid] or rarityOf(data.PetPassives and data.PetPassives[uid]),
                }
            end
        end
        table.sort(list, function(a, b)
            return a.key < b.key
        end)
        return list
    end),
    systemDef("AutoPassiveSword", "Espada", "SwordPassiveConfig", "SwordPassiveRollRequest", "SwordPassiveResult", function(sys)
        local s = PlayerData.Data.EquippedSword
        if type(s) ~= "table" or not s.SwordKey then
            return {}
        end
        local key = ("%s_%s_%d_%d"):format(s.SwordKey, tostring(s.Rarity), s.Level or 0, s.Index or 1)
        local saved = PlayerData.Data.SwordPassives
        return { {
            key = key, label = ("%s %s"):format(s.SwordKey, tostring(s.Rarity)),
            arg = { SystemKey = sys.config.SystemKey, SwordKey = s.SwordKey, Rarity = s.Rarity, Level = s.Level or 0, Index = s.Index or 1 },
            current = sys.cache[key] or rarityOf(saved and saved[key]),
        } }
    end),
    systemDef("AutoPassiveShadow", "Shadow", "ShadowPassiveConfig", "ShadowPassiveRollRequest", "ShadowPassiveResult", function(sys)
        local s = PlayerData.Data.EquippedShadow
        if type(s) ~= "table" or not s.Uid then
            return {}
        end
        return { {
            key = s.Uid, label = tostring(s.ShadowKey),
            arg = { SystemKey = sys.config.SystemKey, Uid = s.Uid },
            current = sys.cache[s.Uid], -- not in PlayerData: learned from the first reply
        } }
    end),
    systemDef("AutoPassiveTitan", "Titan", "TitanPassiveConfig", "TitanPassiveRollRequest", "TitanPassiveResult", function(sys)
        local t = PlayerData.Data.EquippedTitan
        if type(t) ~= "table" or not t.TitanKey then
            return {}
        end
        local key = sys.config:BuildKey(t.TitanKey, t.Rarity, 1)
        local saved = PlayerData.Data.TitanPassives
        return { {
            key = key, label = ("%s %s"):format(t.TitanKey, tostring(t.Rarity)),
            arg = { SystemKey = sys.config.SystemKey, TitanKey = t.TitanKey, Rarity = t.Rarity, Index = 1 },
            current = sys.cache[key] or rarityOf(saved and saved[key]),
        } }
    end),
    systemDef("AutoPassiveGrimoire", "Grimoire", "GrimoirePassiveConfig", "GrimoirePassiveRollRequest", "GrimoirePassiveResult", function(sys)
        local list = {}
        local active = PlayerData.Data.ActiveGrimoires or {}
        for grimoireKey in pairs(GrimoireConfigPassive.Grimoires) do
            local slots = type(active[grimoireKey]) == "table" and active[grimoireKey] or {}
            for _, slotKey in ipairs({ "Slot1", "Slot2" }) do
                if slots[slotKey] then
                    local key = grimoireKey .. "|" .. slotKey
                    list[#list + 1] = {
                        key = key, label = ("%s %s"):format(grimoireKey, slotKey),
                        arg = { SystemKey = sys.config.SystemKey, GrimoireKey = grimoireKey, SlotKey = slotKey },
                        current = sys.cache[key],
                    }
                end
            end
        end
        return list
    end),
    systemDef("AutoPassivePlayer", "Jogador", "PlayerPassiveConfig", "PlayerPassiveRoll", "PlayerPassiveResult", function(sys)
        return { {
            key = "player", label = "jogador", arg = nil,
            current = sys.cache.player or rarityOf(PlayerData.Data.ActivePassive),
        } }
    end),
}

local function report(sys, text)
    setLine(extraTabs.passiveLines, extraTabs.passiveStatus, sys.flag, sys.label .. ": " .. text)
end

local function isDone(sys, rarity)
    if not rarity then
        return false
    end
    return (sys.config:GetRarityIndex(rarity) or 0) >= (sys.config:GetRarityIndex(State.PassiveTarget) or 99)
end

-- The best passive the reply says this target now has.
local function replyRarity(payload)
    if type(payload) ~= "table" then
        return nil
    end
    return rarityOf(payload.CurrentPassive) or rarityOf(payload.ActivePassive) or rarityOf(payload.ChangedEntry)
end

local function passiveStep(sys)
    local targets = sys.targets(sys)
    local pending = {}
    for _, target in ipairs(targets) do
        if not isDone(sys, target.current) then
            pending[#pending + 1] = target
        end
    end
    if #pending == 0 then
        report(sys, #targets == 0 and "nenhum alvo (filtro/equipado)." or ("todos no alvo %s (%d rolls)."):format(State.PassiveTarget, sys.rolls))
        task.wait(3)
        return
    end
    local cost = sys.config.ItemCost
    if type(cost) == "table" and (tonumber(PlayerData.Data[cost.ItemId]) or 0) < (cost.Amount or 1) then
        report(sys, "sem " .. tostring(cost.ItemId) .. ".")
        task.wait(5)
        return
    end
    sys.cursor = sys.cursor % #pending + 1
    local target = pending[sys.cursor]

    local reply
    local connection = sys.result:Connect(function(success, reason, payload)
        reply = reply or { success = success, reason = reason, payload = payload }
    end)
    if target.arg == nil then
        sys.request:Fire()
    else
        sys.request:Fire(target.arg)
    end
    local deadline = os.clock() + 6
    while not reply and os.clock() < deadline and State.Running and State[sys.flag] do
        task.wait()
    end
    connection:Disconnect()
    if not reply then
        report(sys, "sem resposta, tentando de novo...")
        task.wait(1)
        return
    end

    if reply.success then
        sys.rolls += 1
        local rarity = replyRarity(reply.payload)
        if rarity then
            sys.cache[target.key] = rarity
        end
        sys.delay = math.max(0.5, sys.delay - 0.05)
        report(sys, ("%s: %s | %d pendentes, %d rolls"):format(target.label, tostring(rarity or "?"), #pending, sys.rolls))
        local spin = type(reply.payload) == "table" and tonumber(reply.payload.SpinDuration) or 0
        task.wait(math.max(spin, sys.delay))
    elseif RETRY[reply.reason] then
        sys.cursor -= 1 -- same target again
        sys.delay = math.min(3, sys.delay + 0.25)
        task.wait(sys.delay)
    elseif reply.reason == "not_enough_items" then
        report(sys, "sem token.")
        task.wait(5)
    elseif reply.reason == "world_locked" then
        report(sys, "mundo do sistema bloqueado.")
        task.wait(30)
    else
        report(sys, "recusado: " .. tostring(reply.reason))
        task.wait(2)
    end
end

for _, sys in ipairs(SYSTEMS) do
    startLoop(sys.flag, function()
        passiveStep(sys)
    end)
end
end

do
local UpgradesConfig = Library.getConfig("UpgradesConfig")
local UpgradesMaxBridge = Library.getBridge("UpgradesMaxRequest")
local Upgrades2Config = Library.getConfig("Upgrades2Config")
local Upgrades2Bridge = Library.getBridge("Upgrades2Request")
local RangeUpgradeConfig = Library.getConfig("RangeUpgradeConfig")
local RangeUpgradeBridge = Library.getBridge("RangeUpgradeRequest")
local ProgressionConfig = Library.getConfig("ProgressionConfig")
local ProgressionBridge = Library.getBridge("ProgressionUpgrade")
local RankUpBridge = Library.getBridge("RankUp")
local PromotionBridge = Library.getBridge("PromotionRankPromote")
local ClaimAchievementsBridge = Library.getBridge("ClaimAllAchievements")
local ClaimGlobalQuestsBridge = Library.getBridge("GlobalQuestClaimAll")
local RelicsConfig = Library.getConfig("Relics")
local RelicMaxBridge = Library.getBridge("RelicMaxUpgradeRequest")
local AccessoryConfig = Library.getConfig("AccessoryConfig")
local AccessoryCurseConfig = Library.getConfig("AccessoryCurseConfig")
local AccessoryCurseBridge = Library.getBridge("AccessoryCurseRollRequest")
local EquipAccessoryRemote = RS.SimpleWorld.Library.Network.Functions.EquipAccessory

-- Upgrade: UpgradesMaxRequest:Fire(systemKey, stat) buys as many levels as the system's currency allows.
-- Levels live in PlayerData.Data.MultiplierUpgrades[systemKey][stat]; a non-number cost means maxed out.

local upgradeBought = 0

local function upgradeStep()
    local data = PlayerData.Data
    local keys = {}
    for key in pairs(State.UpgradeKeys) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    if #keys == 0 then
        setUpgrade("Escolha ao menos um sistema.")
        task.wait(2)
        return
    end

    local lines = {}
    for _, key in ipairs(keys) do
        local system = UpgradesConfig.Systems[key]
        local levels = type(data.MultiplierUpgrades) == "table" and data.MultiplierUpgrades[key] or {}
        local have = system and tonumber(data[system.CostItemId]) or 0
        local pending, maxed = 0, 0
        for stat in pairs(system and system.Upgrades or {}) do
            local level = UpgradesConfig:NormalizeLevel(key, stat, levels[stat] or 0)
            local cost = UpgradesConfig:GetCostForLevel(key, stat, level)
            if type(cost) ~= "number" then
                maxed += 1
            elseif have >= cost then
                pending += 1
                UpgradesMaxBridge:Fire(key, stat)
                upgradeBought += 1
                task.wait(0.4) -- the server resolves one request at a time
                have = tonumber(data[system.CostItemId]) or 0
            end
        end
        lines[#lines + 1] = ("%s: %d comprados, %d no max"):format(key, pending, maxed)
        if not State.AutoUpgrade then
            return
        end
    end
    setUpgrade(table.concat(lines, "\n") .. ("\nPedidos enviados: %d"):format(upgradeBought))
    task.wait(State.UpgradeInterval)
end

startLoop("AutoUpgrade", upgradeStep)

-- Progression. Every request is validated by the server, so a failed attempt costs nothing; steps only
-- fire when the local data says the purchase can go through, and pause 0.5s between requests (rate_limited otherwise).

local function selectedKeys(set)
    local keys = {}
    for key in pairs(set) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

-- Upgrades2Request:Fire(systemKey, statKey). Levels: Upgrades2Levels[system][stat], unlocked: Upgrades2Unlocked.
startLoop("AutoUpgrade2", function()
    local data = PlayerData.Data
    local keys = selectedKeys(State.Upgrade2Keys)
    if #keys == 0 then
        setProgress("1_u2", "Upgrades 2: escolha um sistema.")
        task.wait(2)
        return
    end
    local sent = 0
    for _, key in ipairs(keys) do
        local system = Upgrades2Config.Systems[key]
        local levels = type(data.Upgrades2Levels) == "table" and data.Upgrades2Levels[key] or {}
        local unlocked = type(data.Upgrades2Unlocked) == "table" and data.Upgrades2Unlocked[key] or {}
        for _, def in pairs(system and system.Upgrades or {}) do
            if State.AutoUpgrade2 and unlocked[def.Key] and (levels[def.Key] or 0) < def.MaximumLevel then
                Upgrades2Bridge:Fire(key, def.Key)
                sent += 1
                task.wait(0.5)
            end
        end
    end
    setProgress("1_u2", ("Upgrades 2: %d pedidos"):format(sent))
    task.wait(State.ProgressInterval)
end)

-- RangeUpgradeRequest:Fire("World0"); RangeLevel and RangeToken in PlayerData.
startLoop("AutoRange", function()
    local data = PlayerData.Data
    local bought = 0
    while State.AutoRange and bought < 10 do
        local nextLevel = RangeUpgradeConfig:GetNextLevelData("World0", data.RangeLevel or 0)
        if not nextLevel then
            setProgress("2_range", "Range: nivel maximo.")
            task.wait(State.ProgressInterval)
            return
        end
        if (tonumber(data.RangeToken) or 0) < nextLevel.Cost then
            break
        end
        RangeUpgradeBridge:Fire("World0")
        bought += 1
        task.wait(0.5)
    end
    setProgress("2_range", ("Range: nivel %d (+%d)"):format(data.RangeLevel or 0, bought))
    task.wait(State.ProgressInterval)
end)

-- ProgressionUpgrade:Fire(worldKey). Level: ActiveProgressions[key]; each try costs ItemCost and may fail.
startLoop("AutoProgression", function()
    local data = PlayerData.Data
    local keys = selectedKeys(State.ProgressionKeys)
    if #keys == 0 then
        setProgress("3_prog", "Progression: escolha ao menos uma.")
        task.wait(2)
        return
    end
    local sent = 0
    for _, key in ipairs(keys) do
        local config = ProgressionConfig.Progressions[key]
        local cost = config and config.ItemCost
        local tries = 0
        while State.AutoProgression and config and tries < 20 do
            local level = type(data.ActiveProgressions) == "table" and data.ActiveProgressions[key] or 0
            if level >= config.MaxLevel or not cost or (tonumber(data[cost.ItemId]) or 0) < cost.Amount then
                break
            end
            ProgressionBridge:Fire(key)
            tries += 1
            sent += 1
            task.wait(0.5)
        end
    end
    setProgress("3_prog", ("Progression: %d tentativas"):format(sent))
    task.wait(State.ProgressInterval)
end)

-- Server flags: the game runs these itself, even with the hub closed, so a toggle only has to set the flag.
-- Each entry reads the current server value (to show it on load) and writes a new one.
local SettingsController = require(RS.SimpleWorld.Library.Client.SettingsController)
local SettingsStateUtil = Library.getUtil("SettingsStateUtil")
local SERVER_FLAGS = {
    AutoRankUp = {
        option = "SrvAutoRankUp",
        read = function()
            return PlayerData.Data.AutoRankUp == true
        end,
        write = function(value)
            RankUpBridge:Fire("SetAutoRankUp", value)
        end,
    },
    AutoPromotion = {
        option = "SrvAutoPromotion",
        read = function()
            return PlayerData.Data.AutoPromote == true
        end,
        write = function(value)
            Library.getBridge("PromotionRankAutoSet"):Fire(value)
        end,
    },
    AutoPotion = {
        option = "SrvAutoPotion",
        read = function()
            return SettingsStateUtil:IsEnabled("AutoUseBoosts") == true
        end,
        write = function(value)
            SettingsController:SetSetting("AutoUseBoosts", value)
        end,
    },
}

-- Show the real server state first (the toggles start off), then forget those writes: they match the server.
for _, flag in pairs(SERVER_FLAGS) do
    local option = MacLib.Options[flag.option]
    local ok, value = pcall(flag.read)
    if option and ok then
        pcall(option.UpdateState, option, value)
    end
end
table.clear(State.FlagDirty)

task.spawn(function()
    while State.Running do
        for name, flag in pairs(SERVER_FLAGS) do
            if State.FlagDirty[name] then
                State.FlagDirty[name] = nil
                local ok, err = pcall(flag.write, State[name] == true)
                if not ok then
                    warn("[AstralX] " .. name .. ":", err)
                end
            end
        end
        task.wait(0.5)
    end
end)

local BattlepassConfig = Library.getConfig("BattlepassConfig")
local BattlepassClaimBridge = Library.getBridge("BattlepassClaimAll")

startLoop("AutoClaim", function()
    ClaimAchievementsBridge:Fire()
    task.wait(0.5)
    ClaimGlobalQuestsBridge:Fire()
    for passKey in pairs(BattlepassConfig.Passes) do
        if not State.AutoClaim then
            return
        end
        task.wait(0.5)
        BattlepassClaimBridge:Fire(passKey)
    end
    task.wait(State.ProgressInterval)
end)

-- EquipBestLoadout:Fire(stat) lets the server pick and equip the best loadout for that stat; it is rate limited.
local EquipBestBridge = Library.getBridge("EquipBestLoadout")
local equipBestReply
connections[#connections + 1] = Library.getBridge("EquipBestLoadoutResult"):Connect(function(success, reason)
    equipBestReply = success and "ok" or tostring(reason)
end)

startLoop("AutoEquipBest", function()
    equipBestReply = nil
    EquipBestBridge:Fire(State.EquipBestStat)
    waitUntil(function()
        return equipBestReply ~= nil
    end, 4)
    setAccessory("3_best", ("Equip Best (%s): %s"):format(State.EquipBestStat, equipBestReply or "sem resposta"))
    task.wait(math.max(State.ProgressInterval, 10))
end)

State.Actions.redeemCodes = function()
    task.spawn(function()
        local reply
        local connection = Library.getBridge("CodeResult"):Connect(function(_, message)
            reply = tostring(message)
        end)
        Library.getBridge("RedeemAllCodes"):Fire()
        waitUntil(function()
            return reply ~= nil
        end, 6)
        connection:Disconnect()
        pcall(function()
            Window:Notify({ Title = "Codigos", Description = reply or "Sem resposta do servidor.", Lifetime = 5 })
        end)
    end)
end

-- RelicMaxUpgradeRequest:Fire(relicId) for every relic the player owns.
startLoop("AutoRelic", function()
    local data = PlayerData.Data
    local owned = type(data.Relics) == "table" and data.Relics or {}
    for id in pairs(owned) do
        if not State.AutoRelic then
            return
        end
        if (tonumber(data.RelicToken) or 0) > 0 then
            RelicMaxBridge:Fire(id)
            task.wait(0.5)
        end
    end
    task.wait(State.ProgressInterval)
end)

-- Accessories --------------------------------------------------------------

local function accessoryScore(item)
    local multiplier = item.Multiplier or {}
    if State.AccScoreMode == "Total" then
        local total = 0
        for _, value in pairs(multiplier) do
            total += tonumber(value) or 0
        end
        return total
    end
    return tonumber(multiplier[State.AccScoreMode]) or 0
end

-- EquipAccessory is a RemoteFunction: InvokeServer(uniqueId) equips into the item's own slot (Type2).
startLoop("AutoAccEquip", function()
    local data = PlayerData.Data
    local equipped = type(data.EquippedAccessories) == "table" and data.EquippedAccessories or {}
    local best = {} -- [slot] = { uid, score }
    for uid, entry in pairs(type(data.Accessories) == "table" and data.Accessories or {}) do
        local item = AccessoryConfig.Items[entry.Id]
        if item and item.Type2 and not AccessoryConfig:IsSkin(entry.Id) then
            local score = accessoryScore(item)
            if not best[item.Type2] or score > best[item.Type2].score then
                best[item.Type2] = { uid = uid, score = score }
            end
        end
    end
    local changed = 0
    for slot, pick in pairs(best) do
        if not State.AutoAccEquip then
            return
        end
        local current = equipped[slot]
        local currentEntry = current and data.Accessories[current]
        local currentItem = currentEntry and AccessoryConfig.Items[currentEntry.Id]
        if current ~= pick.uid and (not currentItem or accessoryScore(currentItem) < pick.score) then
            local ok = pcall(function()
                return EquipAccessoryRemote:InvokeServer(pick.uid)
            end)
            if ok then
                changed += 1
            end
            task.wait(0.5)
        end
    end
    setAccessory("1_equip", ("Equipar: %d trocados (%s)"):format(changed, State.AccScoreMode))
    task.wait(State.ProgressInterval)
end)

-- AccessoryCurseRollRequest:Fire({ AccessoryUniqueId = uid }) costs ItemCost (CursesCoin); the server only
-- replaces a curse with a higher-rarity one, so rolling until the target is reached cannot lower it.
startLoop("AutoCurse", function()
    local data = PlayerData.Data
    local cost = AccessoryCurseConfig.ItemCost
    local target = AccessoryCurseConfig:GetRarityIndex(State.CurseTarget) or 99
    local equipped = type(data.EquippedAccessories) == "table" and data.EquippedAccessories or {}
    local curses = type(data.AccessoryCurses) == "table" and data.AccessoryCurses or {}
    local rolled, done, total = 0, 0, 0
    for _, uid in pairs(equipped) do
        total += 1
        local curse = curses[uid]
        local index = curse and AccessoryCurseConfig:GetRarityIndex(tostring(curse.Rarity)) or 0
        if index >= target then
            done += 1
        elseif (tonumber(data[cost.ItemId]) or 0) >= cost.Amount + State.CurseReserve then
            AccessoryCurseBridge:Fire({ AccessoryUniqueId = uid })
            rolled += 1
            task.wait(0.6)
        end
        if not State.AutoCurse then
            return
        end
    end
    setAccessory("2_curse", ("Curse: %d/%d no alvo (%s), %d rolls, %s: %s"):format(
        done, total, State.CurseTarget, rolled, cost.ItemId, tostring(data[cost.ItemId])))
    if rolled == 0 then
        task.wait(State.ProgressInterval)
    end
end)

end

-- Sell: the game has no sell button, only deleting. Remove unwanted pets up to a rarity,
-- never equipped or locked ones, optionally keeping shinies.

local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythical = 6 }
local SELL_BATCH = 50

local function sellCandidates()
    local data = PlayerData.Data
    local pets = type(data.Pets) == "table" and data.Pets or {}
    local equipped = type(data.EquippedPets) == "table" and data.EquippedPets or {}
    local locked = type(data.LockedPets) == "table" and data.LockedPets or {}
    local maxRank = RARITY_RANK[State.SellMaxRarity] or 1
    local ids = {}
    for uid, pet in pairs(pets) do
        if type(pet) == "table"
            and not pet.IsLocked
            and not equipped[uid]
            and not locked[uid]
            and not (State.SellKeepShiny and pet.Shiny) then
            local info = PetsData[pet.PetId]
            local rank = info and RARITY_RANK[info.Rarity]
            if rank and rank <= maxRank then
                ids[#ids + 1] = uid
            end
        end
    end
    return ids
end

local function sellStep()
    local ids = sellCandidates()
    if #ids == 0 then
        setSell(("Nada para vender (ate %s). Total apagado: %d"):format(State.SellMaxRarity, rollStats.sold))
        task.wait(State.SellInterval)
        return
    end
    for first = 1, #ids, SELL_BATCH do
        if not State.AutoSell then
            return
        end
        local batch = table.move(ids, first, math.min(first + SELL_BATCH - 1, #ids), 1, {})
        DeletePetsBridge:Fire(batch)
        rollStats.sold += #batch
        setSell(("Apagados %d pets (total %d)"):format(#batch, rollStats.sold))
        task.wait(0.6)
    end
    task.wait(State.SellInterval)
end

startLoop("AutoSell", sellStep)

-- Server auto-delete: SetAutoActions:Fire(eggKey, {[rarity] = action}) is the Delete/Lock menu of each Star.
-- The server applies it at hatch time. The game's AutoActionController holds the current rules (the
-- PlayerData copy is only loaded at join), so read from it, change only the rarities in SELL_RARITIES, and
-- write the result back to both the server and the controller so the game's own menu stays in sync.
do
local AutoActionController = require(RS.SimpleWorld.Library.Client.AutoActionController)
local EggsData = require(RS.SimpleWorld.Library.Config.EggsData)
local SetAutoActionsBridge = Library.getBridge("SetAutoActions")
local HttpService = game:GetService("HttpService")
local DELETE_ACTIONS = { delete = true, deleteShiny = true }

local function eggKeys()
    local keys = {}
    for key in pairs(EggsData) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

-- edit(rules, rarity, rank) changes rules in place; returns how many Stars were written.
local function rewriteAutoActions(edit)
    local written, saved = 0, {}
    for _, key in ipairs(eggKeys()) do
        local rules = AutoActionController:GetActionsForEgg(key)
        local before = HttpService:JSONEncode(rules)
        for rank, rarity in ipairs(SELL_RARITIES) do
            edit(rules, rarity, rank)
        end
        if HttpService:JSONEncode(rules) ~= before then
            SetAutoActionsBridge:Fire(key, rules)
            saved[key] = rules
            written += 1
            task.wait(0.2)
        end
    end
    AutoActionController:ApplySavedActions(saved)
    return written
end

State.Actions.applyAutoDelete = function()
    task.spawn(function()
        local maxRank = RARITY_RANK[State.SellMaxRarity] or 1
        local action = State.SellKeepShiny and "delete" or "deleteShiny"
        local written = rewriteAutoActions(function(rules, rarity, rank)
            if rank <= maxRank and rules[rarity] ~= "lock" and rules[rarity] ~= "lockShiny" then
                rules[rarity] = action
            end
        end)
        setSell(("Auto-delete do servidor: ate %s (%s) em %d Stars."):format(State.SellMaxRarity, action, written))
    end)
end

State.Actions.clearAutoDelete = function()
    task.spawn(function()
        local written = rewriteAutoActions(function(rules, rarity)
            if DELETE_ACTIONS[rules[rarity]] then
                rules[rarity] = nil
            end
        end)
        setSell(("Auto-delete do servidor removido de %d Stars."):format(written))
    end)
end
end

-- Rare drop alerts ------------------------------------------------------------
-- Every drop in the game goes through DropNotifyController:NotifyDrops(payload), whatever the source
-- (gacha, star, raid, shop...). Wrap it, look for entries at or above the chosen rarity, then call the original.

local NotificationUtil = Library.getUtil("NotificationUtil")
local ResourcesConfig = Library.getConfig("ResourcesConfig")
local DropNotifyController = require(Library.Client.DropNotifyController)

-- Same order the game uses to sort drops.
local RARITY_ORDER = {
    Resource = 1, Key = 2, Common = 3, Uncommon = 4, Rare = 5, Epic = 6, Legendary = 7, Mythical = 8,
    Crafted = 9, Secret = 10, Divine = 11, Astral = 12, Exclusive = 13, Limited = 14,
}
local ALERT_LOG_SIZE = 8
local recentAlerts = {} -- [dedupe key] = time

-- The same drop can reach both NotifyDrops and the OpenEgg listener. Returns true for a repeat within 2s;
-- old keys are dropped as it goes so long AFK sessions do not grow the table forever.
local function isRepeat(map, key)
    local now = os.clock()
    if map[key] and now - map[key] < 2 then
        return true
    end
    map[key] = now
    map.__count = (map.__count or 0) + 1
    if map.__count > 200 then
        for k, t in pairs(map) do
            if k ~= "__count" and now - t >= 2 then
                map[k] = nil
            end
        end
        map.__count = 0
    end
    return false
end

-- Discord webhook: one queue, one sender. Discord allows about 30 posts a minute per webhook, so the
-- sender waits between posts and honours 429 retry_after instead of dropping messages.
do
    local HttpService = game:GetService("HttpService")
    local httpRequest = request or http_request or (syn and syn.request) or (http and http.request)
    local queue, seen = {}, {}
    local startedAt = os.clock()
    local EMBED_COLORS = {
        Epic = 0xA335EE, Legendary = 0xFF8000, Mythical = 0xFF2D55, Crafted = 0x2ECC71,
        Secret = 0x00E5FF, Divine = 0xFFD700, Astral = 0x7C4DFF, Exclusive = 0xE91E63, Limited = 0xE91E63,
    }

    local function currentUrl()
        local url = State.WebhookUrl
        if (not url or url == "") and MacLib.Options.WebhookUrl then
            url = MacLib.Options.WebhookUrl.Text -- config loads set the box text
        end
        url = tostring(url or ""):gsub("%s", "")
        if url:match("^https://[%w%.]*discord%.com/api/webhooks/") or url:match("^https://[%w%.]*discordapp%.com/api/webhooks/") then
            return url
        end
    end

    local function enqueue(body)
        if #queue >= 50 then
            table.remove(queue, 1)
        end
        queue[#queue + 1] = body
    end

    local function embed(title, description, color, fields)
        local player = game:GetService("Players").LocalPlayer
        return {
            title = title,
            description = description,
            color = color,
            fields = fields,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            footer = { text = "AstralX | " .. player.Name },
        }
    end

    local FormatUtilHook = Library.getUtil("FormatUtil")
    local DefenseConfigHook = Library.getConfig("DefenseConfig")
    local raresThisSession = 0

    local function num(value)
        local ok, text = pcall(FormatUtilHook.Number, value, 2)
        return ok and tostring(text) or tostring(value)
    end

    -- Discord limits: 1024 chars per field value, 25 fields and 6000 chars per message.
    local function field(name, value, inline)
        value = tostring(value == nil and "-" or value)
        if value == "" then
            value = "-"
        end
        if #value > 1000 then
            value = value:sub(1, 997) .. "..."
        end
        return { name = name, value = value, inline = inline == true }
    end

    local function uptimeText()
        local uptime = math.floor(os.clock() - startedAt)
        return ("%dh %02dm"):format(uptime // 3600, uptime % 3600 // 60)
    end

    -- What the character is doing right now, as one short line.
    local function activityText()
        local parts = { "Dono: " .. tostring(State.Owner or "nenhum") }
        if raid.active then
            parts[#parts + 1] = ("%s wave %s/%s"):format(raid.label, tostring(raid.wave), tostring(raid.total))
        end
        local st = defense.state and defense.state()
        if st and st.InDefense then
            parts[#parts + 1] = ("Defense %s wave %s/%s"):format(tostring(st.ActiveKey), tostring(defense.wave), tostring(defense.total))
        end
        local full = defense.full
        if State.FullAuto and full then
            if full.choice then
                parts[#parts + 1] = ("Full Auto: %s %s"):format(full.choice.kind, full.choice.key)
            elseif full.farm then
                parts[#parts + 1] = "Full Auto: farmando " .. tostring(full.farm.item)
            end
        end
        return table.concat(parts, " | ")
    end

    local function activeFeatures()
        local list = {}
        for key, value in pairs(State) do
            if value == true and key:sub(1, 4) == "Auto" then
                list[#list + 1] = key:sub(5)
            end
        end
        if State.FullAuto then
            list[#list + 1] = "FullAuto"
        end
        table.sort(list)
        return #list > 0 and table.concat(list, ", ") or "nenhuma"
    end

    -- Every raid/defense key the player owns: "Nome: n".
    local function keyLines()
        local lines = {}
        for key in pairs(RaidConfig:GetAllRaids()) do
            local info = RaidConfig:GetRaid(key)
            local cost = info and info.Cost
            local have = cost and tonumber(PlayerData.Data[cost.ItemId]) or 0
            if have > 0 then
                lines[#lines + 1] = ("%s: %d"):format(info.Name or key, have)
            end
        end
        for key in pairs(DefenseConfigHook:GetAllDefenses()) do
            local info = DefenseConfigHook:GetDefense(type(key) == "string" and key or tostring(key))
            local cost = info and info.Cost
            local have = cost and tonumber(PlayerData.Data[cost.ItemId]) or 0
            if have > 0 then
                lines[#lines + 1] = ("%s: %d"):format(info.Name or tostring(key), have)
            end
        end
        table.sort(lines)
        return #lines > 0 and table.concat(lines, "\n") or "nenhuma"
    end

    -- Totals at hub start, so the summary can show what this session gained.
    local baseline = {}
    local TRACKED = {
        { "TotalGachaRolls", "Gacha rolls" }, { "TotalGrimoireRolls", "Grimoire rolls" },
        { "TotalEggsOpened", "Stars abertas" }, { "TotalPetPassiveRolls", "Passivas de pet" },
        { "TotalSwordPassiveRolls", "Passivas de espada" }, { "TotalPlayerPassiveRolls", "Passivas do jogador" },
        { "TotalShadowPassiveRolls", "Passivas de shadow" }, { "TotalTitanPassiveRolls", "Passivas de titan" },
        { "TotalGamemodeWaves", "Waves de gamemode" }, { "GlobalDefenseWaves", "Waves de defense" },
        { "Level", "Niveis" }, { "Rank", "Ranks" },
    }
    for _, entry in ipairs(TRACKED) do
        baseline[entry[1]] = tonumber(PlayerData.Data[entry[1]]) or 0
    end
    baseline.Power = PlayerData.Data.Power
    baseline.Yen = PlayerData.Data.Yen

    local function sessionLines()
        local lines = {}
        for _, entry in ipairs(TRACKED) do
            local gained = (tonumber(PlayerData.Data[entry[1]]) or 0) - (baseline[entry[1]] or 0)
            if gained ~= 0 then
                lines[#lines + 1] = ("%s: +%s"):format(entry[2], num(gained))
            end
        end
        lines[#lines + 1] = ("Pets apagados: %d | Itens coletados: %d"):format(rollStats.sold, rollStats.collected or 0)
        lines[#lines + 1] = ("Stars (hub): %d aberturas, %d pets"):format(rollStats.starOpens, rollStats.starPets)
        lines[#lines + 1] = ("Drops raros: %d"):format(raresThisSession)
        return table.concat(lines, "\n")
    end

    -- Best gacha rarity counts ("Divine x3, Secret x5 ...") plus the grimoire, player and sword passives.
    local function bestLines()
        local data = PlayerData.Data
        local counts = {}
        for _, rarity in pairs(type(data.EquippedGachas) == "table" and data.EquippedGachas or {}) do
            counts[rarity] = (counts[rarity] or 0) + 1
        end
        local order = { "Astral", "Divine", "Secret", "Mythical", "Legendary", "Epic", "Rare", "Uncommon", "Common" }
        local parts = {}
        for _, rarity in ipairs(order) do
            if counts[rarity] then
                parts[#parts + 1] = ("%s x%d"):format(rarity, counts[rarity])
            end
        end
        local lines = { "Gachas: " .. (#parts > 0 and table.concat(parts, ", ") or "-") }
        for key, slots in pairs(type(data.ActiveGrimoires) == "table" and data.ActiveGrimoires or {}) do
            if type(slots) == "table" then
                lines[#lines + 1] = ("Grimoire %s: %s / %s"):format(key, tostring(slots.Slot1 or "-"), tostring(slots.Slot2 or "-"))
            end
        end
        local active = data.ActivePassive
        lines[#lines + 1] = "Passiva do jogador: " .. (type(active) == "table" and ("%s (%s)"):format(tostring(active.Name), tostring(active.Rarity)) or "-")
        local sword = data.EquippedSword
        if type(sword) == "table" and type(data.SwordPassives) == "table" then
            local key = ("%s_%s_%d_%d"):format(tostring(sword.SwordKey), tostring(sword.Rarity), sword.Level or 0, sword.Index or 1)
            local passive = data.SwordPassives[key]
            lines[#lines + 1] = "Passiva da espada: " .. (type(passive) == "table" and ("%s (%s)"):format(tostring(passive.Name), tostring(passive.Rarity)) or "-")
        end
        return table.concat(lines, "\n")
    end

    local function tokenLines()
        local data = PlayerData.Data
        local lines = {}
        for _, entry in ipairs({
            { "PetPassiveToken", "Pet passive" }, { "BreathToken", "Breath (espada)" }, { "PassiveToken", "Passive (jogador)" },
            { "ShadowPassiveToken", "Shadow passive" }, { "TitanPassiveToken", "Titan passive" }, { "GrimoireToken", "Grimoire" },
            { "GrimoirePassiveToken", "Grimoire passive" }, { "WorldToken", "World" }, { "CursesCoin", "CursesCoin" },
            { "DefenseCoin", "DefenseCoin" },
        }) do
            local have = tonumber(data[entry[1]])
            if have and have > 0 then
                lines[#lines + 1] = ("%s: %s"):format(entry[2], num(have))
            end
        end
        return #lines > 0 and table.concat(lines, "\n") or "-"
    end

    function Webhook.drop(category, name, rarity, extra)
        local rank = RARITY_ORDER[rarity]
        if not rank or rank < (RARITY_ORDER[State.WebhookMinRarity] or RARITY_ORDER.Mythical) then
            return
        end
        raresThisSession += 1 -- counted even with drop posts off, for the summary
        if not State.WebhookDrops or not currentUrl() then
            return
        end
        if isRepeat(seen, category .. "|" .. tostring(name) .. "|" .. rarity) then
            return
        end
        local ping = tostring(State.WebhookPing or ""):gsub("%D", "")
        local data = PlayerData.Data
        enqueue({
            content = ping ~= "" and ("<@" .. ping .. ">") or nil,
            embeds = { embed("Drop raro: " .. tostring(name), ("**%s** (%s)%s"):format(category, rarity, extra or ""), EMBED_COLORS[rarity] or 0x95A5A6, {
                field("Item", name, true),
                field("Raridade", rarity, true),
                field("Origem", category, true),
                field("Mundo", data.CurrentWorld, true),
                field("Nivel / Rank", ("%s / %s"):format(tostring(data.Level), tostring(data.Rank)), true),
                field("Drops raros na sessao", raresThisSession, true),
                field("Atividade", activityText()),
            }) },
        })
    end

    -- Several embeds: account, session gains, activity, resources and best rolls.
    local function summary(title)
        local data = PlayerData.Data
        local player = game:GetService("Players").LocalPlayer
        local dpsNow, dpsPeak = "-", "-"
        if defense.dpsText then
            dpsNow, dpsPeak = defense.dpsText()
        end
        return {
            embed(title, ("**%s** (@%s) | ativo ha %s"):format(player.DisplayName, player.Name, uptimeText()), 0x3498DB, {
                field("Nivel", data.Level, true),
                field("Rank", data.Rank, true),
                field("Promotion", data.PromotionRank, true),
                field("Power", num(data.Power), true),
                field("Yen", num(data.Yen), true),
                field("DPS agora / pico", ("%s / %s"):format(dpsNow, dpsPeak), true),
                field("Mundo atual", data.CurrentWorld, true),
                field("Quest", data.QuestIndex, true),
                field("Servidor", game.JobId:sub(1, 8), true),
            }),
            embed("Sessao", nil, 0x2ECC71, {
                field("Ganhos desde o inicio", sessionLines()),
                field("Power ganho", ("%s -> %s"):format(num(baseline.Power), num(data.Power)), true),
                field("Yen ganho", ("%s -> %s"):format(num(baseline.Yen), num(data.Yen)), true),
            }),
            embed("Atividade", nil, 0xF1C40F, {
                field("Agora", activityText()),
                field("Ultimo status", State.LastStatus),
                field("Funcoes ligadas", activeFeatures()),
            }),
            embed("Recursos", nil, 0x9B59B6, {
                field("Chaves de raid/defense", keyLines(), true),
                field("Tokens", tokenLines(), true),
            }),
            embed("Melhores", nil, 0xE67E22, {
                field("Raridades", bestLines()),
            }),
        }
    end

    -- Events: raid/defense finished (with the last wave), key obtained, world unlocked.
    local function event(title, description, color, fields)
        if State.WebhookEvents and currentUrl() then
            enqueue({ embeds = { embed(title, description, color, fields) } })
        end
    end
    local lastDefense = { key = nil, wave = 0, total = 0 }
    connections[#connections + 1] = Library.getBridge("DefenseState"):Connect(function(payload)
        if type(payload) == "table" then
            lastDefense.key = payload.DefenseKey or lastDefense.key
            lastDefense.wave = tonumber(payload.Wave) or lastDefense.wave
            lastDefense.total = tonumber(payload.TotalWaves) or lastDefense.total
        end
    end)
    connections[#connections + 1] = Library.getBridge("DefenseEnded"):Connect(function()
        event("Defense terminada", ("%s: wave %d/%d"):format(tostring(lastDefense.key), lastDefense.wave, lastDefense.total), 0x1ABC9C, {
            field("Chaves restantes", keyLines()),
        })
        lastDefense.wave = 0
    end)
    connections[#connections + 1] = Library.getBridge("RaidEnded"):Connect(function()
        event("Raid terminada", ("%s: wave %s/%s"):format(tostring(raid.label), tostring(raid.wave), tostring(raid.total)), 0x1ABC9C, {
            field("Chaves restantes", keyLines()),
        })
    end)
    task.spawn(function()
        local keysBefore, worldsBefore = keyLines(), {}
        for id = 1, 30 do
            worldsBefore[id] = TeleportController:IsWorldUnlocked(id)
        end
        while State.Running do
            task.wait(10)
            local keysNow = keyLines()
            if keysNow ~= keysBefore then
                event("Chaves mudaram", nil, 0x3498DB, { field("Antes", keysBefore, true), field("Agora", keysNow, true) })
                keysBefore = keysNow
            end
            for id = 1, 30 do
                local unlocked = TeleportController:IsWorldUnlocked(id)
                if unlocked and not worldsBefore[id] then
                    event("Mundo liberado", ("Mundo %d"):format(id), 0x2ECC71)
                end
                worldsBefore[id] = unlocked
            end
        end
    end)

    function Webhook.test()
        if not httpRequest then
            Window:Notify({ Title = "Webhook", Description = "Este executor nao tem request.", Lifetime = 5 })
            return
        end
        if not currentUrl() then
            Window:Notify({ Title = "Webhook", Description = "URL invalida. Use https://discord.com/api/webhooks/...", Lifetime = 5 })
            return
        end
        enqueue({ embeds = summary("Teste do AstralX") })
        Window:Notify({ Title = "Webhook", Description = "Teste enviado para a fila.", Lifetime = 4 })
    end

    task.spawn(function()
        while State.Running do
            local body = queue[1]
            local url = body and currentUrl()
            if body and url and httpRequest then
                local ok, response = pcall(httpRequest, {
                    Url = url,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(body),
                })
                local status = ok and type(response) == "table" and response.StatusCode or 0
                if status == 429 then
                    local retry = 2
                    pcall(function()
                        retry = tonumber(HttpService:JSONDecode(response.Body).retry_after) or retry
                    end)
                    task.wait(retry + 0.2)
                else
                    table.remove(queue, 1)
                    if status < 200 or status >= 300 then
                        warn("[AstralX] webhook:", ok and status or response)
                    end
                    task.wait(1.2)
                end
            else
                if body and not url then
                    table.remove(queue, 1) -- no usable URL: do not let messages pile up
                end
                task.wait(0.5)
            end
        end
    end)

    task.spawn(function()
        local last = os.clock()
        while State.Running do
            task.wait(1)
            if State.WebhookSummary and currentUrl() then
                if os.clock() - last >= State.WebhookInterval * 60 then
                    last = os.clock()
                    enqueue({ embeds = summary("Resumo AstralX") })
                end
            else
                last = os.clock()
            end
        end
    end)
end

local function alertHit(category, name, rarity, extra)
    pcall(Webhook.drop, category, name, rarity, extra) -- has its own rarity floor, independent of the on-screen alerts
    if not State.AlertsEnabled then
        return
    end
    local rank = RARITY_ORDER[rarity]
    local minRank = RARITY_ORDER[State.AlertMinRarity] or RARITY_ORDER.Mythical
    if not rank or rank < minRank then
        return
    end

    if isRepeat(recentAlerts, category .. "|" .. tostring(name) .. "|" .. rarity) then
        return
    end

    local text = ("%s: %s (%s)%s"):format(category, tostring(name), rarity, extra or "")
    pcall(function()
        NotificationUtil.Notify("RARO! " .. text, 8)
    end)
    pcall(function()
        Window:Notify({ Title = "Drop raro", Description = text, Lifetime = 8 })
    end)
    table.insert(alertLines, 1, os.date("%H:%M:%S") .. "  " .. text)
    while #alertLines > ALERT_LOG_SIZE do
        table.remove(alertLines)
    end
    updateBody(alertLog, table.concat(alertLines, "\n"))
end

local function inspectDrops(payload)
    if type(payload) ~= "table" then
        return
    end
    for category, entries in pairs(payload) do
        if type(entries) == "table" then
            if category == "Items" then
                for itemId, amount in pairs(entries) do
                    local item = ResourcesConfig:GetItem(itemId)
                    if item and item.Rarity then
                        alertHit("Item", item.Name or itemId, item.Rarity, " x" .. tostring(amount))
                    end
                end
            else
                for key, entry in pairs(entries) do
                    if type(entry) == "table" then
                        local pet = type(entry.PetId) == "string" and PetsData[entry.PetId]
                        local rarity = entry.Rarity or entry.RolledRarity or (pet and pet.Rarity)
                        local itemData = entry.ItemData or entry.RolledItem
                        local name = entry.Name
                            or (type(itemData) == "table" and itemData.Name)
                            or (pet and pet.Name)
                            or entry.PetId
                            or entry.MountId
                            or (type(key) == "string" and key)
                            or entry.GachaKey
                            or category
                        if rarity then
                            local extra = (entry.Shiny and " [SHINY]" or "")
                                .. (type(entry.Action) == "string" and entry.Action:lower() == "delete" and " (auto-apagado)" or "")
                            alertHit(category, name, rarity, extra)
                        end
                    end
                end
            end
        end
    end
end

local originalNotifyDrops = DropNotifyController.NotifyDrops
DropNotifyController.NotifyDrops = function(self, payload)
    pcall(inspectDrops, payload)
    return originalNotifyDrops(self, payload)
end
unloadHooks[#unloadHooks + 1] = function()
    DropNotifyController.NotifyDrops = originalNotifyDrops
end

-- Star opens reply on OpenEgg and never reach NotifyDrops, so watch that bridge too.
connections[#connections + 1] = OpenEggBridge:Connect(function(_, pets)
    if type(pets) == "table" and not pets.Error then
        pcall(inspectDrops, { Pets = pets })
    end
end)

getgenv().AstralX.Webhook = Webhook -- .test() sends the full summary, for checking the embeds
getgenv().AstralX.TestAlert = function(payload)
    inspectDrops(payload)
end
getgenv().AstralX.AlertLines = alertLines

-- Auto collect: world pickups (crows, balls, commandments...) live in workspace folders named World<N><Kind>.
-- Their claim prompt only exists while we are in that world, so switch world, stand next to the item and hold it.

local COLLECT_SKIP_SECONDS = 60
local collectSkip = setmetatable({}, { __mode = "k" }) -- [item instance] = time until which it is ignored
local claimedAttribute = "Claimed_" .. game:GetService("Players").LocalPlayer.UserId
local collectOrigin -- world we left to collect something
local collectedCount = 0
local pickupCache, pickupCacheAt = {}, 0

-- The scheduler asks for this every tick, so the workspace scan is cached for a second.
local function pendingPickups()
    if os.clock() - pickupCacheAt < 1 then
        return pickupCache
    end
    local list = {}
    local now = os.clock()
    for _, folder in ipairs(workspace:GetChildren()) do
        if folder:IsA("Folder") then
            local worldId = folder.Name:match("^World(%d+)%a+$")
            if worldId then
                for _, item in ipairs(folder:GetChildren()) do
                    -- a claimed pickup stays in the folder (only hidden for us) with its prompt disabled
                    if (collectSkip[item] or 0) <= now and item:GetAttribute(claimedAttribute) ~= true then
                        list[#list + 1] = { item = item, world = tonumber(worldId), kind = folder.Name }
                    end
                end
            end
        end
    end
    pickupCache, pickupCacheAt = list, now
    return list
end

local function skipPickup(item)
    collectSkip[item] = os.clock() + COLLECT_SKIP_SECONDS
    pickupCacheAt = 0
end

local function reportCollect(text)
    setStatus("Coleta: " .. text)
end

local function claimPickup(entry)
    local item = entry.item
    local prompt
    waitUntil(function()
        prompt = item.Parent and item:FindFirstChildWhichIsA("ProximityPrompt", true)
        return prompt ~= nil or item.Parent == nil
    end, 10, "Collect")
    if not prompt then
        return item.Parent == nil -- gone already counts as done
    end
    for _ = 1, 3 do
        local root = getRoot()
        if not (root and item.Parent) then
            break
        end
        -- stand next to the prompt's own part (the item's pivot can sit away from it), inside MaxActivationDistance
        local parent = prompt.Parent
        local anchor = parent and parent:IsA("BasePart") and parent.Position or item:GetPivot().Position
        root.CFrame = CFrame.new(anchor + Vector3.new(0, 2, 2))
        task.wait(0.8)
        -- InputHoldBegin only runs the local prompt UI and the server never sees it; fireproximityprompt does trigger it
        if fireproximityprompt then
            pcall(fireproximityprompt, prompt)
        else
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration + 0.3)
            prompt:InputHoldEnd()
        end
        if waitUntil(function()
            return item.Parent == nil or item:GetAttribute(claimedAttribute) == true
        end, 3, "Collect") then
            return true
        end
    end
    return item.Parent == nil or item:GetAttribute(claimedAttribute) == true
end

local function collectStep()
    if not getRoot() or TeleportController:IsLoading() then
        task.wait(1)
        return
    end
    local pending = pendingPickups()
    if #pending == 0 then
        if State.CollectReturn and collectOrigin and WorldController:GetCurrentWorld() ~= collectOrigin then
            travelToWorld(collectOrigin, "Collect", reportCollect, false)
        end
        collectOrigin = nil
        setStatus(("Coleta: aguardando itens... (%d coletados)"):format(collectedCount))
        task.wait(2)
        return
    end

    -- Prefer what is in the world we already stand in; otherwise the first one.
    local current = WorldController:GetCurrentWorld()
    local pick = pending[1]
    for _, entry in ipairs(pending) do
        if entry.world == current then
            pick = entry
            break
        end
    end

    if pick.world ~= current then
        collectOrigin = collectOrigin or current
        local arrived, reason = travelToWorld(pick.world, "Collect", reportCollect, false)
        if not arrived then
            if reason ~= "loading" and State.Owner == "Collect" then -- a handover is not the item's fault
                skipPickup(pick.item)
            end
            return
        end
    end
    setStatus(("Coletando %s (mundo %d)"):format(pick.kind, pick.world))
    if claimPickup(pick) then
        collectedCount += 1
        rollStats.collected = collectedCount
        pickupCacheAt = 0
    elseif State.Owner == "Collect" then -- lost control mid-claim is not a failure
        skipPickup(pick.item)
    end
end

startOwnedLoop(collectStep, "Collect")

-- Scheduler ---------------------------------------------------------------------
-- Gate, Time Trial, Raid, Collect, Star and Quest all drive the character, so only one may act at a time.
-- Every tick the highest-priority enabled feature that has work right now gets control. A feature inside an
-- instance (raid, gate, time trial) keeps control until it leaves, and control is never taken mid-step.
-- Gacha, potions, sell and alerts never touch the character and run independently.

local function raidAffordable()
    local info = RaidConfig:GetRaid(State.RaidKey)
    if not info then
        return false
    end
    local cost = info.Cost
    return type(cost) ~= "table" or (tonumber(PlayerData.Data[cost.ItemId]) or 0) >= (cost.Amount or 1)
end

local FEATURES = {
    Gate = {
        flag = "AutoGate",
        wants = function()
            if raid.active then
                return raid.kind == "Gate"
            end
            return raid.gate ~= nil and os.clock() - raid.gate.at < GATE_ANNOUNCE_TTL
        end,
        locked = function()
            return raid.active and raid.kind == "Gate"
        end,
    },
    TimeTrial = {
        flag = "AutoTimeTrial",
        wants = function()
            local st = getTrialState()
            if not st then
                return false
            end
            return (st.InTrial or st.IsJoining or (st.OpenTrialKeys and pickTrialKey(st.OpenTrialKeys) ~= nil)) and true or false
        end,
        locked = function()
            local st = trialState
            return st ~= nil and (st.InTrial or st.IsJoining) and true or false
        end,
    },
    Raid = {
        flag = "AutoRaid",
        wants = function()
            if raid.active then
                return raid.kind == "Raid"
            end
            return raidAffordable()
        end,
        locked = function()
            return raid.active and raid.kind == "Raid"
        end,
    },
    Defense = {
        flag = "AutoDefense",
        wants = function()
            local st = defense.state()
            if st and (st.InDefense or st.IsJoining) then
                return true
            end
            return os.clock() >= defense.idleUntil and defense.pickKey() ~= nil
        end,
        locked = function()
            local st = defense.state()
            return st ~= nil and (st.InDefense or st.IsJoining) and true or false
        end,
    },
    KeyFarm = {
        flag = "FullAuto",
        wants = function()
            -- never farm world enemies from inside a raid/defense/trial arena
            return defense.full.farm ~= nil and not TeleportController:IsInGamemode()
        end,
        locked = function()
            return false
        end,
    },
    Collect = {
        flag = "AutoCollect",
        wants = function()
            return #pendingPickups() > 0
        end,
        locked = function()
            return false
        end,
    },
    Star = {
        flag = "AutoStar",
        wants = function()
            return os.clock() >= starBlockedUntil -- broke, inventory full or world locked: back off
        end,
        locked = function()
            return false
        end,
    },
    Quest = {
        flag = "AutoQuest",
        wants = function()
            return os.clock() >= questIdleUntil -- chain finished or stuck on a locked world: back off
        end,
        locked = function()
            return false
        end,
    },
}

local function priorityOrder()
    local order = {}
    for index, name in ipairs(FEATURE_ORDER) do
        order[#order + 1] = { name = name, rank = State.Priority[name] or 99, index = index }
    end
    table.sort(order, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.index < b.index
    end)
    return order
end

local lastPriorityText

local function describeScheduler(order)
    local queue = {}
    for _, entry in ipairs(order) do
        if defense.featureOn(entry.name, FEATURES[entry.name]) then
            queue[#queue + 1] = ("%d. %s%s"):format(entry.rank, FEATURE_LABELS[entry.name], entry.name == State.Owner and "  <-- ativo" or "")
        end
    end
    if #queue == 0 then
        return "Nenhuma funcao de personagem ligada."
    end
    return table.concat(queue, "\n")
end

local function scheduleTick()
    if (State.AutoGate or State.AutoRaid or State.FullAuto) and not raid.active then
        adoptCurrentRaid() -- already inside a raid/gate: take it over
    end

    local owner = State.Owner
    local order = priorityOrder()
    local current = owner and FEATURES[owner]
    if current and defense.featureOn(owner, current) and current.locked() then
        -- stay put
    else
        local pick
        for _, entry in ipairs(order) do
            local feature = FEATURES[entry.name]
            if defense.featureOn(entry.name, feature) and feature.wants() then
                pick = entry.name
                break
            end
        end
        State.Owner = pick
    end

    local text = describeScheduler(order)
    if text ~= lastPriorityText then
        lastPriorityText = text
        updateBody(priorityStatus, text)
    end
end

getgenv().AstralX.Features = FEATURES
getgenv().AstralX.RaidState = raid

task.spawn(function()
    while State.Running do
        local ok, err = pcall(scheduleTick)
        if not ok then
            warn("[AstralX] scheduler:", err)
        end
        task.wait(0.3)
    end
end)

-- Best panel refresh: the best rarity the game keeps equipped per gacha, shown with that item's icon.
local function refreshBestPanel()
    bestFrame.Visible = State.BestPanel
    if not State.BestPanel then
        return
    end
    local keys = {}
    for key in pairs(State.GachaKeys) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local wa, wb = tonumber(a:match("%d+")) or 99, tonumber(b:match("%d+")) or 99
        if wa ~= wb then
            return wa < wb
        end
        return a < b
    end)

    local data = PlayerData.Data
    local equipped = type(data.EquippedGachas) == "table" and data.EquippedGachas or {}
    local active = type(data.ActiveGachas) == "table" and data.ActiveGachas or {}
    for index, slot in ipairs(bestSlots) do
        local key = keys[index]
        slot.cell.Visible = key ~= nil
        if key then
            local gacha = GachaConfig.Gachas[key]
            local rarity = equipped[key] or active[key]
            local item = rarity and gacha and gacha.Items and gacha.Items[rarity]
            slot.icon.Image = item and item.Icon or ""
            slot.item.Text = item and item.Name or "Nenhum"
            slot.rarity.Text = rarity or "-"
            slot.gacha.Text = gachaNameByKey[key] or key
            local color = RARITY_COLORS[rarity or "Common"] or RARITY_COLORS.Common
            slot.rarity.TextColor3 = color
            slot.stroke.Color = color
        end
    end
    bestTitle.Text = #keys == 0 and "Selecione gachas na aba Gacha" or ("Melhor de cada Gacha (%d)"):format(#keys)
end

task.spawn(function()
    while State.Running do
        local ok, err = pcall(refreshBestPanel)
        if not ok then
            warn("[AstralX] bestPanel:", err)
        end
        task.wait(1)
    end
end)

-- Info panel refresh. Each builder returns the entries (and optionally a title) for one panel.
do
    local GRAY, BLUE, GOLD, GREEN = RARITY_COLORS.Common, RARITY_COLORS.Rare, RARITY_COLORS.Divine, RARITY_COLORS.Uncommon
    local UpgradesCfg = Library.getConfig("UpgradesConfig")
    local Upgrades2Cfg = Library.getConfig("Upgrades2Config")
    local RangeCfg = Library.getConfig("RangeUpgradeConfig")
    local ProgressionCfg = Library.getConfig("ProgressionConfig")
    local AccessoryCfg = Library.getConfig("AccessoryConfig")

    local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local function fmt(value)
        value = tonumber(value) or 0
        local index = 1
        while math.abs(value) >= 1000 and index < #SUFFIXES do
            value /= 1000
            index += 1
        end
        return (index == 1 and "%d%s" or "%.1f%s"):format(value, SUFFIXES[index])
    end

    local function itemIcon(itemId)
        local ok, item = pcall(ResourcesConfig.GetItem, ResourcesConfig, itemId)
        return ok and item and item.Icon or ""
    end

    local function levelColor(level, max)
        if level >= max then
            return GOLD
        end
        return level > 0 and BLUE or GRAY
    end

    local function sortedKeys(set)
        local keys = {}
        for key in pairs(set) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local na, nb = tonumber(tostring(a):match("%d+")) or 0, tonumber(tostring(b):match("%d+")) or 0
            return na == nb and tostring(a) < tostring(b) or na < nb
        end)
        return keys
    end

    local builders = {}

    function builders.Accessories()
        local data = PlayerData.Data
        local entries = {}
        local equipped = type(data.EquippedAccessories) == "table" and data.EquippedAccessories or {}
        local curses = type(data.AccessoryCurses) == "table" and data.AccessoryCurses or {}
        for _, slot in ipairs(sortedKeys(equipped)) do
            local uid = equipped[slot]
            local entry = data.Accessories and data.Accessories[uid]
            local item = entry and AccessoryCfg.Items[entry.Id]
            local curse = curses[uid]
            entries[#entries + 1] = {
                icon = item and item.Icon,
                line1 = item and item.Name or "?",
                line2 = curse and ("%s (%s)"):format(curse.Name or curse.Id, curse.Rarity) or "Sem curse",
                line3 = tostring(slot) .. (curse and curse.Percent and (" +%d%%"):format(curse.Percent * 100) or ""),
                color = curse and RARITY_COLORS[curse.Rarity] or GRAY,
            }
        end
        return entries, ("Acessorios equipados (%d)"):format(#entries)
    end

    function builders.Upgrades()
        local data = PlayerData.Data
        local entries = {}
        for _, key in ipairs(sortedKeys(State.UpgradeKeys)) do
            local system = UpgradesCfg.Systems[key]
            local levels = type(data.MultiplierUpgrades) == "table" and data.MultiplierUpgrades[key] or {}
            for _, stat in ipairs(sortedKeys(system and system.Upgrades or {})) do
                local level = UpgradesCfg:NormalizeLevel(key, stat, levels[stat] or 0)
                local max = UpgradesCfg:GetMaxLevel(key, stat) or level
                entries[#entries + 1] = {
                    icon = itemIcon(system.CostItemId),
                    line1 = stat,
                    line2 = ("Lv %d/%d"):format(level, max),
                    line3 = key .. " | " .. fmt(data[system.CostItemId]),
                    color = levelColor(level, max),
                }
            end
        end
        return entries, #entries == 0 and "Escolha sistemas na aba Upgrade" or ("Upgrades (%d)"):format(#entries)
    end

    function builders.Progress()
        local data = PlayerData.Data
        local entries = {}
        local rangeLevel = data.RangeLevel or 0
        local nextRange = RangeCfg:GetNextLevelData("World0", rangeLevel)
        local rangeMax = RangeCfg:GetMaxLevel("World0") or rangeLevel
        entries[#entries + 1] = {
            icon = itemIcon("RangeToken"),
            line1 = "Range",
            line2 = ("Lv %d/%d"):format(rangeLevel, rangeMax),
            line3 = nextRange and ("%s / %s"):format(fmt(data.RangeToken), fmt(nextRange.Cost)) or "maximo",
            color = levelColor(rangeLevel, rangeMax),
        }
        for _, key in ipairs(sortedKeys(State.ProgressionKeys)) do
            local config = ProgressionCfg.Progressions[key]
            local level = type(data.ActiveProgressions) == "table" and data.ActiveProgressions[key] or 0
            if config then
                entries[#entries + 1] = {
                    icon = itemIcon(config.ItemCost and config.ItemCost.ItemId),
                    line1 = config.Name or key,
                    line2 = ("Lv %d/%d"):format(level, config.MaxLevel),
                    line3 = config.ItemCost and ("%s / %d"):format(fmt(data[config.ItemCost.ItemId]), config.ItemCost.Amount) or key,
                    color = levelColor(level, config.MaxLevel),
                }
            end
        end
        for _, key in ipairs(sortedKeys(State.Upgrade2Keys)) do
            local system = Upgrades2Cfg.Systems[key]
            local levels = type(data.Upgrades2Levels) == "table" and data.Upgrades2Levels[key] or {}
            for _, def in pairs(system and system.Upgrades or {}) do
                local level = levels[def.Key] or 0
                entries[#entries + 1] = {
                    icon = def.Icon,
                    line1 = def.DisplayName or def.Key,
                    line2 = ("Lv %d/%d"):format(level, def.MaximumLevel),
                    line3 = key,
                    color = levelColor(level, def.MaximumLevel),
                }
            end
        end
        return entries, ("Progressao (%d)"):format(#entries)
    end

    function builders.Tokens()
        local data = PlayerData.Data
        local entries = {}
        for _, key in ipairs(sortedKeys(State.GachaKeys)) do
            local itemId, amount = gachaCost(key)
            local have = itemId and tonumber(data[itemId]) or 0
            entries[#entries + 1] = {
                icon = itemId and itemIcon(itemId),
                line1 = gachaNameByKey[key] or key,
                line2 = fmt(have) .. " tokens",
                line3 = ("%d rolls | %d por roll"):format(rollStats.gachaRolls[key] or 0, amount or 0),
                color = (amount and have >= amount) and GREEN or GRAY,
            }
        end
        return entries, #entries == 0 and "Selecione gachas na aba Gacha" or ("Tokens (%d)"):format(#entries)
    end

    task.spawn(function()
        while State.Running do
            for id, build in pairs(builders) do
                local panel = Panels[id]
                local visible = State["Panel" .. id] == true
                panel.frame.Visible = visible
                if visible then
                    local ok, entries, title = pcall(build)
                    if ok then
                        panel.render(entries, title)
                    else
                        warn("[AstralX] panel " .. id .. ":", entries)
                    end
                end
            end
            task.wait(1)
        end
    end)
end

-- Last: every control exists and every loop is running, so a loaded config can set any of them.
pcall(function()
    MacLib:LoadAutoLoadConfig()
end)
