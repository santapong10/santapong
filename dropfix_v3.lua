--[[
	es Farming Monitor (Fixed & Isolated)
	- ส่ง Webhook และบันทึก API ได้แม้เปิดสคริปต์ออโต้ฟาร์มร่วมด้วย
	- ป้องกันตัวแปร / Callback / Connection ชนกับสคริปต์อื่น
	- ตรวจสอบ HTTP Response (StatusCode / Retry-After) และบันทึก Error Log
	- ตรวจจับ Bean, Fruit, Key, Gems, SummerPearls, Gold และ XP ครบถ้วน
]]

do
	-------------------------------------------------
	-- ISOLATION & CLEANUP (ป้องกันชนกับสคริปต์อื่น / รันซ้ำ)
	-------------------------------------------------
	local env = (type(getgenv) == "function" and getgenv()) or _G
	if type(env.__AA_MONITOR_CLEANUP) == "function" then
		pcall(env.__AA_MONITOR_CLEANUP)
	end

	local isAlive = true
	local activeConnections = {}

	local function trackConn(conn)
		if conn then
			table.insert(activeConnections, conn)
		end
		return conn
	end

	local function cleanupAll()
		isAlive = false
		for i = #activeConnections, 1, -1 do
			local conn = activeConnections[i]
			if conn and conn.Connected then
				pcall(function() conn:Disconnect() end)
			end
			activeConnections[i] = nil
		end
	end

	env.__AA_MONITOR_CLEANUP = cleanupAll

	local function getService(serviceName)
		local svc = game:GetService(serviceName)
		if type(cloneref) == "function" then
			local ok, cloned = pcall(cloneref, svc)
			if ok and cloned then
				return cloned
			end
		end
		return svc
	end

	-------------------------------------------------
	-- CONFIG
	-------------------------------------------------
	local WEBHOOK_URL = "https://discord.com/api/webhooks/1254702199171448883/zUHXUvtOhL8NjiUdLXM3hbxsU4--2pHMqeba7vxFNRSRhE1-MKn_ujVAkIb2ap2OyiNx"

	-- เก็บข้อมูลดรอปเข้า Firebase (แบบ money tracker)
	local FIREBASE_URL     = "https://roblox-money-tracker-default-rtdb.firebaseio.com"
	local FIREBASE_PATH    = "AA_Drops" -- ต้องตรงกับ ?path= บนเว็บ
	local FIREBASE_ENABLED = true

	local SETTINGS = {
		AutoSendOnResults  = true,
		WaitAfterResults   = 3.0,  -- รอขั้นต่ำหลัง Results โผล่ (วินาที)
		SettleTime         = 2.0,  -- ถ้ามีดรอปเพิ่มอยู่ ให้รอจนนิ่งอย่างน้อยกี่วินาที
		MaxWaitAfterResults = 8.0, -- เพดานรอสูงสุด กันค้าง
		DeepScanResults    = true, -- สแกนหาไอเท็มในทุกส่วนของ ResultsUI (กันหลุดจากโครง UI ที่ต่างกัน)
		MaxEmbedDrops      = 40,   -- จำนวนดรอปสูงสุดที่แสดงใน Discord embed
		MaxHttpRetries     = 3,    -- จำนวนครั้งที่ส่งซ้ำเมื่อ HTTP ล้มเหลวหรือติด 429
		RetryBaseDelay     = 1.5,  -- หน่วงเวลาก่อนลองส่งใหม่ (วินาที)
		Username           = "AA Farming Monitor",
		AvatarUrl          = "https://tr.rbxcdn.com/e5b5844fb26df605986b94d87384f5fb/150/150/Image/Jpeg",
		PrintToConsole     = true,
		UseEmbed           = true,
		UseInventoryDiff   = true,
		UseLiveDropWatcher = false,
	}

	-------------------------------------------------
	-- Services (Isolated via cloneref)
	-------------------------------------------------
	local Players           = getService("Players")
	local HttpService       = getService("HttpService")
	local ReplicatedStorage = getService("ReplicatedStorage")
	local Workspace         = getService("Workspace")
	local LocalPlayer       = Players.LocalPlayer

	-------------------------------------------------
	-- Logger & HTTP Response Diagnostics
	-------------------------------------------------
	local MonitorStats = {
		webhookSent    = 0,
		webhookFailed  = 0,
		firebaseSent   = 0,
		firebaseFailed = 0,
		lastWebhookRes = nil,
		lastApiRes     = nil,
	}

	local LogHistory = {}
	local ErrorHistory = {}
	local MAX_LOGS = 120

	local function pushLog(level, tag, message, extra)
		local entry = {
			time    = os.date("%Y-%m-%d %H:%M:%S"),
			clock   = os.clock(),
			level   = level,
			tag     = tag,
			message = tostring(message),
			extra   = extra,
		}
		table.insert(LogHistory, entry)
		if #LogHistory > MAX_LOGS then
			table.remove(LogHistory, 1)
		end

		if level == "ERROR" or level == "WARN" then
			table.insert(ErrorHistory, entry)
			if #ErrorHistory > MAX_LOGS then
				table.remove(ErrorHistory, 1)
			end
		end

		if SETTINGS.PrintToConsole or level == "ERROR" then
			local prefix = string.format("[AA Monitor][%s][%s] %s", level, tag, tostring(message))
			if level == "ERROR" or level == "WARN" then
				warn(prefix)
			else
				print(prefix)
			end
		end
		return entry
	end

	local function safeCall(tag, fn, ...)
		local args = { ... }
		local ok, res1, res2, res3 = xpcall(function()
			return fn(table.unpack(args))
		end, function(err)
			return tostring(err) .. "\n" .. debug.traceback("", 2)
		end)
		if not ok then
			pushLog("ERROR", tag, res1)
			return false, nil
		end
		return true, res1, res2, res3
	end

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
		if type(str) == "number" then return str end
		if not str or type(str) ~= "string" then return nil end
		local cleaned = string.gsub(str, "[^%d%-%.]", "")
		return tonumber(cleaned)
	end

	local function cleanRewardText(str)
		if not str or type(str) ~= "string" then return nil end
		local s = string.gsub(str, "%s+", " ")
		s = string.gsub(s, "^%s+", "")
		s = string.gsub(s, "%s+$", "")
		if s == "" then return nil end
		-- กรองเฉพาะค่า placeholder 99999 เป๊ะ ๆ (เดิมกรองทุกเลขที่มี 99999 อยู่ข้างใน เช่น 199999)
		local digits = string.gsub(s, "[^%d]", "")
		if digits == "99999" then return nil end
		return s
	end

	local function comma(n)
		n = tonumber(n)
		if not n then return tostring(n) end
		local s = tostring(math.floor(n))
		local left, num, right = string.match(s, "^([^%d]*%d)(%d*)(.-)$")
		return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
	end

	local function sanitizeForJson(val, seen)
		local t = type(val)
		if t == "number" then
			if val ~= val or val == math.huge or val == -math.huge then
				return 0
			end
			return val
		elseif t == "string" or t == "boolean" then
			return val
		elseif t == "table" then
			seen = seen or {}
			if seen[val] then return nil end
			seen[val] = true
			local out = {}
			local isArray = true
			local maxIdx = 0
			local count = 0
			for k in pairs(val) do
				count = count + 1
				if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
					isArray = false
				else
					if k > maxIdx then maxIdx = k end
				end
			end
			if isArray and count == maxIdx then
				for i = 1, maxIdx do
					out[i] = sanitizeForJson(val[i], seen)
				end
			else
				for k, v in pairs(val) do
					local cleanV = sanitizeForJson(v, seen)
					if cleanV ~= nil then
						out[tostring(k)] = cleanV
					end
				end
			end
			seen[val] = nil
			return out
		end
		return nil
	end

	-------------------------------------------------
	-- Match detect
	-------------------------------------------------
	local function isInMatch()
		if Workspace:FindFirstChild("_MAP_CONFIG") or Workspace:FindFirstChild("MAP_CONFIG") then
			return true
		end
		if Workspace:FindFirstChild("_UNITS") or Workspace:FindFirstChild("UNITS") then
			return true
		end
		local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if pg then
			if pg:FindFirstChild("spawn_units") or pg:FindFirstChild("ResultsUI") then
				return true
			end
			-- บางแมพใช้ชื่ออื่น
			for _, n in ipairs({"Hotbar", "UnitManager", "BattleUI", "MatchUI"}) do
				if pg:FindFirstChild(n) then return true end
			end
		end
		return false
	end

	-------------------------------------------------
	-- Inventory (ItemInventoryServiceClient)
	-------------------------------------------------
	local InventorySnap = {
		before = nil,
		beforeOk = false,
		beforeResources = nil,
	}
	local InventoryServiceCache = nil
	local LoggedFilteredNames = {}

	local function loadInventoryService()
		if InventoryServiceCache then return InventoryServiceCache end

		local ok, loader = pcall(function()
			local src = ReplicatedStorage:WaitForChild("src", 8)
			return src and require(src:WaitForChild("Loader", 8))
		end)
		if not ok or not loader then
			pushLog("WARN", "Inventory", "Loader not found in ReplicatedStorage.src")
			return nil
		end

		local svc
		local ok1, r1 = pcall(function()
			return loader.load_client_service(nil, "ItemInventoryServiceClient")
		end)
		if ok1 and r1 then svc = r1 end

		if not svc then
			local ok2, r2 = pcall(function()
				return loader.load_client_service(script, "ItemInventoryServiceClient")
			end)
			if ok2 and r2 then svc = r2 end
		end

		if not svc then
			pushLog("WARN", "Inventory", "ItemInventoryServiceClient could not be loaded")
			return nil
		end

		InventoryServiceCache = svc
		pushLog("INFO", "Inventory", "ItemInventoryServiceClient loaded")
		return svc
	end

	-- key ที่เป็น GUID / UUID (unique_items มักใช้ GUID เป็น key และเก็บชื่อจริงไว้ใน item_id)
	local function looksLikeGuid(k)
		if type(k) ~= "string" or #k < 20 then return false end
		return string.match(k, "^[%x%-%{%}]+$") ~= nil
	end

	local function tableFromItems(result, items)
		if type(result) ~= "table" then return end
		for k, v in pairs(result) do
			local amount = v
			local key = tostring(k)
			if type(v) == "table" then
				amount = v.amount or v.count or v.value or v.Quantity or v.qty or v.Amount or 1
				local id = v.item_id or v.id or v.name or v.ItemId or v.itemId
				-- แก้บั๊ก: ไอเท็ม unique ที่ key เป็น GUID เดิมถูกนับด้วยชื่อ GUID (ไม่ใช่ชื่อไอเท็มจริง)
				if type(id) == "string" and id ~= "" and (tonumber(k) or looksLikeGuid(k)) then
					key = id
				end
			end
			items[key] = (items[key] or 0) + (tonumber(amount) or 0)
		end
	end

	local function readNormalItems()
		local items = {}
		local readOk = false
		safeCall("InventoryRead", function()
			local svc = loadInventoryService()
			if not svc then return end
			local session = svc.session
			if not session then
				pushLog("WARN", "Inventory", "svc.session is nil")
				return
			end
			local inv = session.inventory
			if not inv then
				pushLog("WARN", "Inventory", "session.inventory is nil")
				return
			end
			local profile = inv.inventory_profile_data
			if not profile then
				pushLog("WARN", "Inventory", "inventory_profile_data is nil")
				return
			end
			-- normal_items = Bean, Fruit, Key ฯลฯ
			tableFromItems(profile.normal_items, items)
			-- unique_items = Portal / ไอเท็มพิเศษ
			tableFromItems(profile.unique_items, items)
			readOk = true
		end)
		return items, readOk
	end

	local function countKeys(t)
		local n = 0
		for _ in pairs(t or {}) do n = n + 1 end
		return n
	end

	local function isResourceDropName(name)
		local n = string.lower(tostring(name or ""))
		n = n:gsub("[%s_%-]", ""):gsub("reward", ""):gsub("amount", "")
		return n == "gem" or n == "gems" or n == "gold"
			or n == "summerpearl" or n == "summerpearls"
			or n == "xp" or n == "exp" or n == "playerxp"
	end

	local function isCurrencyName(name)
		local n = string.lower(tostring(name or ""))
		n = n:gsub("[%s_%-]", "")
		if n == "" then return true end

		-- ทรัพยากร 4 ประเภทนี้ตั้งใจให้นับเป็นดรอป
		if isResourceDropName(n) then return false end

		if n:find("summerpearl") or n == "pearls" or n == "pearl" then return true end
		if n:find("gem") or n:find("gold") or n:find("trophy") then return true end
		if n == "xp" or n == "exp" or n:find("playerxp") or n:find("xpreward") or n:find("levelreward") then return true end
		if n:find("legacy") then return true end
		if n == "money" or n == "cash" then return true end
		if n:find("victory") or n:find("defeat") or n:find("wave") or n:find("timer") then return true end
		if n:find("damage") or n:find("dps") or n:find("yen") or n:find("reward") then return true end
		if n:find("click") or n:find("button") or n:find("frame") or n:find("label") then return true end
		if n:find("playergui") or n:find("screen") or n:find("text") then return true end
		return false
	end

	local function isKnownDropItem(name)
		local n = string.lower(tostring(name or ""))
		-- ไอเท็มดรอปที่พบบ่อยใน AA
		local keys = {
			"bean", "senzu", "fruit", "starfruit", "coffee", "candy", "fish",
			"key", "portal", "talisman", "mask", "finger", "potion", "luck",
			"cube", "charm", "remnant", "token", "ticket", "capsule",
			"arrancar", "sukuna", "jjk", "hxh", "fairy", "soul", "dungeon",
			"exp", "xp_food", "food", "shard", "ore", "ingot", "scroll",
			"wing", "horn", "skull", "tail", "tome", "chapter", "heart",
		}
		for _, k in ipairs(keys) do
			if n:find(k, 1, true) then return true end
		end
		return false
	end

	-- ชื่อ UI ล้วน ๆ (ต้องตรงเป๊ะ) ที่ไม่ใช่ไอเท็ม
	-- แก้บั๊ก: เดิมใช้ substring (gem/gold/frame/label/text/reward/yen ฯลฯ) ทำให้ไอเท็มจริงที่ชื่อมีคำเหล่านี้โดนกรองทิ้ง
	local UI_NOISE = {
		frame = true, template = true, item = true, items = true, itemframe = true,
		itemtemplate = true, imagelabel = true, imagebutton = true, textlabel = true,
		textbutton = true, button = true, label = true, holder = true, content = true,
		container = true, main = true, background = true, bg = true, icon = true,
		image = true, amount = true, title = true, name = true, slot = true, card = true,
		reward = true, rewards = true, scrollingframe = true, uilistlayout = true,
		uigridlayout = true, uipadding = true, uistroke = true, uicorner = true,
		money = true, cash = true, trophy = true, trophies = true, legacygem = true,
		legacygems = true, victory = true, defeat = true, damage = true, dps = true,
		yen = true, timer = true, wave = true, waves = true, level = true,
	}

	local function isPlausibleItemName(name)
		if not name or name == "" then return false end
		local n = tostring(name)
		-- ทรัพยากรที่ผู้ใช้ระบุให้ผ่านเป็นดรอปโดยตรง
		if isResourceDropName(n) then return true end
		if #n > 64 then return false end
		if not n:find("%a") then return false end
		if select(2, n:gsub(" ", "")) >= 6 then return false end
		local k = string.lower(n):gsub("[%s_%-]", "")
		if k == "" or UI_NOISE[k] then return false end
		-- ข้อความหน้าสรุปผลที่ไม่ใช่ไอเท็ม
		if k:find("^victory") or k:find("^defeat") or k:find("^wavescompleted")
			or k:find("^totaltime") or k:find("^playergui") or k:find("^levelreward") then
			return false
		end
		return true
	end

	local function diffInventory()
		local after, afterOk = readNormalItems()
		local before = InventorySnap.before

		if not before or not InventorySnap.beforeOk then
			pushLog("INFO", "InventoryDiff", "skip drops — no before-snapshot")
			return {}
		end
		if not afterOk then
			pushLog("INFO", "InventoryDiff", "skip drops — after-snapshot unreadable")
			return {}
		end

		local gained = {}
		local keys = {}
		for k in pairs(after) do keys[k] = true end
		for k in pairs(before) do keys[k] = true end

		for k in pairs(keys) do
			local a = after[k] or 0
			local b = before[k] or 0
			local delta = a - b
			if delta > 0 then
				-- inventory คือข้อมูลจริงของเกม: เชื่อถือได้ ไม่ต้องกรองด้วยชื่อ
				-- แก้บั๊ก: เดิมตัดทิ้งถ้า delta > 99 ทำให้ไอเท็มที่ได้เป็นจำนวนมากไม่แจ้งเตือน
				if delta < 1e7 then
					table.insert(gained, { name = tostring(k), amount = delta })
				else
					pushLog("WARN", "InventoryDiff", string.format("ignore huge delta: %s (%s)", tostring(k), tostring(delta)))
				end
			end
		end

		table.sort(gained, function(x, y) return x.name < y.name end)
		if #gained > 0 then
			pushLog("INFO", "InventoryDiff", "items gained: " .. tostring(#gained))
			for _, d in ipairs(gained) do
				print("[AA Monitor]   drop+", d.name, d.amount)
			end
		end
		return gained
	end

	-------------------------------------------------
	-- Live drop collector (Optional)
	-------------------------------------------------
	local LiveDrops = { list = {} }

	local function rememberDrop(name, amount)
		if not isPlausibleItemName(name) then return end
		local amt = tonumber(amount) or 1
		if amt <= 0 or amt >= 99999 then return end
		name = tostring(name)
		for _, d in ipairs(LiveDrops.list) do
			if d.name == name and (os.clock() - (d.at or 0)) < 8 then
				d.amount = (d.amount or 0) + amt
				return
			end
		end
		table.insert(LiveDrops.list, { name = name, amount = amt, at = os.clock() })
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
		if string.find(t, "%+%s*%d+") or string.find(low, "x%s*%d+") or string.find(low, "×%s*%d+") then
			return true
		end
		return false
	end

	local function parseDropText(text)
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
		local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if not pg then return end

		local function scanLabel(label)
			if not label or (not label:IsA("TextLabel") and not label:IsA("TextButton")) then return end
			local t = label.Text
			if not textLooksLikeDrop(t) then return end
			local name, amt = parseDropText(t)
			if name then rememberDrop(name, amt) end
		end

		local function hookGui(gui)
			if not gui then return end
			trackConn(gui.DescendantAdded:Connect(function(desc)
				if not isAlive then return end
				if desc:IsA("TextLabel") or desc:IsA("TextButton") then
					task.defer(function()
						if isAlive then scanLabel(desc) end
					end)
				end
			end))
			for _, d in ipairs(gui:GetDescendants()) do
				if d:IsA("TextLabel") or d:IsA("TextButton") then
					trackConn(d:GetPropertyChangedSignal("Text"):Connect(function()
						if isAlive then scanLabel(d) end
					end))
				end
			end
		end

		local watchNames = {
			"Notifications", "Notification", "Notify", "Toasts", "Toast",
			"DropNotification", "ItemNotification", "RewardsNotification",
			"Message", "Messages", "Prompt", "Awards", "Loot",
		}
		for _, name in ipairs(watchNames) do
			local g = pg:FindFirstChild(name)
			if g then hookGui(g) end
		end

		trackConn(pg.ChildAdded:Connect(function(child)
			if not isAlive then return end
			local n = string.lower(child.Name)
			for _, w in ipairs(watchNames) do
				if n == string.lower(w) or n:find("notif") or n:find("toast") or n:find("drop") or n:find("loot") then
					task.defer(function()
						if isAlive then hookGui(child) end
					end)
					break
				end
			end
		end))

		pushLog("INFO", "LiveDrop", "Drop watcher ready")
	end

	-------------------------------------------------
	-- Snapshot Adapter
	-------------------------------------------------
	local SnapshotAdapter = {}

	function SnapshotAdapter.getResources()
		local stats = LocalPlayer and LocalPlayer:FindFirstChild("_stats")
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
			gems         = val("gem_amount"),
			gold         = val("gold_amount"),
			summerPearls = summer,
			legacyGems   = legacy,
			playerXp     = playerXp,
			level        = val("level") or val("player_level"),
		}
	end

	local function snapshotInventory(tag)
		local items, ok = readNormalItems()
		if ok then
			InventorySnap.before = items
			InventorySnap.beforeOk = true
		else
			-- อ่าน inventory ไม่สำเร็จ: ห้ามเก็บเป็น snapshot ว่าง ไม่งั้น retry จะไม่ทำงาน
			-- และทุกไอเท็มจะถูกนับเป็นของใหม่/หรือถูกข้ามทั้งรอบ
			if not InventorySnap.beforeOk then
				InventorySnap.before = nil
			end
		end
		InventorySnap.beforeResources = SnapshotAdapter.getResources()
		pushLog(ok and "INFO" or "WARN", "Snapshot", string.format(
			"Inventory snapshot (%s) ok=%s = %d items",
			tostring(tag), tostring(ok), countKeys(items)
		))
	end

	function SnapshotAdapter.getHUD()
		local gui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if not gui then return {} end
		local lives = safeGet(gui, {"spawn_units", "Lives"})
		local levelText = nil
		if lives then
			levelText = getText(safeGet(lives, {"Main", "Desc", "Level"}))
		end
		if not levelText then
			for _, d in ipairs(gui:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name == "Level" and d.Text and d.Text ~= "" then
					levelText = d.Text
					break
				end
			end
		end
		return { levelText = levelText }
	end

	function SnapshotAdapter.getMatchInfo()
		local info = {
			mapName    = nil,
			mode       = nil,
			difficulty = nil,
			act        = nil,
			wave       = nil,
			waveMax    = nil,
			weather    = nil,
			modifiers  = {},
		}

		local mapConfig = Workspace:FindFirstChild("_MAP_CONFIG") or Workspace:FindFirstChild("MAP_CONFIG")
		if mapConfig then
			for _, key in ipairs({"MapName", "map_name", "Name", "StageName", "stage_name"}) do
				local v = mapConfig:FindFirstChild(key)
				if v and v:IsA("ValueBase") then info.mapName = tostring(v.Value) break end
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
		readWaveFrom(Workspace)
		pcall(function() readWaveFrom(ReplicatedStorage) end)

		local gui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
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
		local gui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if not gui then return units end
		local spawn = gui:FindFirstChild("spawn_units")
		if not spawn then return units end

		local unitsFolder = safeGet(spawn, {"Lives", "Frame", "Units"})
			or safeGet(spawn, {"Lives", "Units"})
			or spawn:FindFirstChild("Units", true)

		local function pushUnit(btn)
			if not btn then return end
			local name = nil
			local level = nil
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

	function SnapshotAdapter.getResults(ignoreEnabledCheck)
		local gui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if not gui then return nil end
		local resultsUI = gui:FindFirstChild("ResultsUI")
		if not resultsUI then return nil end
		if not ignoreEnabledCheck and resultsUI:IsA("ScreenGui") and not resultsUI.Enabled then
			return nil
		end
		local holder = resultsUI:FindFirstChild("Holder")
		if not holder then return nil end

		local data = {
			result       = getText(holder:FindFirstChild("Title")),
			waves        = nil,
			time         = nil,
			gold         = nil,
			gems         = nil,
			xp           = nil,
			summerPearls = nil,
			trophy       = nil,
			drops        = {},
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

		local skipNames = {
			GoldReward = true, GemReward = true, XPReward = true, TrophyReward = true,
			SummerPearlReward = true, SummerPearlsReward = true,
			Title = true, Middle = true, Timer = true, WavesCompleted = true,
			LevelRewards = true, GoldGemXP = true, Holder = true, UIListLayout = true,
			UIPadding = true, UIStroke = true, UICorner = true, Main = true, Amount = true,
		}

		-- หาชื่อไอเท็มจาก Frame: ลอง Title/ItemName/Name ก่อน แล้วค่อยหา TextLabel อื่นที่ไม่ใช่ตัวเลข
		-- แก้บั๊ก: เดิมถ้าไม่เจอ label จะใช้ชื่อ Frame (เช่น "Frame") ซึ่งโดนกรองทิ้งเงียบ ๆ
		local function resolveItemName(frame)
			local label = getText(safeGet(frame, {"Main", "Title"}))
				or getText(frame:FindFirstChild("Title"))
				or getText(frame:FindFirstChild("ItemName"))
				or getText(frame:FindFirstChild("Name"))
				or getText(safeGet(frame, {"Main", "ItemName"}))
			if label and label ~= "" then return label end

			for _, d in ipairs(frame:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name ~= "Amount" and d.Text and d.Text ~= "" then
					local t = d.Text
					if not string.match(t, "^[%s%d%+xX×%.,KMBkmb]+$") then
						return t
					end
				end
			end

			local okA, attr = pcall(function()
				return frame:GetAttribute("ItemName") or frame:GetAttribute("item_id")
					or frame:GetAttribute("ItemId") or frame:GetAttribute("Name")
			end)
			if okA and type(attr) == "string" and attr ~= "" then return attr end

			return frame.Name
		end

		-- รวมดรอปตามชื่อ: ถ้าเจอซ้ำให้เก็บค่าที่มากกว่า (เดิม "ตัวแรกชนะ" ทำให้จำนวนจริงจาก deep scan ถูกบล็อกด้วย 1)
		local dropIndex = {}
		local function pushDrop(name, amount)
			if not name or name == "" then return end
			name = tostring(name):gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" then return end
			if skipNames[name] then return end
			if not isPlausibleItemName(name) then
				if not LoggedFilteredNames[name] then
					LoggedFilteredNames[name] = true
					pushLog("INFO", "ResultsDrop", "filtered name: " .. tostring(name))
				end
				return
			end
			local low = string.lower(name)
			if low:find("reward") then return end
			local amt = tonumber(amount)
			if not amt or amt <= 0 or amt >= 99999 then return end
			local existing = dropIndex[name]
			if existing then
				if amt > existing.amount then existing.amount = amt end
				return
			end
			local entry = { name = tostring(name), amount = amt }
			dropIndex[name] = entry
			table.insert(data.drops, entry)
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
							amt = parseNumber(cleaned or amountText)
						end
						local name = resolveItemName(child)
						pushDrop(name, amt or 1)
					end
				end
			end
		end

		if levelRewards then
			scanRewardFrame(levelRewards)
		end

		-- ตรวจจับ Summer Pearls จาก ResultsUI
		local summerPearlReward = safeGet(levelRewards, {"SummerPearlReward"})
			or safeGet(levelRewards, {"SummerPearlsReward"})
			or safeGet(holder, {"SummerPearlReward"})
			or safeGet(holder, {"SummerPearlsReward"})
		if not summerPearlReward and levelRewards then
			for _, child in ipairs(levelRewards:GetChildren()) do
				local low = string.lower(child.Name)
				if low:find("summer") and low:find("pearl") then
					summerPearlReward = child
					break
				end
			end
		end
		if summerPearlReward then
			data.summerPearls = readAmount(summerPearlReward)
		end

		-- บันทึก Gems, Gold, XP, SummerPearls เข้า itemDrops ตามระบบเดิม
		local function pushResourceDrop(name, amount)
			local amt = parseNumber(amount)
			if amt and amt > 0 and amt ~= 99999 and amt < 1e12 then
				table.insert(data.drops, { name = name, amount = amt })
			end
		end
		pushResourceDrop("Gold", data.gold)
		pushResourceDrop("Gems", data.gems)
		pushResourceDrop("XP", data.xp)
		pushResourceDrop("SummerPearls", data.summerPearls)

		local itemRewards = holder:FindFirstChild("ItemRewards")
			or holder:FindFirstChild("Items")
			or holder:FindFirstChild("Drops")
			or safeGet(holder, {"Rewards", "ScrollingFrame"})
		if itemRewards then
			scanRewardFrame(itemRewards)
		end

		-- Deep scan: เผื่อไอเท็มอยู่ใน Frame/ชื่อที่โค้ดข้างบนไม่ได้ดู
		if SETTINGS.DeepScanResults then
			for _, d in ipairs(holder:GetDescendants()) do
				local isAmountLabel = d:IsA("TextLabel") and (
					d.Name == "Amount" or d.Name == "Count" or d.Name == "Quantity"
					or d.Name == "Qty" or d.Name == "ItemAmount"
					or string.match(d.Text or "", "^%s*[xX×]%s*%d+%s*$") ~= nil
				)
				if isAmountLabel then
					local frame = d.Parent
					if frame and frame.Name == "Main" and frame.Parent then
						frame = frame.Parent
					end
					if frame and frame ~= holder and not skipNames[frame.Name] then
						local name = resolveItemName(frame)
						local cleaned = cleanRewardText(d.Text)
						local amt = cleaned and parseNumber(cleaned) or nil
						if amt then pushDrop(name, amt) end
					end
				end
			end
		end

		return data
	end

	function SnapshotAdapter.capture(extraDrops, cachedResults)
		local matchInfo = {}
		local units = {}
		safeCall("CaptureMatch", function() matchInfo = SnapshotAdapter.getMatchInfo() end)
		safeCall("CaptureUnits", function() units = SnapshotAdapter.getUnits() end)

		local drops = (type(extraDrops) == "table") and extraDrops or {}
		local resResults = cachedResults or SnapshotAdapter.getResults(true)

		return {
			timestamp   = os.time(),
			isoTime     = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()),
			placeId     = game.PlaceId,
			jobId       = game.JobId,
			playerName  = LocalPlayer and LocalPlayer.Name or "Unknown",
			displayName = LocalPlayer and LocalPlayer.DisplayName or "Unknown",
			userId      = LocalPlayer and LocalPlayer.UserId or 0,
			resources   = SnapshotAdapter.getResources(),
			hud         = SnapshotAdapter.getHUD(),
			match       = matchInfo,
			units       = units,
			results     = resResults,
			itemDrops   = drops,
		}
	end

	-------------------------------------------------
	-- Format (Plain & Discord Embed)
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
		table.insert(lines, string.format("Player `%s` · Place `%s` · %s", tostring(snap.playerName), tostring(snap.placeId), os.date("%H:%M:%S", snap.timestamp)))

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
			if r.summerPearls then table.insert(lines, "· Summer Pearls " .. tostring(r.summerPearls)) end
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
		elseif resultText and resultText ~= "" then
			title = resultText
		else
			title = "Stage Report"
		end

		local fields = {}

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
			if r.summerPearls then table.insert(rewards, "🫧  " .. tostring(r.summerPearls)) end
			if r.trophy then table.insert(rewards, "🏆  " .. tostring(r.trophy)) end
		end
		table.insert(fields, {
			name = "Run Rewards",
			value = (#rewards > 0) and table.concat(rewards, "\n") or "_none_",
			inline = true,
		})

		if snap.itemDrops and #snap.itemDrops > 0 then
			local maxShow = SETTINGS.MaxEmbedDrops or 40
			local shown = math.min(#snap.itemDrops, maxShow)
			local chunk, chunkLen, part = {}, 0, 1
			local function flushChunk()
				if #chunk == 0 then return end
				table.insert(fields, {
					name = (part == 1) and "Item Drops" or "Item Drops (cont.)",
					value = table.concat(chunk, "\n"),
					inline = false,
				})
				part = part + 1
				chunk, chunkLen = {}, 0
			end
			for i = 1, shown do
				local d = snap.itemDrops[i]
				local line = string.format("▸ `%s`　**+%s**", tostring(d.name), tostring(d.amount))
				-- Discord จำกัดค่าใน field ที่ 1024 ตัวอักษร: เกินก็แตกเป็น field ใหม่
				if chunkLen + #line + 1 > 1000 then flushChunk() end
				table.insert(chunk, line)
				chunkLen = chunkLen + #line + 1
			end
			flushChunk()
			if #snap.itemDrops > shown then
				table.insert(fields, {
					name = "Item Drops (more)",
					value = string.format("_…and %d more_", #snap.itemDrops - shown),
					inline = false,
				})
			end
		end

		local embed = {
			author = {
				name = string.format("Anime Adventures · %s", tostring(snap.playerName or "Player")),
				icon_url = SETTINGS.AvatarUrl,
			},
			title = title,
			color = color,
			fields = fields,
			thumbnail = {
				url = SETTINGS.AvatarUrl,
			},
			image = {
				url = "https://tr.rbxcdn.com/180DAY-bd4fbfaf530e5a1f2f4a053791448977/768/432/Image/Png/noFilter",
			},
			footer = {
				text = string.format("%s  ·  %s", tostring(snap.placeId), os.date("%d/%m %H:%M", snap.timestamp)),
				icon_url = SETTINGS.AvatarUrl,
			},
		}

		return {
			username = SETTINGS.Username,
			avatar_url = SETTINGS.AvatarUrl,
			embeds = { embed },
		}
	end

	-------------------------------------------------
	-- HTTP Engine with Status Check, Retry & Response Log
	-------------------------------------------------
	local function getHttpBackends()
		local list = {}
		if type(syn) == "table" and type(syn.request) == "function" then
			table.insert(list, { name = "syn.request", fn = syn.request })
		end
		if type(http) == "table" and type(http.request) == "function" then
			table.insert(list, { name = "http.request", fn = http.request })
		end
		if type(http_request) == "function" then
			table.insert(list, { name = "http_request", fn = http_request })
		end
		if type(request) == "function" then
			table.insert(list, { name = "request", fn = request })
		end
		if type(fluxus) == "table" and type(fluxus.request) == "function" then
			table.insert(list, { name = "fluxus.request", fn = fluxus.request })
		end
		return list
	end

	local function executeHttpJson(label, url, method, payloadTable)
		local cleanPayload = sanitizeForJson(payloadTable)
		local okEncode, body = pcall(function()
			return HttpService:JSONEncode(cleanPayload)
		end)
		if not okEncode or not body then
			local errMsg = "JSONEncode failed: " .. tostring(body)
			pushLog("ERROR", label, errMsg)
			return false, { ok = false, statusCode = 0, error = errMsg }
		end

		local backends = getHttpBackends()
		if #backends == 0 then
			local startT = os.clock()
			local okPost, resPost = pcall(function()
				return HttpService:RequestAsync({
					Url = url,
					Method = method or "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = body,
				})
			end)
			local elapsed = math.floor((os.clock() - startT) * 1000)
			if okPost and type(resPost) == "table" and resPost.Success then
				local info = {
					ok = true,
					statusCode = resPost.StatusCode,
					statusMessage = resPost.StatusMessage,
					body = tostring(resPost.Body or ""):sub(1, 300),
					elapsedMs = elapsed,
					provider = "HttpService:RequestAsync",
				}
				pushLog("INFO", label, string.format("HTTP %d (%dms) via RequestAsync", info.statusCode, elapsed), info)
				return true, info
			else
				local errMsg = okPost and string.format("HTTP %s: %s", tostring(resPost and resPost.StatusCode), tostring(resPost and resPost.Body)) or tostring(resPost)
				pushLog("ERROR", label, "RequestAsync failed: " .. errMsg)
				return false, { ok = false, statusCode = (type(resPost) == "table" and resPost.StatusCode) or 0, error = errMsg, elapsedMs = elapsed }
			end
		end

		local lastDiag = nil
		for attempt = 1, SETTINGS.MaxHttpRetries do
			local backend = backends[((attempt - 1) % #backends) + 1]
			local startT = os.clock()
			local okCall, res = pcall(function()
				return backend.fn({
					Url = url,
					Method = method or "POST",
					Headers = {
						["Content-Type"] = "application/json",
						["Accept"] = "application/json",
					},
					Body = body,
				})
			end)
			local elapsed = math.floor((os.clock() - startT) * 1000)

			if okCall and type(res) == "table" then
				local code = tonumber(res.StatusCode) or 0
				local resBody = tostring(res.Body or "")
				local isSuccess = (code >= 200 and code < 300) or (res.Success == true and code == 0)

				lastDiag = {
					ok            = isSuccess,
					statusCode    = code,
					statusMessage = tostring(res.StatusMessage or ""),
					body          = resBody:sub(1, 300),
					elapsedMs     = elapsed,
					attempt       = attempt,
					provider      = backend.name,
				}

				if isSuccess then
					pushLog("INFO", label, string.format("HTTP %d OK (%dms) [attempt %d via %s]", code, elapsed, attempt, backend.name), lastDiag)
					return true, lastDiag
				end

				local retryAfter = SETTINGS.RetryBaseDelay * attempt
				if type(res.Headers) == "table" then
					local ra = res.Headers["retry-after"] or res.Headers["Retry-After"] or res.Headers["x-ratelimit-reset-after"]
					if tonumber(ra) then
						retryAfter = math.clamp(tonumber(ra) + 0.25, 0.5, 15)
					end
				end

				pushLog("WARN", label, string.format("HTTP %d (%s) [attempt %d/%d via %s] Body: %s",
					code, tostring(res.StatusMessage or ""), attempt, SETTINGS.MaxHttpRetries, backend.name, resBody:sub(1, 180)), lastDiag)

				if attempt < SETTINGS.MaxHttpRetries then
					task.wait(retryAfter)
				end
			else
				local errStr = tostring(res)
				lastDiag = {
					ok         = false,
					statusCode = 0,
					error      = errStr,
					elapsedMs  = elapsed,
					attempt    = attempt,
					provider   = backend.name,
				}
				pushLog("WARN", label, string.format("Transport error [attempt %d/%d via %s]: %s",
					attempt, SETTINGS.MaxHttpRetries, backend.name, errStr), lastDiag)
				if attempt < SETTINGS.MaxHttpRetries then
					task.wait(SETTINGS.RetryBaseDelay * attempt)
				end
			end
		end

		pushLog("ERROR", label, string.format("All %d attempts failed (Last HTTP %s)", SETTINGS.MaxHttpRetries, tostring(lastDiag and lastDiag.statusCode or 0)), lastDiag)
		return false, lastDiag
	end

	-------------------------------------------------
	-- Senders (Discord Webhook & Firebase API)
	-------------------------------------------------
	local function rawHttpPost(url, body)
		-- ยิงตรง ๆ ทุกช่องทางที่ executor มี — ไม่พึ่ง wrapper เดียว
		local attempts = {}
		local function try(name, fn)
			local ok, res = pcall(fn)
			local code = 0
			if ok and type(res) == "table" then
				code = tonumber(res.StatusCode or res.Status or 0) or 0
				if code >= 200 and code < 300 then
					return true, name, code, res
				end
				return false, name, code, res
			elseif ok and res == true then
				return true, name, 200, res
			end
			return false, name, 0, res
		end

		if type(syn) == "table" and type(syn.request) == "function" then
			table.insert(attempts, function()
				return try("syn.request", function()
					return syn.request({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
				end)
			end)
		end
		if type(http_request) == "function" then
			table.insert(attempts, function()
				return try("http_request", function()
					return http_request({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
				end)
			end)
		end
		if type(request) == "function" then
			table.insert(attempts, function()
				return try("request", function()
					return request({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
				end)
			end)
		end
		if type(http) == "table" and type(http.request) == "function" then
			table.insert(attempts, function()
				return try("http.request", function()
					return http.request({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
				end)
			end)
		end
		table.insert(attempts, function()
			return try("RequestAsync", function()
				return HttpService:RequestAsync({
					Url = url, Method = "POST",
					Headers = { ["Content-Type"] = "application/json" },
					Body = body,
				})
			end)
		end)
		table.insert(attempts, function()
			return try("PostAsync", function()
				HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
				return { StatusCode = 200 }
			end)
		end)

		local last = nil
		for _, fn in ipairs(attempts) do
			local ok, name, code, res = fn()
			last = { ok = ok, name = name, code = code, res = res }
			print(string.format("[AA Monitor] HTTP try %s → ok=%s code=%s", tostring(name), tostring(ok), tostring(code)))
			if ok then return true, last end
		end
		return false, last
	end

	local function sendWebhookPayload(payload)
		if not WEBHOOK_URL or WEBHOOK_URL == "" or string.find(WEBHOOK_URL, "YOUR_ID") then
			pushLog("WARN", "Webhook", "WEBHOOK_URL is empty or placeholder")
			return false
		end

		local body
		local okE, encoded = pcall(function()
			return HttpService:JSONEncode(sanitizeForJson(payload))
		end)
		if not okE then
			pushLog("ERROR", "Webhook", "JSON encode failed: " .. tostring(encoded))
			return false
		end
		body = encoded

		-- ทางหลัก
		local ok, diag = executeHttpJson("Webhook", WEBHOOK_URL, "POST", payload)
		if not ok then
			print("[AA Monitor] executeHttpJson failed → fallback rawHttpPost")
			ok, diag = rawHttpPost(WEBHOOK_URL, body)
			if type(diag) == "table" then
				diag = { ok = ok, statusCode = diag.code, provider = diag.name }
			end
		end

		MonitorStats.lastWebhookRes = diag
		if ok then
			MonitorStats.webhookSent = MonitorStats.webhookSent + 1
			print("[AA Monitor] ✅ Webhook SENT")
		else
			MonitorStats.webhookFailed = MonitorStats.webhookFailed + 1
			print("[AA Monitor] ❌ Webhook FAILED")
		end
		return ok and true or false
	end

	local function sendToWeb(snap)
		if not FIREBASE_ENABLED then return false end
		if not FIREBASE_URL or FIREBASE_URL == "" then
			pushLog("WARN", "FirebaseAPI", "FIREBASE_URL is empty")
			return false
		end

		local base = tostring(FIREBASE_URL):gsub("/+$", "")
		local path = tostring(FIREBASE_PATH or "AA_Drops"):gsub("^/+", ""):gsub("/+$", "")
		local uid  = tostring(snap.userId or (LocalPlayer and LocalPlayer.UserId) or "0")
		local url  = string.format("%s/%s/%s.json", base, path, uid)

		local payload = {
			timestamp   = snap.timestamp or os.time(),
			isoTime     = snap.isoTime or os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()),
			userId      = snap.userId,
			playerName  = snap.playerName,
			displayName = snap.displayName,
			placeId     = snap.placeId,
			resources   = snap.resources or {},
			hud         = snap.hud or {},
			match       = snap.match or {},
			results     = snap.results or {},
			itemDrops   = snap.itemDrops or {},
		}

		local ok, diag = executeHttpJson("FirebaseAPI", url, "POST", payload)
		MonitorStats.lastApiRes = diag
		if ok then
			MonitorStats.firebaseSent = MonitorStats.firebaseSent + 1
		else
			MonitorStats.firebaseFailed = MonitorStats.firebaseFailed + 1
		end
		return ok
	end

	local function sendReport(snap)
		task.spawn(function()
			safeCall("SendFirebase", sendToWeb, snap)
		end)

		local payload = SETTINGS.UseEmbed
			and SnapshotAdapter.formatEmbed(snap)
			or {
				content    = SnapshotAdapter.formatPlain(snap),
				username   = SETTINGS.Username,
				avatar_url = SETTINGS.AvatarUrl,
			}

		local ok, sent = safeCall("SendWebhook", sendWebhookPayload, payload)
		return ok and sent or false
	end

	-------------------------------------------------
	-- Report Entrypoint
	-------------------------------------------------
	local function report(reason, extraDrops, cachedResults)
		reason = reason or "manual"
		local isForced = tostring(reason):find("^force") ~= nil

		local hasDrops = type(extraDrops) == "table" and #extraDrops > 0
		if not isForced and not isInMatch() and not cachedResults and not hasDrops then
			pushLog("INFO", "Report", "skip — in lobby (no cached results/drops)")
			return nil
		end

		local snap = SnapshotAdapter.capture(extraDrops, cachedResults)
		if SETTINGS.PrintToConsole then
			print("========== AA Report (" .. reason .. ") ==========")
			print(SnapshotAdapter.formatPlain(snap))
			print("================================================")
		end
		sendReport(snap)
		return snap
	end

	-------------------------------------------------
	-- Auto Detect (ทนทานต่อสคริปต์ออโต้ฟาร์มที่กดปิด ResultsUI เร็ว)
	-------------------------------------------------
	local function startAutoDetect()
		local playerGui = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui", 30)
		if not playerGui then
			pushLog("ERROR", "AutoDetect", "PlayerGui not found")
			return
		end

		local isProcessingStage = false
		local stageReportedThisRun = false
		local lastSendAt = 0
		local stageToken = 0
		local wasInMatch = false
		local matchEnteredAt = 0
		local enterGraceUntil = 0  -- ช่วงหลังเข้าแมพ ห้ามส่ง
		local lastSnapTry = 0

		local function hasValidResultsData(res)
			if not res then return false end
			if res.result and res.result ~= "" then
				local up = string.upper(res.result)
				if up:find("VICTORY") or up:find("DEFEAT") or up:find("WIN") or up:find("LOSE") or up:find("CLEAR") or up:find("RESULT") or up:find("STAGE") then
					return true
				end
			end
			if res.waves and parseNumber(res.waves) then return true end
			if res.gold or res.gems or res.xp or res.summerPearls then return true end
			return false
		end

		local function scoreResults(res)
			if not res then return 0 end
			local s = 0
			if res.result and res.result ~= "" then s = s + 2 end
			if res.waves and res.waves ~= "" then s = s + 2 end
			if res.time and res.time ~= "" then s = s + 1 end
			if res.gold then s = s + 2 end
			if res.gems then s = s + 2 end
			if res.xp then s = s + 2 end
			if res.summerPearls then s = s + 2 end
			if res.drops then s = s + #res.drops end
			return s
		end

		local function collectGained(bestResults, bestInvDiff)
			local gained = {}
			local seenSourceItems = {}

			local function isResourceDropName(n)
				local k = string.lower(tostring(n or "")):gsub("[%s_%-]", "")
				return k == "gems" or k == "gem" or k == "gold"
					or k == "summerpearls" or k == "summerpearl"
					or k == "xp" or k == "exp"
			end

			local function addDropEntry(sourceTag, name, amount)
				local n = tostring(name or "")
				local a = tonumber(amount) or 0
				if a <= 0 then return end
				local isRes = isResourceDropName(n)
				if isRes then
					-- ทรัพยากร (Gems/Gold/XP/Pearls): กรองเฉพาะ placeholder 99999 เป๊ะ ๆ
					if a == 99999 or a >= 1e12 then return end
				else
					-- inventory เชื่อถือได้ จึงเพดานสูงกว่า; ResultsUI ยังกัน placeholder 99999
					local cap = (sourceTag == "inv") and 1e7 or 99999
					if a >= cap then return end
					if not isPlausibleItemName(n) then return end
				end
				if not seenSourceItems[n] then seenSourceItems[n] = {} end
				local prev = seenSourceItems[n][sourceTag] or 0
				if a > prev then
					seenSourceItems[n][sourceTag] = a
				end
			end

			for _, d in ipairs(consumeLiveDrops()) do
				addDropEntry("live", d.name, d.amount)
			end
			if bestResults and type(bestResults.drops) == "table" then
				for _, d in ipairs(bestResults.drops) do
					addDropEntry("results", d.name, d.amount)
				end
			end
			for _, d in ipairs(bestInvDiff or {}) do
				addDropEntry("inv", d.name, d.amount)
			end
			if InventorySnap.beforeResources then
				local nowRes = SnapshotAdapter.getResources()
				local prevRes = InventorySnap.beforeResources
				local fallbackMap = {
					{ key = "gems", label = "Gems" },
					{ key = "gold", label = "Gold" },
					{ key = "summerPearls", label = "SummerPearls" },
					{ key = "playerXp", label = "XP" },
				}
				for _, item in ipairs(fallbackMap) do
					if not seenSourceItems[item.label] then
						local vAfter = tonumber(nowRes[item.key])
						local vBefore = tonumber(prevRes[item.key])
						if vAfter and vBefore and (vAfter - vBefore) > 0 and (vAfter - vBefore) ~= 99999 then
							addDropEntry("stats_delta", item.label, vAfter - vBefore)
						end
					end
				end
			end
			for itemName, bySource in pairs(seenSourceItems) do
				local finalAmt = 0
				for _, amt in pairs(bySource) do
					if amt > finalAmt then finalAmt = amt end
				end
				if finalAmt > 0 then
					table.insert(gained, { name = itemName, amount = finalAmt })
				end
			end
			table.sort(gained, function(x, y) return x.name < y.name end)
			return gained
		end

		local ALLOWED_REASONS = {
			results_enabled = true,
			results_text = true,
			results_removed = true, -- บางด่านปิด UI เร็ว ยังส่งจาก cache ได้
		}

		local function looksLikeEndResultText(t)
			if not t or t == "" then return false end
			local up = string.upper(tostring(t))
			-- อังกฤษ
			if up:find("VICTORY") or up:find("DEFEAT") or up:find("WIN") or up:find("LOSE") then return true end
			if up:find("CLEAR") or up:find("RESULT") or up:find("COMPLETE") or up:find("FAILED") then return true end
			if up:find("STAGE") and (up:find("END") or up:find("CLEAR")) then return true end
			-- ไทย / คำทั่วไป
			if tostring(t):find("ชนะ") or tostring(t):find("แพ้") or tostring(t):find("จบ") then return true end
			return false
		end

		local function readResultsSignals()
			local info = {
				hasUI = false,
				enabled = false,
				title = nil,
				waves = nil,
				hasReward = false,
				titleOk = false,
			}
			pcall(function()
				local pg = LocalPlayer:FindFirstChild("PlayerGui")
				local ui = pg and pg:FindFirstChild("ResultsUI")
				if not ui then return end
				info.hasUI = true
				info.enabled = (not ui:IsA("ScreenGui")) or ui.Enabled
				local holder = ui:FindFirstChild("Holder")
				if not holder then
					-- บางแมพโครงต่าง
					for _, d in ipairs(ui:GetDescendants()) do
						if d:IsA("TextLabel") then
							local n = string.lower(d.Name)
							local tx = d.Text or ""
							if n == "title" or looksLikeEndResultText(tx) then
								info.title = tx
							end
							if n:find("wave") or tx:lower():find("wave") then
								info.waves = tx
							end
						end
					end
				else
					local title = holder:FindFirstChild("Title")
					if title and title:IsA("TextLabel") then
						info.title = title.Text
					end
					local middle = holder:FindFirstChild("Middle")
					if middle then
						local w = middle:FindFirstChild("WavesCompleted")
						if w and w:IsA("TextLabel") then info.waves = w.Text end
					end
					-- reward frames
					local function anyAmount(root)
						if not root then return false end
						for _, d in ipairs(root:GetDescendants()) do
							if d:IsA("TextLabel") and d.Name == "Amount" and d.Text and d.Text ~= "" and not tostring(d.Text):find("99999") then
								return true
							end
						end
						return false
					end
					info.hasReward = anyAmount(holder:FindFirstChild("LevelRewards"))
						or anyAmount(holder:FindFirstChild("GoldGemXP"))
						or anyAmount(holder)
				end
				info.titleOk = looksLikeEndResultText(info.title)
			end)
			return info
		end

		local function finishStage(reason, force)
			reason = tostring(reason or "")
			if not ALLOWED_REASONS[reason] and not force then
				return
			end
			if not SETTINGS.AutoSendOnResults then return end
			if stageReportedThisRun or isProcessingStage then return end
			if (os.clock() - lastSendAt) < 18 then return end
			if os.clock() < enterGraceUntil then
				pushLog("INFO", "AutoDetect", "skip grace: " .. reason)
				return
			end
			if matchEnteredAt == 0 or (os.clock() - matchEnteredAt) < 10 then
				pushLog("INFO", "AutoDetect", "skip too early: " .. reason)
				return
			end

			local sig = readResultsSignals()
			local okEnd = sig.titleOk or (sig.hasReward and sig.waves) or (sig.hasReward and reason == "results_removed")
			if not okEnd and reason ~= "results_removed" then
				-- ยังไม่ชัดว่าจบ — ลองอ่าน adapter
				local r = SnapshotAdapter.getResults(true) or SnapshotAdapter.getResults(false)
				if r and (looksLikeEndResultText(r.result) or r.gems or r.xp or r.gold or (r.waves and r.waves ~= "")) then
					okEnd = true
				end
			end
			if not okEnd then
				pushLog("INFO", "AutoDetect", "skip not end-screen: " .. reason .. " title=" .. tostring(sig.title))
				return
			end

			-- ล็อกก่อน spawn งาน (กัน Results text/enabled/removed/teleport ยิงพร้อมกัน)
			isProcessingStage = true
			stageReportedThisRun = true
			lastSendAt = os.clock()
			stageToken = stageToken + 1
			local myToken = stageToken
			pushLog("INFO", "AutoDetect", "Finish ONCE (" .. tostring(reason) .. ")")

			task.spawn(function()
				-- 1) แคช Results ทันที (เฟรมแรก)
				local bestResults = SnapshotAdapter.getResults(true) or SnapshotAdapter.getResults(false)
				local invMap = {}   -- ชื่อ -> จำนวนสูงสุดที่เคยเห็นจาก inventory diff
				local resMap = {}   -- ชื่อ -> จำนวนสูงสุดที่เคยเห็นจาก ResultsUI

				local function mergeInv(list)
					local changed = false
					for _, d in ipairs(list or {}) do
						if (invMap[d.name] or 0) < (tonumber(d.amount) or 0) then
							invMap[d.name] = tonumber(d.amount)
							changed = true
						end
					end
					return changed
				end

				local function mergeRes(res)
					local changed = false
					if res and type(res.drops) == "table" then
						for _, d in ipairs(res.drops) do
							if (resMap[d.name] or 0) < (tonumber(d.amount) or 0) then
								resMap[d.name] = tonumber(d.amount)
								changed = true
							end
						end
					end
					return changed
				end

				local function mapToList(map)
					local out = {}
					for n, a in pairs(map) do
						table.insert(out, { name = n, amount = a })
					end
					table.sort(out, function(x, y) return x.name < y.name end)
					return out
				end

				mergeRes(bestResults)
				if SETTINGS.UseInventoryDiff then
					mergeInv(diffInventory())
				end

				-- 2) รอให้ของเข้ากระเป๋า/UI โหลดครบ: รอขั้นต่ำ แล้วรอต่อจนดรอปนิ่ง (มีเพดาน)
				local t0 = os.clock()
				local minDeadline = t0 + (force and 0.8 or SETTINGS.WaitAfterResults)
				local maxDeadline = t0 + (force and 0.8 or math.max(SETTINGS.MaxWaitAfterResults or 0, SETTINGS.WaitAfterResults))
				local settle = SETTINGS.SettleTime or 1.2
				local lastChange = t0
				local lastInvPoll = os.clock()

				while isAlive and myToken == stageToken do
					local now = os.clock()
					if now >= maxDeadline then break end
					if now >= minDeadline and (now - lastChange) >= settle then break end
					task.wait(0.15)

					local changed = false
					local curRes = SnapshotAdapter.getResults(true) or SnapshotAdapter.getResults(false)
					if curRes then
						if scoreResults(curRes) >= scoreResults(bestResults) then
							bestResults = curRes
						end
						if mergeRes(curRes) then changed = true end
					end
					if SETTINGS.UseInventoryDiff and (os.clock() - lastInvPoll) >= 0.45 then
						lastInvPoll = os.clock()
						if mergeInv(diffInventory()) then changed = true end
					end
					if changed then lastChange = os.clock() end
				end

				-- 3) รวมดรอปที่เก็บได้ทุกรอบเข้าไปใน results (กัน UI ปิดไปก่อน/โหลดทีละชิ้น)
				local mergedResDrops = mapToList(resMap)
				if bestResults then
					bestResults.drops = mergedResDrops
				end
				local finalInvDiff = mapToList(invMap)

				if not isAlive or myToken ~= stageToken then
					-- พยายามส่งด้วยของที่มี แม้สคริปต์กำลังตาย
					if bestResults or #finalInvDiff > 0 or #mergedResDrops > 0 or InventorySnap.beforeResources then
						if not bestResults then
							bestResults = { result = "STAGE_END", drops = mergedResDrops }
						end
						local gained = collectGained(bestResults, finalInvDiff)
						pcall(function() report("stage_end_dying", gained, bestResults) end)
					end
					isProcessingStage = false
					return
				end

				if not bestResults then
					bestResults = {
						result = "STAGE_END",
						waves = nil, time = nil,
						gold = nil, gems = nil, xp = nil, trophy = nil,
						drops = mergedResDrops,
					}
				elseif not bestResults.result or bestResults.result == "" then
					bestResults.result = "STAGE_END"
				end

				local gained = collectGained(bestResults, finalInvDiff)

				pushLog("INFO", "AutoDetect", string.format(
					"Send reason=%s drops=%d (results=%d inv=%d) waited=%.1fs",
					tostring(reason), #gained, #mergedResDrops, #finalInvDiff, os.clock() - t0
				))
				for _, g in ipairs(gained) do
					pushLog("INFO", "AutoDetect", string.format("  drop: %s x%s", tostring(g.name), tostring(g.amount)))
				end
				report("stage_end", gained, bestResults)
				isProcessingStage = false

				-- ไม่ปลดล็อกด้วยเวลา — ปลดตอนเข้าแมพใหม่เท่านั้น
			end)
		end

		-- ResultsUI hooks (ถ้ามี)
		local hookedResultsRefs = setmetatable({}, { __mode = "k" })
		local function hookResults(ui)
			if not ui or hookedResultsRefs[ui] then return end
			hookedResultsRefs[ui] = true
			if ui:IsA("ScreenGui") then
				trackConn(ui:GetPropertyChangedSignal("Enabled"):Connect(function()
					if not isAlive or not ui.Enabled then return end
					-- หน่วงนิดให้ Title/รางวัลโหลด แล้วค่อยตัดสิน
					task.delay(0.35, function()
						if not isAlive then return end
						finishStage("results_enabled")
					end)
				end))
				-- ไม่ยิง results_already_on (กันตอนเข้าด่าน/โหลด UI)
			end
			local function watchLabel(desc)
				if desc:IsA("TextLabel") and (desc.Name == "Title" or desc.Name == "WavesCompleted") then
					trackConn(desc:GetPropertyChangedSignal("Text"):Connect(function()
						if not isAlive or not desc.Text then return end
						local up = string.upper(desc.Text)
						if up:find("VICTORY") or up:find("DEFEAT") or up:find("WIN") or up:find("LOSE") or up:find("CLEAR") or desc.Name == "WavesCompleted" then
							finishStage("results_text")
						end
					end))
				end
			end
			for _, desc in ipairs(ui:GetDescendants()) do
				watchLabel(desc)
			end
			trackConn(ui.DescendantAdded:Connect(function(desc)
				if isAlive then watchLabel(desc) end
			end))
		end

		trackConn(playerGui.ChildAdded:Connect(function(child)
			if not isAlive then return end
			if child.Name == "ResultsUI" then
				hookResults(child)
			end
		end))
		trackConn(playerGui.ChildRemoved:Connect(function(child)
			if not isAlive then return end
			if child.Name == "ResultsUI" then
				finishStage("results_removed")
			end
		end))
		hookResults(playerGui:FindFirstChild("ResultsUI"))

		-- แกนหลัก: ติดตามเข้า/ออกแมพเอง ไม่พึ่ง ResultsUI อย่างเดียว
		task.spawn(function()
			while isAlive do
				task.wait(1)
				if not isAlive then break end
				local nowIn = isInMatch()

				if nowIn and not wasInMatch then
					wasInMatch = true
					matchEnteredAt = os.clock()
					enterGraceUntil = os.clock() + 10
					stageReportedThisRun = false
					isProcessingStage = false
					stageToken = stageToken + 1
					LiveDrops.list = {}
					-- ทิ้ง snapshot ของแมพก่อนหน้า กันนับดรอปเก่าปนรอบนี้
					InventorySnap.before = nil
					InventorySnap.beforeOk = false
					lastSnapTry = 0
					pushLog("INFO", "Match", "Entered match · grace 10s · send on end Results")
					task.delay(3, function()
						if isAlive and isInMatch() then
							snapshotInventory("match_start")
						end
					end)
				elseif nowIn and wasInMatch then
					-- ระหว่างแมพ: ถ้า Results โผล่ให้ finishStage จาก hook ด้านบน
					if not InventorySnap.beforeOk and (os.clock() - matchEnteredAt) > 4
						and (os.clock() - lastSnapTry) > 3 then
						lastSnapTry = os.clock()
						snapshotInventory("match_retry")
					end
				elseif (not nowIn) and wasInMatch then
					wasInMatch = false
					pushLog("INFO", "Match", "Left match · no auto-send (wait Results only)")
					task.delay(5, function()
						if isAlive and not isInMatch() then
							InventorySnap.before = nil
							InventorySnap.beforeOk = false
							InventorySnap.beforeResources = nil
						end
					end)
					matchEnteredAt = 0
				end
			end
		end)

		-- กันโดนเทเลพอร์ต/เด้งเกมก่อนส่ง: เริ่มยิงทันทีที่ Results โชว์ + flush ตอนออก
		-- ไม่ flush ตอนเทเลพอร์ต/ปิดเกม (กันยิงตอนเข้าด่าน)
		pushLog("INFO", "AutoDetect", "Ready · send ONLY on Victory/Defeat ResultsUI")
	end

	-------------------------------------------------
	-- Public API (_G.AA_Monitor)
	-------------------------------------------------
	local API = {
		Report    = function(reason) return report(reason or "force_test", {}, nil) end,
		Capture   = function() return SnapshotAdapter.capture({}, nil) end,
		Settings  = SETTINGS,
		Stats     = MonitorStats,
		GetLogs   = function(limit)
			limit = limit or 20
			local out = {}
			for i = math.max(1, #LogHistory - limit + 1), #LogHistory do
				local l = LogHistory[i]
				print(string.format("[%s][%s][%s] %s", l.time, l.level, l.tag, l.message))
				table.insert(out, l)
			end
			return out
		end,
		GetErrors = function(limit)
			limit = limit or 20
			local out = {}
			if #ErrorHistory == 0 then
				print("[AA Monitor] ไม่มี Error Log")
				return out
			end
			for i = math.max(1, #ErrorHistory - limit + 1), #ErrorHistory do
				local e = ErrorHistory[i]
				warn(string.format("[%s][%s][%s] %s", e.time, e.level, e.tag, e.message))
				table.insert(out, e)
			end
			return out
		end,
		ClearLogs = function()
			table.clear(LogHistory)
			table.clear(ErrorHistory)
			print("[AA Monitor] Logs cleared")
		end,
		Stop      = cleanupAll,
		-- ใช้ดีบั๊ก: เรียกตอนหน้า Results ยังเปิดอยู่ เพื่อดูว่าไอเท็มอยู่ตรงไหนใน UI
		DumpResults = function()
			local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
			local ui = pg and pg:FindFirstChild("ResultsUI")
			if not ui then
				print("[AA Monitor] ไม่พบ ResultsUI (ต้องเรียกตอนหน้า Results ยังอยู่)")
				return
			end
			local n = 0
			for _, d in ipairs(ui:GetDescendants()) do
				if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
					n = n + 1
					if n > 300 then print("... (ตัดที่ 300 รายการ)") break end
					print(string.format("[ResultsUI] %s = %q", d:GetFullName():gsub("^.-ResultsUI", "ResultsUI"), d.Text))
				end
			end
			print("[AA Monitor] DumpResults done, text nodes =", n)
		end,
		ForceSend = function()
			print("[AA Monitor] ForceSend...")
			local snap = SnapshotAdapter.capture({}, {
				result = "FORCE",
				waves = "manual",
				time = os.date("%H:%M:%S"),
			})
			snap.itemDrops = snap.itemDrops or {}
			return sendReport(snap)
		end,
	}

	_G.AA_Monitor = API
	pcall(function()
		if type(getgenv) == "function" then
			getgenv().AA_Monitor = API
		end
	end)

	-------------------------------------------------
	-- Start
	-------------------------------------------------
	pushLog("INFO", "Boot", "Loading AA Farming Monitor...")
	print("[AA Monitor] Boot OK · place=" .. tostring(game.PlaceId))
	print("[AA Monitor] Webhook set=" .. tostring(WEBHOOK_URL ~= nil and #WEBHOOK_URL > 20))
	task.spawn(function()
		task.wait(1)
		if not isAlive then return end
		if SETTINGS.UseLiveDropWatcher then
			safeCall("LiveDropBoot", hookDropNotifications)
		end
	end)
	task.spawn(function()
		safeCall("AutoDetectBoot", startAutoDetect)
	end)
	-- heartbeat ทุก 30 วิ ยืนยันว่าสคริปต์ยังอยู่
	task.spawn(function()
		while isAlive do
			task.wait(30)
			if not isAlive then break end
			print(string.format(
				"[AA Monitor] heartbeat inMatch=%s sent=%d fail=%d",
				tostring(isInMatch()),
				MonitorStats.webhookSent,
				MonitorStats.webhookFailed
			))
		end
	end)
	print("→ ทดสอบส่งทันที: _G.AA_Monitor.ForceSend() หรือ .Report()")
	print("→ ดู Log: _G.AA_Monitor.GetLogs()")
	print("→ ดู Error: _G.AA_Monitor.GetErrors()")
	print("→ ดีบั๊กดรอป (ตอนหน้า Results เปิด): _G.AA_Monitor.DumpResults()")
end
