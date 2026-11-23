--====================================================================
-- Re:Zero / Aura Monster Quiz Auto-Solver Hub (Delta Android Optimized)
-- Features:
--   1. Direct Remote Hook (DisplayFromServer + Display)
--   2. 5-Tier Smart Solver: Confirmed Cache -> Elimination -> Built-in Re:Zero DB -> AI API (Gemini & OpenAI /v1) -> Trial & Error
--   3. Instant Verdict: Display toast + Fling/Death monitor + Next-question auto-confirm
--   4. Mobile-Friendly Touch Draggable UI + Adjustable Answer Delay (0s~10s, presets incl. 3s) + Built-in Live Log + API Ping Test
--   5. Supports loadstring() + getgenv().Re0QuizConfig + Persistent Config & Cache
--====================================================================

local env = (getgenv and getgenv()) or _G
if type(env.__Re0QuizHubDestroy) == "function" then
	pcall(env.__Re0QuizHubDestroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer
local req = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)

local CACHE_FILE = "re0_quiz_cache_v2.json"
local CONFIG_FILE = "re0_quiz_config.json"
local DEFAULT_CLOUD_CACHE_URL = "https://raw.githubusercontent.com/yuertnm-dev/Re0/main/re0_quiz_cache_v2.json"

-- 默认配置（可被 getgenv().Re0QuizConfig 或本地保存文件覆盖）
local config = {
	Enabled = true,
	AutoYN = true,
	UseBuiltinDB = true,
	UseGemini = true,
	ApiKey = "",
	BaseUrl = "https://generativelanguage.googleapis.com",
	Model = "gemini-2.5-flash-lite",
	ApiTimeout = 3.2,
	AnswerDelay = 0.1,
}

-- 读取持久化配置
pcall(function()
	if isfile and isfile(CONFIG_FILE) then
		local saved = HttpService:JSONDecode(readfile(CONFIG_FILE))
		if type(saved) == "table" then
			for k, v in pairs(saved) do
				if config[k] ~= nil then
					config[k] = v
				end
			end
		end
	end
end)

-- 合并外部 loadstring 传入的 getgenv().Re0QuizConfig
if type(env.Re0QuizConfig) == "table" then
	local ext = env.Re0QuizConfig
	if ext.Enabled ~= nil then config.Enabled = ext.Enabled end
	if ext.AutoStart ~= nil then config.Enabled = ext.AutoStart end
	if ext.AutoYN ~= nil then config.AutoYN = ext.AutoYN end
	if ext.UseBuiltinDB ~= nil then config.UseBuiltinDB = ext.UseBuiltinDB end
	if ext.UseGemini ~= nil then config.UseGemini = ext.UseGemini end
	if type(ext.ApiKey) == "string" and ext.ApiKey ~= "" then config.ApiKey = ext.ApiKey end
	if type(ext.BaseUrl) == "string" and ext.BaseUrl ~= "" then config.BaseUrl = ext.BaseUrl end
	if type(ext.Model) == "string" and ext.Model ~= "" then config.Model = ext.Model end
	if type(ext.ApiTimeout) == "number" then config.ApiTimeout = ext.ApiTimeout end
	if type(ext.AnswerDelay) == "number" then config.AnswerDelay = ext.AnswerDelay end
end

local function saveConfig()
	pcall(function()
		if writefile then
			writefile(CONFIG_FILE, HttpService:JSONEncode(config))
		end
	end)
end

--====================================================================
-- 1. 题库管理 & 文本规范化
--====================================================================
local function normText(s)
	s = tostring(s or ""):upper()
	s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	return s
end

local quizCache = {} -- [normQuestion] = { raw = "...", correct = "OPT", wrong = { "OPT1", ... } }

pcall(function()
	if isfile and isfile(CACHE_FILE) then
		local loaded = HttpService:JSONDecode(readfile(CACHE_FILE))
		if type(loaded) == "table" then
			for k, v in pairs(loaded) do
				if type(v) == "table" then
					local nk = normText(k)
					quizCache[nk] = {
						raw = v.raw or k,
						correct = v.correct,
						wrong = type(v.wrong) == "table" and v.wrong or {},
					}
				end
			end
		end
	end
end)

local function saveCache()
	pcall(function()
		if writefile then
			writefile(CACHE_FILE, HttpService:JSONEncode(quizCache))
		end
	end)
end

local function ensureEntry(qRaw)
	local nk = normText(qRaw)
	local e = quizCache[nk]
	if type(e) ~= "table" then
		e = { raw = qRaw, correct = nil, wrong = {} }
		quizCache[nk] = e
	end
	e.wrong = e.wrong or {}
	return e
end

local function inList(list, val)
	local nv = normText(val)
	for _, v in ipairs(list) do
		if normText(v) == nv then return true end
	end
	return false
end

local function findMatchingButton(buttons, targetText)
	local nt = normText(targetText)
	for _, b in ipairs(buttons) do
		if normText(b) == nt then return b end
	end
	return nil
end

local function getCacheStats()
	local total, solved, wrongTotal = 0, 0, 0
	for _, e in pairs(quizCache) do
		if type(e) == "table" then
			total += 1
			if e.correct then solved += 1 end
			if type(e.wrong) == "table" then wrongTotal += #e.wrong end
		end
	end
	return total, solved, wrongTotal
end

--====================================================================
-- 2. 内置 Re:Zero 常见知识库（仅在未缓存时优先匹配，答完仍走真实验证）
--    all = 必须全部命中；any = 命中任意一个即可
--====================================================================
local BUILTIN_RULES = {
	-- 贤者 / 弗琉盖尔大树 / 沙乌拉 / 雷德 / 波尔肯尼卡
	{ all = { "SAGE", "TREE" }, a = { "FLUGEL" } },
	{ all = { "PLANTED", "GREAT TREE" }, a = { "FLUGEL" } },
	{ any = { "PLEIADES WATCHTOWER", "SCORPION", "OVERSEER OF THE WATCHTOWER" }, a = { "SHAULA" } },
	{ all = { "FIRST", "SWORD SAINT" }, a = { "REID ASTREA", "REID" } },
	{ any = { "DIVINE DRAGON", "DRAGON THAT PROTECTED LUGUNICA" }, a = { "VOLCANICA" } },
	{ all = { "CURRENT", "SWORD SAINT" }, a = { "REINHARD VAN ASTREA", "REINHARD" } },
	-- 主角与基础设定
	{ any = { "MAIN CHARACTER", "PROTAGONIST" }, a = { "NATSUKI SUBARU", "SUBARU NATSUKI", "SUBARU" } },
	{ all = { "SUBARU", "ABILITY" }, a = { "RETURN BY DEATH", "RBD" } },
	{ all = { "SUBARU", "POWER" }, a = { "RETURN BY DEATH", "RBD" } },
	{ all = { "RETURN BY DEATH", "WHO" }, a = { "SATELLA", "WITCH OF ENVY" } },
	{ any = { "HALF%-ELF", "SILVER%-HAIRED" }, a = { "EMILIA" } },
	{ all = { "EMILIA", "SPIRIT" }, a = { "PUCK" } },
	{ all = { "EMILIA", "CAT" }, a = { "PUCK" } },
	{ any = { "FORBIDDEN LIBRARY", "LIBRARIAN" }, a = { "BEATRICE", "BEAKO" } },
	{ all = { "BLUE", "MAID" }, a = { "REM" } },
	{ all = { "PINK", "MAID" }, a = { "RAM" } },
	{ any = { "MARGRAVE", "CLOWN", "MANSION OWNER" }, a = { "ROSWAAL L MATHERS", "ROSWAAL" } },
	-- 魔女与大罪司教
	{ any = { "WITCH OF GREED" }, a = { "ECHIDNA" } },
	{ any = { "WITCH OF ENVY" }, a = { "SATELLA" } },
	{ any = { "WITCH OF SLOTH" }, a = { "SEKHMET" } },
	{ any = { "WITCH OF WRATH" }, a = { "MINERVA" } },
	{ any = { "WITCH OF PRIDE" }, a = { "TYPHON" } },
	{ any = { "WITCH OF LUST" }, a = { "CARMILLA" } },
	{ any = { "WITCH OF GLUTTONY" }, a = { "DAPHNE" } },
	{ any = { "WITCH OF VAINGLORY", "WITCH OF VANITY" }, a = { "PANDORA" } },
	{ any = { "WARLOCK OF MELANCHOLY" }, a = { "HECTOR" } },
	{ all = { "ARCHBISHOP", "SLOTH" }, a = { "PETELGEUSE", "BETELGEUSE" } },
	{ all = { "ARCHBISHOP", "GREED" }, a = { "REGULUS CORNEAS", "REGULUS" } },
	{ all = { "ARCHBISHOP", "WRATH" }, a = { "SIRIUS" } },
	{ all = { "ARCHBISHOP", "LUST" }, a = { "CAPELLA" } },
	{ all = { "ARCHBISHOP", "GLUTTONY" }, a = { "LYE", "ROY", "LOUIS", "RUI" } },
	-- 三大魔兽 / 国家 / 阵营 / 其他角色
	{ all = { "WHITE WHALE", "CREAT" }, a = { "DAPHNE" } },
	{ any = { "GREAT RABBIT", "BLACK SERPENT" }, a = { "DAPHNE" } },
	{ any = { "NAME OF THE KINGDOM", "ROYAL CAPITAL", "KINGDOM IN RE" }, a = { "LUGUNICA", "LUGNICA" } },
	{ any = { "SWORD DEMON" }, a = { "WILHELM VAN ASTREA", "WILHELM" } },
	{ any = { "BOWEL HUNTER" }, a = { "ELSA GRANHIERT", "ELSA" } },
	{ any = { "MABEAST", "BEAST TAMER" }, a = { "MEILI" } },
	{ all = { "HEALER", "CRUSCH" }, a = { "FELIX", "FERRIS" } },
	{ all = { "CAT", "HEALER" }, a = { "FELIX", "FERRIS" } },
	{ all = { "ONE%-ARMED", "KNIGHT" }, a = { "ALDEBARAN", "AL" } },
	{ any = { "SUN PRINCESS" }, a = { "PRISCILLA" } },
	{ any = { "WHICH CAMP", "MERCHANT CANDIDATE" }, a = { "ANASTASIA" } },
	{ any = { "DIVINE PROTECTION OF WIND READING", "TALK TO ANIMALS" }, a = { "OTTO" } },
	{ any = { "SANCTUARY", "SHIELD OF" }, a = { "GARFIEL" } },
	{ any = { "APPA", "FRUIT SELLER" }, a = { "KADOMON" } },
	{ any = { "FIRST PERSON SUBARU MET", "FELT" }, a = { "FELT", "KADOMON" } },
}

local function tryBuiltinMatch(qRaw, candidates)
	if not config.UseBuiltinDB then return nil end
	local nq = normText(qRaw)
	for _, rule in ipairs(BUILTIN_RULES) do
		local hit = false
		if rule.all then
			hit = true
			for _, kw in ipairs(rule.all) do
				if not nq:find(kw) then
					hit = false
					break
				end
			end
		elseif rule.any then
			for _, kw in ipairs(rule.any) do
				if nq:find(kw) then
					hit = true
					break
				end
			end
		end
		if hit then
			for _, ansPattern in ipairs(rule.a) do
				for _, opt in ipairs(candidates) do
					local no = normText(opt)
					if no == ansPattern or no:find(ansPattern, 1, true) then
						return opt
					end
				end
			end
		end
	end
	return nil
end

--====================================================================
-- 3. AI 极速问答 + 延迟测试（自动兼容 Gemini 原生 & OpenAI /v1 中转）
--====================================================================
local function isOpenAICompatible(base)
	local b = tostring(base or ""):lower():gsub("/+$", "")
	return b:sub(-3) == "/v1" or b:sub(-17) == "/chat/completions"
end

local function buildAiRequest(promptText)
	local base = tostring(config.BaseUrl or "https://generativelanguage.googleapis.com"):gsub("/+$", "")
	if isOpenAICompatible(base) then
		local url = base:lower():sub(-17) == "/chat/completions" and base or (base .. "/chat/completions")
		local body = HttpService:JSONEncode({
			model = config.Model,
			messages = {
				{ role = "user", content = promptText },
			},
			temperature = 0,
			max_tokens = 16,
		})
		return {
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. tostring(config.ApiKey),
			},
			Body = body,
		}, "OpenAI/v1"
	else
		local gc = {
			temperature = 0,
			maxOutputTokens = 8,
		}
		if tostring(config.Model):find("2%.5") then
			gc.thinkingConfig = { thinkingBudget = 0 }
		end
		local url = string.format("%s/v1beta/models/%s:generateContent?key=%s", base, config.Model, config.ApiKey)
		local body = HttpService:JSONEncode({
			contents = {{ parts = {{ text = promptText }} }},
			generationConfig = gc,
		})
		return {
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		}, "Gemini原生"
	end
end

local function extractAiReplyText(data)
	if type(data) ~= "table" then return nil end
	-- OpenAI /v1 格式
	if data.choices and data.choices[1] then
		local c = data.choices[1]
		if c.message and type(c.message.content) == "string" then
			return c.message.content
		end
		if type(c.text) == "string" then
			return c.text
		end
	end
	-- Gemini 原生格式
	if data.candidates and data.candidates[1] then
		local parts = data.candidates[1].content and data.candidates[1].content.parts
		if parts and parts[1] and type(parts[1].text) == "string" then
			return parts[1].text
		end
	end
	return nil
end

local function askGeminiFast(questionText, candidates)
	if not config.UseGemini or config.ApiKey == "" or not req then
		return nil, 0, nil
	end

	local lines = {
		"Re:Zero / Roblox trivia. Reply ONLY with a single digit (1-" .. #candidates .. "). No explanation.",
		"Q: " .. questionText,
	}
	for i, opt in ipairs(candidates) do
		table.insert(lines, i .. ") " .. opt)
	end

	local reqParams = buildAiRequest(table.concat(lines, "\n"))
	local t0 = os.clock()
	local done = false
	local picked = nil
	local errMsg = nil

	task.spawn(function()
		local ok, res = pcall(function()
			return req(reqParams)
		end)
		if ok and res and res.StatusCode == 200 then
			local okJson, data = pcall(function()
				return HttpService:JSONDecode(res.Body)
			end)
			local reply = okJson and extractAiReplyText(data) or nil
			if reply then
				local n = tonumber(reply:match("%d+"))
				if n and n >= 1 and n <= #candidates then
					picked = n
				else
					errMsg = "解析失败:" .. reply:sub(1, 20)
				end
			else
				errMsg = "空响应"
			end
		else
			errMsg = res and ("HTTP " .. tostring(res.StatusCode)) or "网络异常"
		end
		done = true
	end)

	local deadline = t0 + (tonumber(config.ApiTimeout) or 3.2)
	while not done and os.clock() < deadline do
		task.wait(0.03)
	end
	if not done then
		errMsg = "超时>" .. tostring(config.ApiTimeout) .. "s"
	end
	return picked, math.floor((os.clock() - t0) * 1000), errMsg
end

local function testGeminiConnection()
	if config.ApiKey == "" then
		return false, "未填写 API Key"
	end
	if not req then
		return false, "当前注入器不支持 HTTP request"
	end
	local reqParams, modeTag = buildAiRequest("Reply ONLY with: 1")
	local t0 = os.clock()
	local ok, res = pcall(function()
		return req(reqParams)
	end)
	local ms = math.floor((os.clock() - t0) * 1000)
	if not ok or not res then
		return false, "[" .. modeTag .. "] 请求失败(" .. ms .. "ms): " .. tostring(res)
	end
	if res.StatusCode == 200 then
		return true, "[" .. modeTag .. "] 连接成功 · 延迟 " .. ms .. "ms"
	end
	local bodyPreview = type(res.Body) == "string" and res.Body:gsub("%s+", " "):sub(1, 45) or ""
	return false, "[" .. modeTag .. "] HTTP " .. tostring(res.StatusCode) .. " (" .. ms .. "ms) " .. bodyPreview
end

--====================================================================
-- 4. 实时日志 & 统计状态
--====================================================================
local stats = {
	sessionRight = 0,
	sessionWrong = 0,
	sessionAnswered = 0,
	hookReady = false,
	lastAction = "等待出题...",
}

local logs = {}
local onUiUpdate = nil

local function pushLog(tag, msg, color)
	local stamp = os.date("%H:%M:%S")
	table.insert(logs, 1, {
		text = string.format("[%s][%s] %s", stamp, tag, msg),
		color = color or Color3.fromRGB(220, 225, 235),
	})
	if #logs > 35 then
		table.remove(logs)
	end
	stats.lastAction = "[" .. tag .. "] " .. msg
	if onUiUpdate then pcall(onUiUpdate) end
end

--====================================================================
-- 5. 移动端友好原生 UI（零外部依赖，适配 Delta 触控）
--====================================================================
local connections = {}
local function trackConn(c)
	table.insert(connections, c)
	return c
end

local function getUiParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then return h end
	end
	local ok = pcall(function() return CoreGui.Name end)
	if ok then return CoreGui end
	return lp:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "Re0QuizHubUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = getUiParent()

-- 颜色主题
local C = {
	Bg = Color3.fromRGB(18, 20, 28),
	Card = Color3.fromRGB(28, 32, 44),
	Border = Color3.fromRGB(56, 66, 90),
	Accent = Color3.fromRGB(88, 130, 255),
	Green = Color3.fromRGB(52, 211, 153),
	Red = Color3.fromRGB(248, 113, 113),
	Amber = Color3.fromRGB(251, 191, 36),
	Text = Color3.fromRGB(240, 244, 255),
	Muted = Color3.fromRGB(150, 160, 185),
}

local function addCorner(obj, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 10)
	c.Parent = obj
	return c
end

local function addStroke(obj, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or C.Border
	s.Thickness = thickness or 1
	s.Parent = obj
	return s
end

-- 通用触控/鼠标拖拽器（区分轻点与拖拽，兼容多指触控、无连接泄漏）
local function makeDraggable(handle, target, onTap)
	local dragging = false
	local moved = false
	local dragInput = nil
	local startPos, startInputPos

	trackConn(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = false
			dragInput = input
			startInputPos = input.Position
			startPos = target.Position
			local endConn
			endConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					dragInput = nil
					if endConn then endConn:Disconnect() end
					if not moved and onTap then
						onTap()
					end
				end
			end)
		end
	end))

	trackConn(UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		local isSameTouch = (input.UserInputType == Enum.UserInputType.Touch and input == dragInput)
		local isMouse = (input.UserInputType == Enum.UserInputType.MouseMovement and dragInput and dragInput.UserInputType == Enum.UserInputType.MouseButton1)
		if isSameTouch or isMouse then
			local delta = input.Position - startInputPos
			if delta.Magnitude > 8 then
				moved = true
			end
			if moved then
				target.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end
	end))
end

-- 悬浮圆角胶囊按钮（随时收起/展开）
local floatBtn = Instance.new("TextButton")
floatBtn.Name = "FloatToggle"
floatBtn.Size = UDim2.new(0, 118, 0, 34)
floatBtn.Position = UDim2.new(0, 14, 0, 76)
floatBtn.BackgroundColor3 = C.Bg
floatBtn.TextColor3 = C.Text
floatBtn.Font = Enum.Font.GothamBold
floatBtn.TextSize = 13
floatBtn.Text = "● Re0 题库"
floatBtn.AutoButtonColor = false
floatBtn.Parent = gui
addCorner(floatBtn, 17)
addStroke(floatBtn, C.Accent, 1.5)

-- 主面板（适配安卓横屏高度，不遮挡全屏）
local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.Size = UDim2.new(0, 330, 0, 295)
panel.Position = UDim2.new(0.5, -165, 0.5, -148)
panel.BackgroundColor3 = C.Bg
panel.BorderSizePixel = 0
panel.Visible = true
panel.Parent = gui
addCorner(panel, 12)
addStroke(panel, C.Border, 1.5)

-- 标题栏
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = C.Card
topBar.BorderSizePixel = 0
topBar.Parent = panel
addCorner(topBar, 12)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -86, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 14
titleLbl.TextColor3 = C.Text
titleLbl.Text = "Re:Zero Quiz Hub v2.1"
titleLbl.Parent = topBar

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 30, 0, 26)
minBtn.Position = UDim2.new(1, -70, 0.5, -13)
minBtn.BackgroundColor3 = C.Bg
minBtn.TextColor3 = C.Text
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 15
minBtn.Text = "—"
minBtn.Parent = topBar
addCorner(minBtn, 7)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 26)
closeBtn.Position = UDim2.new(1, -36, 0.5, -13)
closeBtn.BackgroundColor3 = Color3.fromRGB(90, 32, 40)
closeBtn.TextColor3 = C.Red
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 13
closeBtn.Text = "✕"
closeBtn.Parent = topBar
addCorner(closeBtn, 7)

makeDraggable(topBar, panel)
makeDraggable(floatBtn, floatBtn, function()
	panel.Visible = not panel.Visible
end)

trackConn(minBtn.MouseButton1Click:Connect(function()
	panel.Visible = false
end))

-- 顶部标签页切换栏
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -16, 0, 30)
tabBar.Position = UDim2.new(0, 8, 0, 44)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabBar

local pages = {}
local tabButtons = {}

local function createTab(id, label)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.333, -4, 1, 0)
	btn.BackgroundColor3 = C.Card
	btn.TextColor3 = C.Muted
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 12
	btn.Text = label
	btn.Parent = tabBar
	addCorner(btn, 8)
	tabButtons[id] = btn

	local page = Instance.new("ScrollingFrame")
	page.Size = UDim2.new(1, -16, 1, -86)
	page.Position = UDim2.new(0, 8, 0, 80)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 4
	page.CanvasSize = UDim2.new(0, 0, 0, 0)
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = page

	pages[id] = page
	return page, btn
end

local function selectTab(id)
	for tid, p in pairs(pages) do
		p.Visible = (tid == id)
		local b = tabButtons[tid]
		b.BackgroundColor3 = (tid == id) and C.Accent or C.Card
		b.TextColor3 = (tid == id) and Color3.fromRGB(255, 255, 255) or C.Muted
	end
end

local pControl, bControl = createTab("control", "控制")
local pGemini, bGemini = createTab("gemini", "AI 配置")
local pLog, bLog = createTab("log", "题库 & 日志")

trackConn(bControl.MouseButton1Click:Connect(function() selectTab("control") end))
trackConn(bGemini.MouseButton1Click:Connect(function() selectTab("gemini") end))
trackConn(bLog.MouseButton1Click:Connect(function() selectTab("log") end))

-- UI 组件构造器
local function addToggle(parent, title, getter, setter)
	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, -4, 0, 36)
	row.BackgroundColor3 = C.Card
	row.Text = ""
	row.AutoButtonColor = false
	row.Parent = parent
	addCorner(row, 9)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -68, 1, 0)
	lbl.Position = UDim2.new(0, 10, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 12
	lbl.TextColor3 = C.Text
	lbl.Text = title
	lbl.Parent = row

	local pill = Instance.new("TextLabel")
	pill.Size = UDim2.new(0, 48, 0, 22)
	pill.Position = UDim2.new(1, -56, 0.5, -11)
	pill.Font = Enum.Font.GothamBold
	pill.TextSize = 11
	pill.Parent = row
	addCorner(pill, 11)

	local function refresh()
		local on = getter()
		pill.BackgroundColor3 = on and C.Green or Color3.fromRGB(60, 66, 82)
		pill.TextColor3 = on and Color3.fromRGB(10, 26, 20) or C.Muted
		pill.Text = on and "ON" or "OFF"
	end
	refresh()

	trackConn(row.MouseButton1Click:Connect(function()
		setter(not getter())
		saveConfig()
		refresh()
		if onUiUpdate then pcall(onUiUpdate) end
	end))
	return refresh
end

local function addInput(parent, label, initial, placeholder, onSave)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, -4, 0, 56)
	card.BackgroundColor3 = C.Card
	card.Parent = parent
	addCorner(card, 9)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -16, 0, 18)
	lbl.Position = UDim2.new(0, 10, 0, 5)
	lbl.BackgroundTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 11
	lbl.TextColor3 = C.Muted
	lbl.Text = label
	lbl.Parent = card

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, -20, 0, 26)
	box.Position = UDim2.new(0, 10, 0, 24)
	box.BackgroundColor3 = C.Bg
	box.TextColor3 = C.Text
	box.PlaceholderColor3 = Color3.fromRGB(100, 110, 130)
	box.PlaceholderText = placeholder or ""
	box.Text = tostring(initial or "")
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Font = Enum.Font.Code
	box.TextSize = 11
	box.Parent = card
	addCorner(box, 6)

	trackConn(box.FocusLost:Connect(function()
		onSave(box.Text)
		saveConfig()
	end))
	return box
end

-- === Tab 1: 控制页 ===
local statusCard = Instance.new("Frame")
statusCard.Size = UDim2.new(1, -4, 0, 62)
statusCard.BackgroundColor3 = C.Card
statusCard.Parent = pControl
addCorner(statusCard, 9)
addStroke(statusCard, C.Border, 1)

local statsLine1 = Instance.new("TextLabel")
statsLine1.Size = UDim2.new(1, -16, 0, 20)
statsLine1.Position = UDim2.new(0, 10, 0, 6)
statsLine1.BackgroundTransparency = 1
statsLine1.TextXAlignment = Enum.TextXAlignment.Left
statsLine1.Font = Enum.Font.GothamBold
statsLine1.TextSize = 12
statsLine1.TextColor3 = C.Green
statsLine1.Text = "状态：正在连接 Remote..."
statsLine1.Parent = statusCard

local statsLine2 = Instance.new("TextLabel")
statsLine2.Size = UDim2.new(1, -16, 0, 16)
statsLine2.Position = UDim2.new(0, 10, 0, 26)
statsLine2.BackgroundTransparency = 1
statsLine2.TextXAlignment = Enum.TextXAlignment.Left
statsLine2.Font = Enum.Font.Gotham
statsLine2.TextSize = 11
statsLine2.TextColor3 = C.Muted
statsLine2.Text = "已锁题库: 0 | 本局对: 0 / 错: 0"
statsLine2.Parent = statusCard

local statsLine3 = Instance.new("TextLabel")
statsLine3.Size = UDim2.new(1, -16, 0, 16)
statsLine3.Position = UDim2.new(0, 10, 0, 42)
statsLine3.BackgroundTransparency = 1
statsLine3.TextXAlignment = Enum.TextXAlignment.Left
statsLine3.Font = Enum.Font.Code
statsLine3.TextSize = 10
statsLine3.TextColor3 = C.Text
statsLine3.TextTruncate = Enum.TextTruncate.AtEnd
statsLine3.Text = "等待出题..."
statsLine3.Parent = statusCard

addToggle(pControl, "自动答题总开关（拦截 DisplayFromServer）", function() return config.Enabled end, function(v) config.Enabled = v end)
addToggle(pControl, "自动确认 2 选 1 弹窗（YES）", function() return config.AutoYN end, function(v) config.AutoYN = v end)
addToggle(pControl, "内置 Re:Zero 知识库优先匹配", function() return config.UseBuiltinDB end, function(v) config.UseBuiltinDB = v end)
addToggle(pControl, "新题启用 AI 极速问答", function() return config.UseGemini end, function(v) config.UseGemini = v end)

-- 答题延迟设置（支持 -/+ 微调、直接输入任意秒数，以及下方 0~3.5s 快捷档位）
local delayRow = Instance.new("Frame")
delayRow.Size = UDim2.new(1, -4, 0, 36)
delayRow.BackgroundColor3 = C.Card
delayRow.Parent = pControl
addCorner(delayRow, 9)

local delayLbl = Instance.new("TextLabel")
delayLbl.Size = UDim2.new(1, -150, 1, 0)
delayLbl.Position = UDim2.new(0, 10, 0, 0)
delayLbl.BackgroundTransparency = 1
delayLbl.TextXAlignment = Enum.TextXAlignment.Left
delayLbl.Font = Enum.Font.GothamMedium
delayLbl.TextSize = 12
delayLbl.TextColor3 = C.Text
delayLbl.Text = "答题延迟（秒）"
delayLbl.Parent = delayRow

local delayMinus = Instance.new("TextButton")
delayMinus.Size = UDim2.new(0, 28, 0, 24)
delayMinus.Position = UDim2.new(1, -134, 0.5, -12)
delayMinus.BackgroundColor3 = C.Bg
delayMinus.TextColor3 = C.Text
delayMinus.Font = Enum.Font.GothamBold
delayMinus.TextSize = 14
delayMinus.Text = "-"
delayMinus.Parent = delayRow
addCorner(delayMinus, 6)

local delayInput = Instance.new("TextBox")
delayInput.Size = UDim2.new(0, 58, 0, 24)
delayInput.Position = UDim2.new(1, -102, 0.5, -12)
delayInput.BackgroundColor3 = C.Bg
delayInput.TextColor3 = C.Amber
delayInput.Font = Enum.Font.GothamBold
delayInput.TextSize = 11
delayInput.ClearTextOnFocus = false
delayInput.Text = string.format("%.1f", tonumber(config.AnswerDelay) or 0)
delayInput.Parent = delayRow
addCorner(delayInput, 6)

local delayPlus = Instance.new("TextButton")
delayPlus.Size = UDim2.new(0, 28, 0, 24)
delayPlus.Position = UDim2.new(1, -40, 0.5, -12)
delayPlus.BackgroundColor3 = C.Bg
delayPlus.TextColor3 = C.Text
delayPlus.Font = Enum.Font.GothamBold
delayPlus.TextSize = 14
delayPlus.Text = "+"
delayPlus.Parent = delayRow
addCorner(delayPlus, 6)

local presetButtons = {}
local function updatePresetHighlight()
	local cur = tonumber(config.AnswerDelay) or 0
	for sec, pb in pairs(presetButtons) do
		local active = math.abs(cur - sec) < 0.05
		pb.BackgroundColor3 = active and C.Accent or C.Card
		pb.TextColor3 = active and Color3.fromRGB(255, 255, 255) or C.Muted
	end
end

local function setAnswerDelay(v)
	local n = math.clamp(math.floor((tonumber(v) or 0) * 10 + 0.5) / 10, 0, 10)
	config.AnswerDelay = n
	delayInput.Text = string.format("%.1f", n)
	saveConfig()
	updatePresetHighlight()
end

trackConn(delayMinus.MouseButton1Click:Connect(function()
	local cur = tonumber(config.AnswerDelay) or 0
	local step = cur <= 0.5 and 0.1 or 0.5
	setAnswerDelay(cur - step)
end))

trackConn(delayPlus.MouseButton1Click:Connect(function()
	local cur = tonumber(config.AnswerDelay) or 0
	local step = cur < 0.5 and 0.1 or 0.5
	setAnswerDelay(cur + step)
end))

trackConn(delayInput.FocusLost:Connect(function()
	local parsed = tonumber((delayInput.Text:gsub("[^%d%.]", "")))
	if parsed then
		setAnswerDelay(parsed)
		pushLog("设置", "答题延迟已设为 " .. string.format("%.1f", config.AnswerDelay) .. "s", C.Amber)
	else
		delayInput.Text = string.format("%.1f", tonumber(config.AnswerDelay) or 0)
	end
end))

-- 快捷预设档位（0s / 0.5s / 1s / 2s / 3s / 3.5s）
local presetRow = Instance.new("Frame")
presetRow.Size = UDim2.new(1, -4, 0, 28)
presetRow.BackgroundTransparency = 1
presetRow.Parent = pControl

local presetLayout = Instance.new("UIListLayout")
presetLayout.FillDirection = Enum.FillDirection.Horizontal
presetLayout.Padding = UDim.new(0, 5)
presetLayout.Parent = presetRow

for _, sec in ipairs({ 0, 0.5, 1, 2, 3, 3.5 }) do
	local pb = Instance.new("TextButton")
	pb.Size = UDim2.new(1 / 6, -4, 1, 0)
	pb.BackgroundColor3 = C.Card
	pb.TextColor3 = C.Muted
	pb.Font = Enum.Font.GothamBold
	pb.TextSize = 11
	pb.Text = tostring(sec) .. "s"
	pb.Parent = presetRow
	addCorner(pb, 7)
	presetButtons[sec] = pb
	trackConn(pb.MouseButton1Click:Connect(function()
		setAnswerDelay(sec)
		pushLog("设置", "答题延迟已设为 " .. tostring(sec) .. "s", C.Amber)
	end))
end
updatePresetHighlight()

-- === Tab 2: AI 配置页 ===
addInput(pGemini, "API Key（留空=纯本地题库+试错）", config.ApiKey, "sk-... 或 AIzaSy...", function(v)
	config.ApiKey = v:gsub("%s+", "")
	pushLog("设置", config.ApiKey == "" and "已清空 API Key（离线模式）" or "已保存 API Key", C.Amber)
end)

local modelBox = addInput(pGemini, "模型名称（如 gemini-2.5-flash-lite）", config.Model, "gemini-2.5-flash-lite", function(v)
	if v:gsub("%s+", "") ~= "" then
		config.Model = v:gsub("%s+", "")
	end
end)

addInput(pGemini, "API Base URL（/v1 结尾自动走 OpenAI 协议）", config.BaseUrl, "https://generativelanguage.googleapis.com", function(v)
	local clean = v:gsub("%s+", ""):gsub("/+$", "")
	if clean ~= "" then config.BaseUrl = clean end
end)

addInput(pGemini, "AI 超时时间（秒，5秒题建议 2.8~3.5）", config.ApiTimeout, "3.2", function(v)
	local n = tonumber((v:gsub("[^%d%.]", "")))
	if n and n >= 0.5 and n <= 15 then
		config.ApiTimeout = n
		pushLog("设置", "AI 超时已设为 " .. tostring(n) .. "s", C.Amber)
	end
end)

local btnRowAI = Instance.new("Frame")
btnRowAI.Size = UDim2.new(1, -4, 0, 34)
btnRowAI.BackgroundTransparency = 1
btnRowAI.Parent = pGemini

local quickModelBtn = Instance.new("TextButton")
quickModelBtn.Size = UDim2.new(0.48, 0, 1, 0)
quickModelBtn.BackgroundColor3 = C.Card
quickModelBtn.TextColor3 = C.Text
quickModelBtn.Font = Enum.Font.GothamBold
quickModelBtn.TextSize = 11
quickModelBtn.Text = "切换 Flash / Lite"
quickModelBtn.Parent = btnRowAI
addCorner(quickModelBtn, 8)

local pingBtn = Instance.new("TextButton")
pingBtn.Size = UDim2.new(0.48, 0, 1, 0)
pingBtn.Position = UDim2.new(0.52, 0, 0, 0)
pingBtn.BackgroundColor3 = C.Accent
pingBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
pingBtn.Font = Enum.Font.GothamBold
pingBtn.TextSize = 11
pingBtn.Text = "测试 API 延迟"
pingBtn.Parent = btnRowAI
addCorner(pingBtn, 8)

local pingResultLbl = Instance.new("TextLabel")
pingResultLbl.Size = UDim2.new(1, -4, 0, 30)
pingResultLbl.BackgroundTransparency = 1
pingResultLbl.TextXAlignment = Enum.TextXAlignment.Left
pingResultLbl.Font = Enum.Font.Gotham
pingResultLbl.TextSize = 11
pingResultLbl.TextColor3 = C.Muted
pingResultLbl.Text = "提示：Base URL 以 /v1 结尾会自动用 OpenAI 格式请求。"
pingResultLbl.TextWrapped = true
pingResultLbl.Parent = pGemini

trackConn(quickModelBtn.MouseButton1Click:Connect(function()
	if config.Model == "gemini-2.5-flash-lite" then
		config.Model = "gemini-2.5-flash"
	else
		config.Model = "gemini-2.5-flash-lite"
	end
	modelBox.Text = config.Model
	saveConfig()
	pingResultLbl.Text = "已切换模型：" .. config.Model
	pingResultLbl.TextColor3 = C.Amber
end))

trackConn(pingBtn.MouseButton1Click:Connect(function()
	pingResultLbl.Text = "正在测试 AI 连通性..."
	pingResultLbl.TextColor3 = C.Amber
	task.spawn(function()
		local ok, msg = testGeminiConnection()
		pingResultLbl.Text = (ok and "✓ " or "✗ ") .. msg
		pingResultLbl.TextColor3 = ok and C.Green or C.Red
		pushLog("PING", msg, ok and C.Green or C.Red)
	end)
end))

-- === Tab 3: 题库 & 实时日志页 ===
local bankBtnRow = Instance.new("Frame")
bankBtnRow.Size = UDim2.new(1, -4, 0, 32)
bankBtnRow.BackgroundTransparency = 1
bankBtnRow.Parent = pLog

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0.48, 0, 1, 0)
copyBtn.BackgroundColor3 = C.Card
copyBtn.TextColor3 = C.Text
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 11
copyBtn.Text = "复制 JSON 题库"
copyBtn.Parent = bankBtnRow
addCorner(copyBtn, 8)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0.48, 0, 1, 0)
clearBtn.Position = UDim2.new(0.52, 0, 0, 0)
clearBtn.BackgroundColor3 = Color3.fromRGB(78, 30, 38)
clearBtn.TextColor3 = C.Red
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 11
clearBtn.Text = "清空本地题库"
clearBtn.Parent = bankBtnRow
addCorner(clearBtn, 8)

local logBox = Instance.new("Frame")
logBox.Size = UDim2.new(1, -4, 0, 160)
logBox.BackgroundColor3 = C.Card
logBox.Parent = pLog
addCorner(logBox, 9)

local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -8, 1, -8)
logScroll.Position = UDim2.new(0, 4, 0, 4)
logScroll.BackgroundTransparency = 1
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 3
logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = logBox

local logLayout = Instance.new("UIListLayout")
logLayout.Padding = UDim.new(0, 3)
logLayout.Parent = logScroll

trackConn(copyBtn.MouseButton1Click:Connect(function()
	local encoded = HttpService:JSONEncode(quizCache)
	if setclipboard then
		setclipboard(encoded)
		pushLog("题库", "已复制到剪贴板（" .. #encoded .. " 字节）", C.Green)
	else
		pushLog("题库", "当前注入器不支持 setclipboard", C.Red)
	end
end))

local clearConfirmAt = 0
trackConn(clearBtn.MouseButton1Click:Connect(function()
	if os.clock() - clearConfirmAt > 3 then
		clearConfirmAt = os.clock()
		clearBtn.Text = "再点一次确认清空"
		task.delay(3, function()
			if clearBtn and clearBtn.Parent then
				clearBtn.Text = "清空本地题库"
			end
		end)
		return
	end
	quizCache = {}
	saveCache()
	clearBtn.Text = "清空本地题库"
	pushLog("题库", "已清空全部本地缓存", C.Amber)
end))

local function refreshUi()
	local total, solved, wrongTotal = getCacheStats()
	floatBtn.Text = (config.Enabled and "● " or "○ ") .. "Re0(" .. solved .. ")"
	floatBtn.TextColor3 = config.Enabled and C.Green or C.Muted

	statsLine1.Text = stats.hookReady
		and (config.Enabled and "状态：已拦截 Remote · 自动答题运行中" or "状态：已拦截 Remote · 已暂停")
		or "状态：等待游戏 Toasts Remote 加载..."
	statsLine1.TextColor3 = (stats.hookReady and config.Enabled) and C.Green or C.Amber
	statsLine2.Text = string.format(
		"题库: %d 题(%d 锁定/%d 排错) | 本局 ✓%d ✗%d",
		total, solved, wrongTotal, stats.sessionRight, stats.sessionWrong
	)
	statsLine3.Text = stats.lastAction

	for _, child in ipairs(logScroll:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end
	for i, item in ipairs(logs) do
		local l = Instance.new("TextLabel")
		l.LayoutOrder = i
		l.Size = UDim2.new(1, -6, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundTransparency = 1
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.Font = Enum.Font.Code
		l.TextSize = 10
		l.TextColor3 = item.color
		l.Text = item.text
		l.Parent = logScroll
	end
end

onUiUpdate = refreshUi
selectTab("control")
refreshUi()

--====================================================================
-- 6. 核心 Remote 拦截与对错判定引擎
--====================================================================
local destroyed = false
local DisplayFromServer = nil
local Display = nil
local oldCallback = nil
local pending = nil
local seq = 0

local function markWrong(p, reason)
	if not p or p.settled then return end
	p.settled = true
	if pending and pending.id == p.id then pending = nil end

	local entry = ensureEntry(p.q)
	if entry.correct and normText(entry.correct) == normText(p.ans) then
		entry.correct = nil
	end
	if not inList(entry.wrong, p.ans) then
		table.insert(entry.wrong, p.ans)
		saveCache()
	end
	stats.sessionWrong += 1
	pushLog("判错", string.format("✗ %s（%s）→ 已加入排除表", p.ans, reason or "WRONG"), C.Red)
end

local function markRight(p, reason)
	if not p or p.settled then return end
	p.settled = true
	if pending and pending.id == p.id then pending = nil end

	stats.sessionRight += 1
	if p.fromCache then
		if onUiUpdate then pcall(onUiUpdate) end
		return
	end

	local entry = ensureEntry(p.q)
	entry.correct = p.ans
	entry.wrong = {}
	saveCache()
	pushLog("判对", string.format("✓ %s（%s）→ 已永久锁死", p.ans, reason or "通过"), C.Green)
end

local function solveInvoke(data)
	if not config.Enabled then
		if oldCallback then return oldCallback(data) end
		return nil
	end
	if type(data) ~= "table" or type(data.Buttons) ~= "table" or #data.Buttons == 0 then
		if oldCallback then return oldCallback(data) end
		return nil
	end

	local qRaw = tostring(data.ContentText or "")
	local buttons = data.Buttons

	-- 2 选 1 确认框（例如 ARE YOU FAMILIAR WITH AURA MONSTER）
	if #buttons == 2 then
		if config.AutoYN then
			local yesBtn = findMatchingButton(buttons, "YES")
			if yesBtn then
				pushLog("确认", "自动选择: " .. yesBtn, C.Muted)
				return yesBtn
			end
		end
		if oldCallback then return oldCallback(data) end
		return buttons[1]
	end

	-- 如果上一题还在等结果，而新题已经发来且不是同一道题、角色未死，说明上一题通过了！
	if pending and not pending.settled and normText(pending.q) ~= normText(qRaw) then
		local char = lp.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			markRight(pending, "已切下一题")
		end
	end

	local tStart = os.clock()
	local entry = ensureEntry(qRaw)
	local chosen = nil
	local sourceTag = "试错"
	local usedConfirmedCache = false

	-- 1) 已锁定正确答案
	if entry.correct then
		local matched = findMatchingButton(buttons, entry.correct)
		if matched then
			chosen = matched
			sourceTag = "缓存"
			usedConfirmedCache = true
		end
	end

	if not chosen then
		-- 2) 过滤掉已知错项
		local candidates = {}
		for _, opt in ipairs(buttons) do
			if not inList(entry.wrong, opt) then
				table.insert(candidates, opt)
			end
		end
		if #candidates == 0 then
			entry.wrong = {}
			candidates = buttons
		end

		if #candidates == 1 then
			chosen = candidates[1]
			sourceTag = "排除必中"
		else
			-- 3) 内置 Re:Zero 知识库
			local builtinPick = tryBuiltinMatch(qRaw, candidates)
			if builtinPick then
				chosen = builtinPick
				sourceTag = "内置库"
			else
				-- 4) AI 极速 API（自动支持 Gemini 原生 & OpenAI /v1）
				local aiIdx, ms, aiErr = askGeminiFast(qRaw, candidates)
				if aiIdx and candidates[aiIdx] then
					chosen = candidates[aiIdx]
					sourceTag = "AI " .. ms .. "ms"
				else
					if aiErr then
						pushLog("AI降级", aiErr .. " → 改用试错", C.Amber)
					end
					-- 5) 纯试错兜底
					chosen = candidates[1]
					sourceTag = "试错"
				end
			end
		end
	end

	-- 仅当耗时短于拟人延迟时补齐剩余延迟，绝不在慢 AI 后额外拖延
	local d = tonumber(config.AnswerDelay) or 0
	local remain = d - (os.clock() - tStart)
	if remain > 0 then task.wait(remain) end

	stats.sessionAnswered += 1
	pushLog(sourceTag, chosen .. " | " .. qRaw:sub(1, 36), usedConfirmedCache and C.Green or C.Text)

	-- 无论哪种来源，都挂短期验证监控（防万一游戏改题也能自动纠错）
	seq += 1
	local myId = seq
	local myPending = { id = myId, q = qRaw, ans = chosen, at = os.clock(), settled = false, fromCache = usedConfirmedCache }
	pending = myPending

	task.spawn(function()
		local tEnd = os.clock() + 2.0
		while os.clock() < tEnd do
			if destroyed or myPending.settled or not pending or pending.id ~= myId then
				return
			end
			local char = lp.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not char or not hrp or not hum or hum.Health <= 0 or hum.PlatformStand or hrp.AssemblyLinearVelocity.Magnitude > 75 then
				markWrong(myPending, "弹飞/倒地")
				return
			end
			task.wait(0.06)
		end
		if not destroyed and not myPending.settled and pending and pending.id == myId then
			markRight(myPending, "2s无惩罚")
		end
	end)

	return chosen
end

-- 异步绑定 Remotes（不阻塞 UI 弹出）
task.spawn(function()
	local Toasts = ReplicatedStorage:WaitForChild("Toasts", 30)
	if destroyed or not Toasts then
		pushLog("警告", "30s 未找到 ReplicatedStorage.Toasts", C.Red)
		return
	end
	local Remotes = Toasts:WaitForChild("Assets"):WaitForChild("Remotes")
	DisplayFromServer = Remotes:WaitForChild("DisplayFromServer")
	Display = Remotes:WaitForChild("Display")

	trackConn(Display.OnClientEvent:Connect(function(toast)
		if destroyed or not pending or pending.settled or type(toast) ~= "table" then return end
		if (os.clock() - pending.at) > 8 then return end

		local txt = type(toast.ContentText) == "string" and toast.ContentText:upper() or ""
		local isRed = toast.Color and toast.Color.R > 0.8 and toast.Color.G < 0.45
		local isGreen = toast.Color and toast.Color.G > 0.7 and toast.Color.R < 0.45

		if txt:find("WRONG") or txt:find("INCORRECT") or txt:find("FAIL") or txt:find("GG") or (toast.Title == "Son" and isRed) then
			markWrong(pending, toast.ContentText or "红字弹窗")
		elseif txt:find("CORRECT") or txt:find("RIGHT") or isGreen then
			markRight(pending, toast.ContentText or "绿字弹窗")
		end
	end))

	if getcallbackvalue then
		local ok, cb = pcall(getcallbackvalue, DisplayFromServer, "OnClientInvoke")
		if ok and cb and cb ~= solveInvoke then
			oldCallback = cb
		end
	end
	DisplayFromServer.OnClientInvoke = solveInvoke
	stats.hookReady = true
	pushLog("就绪", "已挂载 DisplayFromServer & Display", C.Green)

	-- 守护：防止游戏脚本后续覆盖 OnClientInvoke
	while not destroyed and task.wait(1) do
		if getcallbackvalue then
			local ok, cur = pcall(getcallbackvalue, DisplayFromServer, "OnClientInvoke")
			if ok and cur and cur ~= solveInvoke then
				oldCallback = cur
				DisplayFromServer.OnClientInvoke = solveInvoke
				pushLog("守护", "检测到回调被覆写，已重新挂载", C.Amber)
			end
		end
	end
end)

-- 彻底卸载/清理函数（支持重新 loadstring 热重载）
local function destroyAll()
	if destroyed then return end
	destroyed = true
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	if DisplayFromServer and oldCallback then
		pcall(function() DisplayFromServer.OnClientInvoke = oldCallback end)
	end
	if gui and gui.Parent then
		pcall(function() gui:Destroy() end)
	end
	if env.__Re0QuizHubDestroy == destroyAll then
		env.__Re0QuizHubDestroy = nil
	end
end

-- 启动时异步合并云端题库（新手机无需手动导库，直接获得已验证答案）
task.spawn(function()
	local url = (type(env.RE0_CACHE_URL) == "string" and #env.RE0_CACHE_URL > 8) and env.RE0_CACHE_URL or DEFAULT_CLOUD_CACHE_URL
	if type(url) ~= "string" or #url < 8 then return end
	local okBody, body = pcall(function()
		return game:HttpGet(url)
	end)
	if (not okBody or type(body) ~= "string" or #body < 10) and req then
		local okReq, res = pcall(function()
			return req({ Url = url, Method = "GET" })
		end)
		if okReq and type(res) == "table" and type(res.Body) == "string" then
			body = res.Body
			okBody = true
		end
	end
	if destroyed or not okBody or type(body) ~= "string" or #body < 10 then return end
	local okJson, cloudData = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not okJson or type(cloudData) ~= "table" then return end

	local added = 0
	local updated = false
	for k, v in pairs(cloudData) do
		if type(v) == "table" then
			local nk = normText(k)
			local cur = quizCache[nk]
			if type(cur) ~= "table" then
				quizCache[nk] = {
					raw = v.raw or k,
					correct = v.correct,
					wrong = type(v.wrong) == "table" and v.wrong or {},
				}
				added += 1
				updated = true
			else
				if not cur.correct and v.correct then
					cur.correct = v.correct
					added += 1
					updated = true
				end
				if type(v.wrong) == "table" then
					cur.wrong = cur.wrong or {}
					for _, w in ipairs(v.wrong) do
						if not inList(cur.wrong, w) then
							table.insert(cur.wrong, w)
							updated = true
						end
					end
				end
			end
		end
	end
	if updated then
		saveCache()
		local total, solved = getCacheStats()
		pushLog("云端题库", string.format("已同步云端题库 +%d 题（已解 %d/%d）", added, solved, total), C.Green)
		if onUiUpdate then pcall(onUiUpdate) end
	end
end)

env.__Re0QuizHubDestroy = destroyAll
trackConn(closeBtn.MouseButton1Click:Connect(destroyAll))
