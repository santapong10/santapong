--[[
	Anime Adventures Farming Monitor
	Ready-to-use · Stage-end webhook only · Inventory drop diff

	Features
	- ส่งเฉพาะตอนจบด่าน (ResultsUI)
	- ไม่ส่งตอนล็อบบี้ / ระหว่างรัน
	- Gems / Gold / Summer Pearls / Level
	- Result · Waves · Time · XP
	- Item drops จาก inventory diff (ItemInventoryServiceClient)
	- กรองค่าหลอก +99999
]]

-------------------------------------------------
-- CONFIG
-------------------------------------------------
local WEBHOOK_URL = "https://discord.com/api/webhooks/xxxxxxxxxxx"

-- เก็บข้อมูลดรอปเข้า Firebase (แบบ money tracker)
-- เว็บจะอ่านจาก path นี้
local FIREBASE_URL = "https://roblox-money-tracker-default-rtdb.firebaseio.com"
local FIREBASE_PATH = "AA_Drops"   -- เปลี่ยนได้ ต้องตรงกับ ?path= บนเว็บ
local FIREBASE_ENABLED = true

local SETTINGS = {
	AutoSendOnResults = true,
	WaitAfterResults  = 3.5, -- รอ inventory อัปเดตก่อน diff
	Username          = "AA Farming Monitor",
	AvatarUrl         = "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
	PrintToConsole    = true,
	UseEmbed          = true,   -- Discord embed สวยขึ้น
	UseInventoryDiff  = true,   -- เปิดจับไอเท็มจริง (กรองเพชร/เพิร์ล/ทองออก)
	UseLiveDropWatcher = false, -- ปิดจับข้อความระหว่างรัน (กันแจ้งมั่ว)
}

-------------------------------------------------
-- Services
-------------------------------------------------
local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-------------------------------------------------
-- Helpers
-------------------------------------------------
local function safeGet(root, path)
	local cur = root
	for _, name in ipairs(path) do
		if not cur then return nil end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function getText(inst)
	if inst and (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
		return inst.Text
	end
	return nil
end

local function parseNumber(str)
	if not str or type(str) ~= "string" then return nil end
	local cleaned = string.gsub(str, "[^%d%-%.]", "")
	return tonumber(cleaned)
end

local function cleanRewardText(str)
	if not str or type(str) ~= "string" then return nil end
	local s = string.gsub(str, "%s+", " ")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	if s == "" or string.find(s, "99999") then return nil end
	return s
end

local function comma(n)
	n = tonumber(n)
	if not n then return tostring(n) end
	local s = tostring(math.floor(n))
	local left, num, right = string.match(s, "^([^%d]*%d)(%d*)(.-)$")
	return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

-------------------------------------------------
-- Match detect
-------------------------------------------------
local function isInMatch()
	local ws = game:GetService("Workspace")
	if ws:FindFirstChild("_MAP_CONFIG") then return true end
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if pg and (pg:FindFirstChild("spawn_units") or pg:FindFirstChild("ResultsUI")) then
		return true
	end
	return false
end

-------------------------------------------------
-- Inventory (ItemInventoryServiceClient)
-------------------------------------------------
local InventorySnap = { before = nil }

local InventoryServiceCache = nil

local function loadInventoryService()
	if InventoryServiceCache then return InventoryServiceCache end

	-- path เดียวกับสคริปต์ฟาร์มสาธารณะ (ArponAG)
	local ok, loader = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("src"):WaitForChild("Loader", 8))
	end)
	if not ok or not loader then
		warn("[AA Monitor] Loader not found")
		return nil
	end

	local svc
	-- ลองทั้ง script และ nil
	local ok1, r1 = pcall(function()
		return loader.load_client_service(script, "ItemInventoryServiceClient")
	end)
	if ok1 and r1 then svc = r1 end
	if not svc then
		local ok2, r2 = pcall(function()
			return loader.load_client_service(nil, "ItemInventoryServiceClient")
		end)
		if ok2 and r2 then svc = r2 end
	end
	if not svc then
		warn("[AA Monitor] ItemInventoryServiceClient not loaded")
		return nil
	end

	InventoryServiceCache = svc
	if SETTINGS.PrintToConsole then
		print("[AA Monitor] ItemInventoryServiceClient loaded")
	end
	return svc
end

local function tableFromItems(result, items)
	if type(result) ~= "table" then return end
	for k, v in pairs(result) do
		local amount = v
		if type(v) == "table" then
			-- unique_items อาจเป็น array ของ object
			amount = v.amount or v.count or v.value or v.Quantity or v.qty or v.Amount or 1
		end
		local key = tostring(k)
		-- ถ้าเป็น array unique items
		if type(v) == "table" and (v.item_id or v.id or v.name) and tonumber(k) then
			key = tostring(v.item_id or v.id or v.name)
			amount = v.amount or v.count or 1
		end
		items[key] = (items[key] or 0) + (tonumber(amount) or 0)
	end
end

local function readNormalItems()
	local items = {}
	local ok, err = pcall(function()
		local svc = loadInventoryService()
		if not svc then return end
		local session = svc.session
		if not session then
			warn("[AA Monitor] svc.session nil")
			return
		end
		local inv = session.inventory
		if not inv then
			warn("[AA Monitor] session.inventory nil")
			return
		end
		local profile = inv.inventory_profile_data
		if not profile then
			warn("[AA Monitor] inventory_profile_data nil")
			return
		end
		-- normal_items = ไอเท็มทั่วไป (bean, fruit, key...)
		tableFromItems(profile.normal_items, items)
		-- unique_items = พอร์ทัล/ของพิเศษ
		tableFromItems(profile.unique_items, items)
	end)
	if not ok then
		warn("[AA Monitor] readNormalItems error:", err)
	end

	if SETTINGS.PrintToConsole then
		local n = 0
		for _ in pairs(items) do n = n + 1 end
		print("[AA Monitor] inventory items readable:", n)
	end
	return items
end

local function snapshotInventory(tag)
	InventorySnap.before = readNormalItems()
	if SETTINGS.PrintToConsole then
		local n = 0
		for _ in pairs(InventorySnap.before) do n = n + 1 end
		print("[AA Monitor] Inventory snapshot (" .. tostring(tag) .. ") =", n, "items")
	end
end

local function countKeys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function isCurrencyName(name)
	local n = string.lower(tostring(name or ""))
	n = n:gsub("[%s_%-]", "")
	if n == "" then return true end
	-- อนุญาตให้ 4 ทรัพยากรนี้ถูกนับเป็นดรอปด้วย
	-- ตัดคำต่อท้ายที่พบบ่อย เช่น Reward / Amount ก่อนตรวจชื่อ
	local resourceName = n:gsub("reward", ""):gsub("amount", "")
	if resourceName == "gem" or resourceName == "gems"
		or resourceName == "gold"
		or resourceName == "summerpearl" or resourceName == "summerpearls"
		or resourceName == "xp" or resourceName == "exp" then
		return false
	end
	-- ทรัพยากรอื่น / ข้อความ UI ทั่วไปยังคงไม่ถือเป็นดรอป
	if n:find("summerpearl") or n == "pearls" or n == "pearl" then return true end
	if n:find("gem") or n:find("gold") or n:find("trophy") then return true end
	if n == "xp" or n == "exp" or n:find("playerxp") or n:find("xpreward") or n:find("levelreward") then return true end
	if n:find("legacy") then return true end
	if n == "money" or n == "cash" then return true end
	-- ข้อความมั่วจาก UI
	if n:find("victory") or n:find("defeat") or n:find("wave") or n:find("timer") then return true end
	if n:find("damage") or n:find("dps") or n:find("yen") or n:find("reward") then return true end
	if n:find("click") or n:find("button") or n:find("frame") or n:find("label") then return true end
	if n:find("playergui") or n:find("screen") or n:find("text") then return true end
	return false
end

local function isPlausibleItemName(name)
	if not name or name == "" then return false end
	if isCurrencyName(name) then return false end
	local n = tostring(name)
	-- ยาวผิดปกติ / มีช่องว่างเยอะจากประโยค UI
	if #n > 40 then return false end
	if select(2, n:gsub(" ", "")) >= 4 then return false end
	-- ต้องมีตัวอักษร
	if not n:find("[%a]") then return false end
	return true
end

local function diffInventory()
	local after = readNormalItems()
	local before = InventorySnap.before

	if not before or countKeys(before) == 0 then
		if SETTINGS.PrintToConsole then
			print("[AA Monitor] skip drops — no before-snapshot")
		end
		return {}
	end
	if countKeys(after) == 0 then
		if SETTINGS.PrintToConsole then
			print("[AA Monitor] skip drops — after-snapshot empty")
		end
		return {}
	end

	local gained = {}
	local keys = {}
	for k in pairs(after) do keys[k] = true end
	for k in pairs(before) do keys[k] = true end

	for k in pairs(keys) do
		if isPlausibleItemName(k) then
			local a = after[k] or 0
			local b = before[k] or 0
			local delta = a - b
			-- รับเฉพาะของที่เพิ่มจริง และจำนวนสมเหตุสมผลต่อรอบ
			if delta > 0 and delta <= 25 then
				table.insert(gained, { name = tostring(k), amount = delta })
			elseif delta > 25 then
				if SETTINGS.PrintToConsole then
					print("[AA Monitor] ignore large delta:", k, delta)
				end
			end
		end
	end

	table.sort(gained, function(x, y) return x.name < y.name end)
	if SETTINGS.PrintToConsole then
		print("[AA Monitor] item drops this run:", #gained)
		for _, d in ipairs(gained) do
			print("  -", d.name, "+", d.amount)
		end
	end
	return gained
end

-------------------------------------------------
-- Live drop collector (ระหว่างแมพ + ตอนจบ)
-------------------------------------------------
local LiveDrops = {
	list = {}, -- {name=, amount=, at=}
}

local function rememberDrop(name, amount)
	if not isPlausibleItemName(name) then return end
	local amt = tonumber(amount) or 1
	if amt <= 0 or amt >= 99999 then return end
	name = tostring(name)
	-- รวมชื่อซ้ำในช่วงเวลาสั้น ๆ
	for _, d in ipairs(LiveDrops.list) do
		if d.name == name and (os.clock() - (d.at or 0)) < 8 then
			d.amount = (d.amount or 0) + amt
			return
		end
	end
	table.insert(LiveDrops.list, { name = name, amount = amt, at = os.clock() })
	if SETTINGS.PrintToConsole then
		print("[AA Monitor] live drop:", name, "+", amt)
	end
end

local function consumeLiveDrops()
	local out = {}
	local map = {}
	for _, d in ipairs(LiveDrops.list) do
		if not isCurrencyName(d.name) then
			map[d.name] = (map[d.name] or 0) + (tonumber(d.amount) or 0)
		end
	end
	for n, a in pairs(map) do
		if a > 0 and a < 99999 then
			table.insert(out, { name = n, amount = a })
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	LiveDrops.list = {}
	return out
end

local function textLooksLikeDrop(text)
	if not text or text == "" then return false end
	local t = tostring(text)
	if #t > 60 then return false end
	local low = string.lower(t)
	if isCurrencyName(t) then return false end
	if low:find("victory") or low:find("defeat") or low:find("wave") then return false end
	if low:find("damage") or low:find("yen") then return false end
	-- มี +ตัวเลข หรือ xตัวเลข
	if string.find(t, "%+%s*%d+") or string.find(low, "x%s*%d+") or string.find(low, "×%s*%d+") then
		return true
	end
	return false
end

local function parseDropText(text)
	-- ตัวอย่าง: "senzu_bean +2" / "+2 senzu" / "StarFruit x1"
	local t = tostring(text or "")
	local amount = parseNumber(t)
	local name = t
	name = name:gsub("^%s*%+%s*%d+%s*", "")
	name = name:gsub("%s*%+%s*%d+%s*$", "")
	name = name:gsub("[xX×]%s*%d+", "")
	name = name:gsub("%d+", "")
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	name = name:gsub("^obtained%s+", ""):gsub("^got%s+", ""):gsub("^received%s+", "")
	if name == "" then return nil end
	return name, amount or 1
end

local function hookDropNotifications()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return end

	local function scanLabel(label)
		if not label or not label:IsA("TextLabel") and not label:IsA("TextButton") then return end
		local t = label.Text
		if not textLooksLikeDrop(t) then return end
		local name, amt = parseDropText(t)
		if name then rememberDrop(name, amt) end
	end

	local function hookGui(gui)
		if not gui then return end
		gui.DescendantAdded:Connect(function(desc)
			if desc:IsA("TextLabel") or desc:IsA("TextButton") then
				task.defer(function()
					scanLabel(desc)
				end)
			end
		end)
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				d:GetPropertyChangedSignal("Text"):Connect(function()
					scanLabel(d)
				end)
			end
		end
	end

	-- ชื่อ UI ที่มักเป็นแจ้งเตือนดรอป
	local watchNames = {
		"Notifications", "Notification", "Notify", "Toasts", "Toast",
		"DropNotification", "ItemNotification", "RewardsNotification",
		"Message", "Messages", "Prompt", "Awards", "Loot",
	}
	for _, name in ipairs(watchNames) do
		local g = pg:FindFirstChild(name)
		if g then hookGui(g) end
	end
	pg.ChildAdded:Connect(function(child)
		local n = string.lower(child.Name)
		for _, w in ipairs(watchNames) do
			if n == string.lower(w) or n:find("notif") or n:find("toast") or n:find("drop") or n:find("loot") then
				task.defer(function() hookGui(child) end)
				break
			end
		end
	end)

	-- สำรอง: ฟังทุก TextLabel ที่โผล่ใต้ PlayerGui ช่วงสั้น ๆ ตอนมี +number
	pg.DescendantAdded:Connect(function(desc)
		if desc:IsA("TextLabel") then
			task.defer(function()
				if not desc.Parent then return end
				local t = desc.Text
				if textLooksLikeDrop(t) then
					local name, amt = parseDropText(t)
					if name then rememberDrop(name, amt) end
				end
			end)
		end
	end)

	print("[AA Monitor] drop watcher ready")
end

-------------------------------------------------
-- Snapshot Adapter
-------------------------------------------------
local SnapshotAdapter = {}

function SnapshotAdapter.getResources()
	local stats = LocalPlayer:FindFirstChild("_stats")
	if not stats then return {} end

	local function val(name)
		local obj = stats:FindFirstChild(name)
		if obj and (obj:IsA("NumberValue") or obj:IsA("IntValue") or obj:IsA("StringValue")) then
			return obj.Value
		end
		return nil
	end

	local function findByKeywords(words)
		for _, child in ipairs(stats:GetChildren()) do
			local n = string.lower(child.Name)
			local ok = true
			for _, w in ipairs(words) do
				if not string.find(n, w) then ok = false break end
			end
			if ok and (child:IsA("NumberValue") or child:IsA("IntValue") or child:IsA("StringValue")) then
				return child.Value
			end
		end
		return nil
	end

	local summer = val("summer_pearls_amount") or val("SummerPearls") or val("summer_pearls")
		or val("summerpearls_amount") or val("pearls_amount")
		or findByKeywords({"pearl"}) or findByKeywords({"summer"})

	local legacy = val("gem_legacy_amount") or val("legacy_gem_amount") or val("legacy_gems")
		or val("gems_legacy") or findByKeywords({"legacy", "gem"})

	local playerXp = val("player_xp") or val("xp_amount") or val("experience") or findByKeywords({"player", "xp"})

	return {
		gems = val("gem_amount"),
		gold = val("gold_amount"),
		summerPearls = summer,
		legacyGems = legacy,
		playerXp = playerXp,
		level = val("level") or val("player_level"),
	}
end

function SnapshotAdapter.getHUD()
	local gui = LocalPlayer:FindFirstChild("PlayerGui")
	if not gui then return {} end
	local lives = safeGet(gui, {"spawn_units", "Lives"})
	local levelText = nil
	if lives then
		levelText = getText(safeGet(lives, {"Main", "Desc", "Level"}))
	end
	-- บางแมพโชว์ level ที่อื่น
	if not levelText then
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("TextLabel") and d.Name == "Level" and d.Text and d.Text ~= "" then
				levelText = d.Text
				break
			end
		end
	end
	return {
		levelText = levelText,
	}
end

function SnapshotAdapter.getMatchInfo()
	local info = {
		mapName = nil,
		mode = nil,
		difficulty = nil,
		act = nil,
		wave = nil,
		waveMax = nil,
		weather = nil,
		modifiers = {},
	}

	local ws = game:GetService("Workspace")

	-- MAP CONFIG
	local mapConfig = ws:FindFirstChild("_MAP_CONFIG") or ws:FindFirstChild("MAP_CONFIG")
	if mapConfig then
		for _, key in ipairs({"MapName", "map_name", "Name", "StageName", "stage_name"}) do
			local v = mapConfig:FindFirstChild(key)
			if v and v:IsA("ValueBase") then info.mapName = tostring(v.Value) break end
			if typeof(v) == "string" then end
		end
		for _, key in ipairs({"Mode", "mode", "GameMode", "game_mode"}) do
			local v = mapConfig:FindFirstChild(key)
			if v and v:IsA("ValueBase") then info.mode = tostring(v.Value) break end
		end
		for _, key in ipairs({"Difficulty", "difficulty", "Diff"}) do
			local v = mapConfig:FindFirstChild(key)
			if v and v:IsA("ValueBase") then info.difficulty = tostring(v.Value) break end
		end
		for _, key in ipairs({"Act", "act", "Chapter"}) do
			local v = mapConfig:FindFirstChild(key)
			if v and v:IsA("ValueBase") then info.act = tostring(v.Value) break end
		end
		-- attributes
		pcall(function()
			for attr, val in pairs(mapConfig:GetAttributes()) do
				local a = string.lower(tostring(attr))
				if not info.mapName and (a:find("map") or a:find("stage") or a:find("world")) then
					info.mapName = tostring(val)
				end
				if not info.mode and a:find("mode") then info.mode = tostring(val) end
				if not info.difficulty and a:find("diff") then info.difficulty = tostring(val) end
			end
		end)
	end

	-- wave values in workspace / replicated
	local function readWaveFrom(root)
		if not root then return end
		for _, name in ipairs({"_wave", "wave", "Wave", "CurrentWave", "current_wave"}) do
			local v = root:FindFirstChild(name, true)
			if v and v:IsA("ValueBase") then
				info.wave = tonumber(v.Value) or v.Value
				return
			end
		end
	end
	readWaveFrom(ws)
	pcall(function()
		readWaveFrom(game:GetService("ReplicatedStorage"))
	end)

	-- HUD wave text
	local gui = LocalPlayer:FindFirstChild("PlayerGui")
	if gui then
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("TextLabel") then
				local t = d.Text or ""
				local w1, w2 = string.match(t, "[Ww]ave%s*(%d+)%s*/%s*(%d+)")
				if w1 then
					info.wave = tonumber(w1)
					info.waveMax = tonumber(w2)
					break
				end
				local w3 = string.match(t, "[Ww]ave%s*(%d+)")
				if w3 and not info.wave then
					info.wave = tonumber(w3)
				end
				-- weather-ish keywords in small labels
				local low = string.lower(t)
				if #t < 24 and (low:find("ลม") or low:find("พายุ") or low:find("storm") or low:find("wind") or low:find("rain") or low:find("weather")) then
					info.weather = t
				end
			end
		end
	end

	return info
end

function SnapshotAdapter.getUnits()
	local units = {}
	local gui = LocalPlayer:FindFirstChild("PlayerGui")
	if not gui then return units end

	local spawn = gui:FindFirstChild("spawn_units")
	if not spawn then return units end

	-- common path: Lives / Frame / Units
	local frames = {}
	local unitsFolder = safeGet(spawn, {"Lives", "Frame", "Units"})
		or safeGet(spawn, {"Lives", "Units"})
		or spawn:FindFirstChild("Units", true)

	local function pushUnit(btn)
		if not btn then return end
		local name = nil
		local level = nil
		-- try WorldModel pet
		pcall(function()
			local wm = btn:FindFirstChild("Main") and btn.Main:FindFirstChild("petimage")
			if wm then
				local world = wm:FindFirstChild("WorldModel")
				if world then
					local model = world:FindFirstChildWhichIsA("Model")
					if model then name = model.Name end
				end
			end
		end)
		-- text labels
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("TextLabel") then
				local t = d.Text or ""
				if not level then
					local lv = string.match(t, "[Ll][Vv]%.?%s*(%d+)") or string.match(t, "Level%s*(%d+)")
					if lv then level = tonumber(lv) end
				end
				if not name and d.Name:lower():find("name") and #t > 1 then
					name = t
				end
			end
		end
		if not name then name = btn.Name end
		if name and name ~= "UIListLayout" and name ~= "UIPadding" then
			table.insert(units, { name = tostring(name), level = level })
		end
	end

	if unitsFolder then
		for _, child in ipairs(unitsFolder:GetChildren()) do
			if child:IsA("ImageButton") or child:IsA("Frame") or child:IsA("TextButton") then
				pushUnit(child)
			end
		end
	end

	return units
end


function SnapshotAdapter.getResults()
	local gui = LocalPlayer:FindFirstChild("PlayerGui")
	if not gui then return nil end
	local resultsUI = gui:FindFirstChild("ResultsUI")
	if not resultsUI then return nil end
	if resultsUI:IsA("ScreenGui") and not resultsUI.Enabled then return nil end
	local holder = resultsUI:FindFirstChild("Holder")
	if not holder then return nil end

	local data = {
		result = getText(holder:FindFirstChild("Title")),
		waves = nil, time = nil,
		gold = nil, gems = nil, xp = nil, trophy = nil,
		drops = {},
	}

	local middle = holder:FindFirstChild("Middle")
	if middle then
		data.waves = getText(middle:FindFirstChild("WavesCompleted"))
		data.time  = getText(middle:FindFirstChild("Timer"))
	end

	local function readAmount(frame)
		if not frame then return nil end
		local a = getText(safeGet(frame, {"Main", "Amount"}))
			or getText(frame:FindFirstChild("Amount"))
		return cleanRewardText(a)
	end

	local levelRewards = safeGet(holder, {"LevelRewards", "ScrollingFrame"})
	if levelRewards then
		data.gold   = readAmount(levelRewards:FindFirstChild("GoldReward"))
		data.gems   = readAmount(levelRewards:FindFirstChild("GemReward"))
		data.xp     = readAmount(levelRewards:FindFirstChild("XPReward"))
		data.trophy = readAmount(levelRewards:FindFirstChild("TrophyReward"))
	end

	if not data.gems or not data.xp then
		local gg = holder:FindFirstChild("GoldGemXP")
		if gg then
			data.gems = data.gems or readAmount(safeGet(gg, {"GemReward"}))
			data.xp   = data.xp   or readAmount(safeGet(gg, {"XPReward"}))
		end
	end

	-- เก็บไอเท็มจาก Results UI เท่านั้น (ไม่ใช้ทั้งกระเป๋า)
	local skipNames = {
		GoldReward=true, GemReward=true, XPReward=true, TrophyReward=true,
		Title=true, Middle=true, Timer=true, WavesCompleted=true,
		LevelRewards=true, GoldGemXP=true, Holder=true, UIListLayout=true,
		UIPadding=true, UIStroke=true, UICorner=true, Main=true, Amount=true,
	}
	local function pushDrop(name, amount)
		if not name or name == "" then return end
		if skipNames[name] then return end
		if not isPlausibleItemName(name) then return end
		local low = string.lower(name)
		if low:find("reward") then return end
		local amt = tonumber(amount)
		if not amt or amt <= 0 or amt >= 99999 then return end
		table.insert(data.drops, { name = tostring(name), amount = amt })
	end

	local function scanRewardFrame(frame)
		if not frame then return end
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("Frame") or child:IsA("ImageButton") or child:IsA("TextButton") then
				if not skipNames[child.Name] then
					local amountText = getText(safeGet(child, {"Main", "Amount"}))
						or getText(child:FindFirstChild("Amount"))
						or getText(child:FindFirstChild("Text"))
					local amt = nil
					if amountText then
						local cleaned = cleanRewardText(amountText)
						if cleaned then
							amt = parseNumber(cleaned)
						else
							amt = parseNumber(amountText)
						end
					end
					-- ชื่อจาก Name หรือ label
					local label = getText(safeGet(child, {"Main", "Title"}))
						or getText(child:FindFirstChild("Title"))
						or getText(child:FindFirstChild("ItemName"))
						or getText(child:FindFirstChild("Name"))
					local name = label
					if not name or name == "" then name = child.Name end
					pushDrop(name, amt or 1)
				end
			end
		end
	end

	if levelRewards then
		scanRewardFrame(levelRewards)
	end

	-- นับทรัพยากรหลักที่แสดงในหน้า Results เป็นดรอปด้วย
	-- (แยกจากบรรทัดสรุป Resources เพื่อให้ไปอยู่ในรายการ Item Drops)
	local function pushResourceDrop(name, amount)
		local amt = parseNumber(amount)
		if amt and amt > 0 and amt < 99999 then
			table.insert(data.drops, { name = name, amount = amt })
		end
	end
	pushResourceDrop("Gold", data.gold)
	pushResourceDrop("Gems", data.gems)
	pushResourceDrop("XP", data.xp)

	-- Summer Pearls อาจอยู่ใน Results UI ด้วยชื่อที่ต่างกันในแต่ละเวอร์ชัน
	local summerPearlReward = safeGet(levelRewards, {"SummerPearlReward"})
		or safeGet(levelRewards, {"SummerPearlsReward"})
		or safeGet(holder, {"SummerPearlReward"})
		or safeGet(holder, {"SummerPearlsReward"})
	if summerPearlReward then
		local amountText = getText(safeGet(summerPearlReward, {"Main", "Amount"}))
			or getText(summerPearlReward:FindFirstChild("Amount"))
		pushResourceDrop("SummerPearls", amountText)
	end

	local itemRewards = holder:FindFirstChild("ItemRewards")
		or holder:FindFirstChild("Items")
		or holder:FindFirstChild("Drops")
		or safeGet(holder, {"Rewards", "ScrollingFrame"})
	if itemRewards then
		scanRewardFrame(itemRewards)
	end

	return data
end

function SnapshotAdapter.capture(extraDrops)
	local matchInfo = {}
	local units = {}
	pcall(function() matchInfo = SnapshotAdapter.getMatchInfo() end)
	pcall(function() units = SnapshotAdapter.getUnits() end)

	-- ใช้เฉพาะ diff ที่ผ่านการกรองแล้ว (ไม่ส่งกระเป๋าทั้งใบ)
	local drops = extraDrops
	if type(drops) ~= "table" then
		drops = {}
	end

	return {
		timestamp = os.time(),
		placeId   = game.PlaceId,
		playerName = LocalPlayer.Name,
		displayName = LocalPlayer.DisplayName,
		userId = LocalPlayer.UserId,
		resources = SnapshotAdapter.getResources(),
		hud       = SnapshotAdapter.getHUD(),
		match     = matchInfo,
		units     = units,
		results   = SnapshotAdapter.getResults(),
		itemDrops = drops,
	}
end

-------------------------------------------------
-- Format (สวย / อ่านง่าย)
-------------------------------------------------
local function resultEmoji(result)
	if not result then return "🏁" end
	local r = string.upper(result)
	if string.find(r, "VICTORY") or string.find(r, "WIN") then return "🏆" end
	if string.find(r, "DEFEAT") or string.find(r, "LOSE") then return "💀" end
	return "🏁"
end

function SnapshotAdapter.formatPlain(snap)
	local lines = {}
	table.insert(lines, "═══ Anime Adventures ═══")
	table.insert(lines, string.format("Place `%s` · %s", tostring(snap.placeId), os.date("%H:%M:%S", snap.timestamp)))

	local res = snap.resources or {}
	if res.gems ~= nil then table.insert(lines, "💎 Gems: **" .. comma(res.gems) .. "**") end
	if res.gold ~= nil then table.insert(lines, "🪙 Gold: **" .. comma(res.gold) .. "**") end
	if res.summerPearls ~= nil then table.insert(lines, "🫧 Summer Pearls: **" .. comma(res.summerPearls) .. "**") end
	if snap.hud and snap.hud.levelText then
		table.insert(lines, "⭐ " .. tostring(snap.hud.levelText))
	end

	if snap.results then
		local r = snap.results
		table.insert(lines, "")
		table.insert(lines, resultEmoji(r.result) .. " **Results**")
		if r.result then table.insert(lines, "· " .. tostring(r.result)) end
		if r.waves  then table.insert(lines, "· " .. tostring(r.waves)) end
		if r.time   then table.insert(lines, "· " .. tostring(r.time)) end
		if r.gems   then table.insert(lines, "· Gems " .. tostring(r.gems)) end
		if r.xp     then table.insert(lines, "· XP " .. tostring(r.xp)) end
		if r.gold   then table.insert(lines, "· Gold " .. tostring(r.gold)) end
		if r.trophy then table.insert(lines, "· Trophy " .. tostring(r.trophy)) end
	end

	if snap.itemDrops and #snap.itemDrops > 0 then
		table.insert(lines, "")
		table.insert(lines, "🎁 **Item Drops**")
		for _, d in ipairs(snap.itemDrops) do
			table.insert(lines, string.format("· %s `+%s`", tostring(d.name), tostring(d.amount)))
		end
	elseif snap.results and not (snap.results.gems or snap.results.xp or snap.results.gold) then
		table.insert(lines, "")
		table.insert(lines, "_ไม่มีรางวัล/ดรอปในรอบนี้_")
	end

	return table.concat(lines, "\n")
end

function SnapshotAdapter.formatEmbed(snap)
	local res = snap.resources or {}
	local r = snap.results
	local resultText = r and r.result and tostring(r.result) or nil
	local up = resultText and string.upper(resultText) or ""

	local isDefeat = up:find("DEFEAT") or up:find("LOSE")
	local isVictory = up:find("VICTORY") or up:find("WIN") or up:find("CLEAR")

	local color = 0x5865F2
	if isVictory then color = 0x3BA55D end
	if isDefeat then color = 0xED4245 end

	local title
	if isVictory then
		title = "Victory"
	elseif isDefeat then
		title = "Defeat"
	elseif resultText then
		title = resultText
	else
		title = "Stage Report"
	end

	local fields = {}

	-- Stage summary (compact one line)
	local stageBits = {}
	if r and r.waves then
		local w = tostring(r.waves):gsub("Waves Completed:%s*", "Wave ")
		table.insert(stageBits, w)
	end
	if r and r.time then
		local t = tostring(r.time):gsub("Total Time:%s*", "")
		table.insert(stageBits, "⏱ " .. t)
	end
	if snap.hud and snap.hud.levelText then
		local lv = tostring(snap.hud.levelText):gsub("^Level%s*", "Lv ")
		table.insert(stageBits, lv)
	end
	if #stageBits > 0 then
		table.insert(fields, {
			name = "Stage",
			value = table.concat(stageBits, "  ·  "),
			inline = false,
		})
	end

	-- Balance (left) / Run Rewards (right)
	local bal = {}
	if res.gems ~= nil then table.insert(bal, "💎  **" .. comma(res.gems) .. "**") end
	if res.gold ~= nil then table.insert(bal, "🪙  **" .. comma(res.gold) .. "**") end
	if res.summerPearls ~= nil then table.insert(bal, "🫧  **" .. comma(res.summerPearls) .. "**") end
	table.insert(fields, {
		name = "Balance",
		value = (#bal > 0) and table.concat(bal, "\n") or "—",
		inline = true,
	})

	local rewards = {}
	if r then
		if r.gems then table.insert(rewards, "💎  " .. tostring(r.gems)) end
		if r.xp then table.insert(rewards, "✨  " .. tostring(r.xp)) end
		if r.gold then table.insert(rewards, "🪙  " .. tostring(r.gold)) end
		if r.trophy then table.insert(rewards, "🏆  " .. tostring(r.trophy)) end
	end
	table.insert(fields, {
		name = "Run Rewards",
		value = (#rewards > 0) and table.concat(rewards, "\n") or "_none_",
		inline = true,
	})

	-- Item drops
	if snap.itemDrops and #snap.itemDrops > 0 then
		local lines = {}
		for i, d in ipairs(snap.itemDrops) do
			if i <= 10 then
				table.insert(lines, string.format("▸ `%s`　**+%s**", tostring(d.name), tostring(d.amount)))
			end
		end
		if #snap.itemDrops > 10 then
			table.insert(lines, string.format("_…and %d more_", #snap.itemDrops - 10))
		end
		table.insert(fields, {
			name = "Item Drops",
			value = table.concat(lines, "\n"),
			inline = false,
		})
	end

	local embed = {
		author = {
			name = "Anime Adventures",
			icon_url = "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
		},
		title = title,
		color = color,
		fields = fields,
		thumbnail = {
			url = isDefeat
				and "https://cdn.discordapp.com/emojis/1234567890.png"
				or "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
		},
		image = {
			url = "https://tr.rbxcdn.com/180DAY-bd4fbfaf530e5a1f2f4a053791448977/768/432/Image/Png/noFilter",
		},
		footer = {
			text = string.format("%s  ·  %s", tostring(snap.placeId), os.date("%d/%m %H:%M", snap.timestamp)),
			icon_url = "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
		},
	}

	-- thumbnail ใช้ไอคอนเกมเสมอ (ไม่พึ่ง emoji url ปลอม)
	embed.thumbnail = {
		url = "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
	}

	return {
		username = SETTINGS.Username,
		avatar_url = SETTINGS.AvatarUrl,
		embeds = { embed },
	}
end

local function sendWebhookPayload(payload)
	if not WEBHOOK_URL or WEBHOOK_URL == "" or string.find(WEBHOOK_URL, "YOUR_ID") then
		warn("[AA Monitor] ยังไม่ได้ใส่ WEBHOOK_URL")
		return false
	end

	local body = HttpService:JSONEncode(payload)
	local req = (syn and syn.request) or http_request or request or (http and http.request)

	if req then
		local ok, res = pcall(function()
			return req({
				Url = WEBHOOK_URL,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = body,
			})
		end)
		if ok then
			if SETTINGS.PrintToConsole then print("[AA Monitor] Webhook sent (request)") end
			return true
		end
		warn("[AA Monitor] request failed:", res)
	end

	local ok2, err2 = pcall(function()
		HttpService:PostAsync(WEBHOOK_URL, body, Enum.HttpContentType.ApplicationJson)
	end)
	if ok2 then
		if SETTINGS.PrintToConsole then print("[AA Monitor] Webhook sent (HttpService)") end
		return true
	end
	warn("[AA Monitor] HttpService failed:", err2)
	return false
end

local function sendToWeb(snap)
	if not FIREBASE_ENABLED then return false end
	if not FIREBASE_URL or FIREBASE_URL == "" then
		warn("[AA Monitor] FIREBASE_URL ว่าง")
		return false
	end

	-- POST ใต้ PATH/{userId} เพื่อแยกหลายไอดี
	local base = tostring(FIREBASE_URL):gsub("/+$", "")
	local path = tostring(FIREBASE_PATH or "AA_Drops"):gsub("^/+", ""):gsub("/+$", "")
	local uid = tostring(LocalPlayer.UserId)
	local url = base .. "/" .. path .. "/" .. uid .. ".json"

	-- ใส่เวลาฝั่ง client ชัดเจน
	local payload = {
		timestamp = snap.timestamp or os.time(),
		placeId = snap.placeId,
		resources = snap.resources,
		hud = snap.hud,
		results = snap.results,
		itemDrops = snap.itemDrops,
	}
	local body = HttpService:JSONEncode(payload)

	local req = (syn and syn.request) or http_request or request or (http and http.request)
	if req then
		local ok, res = pcall(function()
			return req({
				Url = url,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = body,
			})
		end)
		if ok then
			if SETTINGS.PrintToConsole then
				print("[AA Monitor] Firebase saved →", path .. "/" .. tostring(LocalPlayer.UserId))
			end
			return true
		end
		warn("[AA Monitor] Firebase request failed:", res)
	end

	local ok2, err2 = pcall(function()
		HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	if ok2 then
		if SETTINGS.PrintToConsole then print("[AA Monitor] Firebase saved (RequestAsync)") end
		return true
	end

	-- fallback บาง executor ใช้ PostAsync ไม่รองรับ POST path แบบ firebase push ดีเท่า request
	local ok3, err3 = pcall(function()
		HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
	end)
	if ok3 then
		if SETTINGS.PrintToConsole then print("[AA Monitor] Firebase saved (PostAsync)") end
		return true
	end

	warn("[AA Monitor] Firebase write failed:", err2 or err3)
	return false
end

local function sendReport(snap)
	-- เว็บไซต์แจ้งเตือน
	pcall(sendToWeb, snap)

	-- Discord (ถ้ามี)
	if SETTINGS.UseEmbed then
		return sendWebhookPayload(SnapshotAdapter.formatEmbed(snap))
	end
	return sendWebhookPayload({
		content = SnapshotAdapter.formatPlain(snap),
		username = SETTINGS.Username,
		avatar_url = SETTINGS.AvatarUrl,
	})
end

-------------------------------------------------
-- Report
-------------------------------------------------
local function report(reason, extraDrops)
	reason = reason or "manual"
	if not isInMatch() and not tostring(reason):find("^force") then
		if SETTINGS.PrintToConsole then
			print("[AA Monitor] skip — lobby")
		end
		return nil
	end

	local snap = SnapshotAdapter.capture(extraDrops)
	if SETTINGS.PrintToConsole then
		print("========== AA Report (" .. reason .. ") ==========")
		print(SnapshotAdapter.formatPlain(snap))
		print("================================================")
	end
	sendReport(snap)
	return snap
end

-------------------------------------------------
-- Auto: ResultsUI only
-------------------------------------------------
local function startAutoDetect()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[AA Monitor] no PlayerGui")
		return
	end

	local sent = false
	local lastSendAt = 0

	local function isRealResultsVisible()
		local ui = playerGui:FindFirstChild("ResultsUI")
		if not ui then return false end
		if ui:IsA("ScreenGui") and not ui.Enabled then return false end
		local holder = ui:FindFirstChild("Holder")
		if not holder then return false end
		local title = holder:FindFirstChild("Title")
		local text = getText(title)
		if not text or text == "" then return false end
		local up = string.upper(text)
		-- ต้องมีคำว่าจบรอบจริง
		if up:find("VICTORY") or up:find("DEFEAT") or up:find("WIN") or up:find("LOSE") or up:find("CLEAR") or up:find("RESULT") then
			return true
		end
		-- หรือมี WavesCompleted พร้อมตัวเลข
		local middle = holder:FindFirstChild("Middle")
		if middle then
			local waves = getText(middle:FindFirstChild("WavesCompleted"))
			if waves and parseNumber(waves) then
				return true
			end
		end
		return false
	end

	local function onStageEnd(reason)
		if not SETTINGS.AutoSendOnResults then return end
		if not isInMatch() then return end
		if sent then return end
		if (os.clock() - lastSendAt) < 8 then return end -- กันยิงซ้ำช่วงสั้น

		-- รอ UI โหลดข้อความจริง
		task.delay(SETTINGS.WaitAfterResults, function()
			if sent then return end
			if not isRealResultsVisible() then
				if SETTINGS.PrintToConsole then
					print("[AA Monitor] skip — ResultsUI ยังไม่ใช่จบด่านจริง")
				end
				return
			end

			sent = true
			lastSendAt = os.clock()
			print("[AA Monitor] Stage end confirmed → reporting...")

			local gained = {}
			-- 1) ของที่เก็บระหว่างแมพจาก UI แจ้งเตือน
			pcall(function()
				for _, d in ipairs(consumeLiveDrops()) do
					table.insert(gained, d)
				end
			end)
			-- 2) จาก Results UI
			pcall(function()
				local r = SnapshotAdapter.getResults()
				if r and type(r.drops) == "table" then
					for _, d in ipairs(r.drops) do
						table.insert(gained, d)
					end
				end
			end)
			-- 3) inventory diff (กรองเพชร/เพิร์ลแล้ว) — รอให้ของเข้ากระเป๋าก่อน
			if SETTINGS.UseInventoryDiff then
				pcall(function()
					-- รีเฟรชหลายครั้ง เผื่อ server sync ช้า
					local inv = {}
					for _ = 1, 3 do
						inv = diffInventory()
						if #inv > 0 then break end
						task.wait(0.8)
					end
					for _, d in ipairs(inv) do
						table.insert(gained, d)
					end
					if SETTINGS.PrintToConsole then
						print("[AA Monitor] inventory-diff drops:", #inv)
						for _, d in ipairs(inv) do
							print("   +", d.name, d.amount)
						end
					end
				end)
			end
			-- รวมชื่อซ้ำ
			local merged = {}
			local map = {}
			for _, d in ipairs(gained) do
				local n = tostring(d.name)
				local a = tonumber(d.amount) or 0
				if a > 0 and a < 99999 and isPlausibleItemName(n) then
					map[n] = (map[n] or 0) + a
				end
			end
			for n, a in pairs(map) do
				table.insert(merged, { name = n, amount = a })
			end
			table.sort(merged, function(x, y) return x.name < y.name end)
			if SETTINGS.PrintToConsole then
				print("[AA Monitor] drops this run:", #merged, "(inventoryDiff=", tostring(SETTINGS.UseInventoryDiff), ")")
			end
			report("stage_end", merged)

			-- ล็อคนานพอจนออกจากหน้า results
			task.delay(15, function()
				sent = false
			end)
			-- รีเซ็ต inventory หลังออกจากแมพ
			task.delay(20, function()
				if not isInMatch() then
					InventorySnap.before = nil
				end
			end)
		end)
	end

	local function hookResults(ui)
		if not ui then return end
		if ui:IsA("ScreenGui") then
			ui:GetPropertyChangedSignal("Enabled"):Connect(function()
				if ui.Enabled then
					onStageEnd("results_enabled")
				end
			end)
			if ui.Enabled then
				onStageEnd("results_already_on")
			end
		end
	end

	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "ResultsUI" then
			-- อย่าส่งทันทีตอนสร้าง — รอ Enabled + ข้อความจริง
			hookResults(child)
		end
	end)

	hookResults(playerGui:FindFirstChild("ResultsUI"))

	-- snapshot inventory while in match (ไม่ส่ง webhook)
	task.spawn(function()
		local snappedThisMatch = false
		while true do
			task.wait(2)
			if isInMatch() then
				if not snappedThisMatch then
					-- รอเข้าแมพนิ่ง ๆ ก่อน แล้วถ่ายครั้งเดียวตอนต้นรอบ
					task.wait(4)
					if isInMatch() then
						snapshotInventory("match_start")
						if countKeys(InventorySnap.before) > 0 then
							snappedThisMatch = true
							print("[AA Monitor] before-snapshot locked for this run")
						else
							print("[AA Monitor] before-snapshot empty — will retry")
							InventorySnap.before = nil
						end
					end
				end
			else
				InventorySnap.before = nil
				snappedThisMatch = false
				sent = false
				LiveDrops.list = {}
			end
		end
	end)

	print("[AA Monitor] Ready · report only on real stage end")
end

-------------------------------------------------
-- API
-------------------------------------------------
_G.AA_Monitor = {
	Report  = function(reason) return report(reason or "force test", {}) end,
	Capture = SnapshotAdapter.capture,
	Settings = SETTINGS,
}

-------------------------------------------------
-- Start
-------------------------------------------------
print("[AA Monitor] loading...")
task.spawn(function()
	task.wait(1)
	if SETTINGS.UseLiveDropWatcher then
		pcall(hookDropNotifications)
	else
		print("[AA Monitor] live drop watcher OFF (กันแจ้งมั่ว)")
	end
end)
task.spawn(startAutoDetect)
print("[AA Monitor] loaded")
print("→ manual test: _G.AA_Monitor.Report()")
