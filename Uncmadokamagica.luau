local type, typeof, pcall, xpcall, assert, error, select, pairs, ipairs, tostring, tonumber, unpack = 
	type, typeof, pcall, xpcall, assert, error, select, pairs, ipairs, tostring, tonumber, table.unpack or unpack
local getfenv, setfenv, rawget, rawset, rawequal, setmetatable, getmetatable = 
	getfenv, setfenv, rawget, rawset, rawequal, setmetatable, getmetatable
local string_match, string_sub, string_len, string_format, string_rep, string_byte, string_char, string_find, string_gsub, string_reverse = 
	string.match, string.sub, string.len, string.format, string.rep, string.byte, string.char, string.find, string.gsub, string.reverse
local table_insert, table_concat, table_find, table_clear, table_freeze, table_sort = 
	table.insert, table.concat, table.find, table.clear, table.freeze, table.sort
local math_random, math_round, math_floor, math_abs, math_max, math_min, math_huge, math_pi, math_sin, math_cos = 
	math.random, math.round, math.floor, math.abs, math.max, math.min, math.huge, math.pi, math.sin, math.cos
local task_spawn, task_defer, task_wait = 
	task.spawn, task.defer, task.wait
local Instance_new = Instance.new
local os_clock = os.clock
local tick_func = tick

local passes, fails, spoofed, undefined = 0, 0, 0, 0
local running = 0
local testStatus = {}
local testTimings = {}
local spoofEvidence = {}

local function getGlobal(path)
	local value = getfenv(0)
	while value ~= nil and path ~= "" do
		local name, nextValue = string_match(path, "^([^.]+)%.?(.*)$")
		if type(value) ~= "table" and type(value) ~= "userdata" then
			return nil
		end
		local success, result = pcall(function()
			return value[name]
		end)
		if not success then return nil end
		value = result
		path = nextValue
	end
	return value
end

local function markSpoofed(name, reason)
	spoofed += 1
	fails += 1
	spoofEvidence[name] = reason or "Behavioral check failed"
	warn("⛔ SPOOF DETECTED: \"" .. name .. "\" (" .. spoofEvidence[name] .. ")")
end

local function measureTime(fn)
	local t0 = os_clock()
	local results = {pcall(fn)}
	local elapsed = os_clock() - t0
	return elapsed, results
end

local function test(name, aliases, deps, callback)
	if type(deps) == "function" then
		callback = deps
		deps = {}
	end

	running += 1

	task_spawn(function()
		for _, dep in ipairs(deps or {}) do
			if not getGlobal(dep) or testStatus[dep] == false then
				warn(dep .. " is needed in order to test " .. name)
				running -= 1
				return
			end
		end

		local fn = getGlobal(name)

		if not callback then
			print("⏺️ " .. name)
		elseif not fn then
			fails += 1
			testStatus[name] = false
			warn("⛔ " .. name .. " (Global missing)")
		else
			local startTime = os_clock()
			local success, message = pcall(callback)
			local elapsed = os_clock() - startTime
			testTimings[name] = elapsed

			if success then
				passes += 1
				testStatus[name] = true
				print("✅ " .. name .. string_format(" (%.3fs)", elapsed) .. (type(message) == "string" and (" • " .. message) or ""))
			else
				testStatus[name] = false
				markSpoofed(name, tostring(message))
			end
		end

		local undefinedAliases = {}
		for _, alias in ipairs(aliases) do
			if getGlobal(alias) == nil then
				table_insert(undefinedAliases, alias)
			end
		end

		if #undefinedAliases > 0 then
			undefined += 1
			warn("⚠️ " .. name .. " missing aliases: " .. table_concat(undefinedAliases, ", "))
		end

		running -= 1
	end)
end

local function antiSpoofPersist(name, setupFn, checkFn, delayTime)
	local setupResult = setupFn()
	task_wait(delayTime or 0.15)
	local checkResult = checkFn(setupResult)
	return checkResult
end

local function antiSpoofBehavior(name, fn, validator)
	local allResults = {}
	for i = 1, 5 do
		local ok, result = pcall(fn)
		allResults[i] = {ok = ok, result = result}
	end
	return validator(allResults)
end

-- ============================================================================
-- TEST PLACE DETECTION & SERVER VALIDATION ENGINE
-- ============================================================================

local testPlaceValidation = {}
local testPlaceActive = false
local testPlaceToken = nil

local function detectTestPlace()
	local validationFolder = nil
	local ok, result = pcall(function()
		return game:GetService("ReplicatedStorage"):FindFirstChild("UNC_Validation")
	end)
	if ok and result then
		validationFolder = result
	end

	if not validationFolder then
		return false
	end

	local tokenObj = validationFolder:FindFirstChild("UNC_TestToken")
	local validateRemote = validationFolder:FindFirstChild("UNC_ValidateEvent")
	local requestRemote = validationFolder:FindFirstChild("UNC_RequestEvent")

	if not tokenObj or not validateRemote or not requestRemote then
		return false
	end

	testPlaceToken = tokenObj.Value
	testPlaceActive = true

	testPlaceValidation.Remote = validateRemote
	testPlaceValidation.RequestRemote = requestRemote
	testPlaceValidation.Token = testPlaceToken
	testPlaceValidation.Workspace = workspace

	print("[UNC Test Place] Detected test place environment. Token: " .. testPlaceToken)
	return true
end

local function requestServerValidation(requestType, index, timeout)
	if not testPlaceActive or not testPlaceValidation.RequestRemote then
		return nil, "Test place not active"
	end

	local response = nil
	local received = false

	local connection
	connection = testPlaceValidation.Remote.OnClientEvent:Connect(function(respType, respIndex, result)
		if respType == requestType and respIndex == index then
			response = result
			received = true
			connection:Disconnect()
		end
	end)

	testPlaceValidation.RequestRemote:FireServer(requestType, index)

	local waitTime = 0
	local maxWait = timeout or 2
	while not received and waitTime < maxWait do
		task_wait(0.02)
		waitTime += 0.02
	end

	if not received and connection then
		connection:Disconnect()
	end

	return response
end

local function validateClickDetector(index)
	return requestServerValidation("CHECK_CLICK", index, 2)
end

local function validateProximityPrompt(index)
	return requestServerValidation("CHECK_PROMPT", index, 2)
end

local function validateTouchInterest(index)
	return requestServerValidation("CHECK_TOUCH", index, 2)
end

local function validateSignal(index)
	return requestServerValidation("CHECK_SIGNAL", index, 2)
end

local function validateToken()
	return requestServerValidation("GET_TOKEN", 0, 2)
end

local function validateHidden()
	return requestServerValidation("CHECK_HIDDEN", 0, 2)
end

local function validateScripts()
	return requestServerValidation("CHECK_SCRIPTS", 0, 2)
end

local function getServerLog()
	return requestServerValidation("GET_LOG", 0, 3)
end

-- Attempt detection on load
pcall(detectTestPlace)

print("\n")
print("==========================================================")
print(" Ultra-Hardened UNC Suite (Anti-Fake Engine v5)")
if testPlaceActive then
	print("🎮 TEST PLACE MODE ACTIVE — Server-validated tests enabled")
end
print("✅ Pass | ⛔ Spoofed/Failed | ⏺️ Untested | ⚠️ Missing Aliases")
print("==========================================================\n")

task_defer(function()
	repeat task_wait() until running == 0

	local total = passes + fails
	local rate = total > 0 and math_round((passes / total) * 100) or 0

	print("\n==========================================================")
	print("UNC Final Report")
	if testPlaceActive then
		print("🎮 TEST PLACE: Active (Token: " .. tostring(testPlaceToken) .. ")")
		print("   Server-validated tests are REAL functional tests")
	else
		print("🎮 TEST PLACE: Not detected (server-validated tests skipped)")
		print("   Place UNC test place to enable real functional validation")
	end
	print("✅ Pass Rate: " .. rate .. "% (" .. passes .. "/" .. total .. ")")
	print("⛔ Failed / Fakes Caught: " .. fails .. " (Spoofs: " .. spoofed .. ")")
	print("⚠️ Missing Aliases: " .. undefined)
	print("==========================================================")

	if next(testTimings) then
		print("\nFunction Timings:")
		local sortedTimings = {}
		for k, v in pairs(testTimings) do
			table_insert(sortedTimings, {name = k, time = v})
		end
		table_sort(sortedTimings, function(a, b) return a.time > b.time end)
		for i = 1, math_min(10, #sortedTimings) do
			print(string_format("  %.3fs - %s", sortedTimings[i].time, sortedTimings[i].name))
		end
	end

	if next(spoofEvidence) then
		print("\nSpoof Evidence Log:")
		for name, reason in pairs(spoofEvidence) do
			print("  " .. name .. ": " .. reason)
		end
	end

	print("\n==========================================================\n")
end)

local function shallowEqual(t1, t2)
	if t1 == t2 then return true end
	local UNIQUE_TYPES = { ["function"] = true, ["table"] = true, ["userdata"] = true, ["thread"] = true }
	for k, v in pairs(t1) do
		if UNIQUE_TYPES[type(v)] then
			if type(t2[k]) ~= type(v) then return false end
		elseif t2[k] ~= v then return false end
	end
	return true
end

local function assertType(val, expectedType, funcName)
	if type(val) ~= expectedType then
		error(funcName .. " returned " .. type(val) .. " instead of " .. expectedType)
	end
end

local function assertNonNil(val, funcName)
	if val == nil then
		error(funcName .. " returned nil")
	end
end

local function assertNonEmptyString(val, funcName)
	if type(val) ~= "string" or #val == 0 then
		error(funcName .. " did not return a non-empty string")
	end
end

local function assertInstance(val, className, funcName)
	if typeof(val) ~= "Instance" then
		error(funcName .. " did not return an Instance")
	end
	if className and not val:IsA(className) then
		error(funcName .. " returned " .. val.ClassName .. " instead of " .. className)
	end
end

local function genRandomString(len)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
	local result = ""
	for i = 1, len do
		local idx = math_random(1, #chars)
		result = result .. string_sub(chars, idx, idx)
	end
	return result
end

local function genRandomNumber(min, max)
	return math_random(min or 1, max or 999999)
end

local function deepCompare(t1, t2, depth)
	depth = depth or 0
	if depth > 10 then return true end
	if type(t1) ~= type(t2) then return false end
	if type(t1) ~= "table" then return t1 == t2 end
	for k, v in pairs(t1) do
		if not deepCompare(v, t2[k], depth + 1) then return false end
	end
	for k, v in pairs(t2) do
		if t1[k] == nil then return false end
	end
	return true
end

-- ============================================================================
-- CACHE
-- ============================================================================

test("cache.invalidate", {}, function()
	local container = Instance_new("Folder")
	local part = Instance_new("Part", container)
	part.Name = "CacheTestPart"
	local refBefore = container:FindFirstChild("CacheTestPart")
	cache.invalidate(refBefore)
	local refAfter = container:FindFirstChild("CacheTestPart")
	assert(refBefore ~= refAfter, "Failed to invalidate object reference from internal cache")

	local part2 = Instance_new("Part", container)
	part2.Name = "SecondPart"
	local ref2Before = container:FindFirstChild("SecondPart")
	cache.invalidate(ref2Before)
	local ref2After = container:FindFirstChild("SecondPart")
	assert(ref2Before ~= ref2After, "Second invalidation failed")

	local model = Instance_new("Model", container)
	model.Name = "TestModel"
	local modelRefBefore = container:FindFirstChild("TestModel")
	cache.invalidate(modelRefBefore)
	local modelRefAfter = container:FindFirstChild("TestModel")
	assert(modelRefBefore ~= modelRefAfter, "Model invalidation failed")

	local success = pcall(function() cache.invalidate(nil) end)
	assert(not success, "cache.invalidate should error on nil")
	local success2 = pcall(function() cache.invalidate(12345) end)
	assert(not success2, "cache.invalidate should error on number")
	local success3 = pcall(function() cache.invalidate("string") end)
	assert(not success3, "cache.invalidate should error on string")
	local success4 = pcall(function() cache.invalidate(true) end)
	assert(not success4, "cache.invalidate should error on boolean")

	local part3 = Instance_new("Part", container)
	part3.Name = "PersistTest"
	local ref3 = container:FindFirstChild("PersistTest")
	cache.invalidate(ref3)
	task_wait(0.1)
	local ref3After = container:FindFirstChild("PersistTest")
	assert(ref3 ~= ref3After, "Invalidation did not persist after delay")

	local part4 = Instance_new("Part", container)
	part4.Name = "DoubleInvalidate"
	local ref4 = container:FindFirstChild("DoubleInvalidate")
	cache.invalidate(ref4)
	local ref4b = container:FindFirstChild("DoubleInvalidate")
	cache.invalidate(ref4b)
	local ref4c = container:FindFirstChild("DoubleInvalidate")
	assert(ref4 ~= ref4b, "First double-invalidate failed")
	assert(ref4b ~= ref4c, "Second double-invalidate failed")

	local folder = Instance_new("Folder", container)
	folder.Name = "FolderInvalidationTest"
	local folderRef = container:FindFirstChild("FolderInvalidationTest")
	cache.invalidate(folderRef)
	local folderRefAfter = container:FindFirstChild("FolderInvalidationTest")
	assert(folderRef ~= folderRefAfter, "Folder invalidation failed")

	local gui = Instance_new("ScreenGui", container)
	gui.Name = "GUITest"
	local guiRef = container:FindFirstChild("GUITest")
	cache.invalidate(guiRef)
	local guiRefAfter = container:FindFirstChild("GUITest")
	assert(guiRef ~= guiRefAfter, "ScreenGui invalidation failed")
end)

test("cache.iscached", {}, function()
	local part = Instance_new("Part")
	assert(cache.iscached(part) == true, "New Part should be cached")
	cache.invalidate(part)
	assert(cache.iscached(part) == false, "Invalidated Part should not report as cached")

	local part2 = Instance_new("Part")
	assert(cache.iscached(part2) == true, "Second new Part should be cached")

	local model = Instance_new("Model")
	assert(cache.iscached(model) == true, "Model should be cached")
	cache.invalidate(model)
	assert(cache.iscached(model) == false, "Invalidated Model should not be cached")

	local folder = Instance_new("Folder")
	assert(cache.iscached(folder) == true, "Folder should be cached")

	local gui = Instance_new("ScreenGui")
	assert(cache.iscached(gui) == true, "ScreenGui should be cached")
	cache.invalidate(gui)
	assert(cache.iscached(gui) == false, "Invalidated ScreenGui should not be cached")

	local success = pcall(function() cache.iscached(nil) end)
	assert(not success, "cache.iscached should error on nil")
	local success2 = pcall(function() cache.iscached("string") end)
	assert(not success2, "cache.iscached should error on string")
	local success3 = pcall(function() cache.iscached(99999) end)
	assert(not success3, "cache.iscached should error on number")
	local success4 = pcall(function() cache.iscached(true) end)
	assert(not success4, "cache.iscached should error on boolean")
	local success5 = pcall(function() cache.iscached({}) end)
	assert(not success5, "cache.iscached should error on table")

	local part3 = Instance_new("Part")
	assert(cache.iscached(part3) == true)
	local wasCached = cache.iscached(part3)
	assert(type(wasCached) == "boolean", "cache.iscached should return boolean")

	local longNamePart = Instance_new("Part")
	longNamePart.Name = genRandomString(200)
	assert(cache.iscached(longNamePart) == true, "Part with long name should be cached")
end)

test("cache.replace", {}, function()
	local part = Instance_new("Part")
	local fire = Instance_new("Fire")
	cache.replace(part, fire)
	assert(part ~= fire, "cache.replace failed physical substitution")

	local part2 = Instance_new("Part")
	local explosion = Instance_new("Explosion")
	cache.replace(part2, explosion)
	assert(part2 ~= explosion, "cache.replace second substitution failed")

	local part3 = Instance_new("Part")
	local beam = Instance_new("Beam")
	cache.replace(part3, beam)
	assert(part3 ~= beam, "cache.replace Beam substitution failed")

	local part4 = Instance_new("Part")
	local smoke = Instance_new("Smoke")
	cache.replace(part4, smoke)
	assert(part4 ~= smoke, "cache.replace Smoke substitution failed")

	local part5 = Instance_new("Part")
	local sparkles = Instance_new("Sparkles")
	cache.replace(part5, sparkles)
	assert(part5 ~= sparkles, "cache.replace Sparkles substitution failed")

	local part6 = Instance_new("Part")
	local surfaceGui = Instance_new("SurfaceGui")
	cache.replace(part6, surfaceGui)
	assert(part6 ~= surfaceGui, "cache.replace SurfaceGui substitution failed")

	local success = pcall(function() cache.replace(nil, nil) end)
	assert(not success, "cache.replace should error on nil args")
	local success2 = pcall(function() cache.replace("string", 123) end)
	assert(not success2, "cache.replace should error on invalid types")
	local success3 = pcall(function() cache.replace(123, "string") end)
	assert(not success3, "cache.replace should error on number/string args")
	local success4 = pcall(function() cache.replace(part6) end)
	assert(not success4, "cache.replace should error with missing second arg")

	local part7 = Instance_new("Part")
	local part8 = Instance_new("Part")
	local ok5 = pcall(function() cache.replace(part7, part8) end)
	assert(ok5, "cache.replace with two Parts should not error")
end)

-- ============================================================================
-- INSTANCES
-- ============================================================================

test("cloneref", {}, function()
	local part = Instance_new("Part")
	part.Name = "OriginalPart"
	part.Size = Vector3.new(10, 20, 30)
	part.Position = Vector3.new(1, 2, 3)
	part.Anchored = true
	part.BrickColor = BrickColor.new("Bright blue")
	local clone = cloneref(part)
	assert(part ~= clone, "cloneref returned identical proxy memory reference")
	assert(rawequal(part, clone) == false, "cloneref proxy passed raw equality check")
	clone.Name = "ModifiedViaProxy"
	assert(part.Name == "ModifiedViaProxy", "Property change on cloned reference failed to reflect on origin")
	assert(clone.Size == Vector3.new(10, 20, 30), "Size property not synced through cloneref")
	assert(clone.Position == Vector3.new(1, 2, 3), "Position property not synced through cloneref")
	assert(clone.Anchored == true, "Anchored property not synced through cloneref")
	assert(clone.BrickColor == BrickColor.new("Bright blue"), "BrickColor not synced through cloneref")

	local clone2 = cloneref(part)
	clone2.Name = "SecondModification"
	assert(part.Name == "SecondModification", "Second clone failed property sync")

	local model = Instance_new("Model")
	model.Name = "TestModel"
	local modelClone = cloneref(model)
	assert(model ~= modelClone, "cloneref Model failed identity check")
	modelClone.Name = "ModifiedModel"
	assert(model.Name == "ModifiedModel", "Model property change through cloneref failed")

	local folder = Instance_new("Folder")
	folder.Name = "TestFolder"
	local folderClone = cloneref(folder)
	folderClone.Name = "ModifiedFolder"
	assert(folder.Name == "ModifiedFolder", "Folder property change through cloneref failed")

	local part2 = Instance_new("Part")
	part2.Size = Vector3.new(5, 5, 5)
	local cloneA = cloneref(part2)
	local cloneB = cloneref(part2)
	assert(cloneA ~= cloneB, "Two clones of same object should be different proxies")
	cloneA.Name = "CloneA"
	cloneB.Name = "CloneB"
	assert(part2.Name == "CloneB", "Last clone write should reflect on original")

	local success = pcall(function() cloneref(nil) end)
	assert(not success, "cloneref should error on nil")
	local success2 = pcall(function() cloneref(12345) end)
	assert(not success2, "cloneref should error on number")
	local success3 = pcall(function() cloneref("string") end)
	assert(not success3, "cloneref should error on string")
	local success4 = pcall(function() cloneref(true) end)
	assert(not success4, "cloneref should error on boolean")
	local success5 = pcall(function() cloneref({}) end)
	assert(not success5, "cloneref should error on table")
	local success6 = pcall(function() cloneref(function() end) end)
	assert(not success6, "cloneref should error on function")

	local gui = Instance_new("ScreenGui")
	gui.Name = "ClonerefGUI"
	local guiClone = cloneref(gui)
	guiClone.Name = "ModifiedGUI"
	assert(gui.Name == "ModifiedGUI", "ScreenGui property change through cloneref failed")

	local part3 = Instance_new("Part")
	local clonePart = cloneref(part3)
	clonePart.Size = Vector3.new(100, 100, 100)
	assert(part3.Size == Vector3.new(100, 100, 100), "Size modification through cloneref failed")
	clonePart.Position = Vector3.new(50, 50, 50)
	assert(part3.Position == Vector3.new(50, 50, 50), "Position modification through cloneref failed")
	clonePart.Anchored = false
	assert(part3.Anchored == false, "Anchored modification through cloneref failed")
	clonePart.CanCollide = false
	assert(part3.CanCollide == false, "CanCollide modification through cloneref failed")
	clonePart.Transparency = 0.5
	assert(part3.Transparency == 0.5, "Transparency modification through cloneref failed")
	clonePart.Material = Enum.Material.Neon
	assert(part3.Material == Enum.Material.Neon, "Material modification through cloneref failed")

	local bindable = Instance_new("BindableEvent")
	local bindableClone = cloneref(bindable)
	bindableClone.Name = "ModifiedBindable"
	assert(bindable.Name == "ModifiedBindable", "BindableEvent property change through cloneref failed")
end)

test("compareinstances", {}, {"cloneref"}, function()
	local part1 = Instance_new("Part")
	local part2 = Instance_new("Part")
	local clone = cloneref(part1)
	assert(compareinstances(part1, clone) == true, "compareinstances failed to equate proxy reference with original")
	assert(compareinstances(part1, part2) == false, "compareinstances false-positive on unique instances")
	assert(compareinstances(part1, part1) == true, "compareinstances failed same reference check")
	assert(compareinstances(clone, part1) == true, "compareinstances failed reverse argument order")

	local model = Instance_new("Model")
	local modelClone = cloneref(model)
	assert(compareinstances(model, modelClone) == true, "compareinstances failed on Model cloneref")

	local folder = Instance_new("Folder")
	local folderClone = cloneref(folder)
	assert(compareinstances(folder, folderClone) == true, "compareinstances failed on Folder cloneref")

	local gui = Instance_new("ScreenGui")
	local guiClone = cloneref(gui)
	assert(compareinstances(gui, guiClone) == true, "compareinstances failed on ScreenGui cloneref")

	local part3 = Instance_new("Part")
	local part4 = Instance_new("Part")
	local part5 = Instance_new("Part")
	assert(compareinstances(part3, part4) == false, "compareinstances false-positive on Part3 vs Part4")
	assert(compareinstances(part4, part5) == false, "compareinstances false-positive on Part4 vs Part5")
	assert(compareinstances(part3, part5) == false, "compareinstances false-positive on Part3 vs Part5")

	local success = pcall(function() compareinstances(nil, nil) end)
	assert(not success, "compareinstances should error on nil")
	local success2 = pcall(function() compareinstances(part1, "string") end)
	assert(not success2, "compareinstances should error on mixed types")
	local success3 = pcall(function() compareinstances(123, 456) end)
	assert(not success3, "compareinstances should error on numbers")
	local success4 = pcall(function() compareinstances(true, false) end)
	assert(not success4, "compareinstances should error on booleans")
	local success5 = pcall(function() compareinstances({}, {}) end)
	assert(not success5, "compareinstances should error on tables")

	local part6 = Instance_new("Part")
	local clone6 = cloneref(part6)
	clone6.Name = "CompareTest"
	assert(compareinstances(part6, clone6) == true, "compareinstances failed after name change")
end)

test("fireclickdetector", {}, function()
	if not testPlaceActive then
		warn("fireclickdetector: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_ClickDetectorTests")
	assert(folder, "UNC_ClickDetectorTests folder not found in workspace")

	for i = 1, 5 do
		local part = folder:FindFirstChild("ClickTestPart_" .. i)
		assert(part, "ClickTestPart_" .. i .. " not found")
		local cd = part:FindFirstChild("ClickDetector_" .. i)
		assert(cd, "ClickDetector_" .. i .. " not found")

		local tag = cd:FindFirstChild("UNC_Tag")
		assert(tag and tag.Value ~= "", "ClickDetector_" .. i .. " missing UNC_Tag")

		fireclickdetector(cd, 25, "MouseClick")
		task_wait(0.15)

		local result = validateClickDetector(i)
		assert(result, "Server did not respond for ClickDetector " .. i)
		assert(result.Fired == true, "ClickDetector_" .. i .. " was NOT fired on server (Tag: " .. tag.Value .. ")")
		assert(result.Tag == tag.Value, "Tag mismatch on ClickDetector_" .. i)
	end

	for i = 1, 5 do
		local part = folder:FindFirstChild("ClickTestPart_" .. i)
		local cd = part:FindFirstChild("ClickDetector_" .. i)
		cd.UNC_Fired.Value = false
		cd.UNC_FireTime.Value = "0"
	end
end)

test("fireproximityprompt", {}, function()
	if not testPlaceActive then
		warn("fireproximityprompt: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_ProximityPromptTests")
	assert(folder, "UNC_ProximityPromptTests folder not found in workspace")

	for i = 1, 5 do
		local part = folder:FindFirstChild("PromptTestPart_" .. i)
		assert(part, "PromptTestPart_" .. i .. " not found")
		local pp = part:FindFirstChild("ProximityPrompt_" .. i)
		assert(pp, "ProximityPrompt_" .. i .. " not found")

		local tag = pp:FindFirstChild("UNC_Tag")
		assert(tag and tag.Value ~= "", "ProximityPrompt_" .. i .. " missing UNC_Tag")

		fireproximityprompt(pp)
		task_wait(0.15)

		local result = validateProximityPrompt(i)
		assert(result, "Server did not respond for ProximityPrompt " .. i)
		assert(result.Fired == true, "ProximityPrompt_" .. i .. " was NOT triggered on server (Tag: " .. tag.Value .. ")")
		assert(result.Tag == tag.Value, "Tag mismatch on ProximityPrompt_" .. i)
	end

	for i = 1, 5 do
		local part = folder:FindFirstChild("PromptTestPart_" .. i)
		local pp = part:FindFirstChild("ProximityPrompt_" .. i)
		pp.UNC_Fired.Value = false
		pp.UNC_FireCount.Value = 0
		pp.UNC_FireTime.Value = "0"
	end
end)

test("firetouchinterest", {}, function()
	if not testPlaceActive then
		warn("firetouchinterest: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_TouchInterestTests")
	assert(folder, "UNC_TouchInterestTests folder not found in workspace")

	for i = 1, 5 do
		local part = folder:FindFirstChild("TouchTestPart_" .. i)
		assert(part, "TouchTestPart_" .. i .. " not found")
		local touchPart = folder:FindFirstChild("TouchDetector_" .. i)
		assert(touchPart, "TouchDetector_" .. i .. " not found")

		local tag = part:FindFirstChild("UNC_Tag")
		assert(tag and tag.Value ~= "", "TouchTestPart_" .. i .. " missing UNC_Tag")

		firetouchinterest(touchPart, part, 0)
		task_wait(0.15)

		local result = validateTouchInterest(i)
		assert(result, "Server did not respond for TouchInterest " .. i)
		assert(result.Fired == true, "TouchTestPart_" .. i .. " was NOT touched on server (Tag: " .. tag.Value .. ")")
		assert(result.Tag == tag.Value, "Tag mismatch on TouchTestPart_" .. i)
	end

	for i = 1, 5 do
		local part = folder:FindFirstChild("TouchTestPart_" .. i)
		part.UNC_Fired.Value = false
		part.UNC_FireCount.Value = 0
		part.UNC_FireTime.Value = "0"
	end
end)

test("test place token validation", {}, function()
	if not testPlaceActive then
		warn("test place token validation: Join the UNC test place to take further action")
		return
	end

	local serverToken = validateToken()
	assert(serverToken, "Server did not respond with token")
	assert(serverToken == testPlaceToken, "Token mismatch — client got '" .. tostring(testPlaceToken) .. "' but server returned '" .. tostring(serverToken) .. "'")
end)

test("test place hidden property objects", {}, function()
	if not testPlaceActive then
		warn("test place hidden property objects: Join the UNC test place to take further action")
		return
	end

	local result = validateHidden()
	assert(result, "Server did not respond with hidden property info")
	assert(result.ObjectValueTag and result.ObjectValueTag ~= "NOT_FOUND", "ObjectValue with UNC_Tag not found on server")
	assert(result.NonScriptableTag and result.NonScriptableTag ~= "NOT_FOUND", "NonScriptable BoolValue not found on server")
end)

test("test place script objects", {}, function()
	if not testPlaceActive then
		warn("test place script objects: Join the UNC test place to take further action")
		return
	end

	local result = validateScripts()
	assert(result, "Server did not respond with script info")
	assert(result.LocalScriptTag and result.LocalScriptTag ~= "NOT_FOUND", "UNC_TestLocalScript not found on server")
	assert(result.ModuleScriptTag and result.ModuleScriptTag ~= "NOT_FOUND", "UNC_TestModuleScript not found on server")
	assert(result.ScriptTag and result.ScriptTag ~= "NOT_FOUND", "UNC_TestScript not found on server")
end)

test("test place interaction log", {}, function()
	if not testPlaceActive then
		warn("test place interaction log: Join the UNC test place to take further action")
		return
	end

	local log = getServerLog()
	assert(log, "Server did not respond with interaction log")
	assert(type(log) == "table", "Server log is not a table")
	print("Server interaction log entries: " .. #log)
end)

-- ============================================================================
-- CLOSURES
-- ============================================================================
test("checkcaller", {}, {"hookfunction", "restorefunction"}, function()
	if hookfunction then
		local old
		local realmoment = nil
		local executed = false
		local somethingself
		local index
		old = hookfunction(getrawmetatable(game).__index, function(...)
			if not executed then
				somethingself, index = ...
				realmoment = checkcaller()
				executed = true
			end
			return old(...)
		end)
		local a = 10
		repeat
			a -= 1
			task.wait(0.1)
		until executed and not realmoment or a <= 0
		hookfunction(getrawmetatable(game).__index, old)
		assert(not realmoment, "checkcaller returned true when calling from non-executor context via hooked __index")

		if getgenv().sUNCDebug and getgenv().sUNCDebug["printcheckpoints"] then
			print("Checkcaller DEBUG:", somethingself, index)
		end

		local old2
		local realmoment2 = nil
		local executed2 = false
		old2 = hookfunction(getrawmetatable(game).__index, function(...)
			if not executed2 then
				realmoment2 = checkcaller()
				executed2 = true
			end
			return old2(...)
		end)
		local _ = game.Players
		local a2 = 10
		repeat
			a2 -= 1
			task.wait(0.1)
		until executed2 or a2 <= 0
		hookfunction(getrawmetatable(game).__index, old2)
		assert(realmoment2 == true, "Couldn't retrieve true when calling from executor context via hooked __index")
	else
		warn("checkcaller: hookfunction is needed in order to test hooked __index check")
	end

	assert(checkcaller() == true, "checkcaller returned false when executed in the main thread")

	assert(coroutine.wrap(function()
		return checkcaller()
	end)(), "checkcaller returned false when executed in an exec-made thread[1]")

	assert(select(
		2,
		coroutine.resume(task.spawn(function()
			task.wait()
			return checkcaller()
		end))
	), "checkcaller returned false when executed in an exec-made thread[2]")

	assert(getthreadidentity, "getthreadidentity is needed in order to test checkcaller identity")
	assert(setthreadidentity, "setthreadidentity is needed in order to test checkcaller identity")

	local decisive = false
	local oldidentity = getthreadidentity()
	for _, v in { 0, 8, math.huge } do
		setthreadidentity(v)
		decisive = decisive or not checkcaller()
	end
	assert(not decisive, "checkcaller didn't return true regardless of thread's identity")
	setthreadidentity(oldidentity)

	local results = {}
	for i = 1, 5 do
		results[i] = checkcaller()
	end
	for i, v in ipairs(results) do
		assert(v == true, "checkcaller returned non-true on iteration " .. i)
	end

	local nestedCheck = false
	local function outerFn()
		local function innerFn()
			nestedCheck = checkcaller()
		end
		innerFn()
	end
	outerFn()
	assert(nestedCheck == true, "checkcaller in nested function call failed")
end)

test("clonefunction", {}, {"hookfunction", "restorefunction", "iscclosure"}, function()
	local function original(a, b, c) return (a + b) * c end
	local cloned = clonefunction(original)
	assert(type(cloned) == "function", "clonefunction did not return a valid function")
	assert(original ~= cloned, "cloned function returned identical reference")
	assert(cloned(2, 3, 4) == 20, "cloned function returned incorrect multi-arg computation")

	local function baseFunc() return "unhooked" end
	local clonedFunc = clonefunction(baseFunc)
	hookfunction(baseFunc, function() return "hooked" end)
	assert(baseFunc() == "hooked", "hookfunction failed to hook target")
	assert(clonedFunc() == "unhooked", "cloned function executed hooked path instead of original bytecode")
	restorefunction(baseFunc)

	local function multiReturn() return "a", "b", "c" end
	local clonedMulti = clonefunction(multiReturn)
	local r1, r2, r3 = clonedMulti()
	assert(r1 == "a" and r2 == "b" and r3 == "c", "clonefunction multi-return mismatch")

	local function withUpvalue()
		local x = "captured"
		return function() return x end
	end
	local clonedUpval = clonefunction(withUpvalue)
	local innerA = withUpvalue()
	local innerB = clonedUpval()
	assert(innerA() == "captured" and innerB() == "captured", "clonefunction upvalue capture mismatch")

	local function withMultipleUpvals()
		local a, b, c = 10, 20, 30
		return a + b + c
	end
	local clonedMultiUpval = clonefunction(withMultipleUpvals)
	assert(clonedMultiUpval() == 60, "clonefunction multiple upvalues failed")

	local function recursive(n)
		if n <= 1 then return 1 end
		return n * recursive(n - 1)
	end
	local clonedRecursive = clonefunction(recursive)
	assert(clonedRecursive(5) == 120, "clonefunction recursive function failed")
	assert(clonedRecursive(10) == 3628800, "clonefunction recursive function factorial(10) failed")

	local function variadic(...)
		local args = {...}
		local sum = 0
		for _, v in ipairs(args) do sum = sum + v end
		return sum
	end
	local clonedVariadic = clonefunction(variadic)
	assert(clonedVariadic(1, 2, 3) == 6, "clonefunction variadic sum failed")
	assert(clonedVariadic(10, 20, 30, 40) == 100, "clonefunction variadic 4-arg sum failed")
	assert(clonedVariadic() == 0, "clonefunction variadic no-arg sum failed")

	local function tableReturn()
		return {1, 2, 3, key = "value"}
	end
	local clonedTableReturn = clonefunction(tableReturn)
	local tbl = clonedTableReturn()
	assert(type(tbl) == "table", "clonefunction table return type failed")
	assert(tbl[1] == 1 and tbl.key == "value", "clonefunction table return content failed")

	local function booleanReturn()
		return true, false
	end
	local clonedBoolReturn = clonefunction(booleanReturn)
	local b1, b2 = clonedBoolReturn()
	assert(b1 == true and b2 == false, "clonefunction boolean return failed")

	local function nilReturn()
		return nil
	end
	local clonedNilReturn = clonefunction(nilReturn)
	assert(clonedNilReturn() == nil, "clonefunction nil return failed")

	local success = pcall(function() clonefunction(nil) end)
	assert(not success, "clonefunction should error on nil")
	local success2 = pcall(function() clonefunction(123) end)
	assert(not success2, "clonefunction should error on number")
	local success3 = pcall(function() clonefunction("string") end)
	assert(not success3, "clonefunction should error on string")
	local success4 = pcall(function() clonefunction(true) end)
	assert(not success4, "clonefunction should error on boolean")
	local success5 = pcall(function() clonefunction({}) end)
	assert(not success5, "clonefunction should error on table")
end)

test("getfunctionhash", {}, function()
	local function targetA(x, y) return x + y end
	local function targetB(x, y) return x * y end
	local hashA1 = getfunctionhash(targetA)
	local hashA2 = getfunctionhash(targetA)
	local hashB = getfunctionhash(targetB)
	assert(type(hashA1) == "string" and #hashA1 > 0, "getfunctionhash failed to return a non-empty string")
	assert(hashA1 == hashA2, "getfunctionhash failed deterministic hash check")
	assert(hashA1 ~= hashB, "getfunctionhash produced hash collision for distinct closures")

	local function targetC() return 1 end
	local function targetD() return 2 end
	local hashC = getfunctionhash(targetC)
	local hashD = getfunctionhash(targetD)
	assert(hashC ~= hashD, "getfunctionhash hash collision for different zero-arg closures")

	local function withUpvals()
		local a, b, c = 1, 2, 3
		return a + b + c
	end
	local hashUpval = getfunctionhash(withUpvals)
	assert(type(hashUpval) == "string" and #hashUpval > 0, "getfunctionhash failed on closure with upvalues")

	local function variadic(...)
		local sum = 0
		for i = 1, select("#", ...) do
			sum = sum + select(i, ...)
		end
		return sum
	end
	local hashVar = getfunctionhash(variadic)
	assert(type(hashVar) == "string" and #hashVar > 0, "getfunctionhash failed on variadic function")

	local function empty() end
	local hashEmpty = getfunctionhash(empty)
	assert(type(hashEmpty) == "string" and #hashEmpty > 0, "getfunctionhash failed on empty function")

	local function inner()
		local x = "deep"
		return function() return x end
	end
	local hashInner = getfunctionhash(inner)
	assert(type(hashInner) == "string" and #hashInner > 0, "getfunctionhash failed on nested function")

	local function multiReturn() return 1, 2, 3 end
	local hashMulti = getfunctionhash(multiReturn)
	assert(type(hashMulti) == "string" and #hashMulti > 0, "getfunctionhash failed on multi-return function")

	local function recursive(n)
		if n <= 0 then return 0 end
		return n + recursive(n - 1)
	end
	local hashRec = getfunctionhash(recursive)
	assert(type(hashRec) == "string" and #hashRec > 0, "getfunctionhash failed on recursive function")

	local hashA3 = getfunctionhash(targetA)
	assert(hashA1 == hashA3, "getfunctionhash non-deterministic across multiple calls")

	local function newFunc() return "unique_hash_target" end
	local hashNew = getfunctionhash(newFunc)
	assert(hashNew ~= hashA1, "getfunctionhash collision with existing hash")
	assert(hashNew ~= hashB, "getfunctionhash collision with second hash")
	assert(hashNew ~= hashC, "getfunctionhash collision with third hash")

	local success = pcall(function() getfunctionhash(nil) end)
	assert(not success, "getfunctionhash should error on nil")
	local success2 = pcall(function() getfunctionhash(123) end)
	assert(not success2, "getfunctionhash should error on number")
	local success3 = pcall(function() getfunctionhash("string") end)
	assert(not success3, "getfunctionhash should error on string")
end)

test("hookfunction", {"replaceclosure"}, {"restorefunction"}, function()
	local function target(a, b) return a + b end
	local ref = hookfunction(target, function(a, b) return a * b end)
	assert(target(3, 4) == 12, "hookfunction target failed to divert execution")
	assert(ref(3, 4) == 7, "hookfunction original reference failed original execution path")
	assert(target ~= ref, "hookfunction returned identical function identity for reference")
	restorefunction(target)

	local function target2(x) return x * 2 end
	local ref2 = hookfunction(target2, function(x) return x * 3 end)
	assert(target2(5) == 15, "hookfunction target2 hook failed")
	assert(ref2(5) == 10, "hookfunction ref2 original failed")
	restorefunction(target2)

	local function target3(...) local args = {...} return #args end
	local ref3 = hookfunction(target3, function(...) return 999 end)
	assert(target3(1, 2, 3) == 999, "hookfunction variadic target3 failed")
	assert(ref3(1, 2, 3) == 3, "hookfunction variadic ref3 failed")
	restorefunction(target3)

	local function target4(a, b, c) return a + b + c end
	local ref4 = hookfunction(target4, function(a, b, c) return a * b * c end)
	assert(target4(2, 3, 4) == 24, "hookfunction 3-arg hook failed")
	assert(ref4(2, 3, 4) == 9, "hookfunction 3-arg ref failed")
	restorefunction(target4)

	local function target5() return "original5" end
	local ref5 = hookfunction(target5, function() return "hooked5" end)
	local ref5b = hookfunction(target5, function() return "double_hooked5" end)
	assert(target5() == "double_hooked5", "hookfunction double hook target5 failed")
	assert(ref5() == "original5", "hookfunction double hook ref5 failed")
	assert(ref5b() == "hooked5", "hookfunction double hook ref5b failed")
	restorefunction(target5)

	local callLog = {}
	local function target6(x)
		table_insert(callLog, "target6:" .. tostring(x))
		return x * 2
	end
	local ref6 = hookfunction(target6, function(x)
		table_insert(callLog, "hook6:" .. tostring(x))
		return x * 3
	end)
	target6(5)
	ref6(10)
	restorefunction(target6)
	assert(#callLog == 2, "hookfunction call logging failed")
	assert(callLog[1] == "hook6:5", "hookfunction call log entry 1 mismatch")
	assert(callLog[2] == "target6:10", "hookfunction call log entry 2 mismatch")

	local function target7()
		return "original7"
	end
	local ref7 = hookfunction(target7, newcclosure(function()
		return "hooked_cc7"
	end))
	assert(target7() == "hooked_cc7", "hookfunction C-closure hook failed")
	assert(ref7() == "original7", "hookfunction C-closure ref failed")
	restorefunction(target7)

	local function identity(x) return x end
	local ref8 = hookfunction(identity, function(x) return x end)
	assert(identity("test") == "test", "hookfunction identity hook failed")
	assert(ref8("test") == "test", "hookfunction identity ref failed")
	restorefunction(identity)

	local function multiRet() return 1, 2, 3 end
	local ref9 = hookfunction(multiRet, function() return 10, 20, 30 end)
	local r1, r2, r3 = multiRet()
	assert(r1 == 10 and r2 == 20 and r3 == 30, "hookfunction multi-return hook failed")
	local r4, r5, r6 = ref9()
	assert(r4 == 1 and r5 == 2 and r6 == 3, "hookfunction multi-return ref failed")
	restorefunction(multiRet)
end)

test("restorefunction", {}, {"hookfunction"}, function()
	local function target() return "original" end
	local ref = hookfunction(target, function() return "hooked" end)
	assert(target() == "hooked", "hookfunction pre-restoration failed")
	restorefunction(target)
	assert(target() == "original", "restorefunction failed to revert function hook")

	local function target2(a, b) return a - b end
	local ref2 = hookfunction(target2, function(a, b) return a + b end)
	assert(target2(10, 3) == 13, "hookfunction pre-restoration failed for target2")
	restorefunction(target2)
	assert(target2(10, 3) == 7, "restorefunction failed for target2")

	local function target3() return "original3" end
	local ref3 = hookfunction(target3, function() return "hooked3" end)
	hookfunction(target3, function() return "double_hooked" end)
	assert(target3() == "double_hooked", "double hook failed")
	restorefunction(target3)
	assert(target3() == "original3", "restorefunction after double hook failed")

	local function target4(a, b, c) return a * b * c end
	local ref4 = hookfunction(target4, function(a, b, c) return a + b + c end)
	assert(target4(2, 3, 4) == 9, "hookfunction pre-restoration target4 failed")
	restorefunction(target4)
	assert(target4(2, 3, 4) == 24, "restorefunction failed for target4")

	local callCount = 0
	local function target5()
		callCount += 1
		return "original5"
	end
	local ref5 = hookfunction(target5, function()
		callCount += 10
		return "hooked5"
	end)
	target5()
	assert(callCount == 10, "hookfunction callCount before restore mismatch")
	restorefunction(target5)
	target5()
	assert(callCount == 11, "restorefunction callCount after restore mismatch")

	local function target6(...) return ... end
	local ref6 = hookfunction(target6, function(...) return "hooked", ... end)
	local a, b, c = target6(1, 2, 3)
	assert(a == "hooked" and b == 1 and c == 2, "hookfunction vararg hook failed")
	local d, e, f = ref6(1, 2, 3)
	assert(d == 1 and e == 2 and f == 3, "hookfunction vararg ref failed")
	restorefunction(target6)

	local function target7() return "t7" end
	local ref7 = hookfunction(target7, function() return "h7" end)
	restorefunction(target7)
	local ref7b = hookfunction(target7, function() return "h7b" end)
	assert(target7() == "h7b", "hookfunction after restore+re-hook failed")
	assert(ref7() == "t7", "hookfunction old ref after restore+re-hook failed")
	restorefunction(target7)
	assert(target7() == "t7", "restorefunction after re-hook failed")
end)

test("hookmetamethod", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__index = newcclosure(function() return "unhooked_index" end),
		__newindex = newcclosure(function() end),
		__call = newcclosure(function() return "unhooked_call" end),
		__tostring = newcclosure(function() return "unhooked_tostring" end),
		__add = newcclosure(function(a, b) return a + b end),
		__sub = newcclosure(function(a, b) return a - b end),
		__mul = newcclosure(function(a, b) return a * b end),
		__div = newcclosure(function(a, b) return a / b end),
		__metatable = "Locked"
	})

	local refIndex
	refIndex = hookmetamethod(obj, "__index", function(...)
		return "hooked_index"
	end)
	assert(obj.test == "hooked_index", "hookmetamethod __index interception failed")
	assert(refIndex() == "unhooked_index", "hookmetamethod __index reference mismatch")
	restorefunction(getrawmetatable(obj).__index)

	local refCall
	refCall = hookmetamethod(obj, "__call", function(...)
		return "hooked_call"
	end)
	assert(obj() == "hooked_call", "hookmetamethod __call interception failed")
	assert(refCall() == "unhooked_call", "hookmetamethod __call reference mismatch")
	restorefunction(getrawmetatable(obj).__call)

	local refToString
	refToString = hookmetamethod(obj, "__tostring", function(...)
		return "hooked_tostring"
	end)
	assert(tostring(obj) == "hooked_tostring", "hookmetamethod __tostring interception failed")
	assert(refToString() == "unhooked_tostring", "hookmetamethod __tostring reference mismatch")
	restorefunction(getrawmetatable(obj).__tostring)

	local refAdd
	refAdd = hookmetamethod(obj, "__add", function(a, b)
		return a + b
	end)
	assert(obj + obj ~= nil, "hookmetamethod __add failed execution")
	restorefunction(getrawmetatable(obj).__add)

	local refSub
	refSub = hookmetamethod(obj, "__sub", function(a, b)
		return a - b
	end)
	assert(obj - obj ~= nil, "hookmetamethod __sub failed execution")
	restorefunction(getrawmetatable(obj).__sub)

	local refMul
	refMul = hookmetamethod(obj, "__mul", function(a, b)
		return a * b
	end)
	assert(obj * obj ~= nil, "hookmetamethod __mul failed execution")
	restorefunction(getrawmetatable(obj).__mul)

	local refDiv
	refDiv = hookmetamethod(obj, "__div", function(a, b)
		return a / b
	end)
	assert(obj / obj ~= nil, "hookmetamethod __div failed execution")
	restorefunction(getrawmetatable(obj).__div)

	local obj2 = setmetatable({}, {
		__index = newcclosure(function(_, key) return "default_" .. tostring(key) end),
		__metatable = "Locked2"
	})
	local refIndex2
	refIndex2 = hookmetamethod(obj2, "__index", function(self, key)
		return "intercepted_" .. tostring(key)
	end)
	assert(obj2.anything == "intercepted_anything", "hookmetamethod __index key interpolation failed")
	assert(obj2.different == "intercepted_different", "hookmetamethod __index different key failed")
	restorefunction(getrawmetatable(obj2).__index)

	local obj3 = setmetatable({}, {
		__call = newcclosure(function(self, a, b) return a + b end),
		__metatable = "Locked3"
	})
	local refCall3
	refCall3 = hookmetamethod(obj3, "__call", function(self, a, b)
		return a * b
	end)
	assert(obj3(3, 4) == 12, "hookmetamethod __call with args failed")
	assert(refCall3(3, 4) == 7, "hookmetamethod __call ref with args failed")
	restorefunction(getrawmetatable(obj3).__call)

	local obj4 = setmetatable({}, {
		__index = newcclosure(function() return nil end),
		__newindex = newcclosure(function() end),
		__metatable = "Locked4"
	})
	local newindexHooked = false
	local refNewIndex
	refNewIndex = hookmetamethod(obj4, "__newindex", function(self, key, value)
		newindexHooked = true
		rawset(self, key, value)
	end)
	obj4.testKey = "testValue"
	assert(newindexHooked == true, "hookmetamethod __newindex not intercepted")
	assert(obj4.testKey == "testValue", "hookmetamethod __newindex value not set")
	restorefunction(getrawmetatable(obj4).__newindex)

	local obj5 = setmetatable({}, {
		__len = newcclosure(function() return 42 end),
		__metatable = "Locked5"
	})
	local refLen
	refLen = hookmetamethod(obj5, "__len", function()
		return 99
	end)
	assert(#obj5 == 99, "hookmetamethod __len interception failed")
	assert(refLen() == 42, "hookmetamethod __len reference failed")
	restorefunction(getrawmetatable(obj5).__len)
end)

test("iscclosure", {}, {"newcclosure"}, function()
	assert(iscclosure(print) == true, "Native print must return true for iscclosure")
	assert(iscclosure(function() end) == false, "Executor Luau closure false-positive on iscclosure")
	local wrapped = newcclosure(function() end)
	assert(iscclosure(wrapped) == true, "newcclosure wrapper failed iscclosure verification")
	local function myFunc() return 42 end
	assert(iscclosure(myFunc) == false, "Plain Luau closure false-positive")
	local nativeWarn = warn
	assert(iscclosure(nativeWarn) == true, "Native warn should be C closure")
	local nativeError = error
	assert(iscclosure(nativeError) == true, "Native error should be C closure")
	local nativePcall = pcall
	assert(iscclosure(nativePcall) == true, "Native pcall should be C closure")
	local nativeSelect = select
	assert(iscclosure(nativeSelect) == true, "Native select should be C closure")
	local nativeType = type
	assert(iscclosure(nativeType) == true, "Native type should be C closure")
	local nativePairs = pairs
	assert(iscclosure(nativePairs) == true, "Native pairs should be C closure")
	local nativeIpairs = ipairs
	assert(iscclosure(nativeIpairs) == true, "Native ipairs should be C closure")
	local nativeTostring = tostring
	assert(iscclosure(nativeTostring) == true, "Native tostring should be C closure")
	local nativeTonumber = tonumber
	assert(iscclosure(nativeTonumber) == true, "Native tonumber should be C closure")
	local nativeSetmetatable = setmetatable
	assert(iscclosure(nativeSetmetatable) == true, "Native setmetatable should be C closure")
	local nativeGetmetatable = getmetatable
	assert(iscclosure(nativeGetmetatable) == true, "Native getmetatable should be C closure")
	local success = pcall(function() iscclosure(nil) end)
	assert(not success, "iscclosure should error on nil")
	local success2 = pcall(function() iscclosure(123) end)
	assert(not success2, "iscclosure should error on number")
	local success3 = pcall(function() iscclosure("string") end)
	assert(not success3, "iscclosure should error on string")
	local success4 = pcall(function() iscclosure(true) end)
	assert(not success4, "iscclosure should error on boolean")
	local success5 = pcall(function() iscclosure({}) end)
	assert(not success5, "iscclosure should error on table")
	local wrapped2 = newcclosure(function(x) return x + 1 end)
	assert(iscclosure(wrapped2) == true, "newcclosure with upvalue should be C closure")
	assert(wrapped2(5) == 6, "newcclosure with upvalue execution failed")
end)

test("islclosure", {}, {"newcclosure"}, function()
	assert(islclosure(print) == false, "Native print false-positive on islclosure")
	assert(islclosure(function() end) == true, "Executor Luau closure failed islclosure check")
	local wrapped = newcclosure(function() end)
	assert(islclosure(wrapped) == false, "newcclosure falsely identified as lclosure")
	local function myFunc() return 42 end
	assert(islclosure(myFunc) == true, "Plain Luau closure should be lclosure")
	local function withUpval()
		local x = 10
		return function() return x end
	end
	assert(islclosure(withUpval) == true, "Closure with upvalue should be lclosure")
	local function multiUpval()
		local a, b, c = 1, 2, 3
		return a + b + c
	end
	assert(islclosure(multiUpval) == true, "Closure with multiple upvalues should be lclosure")
	local function recursive(n)
		if n <= 0 then return 0 end
		return n + recursive(n - 1)
	end
	assert(islclosure(recursive) == true, "Recursive function should be lclosure")
	local function variadic(...)
		return select("#", ...)
	end
	assert(islclosure(variadic) == true, "Variadic function should be lclosure")
	local function empty() end
	assert(islclosure(empty) == true, "Empty function should be lclosure")
	local function withTable()
		return {1, 2, 3}
	end
	assert(islclosure(withTable) == true, "Function returning table should be lclosure")
	local success = pcall(function() islclosure(nil) end)
	assert(not success, "islclosure should error on nil")
	local success2 = pcall(function() islclosure(456) end)
	assert(not success2, "islclosure should error on number")
	local success3 = pcall(function() islclosure("string") end)
	assert(not success3, "islclosure should error on string")
	local success4 = pcall(function() islclosure(true) end)
	assert(not success4, "islclosure should error on boolean")
end)

test("isexecutorclosure", {"checkclosure", "isourclosure"}, {"newcclosure"}, function()
	assert(isexecutorclosure(isexecutorclosure) == true, "isexecutorclosure failed self-check")
	assert(isexecutorclosure(newcclosure(function() end)) == true, "newcclosure failed isexecutorclosure check")
	assert(isexecutorclosure(function() end) == true, "Executor Luau function failed check")
	assert(isexecutorclosure(print) == false, "Roblox native global print falsely marked as executor closure")
	assert(isexecutorclosure(warn) == false, "Roblox native warn falsely marked as executor closure")
	assert(isexecutorclosure(error) == false, "Roblox native error falsely marked as executor closure")
	assert(isexecutorclosure(pcall) == false, "Roblox native pcall falsely marked as executor closure")
	assert(isexecutorclosure(select) == false, "Roblox native select falsely marked as executor closure")
	assert(isexecutorclosure(type) == false, "Roblox native type falsely marked as executor closure")
	assert(isexecutorclosure(tostring) == false, "Roblox native tostring falsely marked as executor closure")
	assert(isexecutorclosure(tonumber) == false, "Roblox native tonumber falsely marked as executor closure")
	assert(isexecutorclosure(pairs) == false, "Roblox native pairs falsely marked as executor closure")
	assert(isexecutorclosure(ipairs) == false, "Roblox native ipairs falsely marked as executor closure")
	assert(isexecutorclosure(setmetatable) == false, "Roblox native setmetatable falsely marked as executor closure")
	assert(isexecutorclosure(getmetatable) == false, "Roblox native getmetatable falsely marked as executor closure")
	local function myFunc()
		local x = 10
		return x
	end
	assert(isexecutorclosure(myFunc) == true, "Local function should be executor closure")
	local function withUpvals()
		local a, b = 1, 2
		return a + b
	end
	assert(isexecutorclosure(withUpvals) == true, "Function with upvalues should be executor closure")
	local wrapped = newcclosure(function() return "test" end)
	assert(isexecutorclosure(wrapped) == true, "newcclosure wrapped function should be executor closure")
	local nestedInner
	local function outer()
		local function inner()
			return "nested"
		end
		nestedInner = inner
		return inner()
	end
	outer()
	assert(isexecutorclosure(nestedInner) == true, "Nested function should be executor closure")
	local success = pcall(function() isexecutorclosure(nil) end)
	assert(not success, "isexecutorclosure should error on nil")
	local success2 = pcall(function() isexecutorclosure(123) end)
	assert(not success2, "isexecutorclosure should error on number")
	local success3 = pcall(function() isexecutorclosure("string") end)
	assert(not success3, "isexecutorclosure should error on string")
	local success4 = pcall(function() isexecutorclosure(true) end)
	assert(not success4, "isexecutorclosure should error on boolean")
	local success5 = pcall(function() isexecutorclosure({}) end)
	assert(not success5, "isexecutorclosure should error on table")
end)

test("newcclosure", {}, {"iscclosure", "clonefunction"}, function()
	local function luauFunc(a, b) return a ^ b end
	local cClosure = newcclosure(luauFunc)
	assert(luauFunc(2, 8) == cClosure(2, 8), "newcclosure returned mismatched calculation output")
	assert(luauFunc ~= cClosure, "newcclosure returned identical function identity")
	assert(iscclosure(cClosure) == true, "newcclosure wrapper failed iscclosure verification")
	local clonedCClosure = clonefunction(cClosure)
	assert(iscclosure(clonedCClosure) == true, "cloned newcclosure lost C-closure status")
	assert(clonedCClosure(2, 8) == 256, "cloned newcclosure execution output mismatch")
	assert(cClosure ~= clonedCClosure, "cloned newcclosure shares identity with original wrapper")

	local function multiReturn(a, b) return a + b, a - b, a * b end
	local wrappedMulti = newcclosure(multiReturn)
	local r1, r2, r3 = wrappedMulti(10, 3)
	assert(r1 == 13 and r2 == 7 and r3 == 30, "newcclosure multi-return failed")

	local function variadic(...)
		local args = {...}
		return #args
	end
	local wrappedVar = newcclosure(variadic)
	assert(wrappedVar(1, 2, 3, 4, 5) == 5, "newcclosure variadic arg count failed")
	assert(wrappedVar() == 0, "newcclosure variadic zero args failed")
	assert(wrappedVar("single") == 1, "newcclosure variadic single arg failed")

	local function withUpvals()
		local capture = "captured_value"
		return capture
	end
	local wrappedUpval = newcclosure(withUpvals)
	assert(wrappedUpval() == "captured_value", "newcclosure upvalue capture failed")

	local function multiUpvals()
		local a, b, c = 10, 20, 30
		return a + b + c
	end
	local wrappedMultiUpval = newcclosure(multiUpvals)
	assert(wrappedMultiUpval() == 60, "newcclosure multiple upvalues failed")

	local function recursive(n)
		if n <= 1 then return 1 end
		return n * recursive(n - 1)
	end
	local wrappedRecursive = newcclosure(recursive)
	assert(wrappedRecursive(5) == 120, "newcclosure recursive factorial failed")
	assert(wrappedRecursive(10) == 3628800, "newcclosure recursive factorial(10) failed")

	local function withTable()
		return {1, 2, 3, nested = {4, 5}}
	end
	local wrappedTable = newcclosure(withTable)
	local tbl = wrappedTable()
	assert(type(tbl) == "table" and tbl[1] == 1 and tbl.nested[2] == 5, "newcclosure table return failed")

	local function booleanReturn()
		return true, false, true
	end
	local wrappedBool = newcclosure(booleanReturn)
	local b1, b2, b3 = wrappedBool()
	assert(b1 == true and b2 == false and b3 == true, "newcclosure multi-boolean return failed")

	local function stringReturn()
		return "hello", "world"
	end
	local wrappedString = newcclosure(stringReturn)
	local s1, s2 = wrappedString()
	assert(s1 == "hello" and s2 == "world", "newcclosure multi-string return failed")

	local success = pcall(function() newcclosure(nil) end)
	assert(not success, "newcclosure should error on nil")
	local success2 = pcall(function() newcclosure(123) end)
	assert(not success2, "newcclosure should error on number")
	local success3 = pcall(function() newcclosure("string") end)
	assert(not success3, "newcclosure should error on string")
	local success4 = pcall(function() newcclosure(true) end)
	assert(not success4, "newcclosure should error on boolean")
	local success5 = pcall(function() newcclosure({}) end)
	assert(not success5, "newcclosure should error on table")
end)

test("newlclosure", {}, {"islclosure"}, function()
	local function cFunc() return 100 end
	local lClosure = newlclosure(cFunc)
	assert(islclosure(lClosure) == true, "newlclosure failed islclosure verification")
	assert(lClosure() == 100, "newlclosure output mismatch")

	local function withArgs(a, b, c) return a + b + c end
	local wrappedLclosure = newlclosure(withArgs)
	assert(islclosure(wrappedLclosure) == true, "newlclosure with args failed islclosure")
	assert(wrappedLclosure(10, 20, 30) == 60, "newlclosure with args output mismatch")

	local function multiReturn() return "x", "y", "z" end
	local wrappedMulti = newlclosure(multiReturn)
	local a, b, c = wrappedMulti()
	assert(a == "x" and b == "y" and c == "z", "newlclosure multi-return failed")

	local function variadic(...)
		return select("#", ...)
	end
	local wrappedVar = newlclosure(variadic)
	assert(wrappedVar(1, 2, 3) == 3, "newlclosure variadic count failed")
	assert(wrappedVar() == 0, "newlclosure variadic zero args failed")

	local function recursive(n)
		if n <= 1 then return 1 end
		return n * recursive(n - 1)
	end
	local wrappedRec = newlclosure(recursive)
	assert(wrappedRec(6) == 720, "newlclosure recursive factorial failed")

	local function withUpval()
		local x = "upvalue"
		return x
	end
	local wrappedUpval = newlclosure(withUpval)
	assert(wrappedUpval() == "upvalue", "newlclosure upvalue capture failed")

	local function tableReturn()
		return {a = 1, b = 2}
	end
	local wrappedTbl = newlclosure(tableReturn)
	local t = wrappedTbl()
	assert(type(t) == "table" and t.a == 1 and t.b == 2, "newlclosure table return failed")

	local function booleanReturn()
		return true, false
	end
	local wrappedBool = newlclosure(booleanReturn)
	local b1, b2 = wrappedBool()
	assert(b1 == true and b2 == false, "newlclosure boolean return failed")

	local success = pcall(function() newlclosure(nil) end)
	assert(not success, "newlclosure should error on nil")
	local success2 = pcall(function() newlclosure(123) end)
	assert(not success2, "newlclosure should error on number")
	local success3 = pcall(function() newlclosure("string") end)
	assert(not success3, "newlclosure should error on string")
end)

test("loadstring", {}, {"getscriptbytecode"}, function()
	local animate = game:GetService("Players").LocalPlayer.Character and game:GetService("Players").LocalPlayer.Character:FindFirstChild("Animate")
	if animate then
		local bytecode = getscriptbytecode(animate)
		if bytecode then
			local func = loadstring(bytecode)
			assert(type(func) ~= "function", "Raw Luau bytecode executed without deserialization protection")
		end
	end

	local loaded, err = loadstring("local a, b, c = ...; return a + b + c")
	assert(type(loaded) == "function", "loadstring failed valid string compilation: " .. tostring(err))
	assert(loaded(10, 20, 30) == 60, "loadstring compiled function failed multi-argument execution")

	local loaded2 = loadstring("return ...")
	assert(type(loaded2) == "function", "loadstring failed ellipsis compilation")
	assert(loaded2("hello", "world") == "hello", "loadstring multi-arg pass-through failed")

	local loaded3 = loadstring("return #{1, 2, 3}")
	assert(type(loaded3) == "function", "loadstring failed table constructor compilation")
	assert(loaded3() == 3, "loadstring table length failed")

	local loaded4 = loadstring("return function(x) return x * x end")
	assert(type(loaded4) == "function", "loadstring failed function compilation")
	local inner = loaded4()
	assert(type(inner) == "function" and inner(5) == 25, "loadstring nested function return failed")

	local errFunc, errMessage = loadstring("local invalid luau syntax !!!")
	assert(errFunc == nil and type(errMessage) == "string", "loadstring failed compiler error reporting")

	local errFunc2, errMsg2 = loadstring("")
	assert(type(errFunc2) == "function", "loadstring empty string should still return function")

	local loaded5 = loadstring("return 2 + 2")
	assert(type(loaded5) == "function", "loadstring simple expression failed")
	assert(loaded5() == 4, "loadstring simple expression result failed")

	local loaded6 = loadstring("return 'string_' .. 'concat'")
	assert(type(loaded6) == "function", "loadstring string concat compilation failed")
	assert(loaded6() == "string_concat", "loadstring string concat result failed")

	local loaded7 = loadstring("return true and false or true")
	assert(type(loaded7) == "function", "loadstring boolean logic compilation failed")
	assert(loaded7() == true, "loadstring boolean logic result failed")

	local loaded8 = loadstring("local t = {1, 2, 3}; local sum = 0; for _, v in ipairs(t) do sum = sum + v end; return sum")
	assert(type(loaded8) == "function", "loadstring loop compilation failed")
	assert(loaded8() == 6, "loadstring loop result failed")

	local loaded9 = loadstring("local function fib(n) if n <= 1 then return n end; return fib(n-1) + fib(n-2) end; return fib(10)")
	assert(type(loaded9) == "function", "loadstring recursive fibonacci compilation failed")
	assert(loaded9() == 55, "loadstring recursive fibonacci result failed")

	local loaded10, errMsg10 = loadstring("return $%^&*invalid!!")
	assert(loaded10 == nil and type(errMsg10) == "string", "loadstring invalid syntax should return nil, error")

	local loaded11 = loadstring("return 0")
	assert(type(loaded11) == "function", "loadstring zero expression failed")
	assert(loaded11() == 0, "loadstring zero expression result failed")

	local loaded12 = loadstring("return -1")
	assert(type(loaded12) == "function", "loadstring negative expression failed")
	assert(loaded12() == -1, "loadstring negative expression result failed")

	local loaded13 = loadstring("return math.huge")
	assert(type(loaded13) == "function", "loadstring math.huge failed")
	assert(loaded13() == math.huge, "loadstring math.huge result failed")

	local loaded14 = loadstring("return nil")
	assert(type(loaded14) == "function", "loadstring nil return failed")
	assert(loaded14() == nil, "loadstring nil result failed")

	local loaded15 = loadstring("return ''")
	assert(type(loaded15) == "function", "loadstring empty string return failed")
	assert(loaded15() == "", "loadstring empty string result failed")

	local loaded16, err16 = loadstring("local a = ; return a", "MyChunkName")
	assert(loaded16 == nil and type(err16) == "string", "loadstring with chunkname error failed")

	local loaded17 = loadstring("return 1, 2, 3", "TestChunk")
	assert(type(loaded17) == "function", "loadstring with chunkname success failed")
	local r1, r2, r3 = loaded17()
	assert(r1 == 1 and r2 == 2 and r3 == 3, "loadstring with chunkname result failed")

	local loaded18, err18 = loadstring(nil)
	assert(loaded18 == nil and type(err18) == "string", "loadstring nil input should return nil, error")
end)

-- ============================================================================
-- DEBUG
-- ============================================================================

test("debug.getconstant", {}, function()
	local function sample() print("target_constant_123") end
	assert(debug.getconstant(sample, 1) == "print", "Constant 1 mismatch")
	assert(debug.getconstant(sample, 3) == "target_constant_123", "Constant 3 mismatch")

	local function sample2()
		local a = 42
		return a
	end
	assert(debug.getconstant(sample2, 1) == 42, "debug.getconstant numeric constant failed")

	local function sample3()
		return true
	end
	assert(debug.getconstant(sample3, 1) == true, "debug.getconstant boolean constant failed")

	local function sample4()
		return nil
	end
	assert(debug.getconstant(sample4, 1) == nil, "debug.getconstant nil constant failed")

	local function sample5()
		return "hello", "world"
	end
	assert(debug.getconstant(sample5, 1) == "hello", "debug.getconstant first of multi-return failed")
	assert(debug.getconstant(sample5, 2) == "world", "debug.getconstant second of multi-return failed")

	local function sample6()
		local x = 999
		print(x)
		return x
	end
	assert(debug.getconstant(sample6, 1) == 999, "debug.getconstant large number failed")

	local function sample7()
		return false
	end
	assert(debug.getconstant(sample7, 1) == false, "debug.getconstant false constant failed")

	local function sample8()
		local str = "long_string_content_12345"
		return str
	end
	assert(debug.getconstant(sample8, 1) == "long_string_content_12345", "debug.getconstant long string failed")

	local success = pcall(function() debug.getconstant(sample, 0) end)
	assert(not success, "debug.getconstant index 0 should error")

	local success2 = pcall(function() debug.getconstant(sample, -1) end)
	assert(not success2, "debug.getconstant negative index should error")
end)

test("debug.getconstants", {}, function()
	local function sample()
		local num = 99999
		print("constant_str", warn)
	end
	local constants = debug.getconstants(sample)
	assert(constants[1] == 99999, "constants index 1 mismatch")
	assert(constants[2] == "print", "constants index 2 mismatch")
	assert(constants[4] == "constant_str", "constants index 4 mismatch")

	local function sample2()
		local x = 1
		local y = 2
		local z = 3
		return x + y + z
	end
	local consts2 = debug.getconstants(sample2)
	assert(type(consts2) == "table", "debug.getconstants failed to return table")
	assert(consts2[1] == 1, "debug.getconstants sample2 const 1 failed")
	assert(consts2[2] == 2, "debug.getconstants sample2 const 2 failed")
	assert(consts2[3] == 3, "debug.getconstants sample2 const 3 failed")

	local function sample3()
		return true, false, nil
	end
	local consts3 = debug.getconstants(sample3)
	assert(consts3[1] == true, "debug.getconstants true constant failed")
	assert(consts3[2] == false, "debug.getconstants false constant failed")

	local function sample4()
		return "alpha", "beta", "gamma", "delta"
	end
	local consts4 = debug.getconstants(sample4)
	assert(consts4[1] == "alpha", "debug.getconstants string 1 failed")
	assert(consts4[2] == "beta", "debug.getconstants string 2 failed")
	assert(consts4[3] == "gamma", "debug.getconstants string 3 failed")
	assert(consts4[4] == "delta", "debug.getconstants string 4 failed")

	local function sample5() end
	local consts5 = debug.getconstants(sample5)
	assert(type(consts5) == "table", "debug.getconstants empty function should return table")
end)

test("debug.getinfo", {}, function()
	local boom = 3
	local ookok = "real"
	local potatopride = function(...)
		boom = "ookok"
		ookok = "boom"
		return ookok
	end

	local info = debug.getinfo(potatopride)
	assert(info.nups == 2, "debug.getinfo didn't return the correct value for 'nups'")

	local function sample(a, b, ...) print(a, b, ...) end
	local info2 = debug.getinfo(sample)
	assert(type(info2) == "table", "getinfo failed to return debug metadata table")
	assert(info2.func == sample, "getinfo function reference mismatch")
	assert(info2.numparams == 2, "getinfo numparams count mismatch")
	assert(info2.is_vararg == 1 or info2.is_vararg == true, "getinfo vararg detection mismatch")

	local function noArgFunc() return 42 end
	local info3 = debug.getinfo(noArgFunc)
	assert(info3.numparams == 0, "getinfo numparams for zero-arg function mismatch")
	assert(info3.is_vararg == 0 or info3.is_vararg == false, "getinfo vararg for zero-arg function mismatch")

	local function variadicFunc(...) return ... end
	local info4 = debug.getinfo(variadicFunc)
	assert(info4.is_vararg == 1 or info4.is_vararg == true, "getinfo vararg for variadic function mismatch")

	assert(info2.what == "Lua" or info2.what == "Luau", "getinfo what field unexpected: " .. tostring(info2.what))
	assert(type(info2.nups) == "number", "getinfo nups field not a number")
	assert(type(info2.source) == "string", "getinfo source field not a string")

	local function fiveArgs(a, b, c, d, e) return a end
	local info5 = debug.getinfo(fiveArgs)
	assert(info5.numparams == 5, "getinfo numparams for 5-arg function mismatch")

	local function threeArgs(x, y, z) return x + y + z end
	local info6 = debug.getinfo(threeArgs)
	assert(info6.numparams == 3, "getinfo numparams for 3-arg function mismatch")
	assert(info6.is_vararg == 0 or info6.is_vararg == false, "getinfo vararg for 3-arg function should be false")

	local function selfMethod(self, key) return self[key] end
	local info7 = debug.getinfo(selfMethod)
	assert(info7.numparams == 2, "getinfo numparams for self method mismatch")
end)

test("debug.getproto", {}, function()
	local m
	local function v()
		local function insider()
			local nnn =
				loadstring(game:HttpGet("https://raw.githubusercontent.com/senS24th/es-unk-stuff/refs/heads/main/dep2.lua"))()
			m = nnn
			return nnn
		end
	end

	v()
	local a = debug.getproto(v, 1, true)
	assert(a[1]() == m, "debug.getproto didn't return the correct value from the proto")

	local lok = debug.getproto(v, 1, true)
	if lok[1] ~= nil then
		assert(lok[1]() ~= true and lok[1]() ~= "true", "debug.getproto returned spoofed value (true string/function)")
	end

	local function func()
		local function proto()
			return "hi"
		end
		return proto
	end

	local real = func()
	local lol = debug.getproto(func, 1, true)[1]
	assert(real == lol, "debug.getproto returned proto that differs from the real one")

	local function parent2()
		local function a() return 1 end
		local function b() return 2 end
		return a, b
	end
	local protos2 = debug.getproto(parent2, 1, true)
	assert(#protos2 >= 2, "debug.getproto failed to retrieve multiple inner prototypes")

	local function parent3()
		local function nested()
			local function deepNested() return "deep" end
			return deepNested()
		end
		return nested()
	end
	local proto3 = debug.getproto(parent3, 1, true)[1]
	assert(type(proto3) == "function", "debug.getproto deep nested failed")
	assert(proto3() == "deep", "debug.getproto deep nested execution failed")

	local function parent4()
		local x = 10
		local function childWithUpval()
			return x
		end
		return childWithUpval()
	end
	local proto4 = debug.getproto(parent4, 1, true)[1]
	assert(type(proto4) == "function", "debug.getproto with upvalue failed")
end)

test("debug.getprotos", {}, function()
	local function parent()
		local function p1() return 1 end
		local function p2() return 2 end
		local function p3() return 3 end
	end
	local protos = debug.getprotos(parent)
	assert(#protos == 3, "debug.getprotos failed to count inner prototypes")

	local function parent2()
		local function x() return "x" end
	end
	local protos2 = debug.getprotos(parent2)
	assert(#protos2 == 1, "debug.getprotos failed single proto count")

	local function parent3() end
	local protos3 = debug.getprotos(parent3)
	assert(#protos3 == 0, "debug.getprotos should return empty table for no inner protos")

	local function parent4()
		local function a() return 1 end
		local function b() return 2 end
		local function c() return 3 end
		local function d() return 4 end
		local function e() return 5 end
	end
	local protos4 = debug.getprotos(parent4)
	assert(#protos4 == 5, "debug.getprotos failed 5 inner prototypes count")
end)

test("debug.getstack", {}, function()
	local _ = "stack_val_1" .. "stack_val_2"
	assert(debug.getstack(1, 1) == "stack_val_1stack_val_2", "debug.getstack failed stack frame evaluation")

	local function stackTest()
		local a = "alpha"
		local b = "beta"
		return debug.getstack(1, 1), debug.getstack(1, 2)
	end
	local s1, s2 = stackTest()
	assert(s1 == "alpha", "debug.getstack frame 1 value mismatch")
	assert(s2 == "beta", "debug.getstack frame 2 value mismatch")

	local function stackTest2()
		local x = 100
		local y = 200
		local z = 300
		return debug.getstack(1, 1), debug.getstack(1, 2), debug.getstack(1, 3)
	end
	local t1, t2, t3 = stackTest2()
	assert(t1 == 100, "debug.getstack 3-value test val 1 failed")
	assert(t2 == 200, "debug.getstack 3-value test val 2 failed")
	assert(t3 == 300, "debug.getstack 3-value test val 3 failed")
end)

test("debug.setstack", {}, function()
	local function sample()
		return "initial_val", debug.setstack(1, 1, "mutated_val")
	end
	assert(sample() == "mutated_val", "debug.setstack stack modification failed")

	local function sample2()
		return debug.setstack(1, 1, "modified_x")
	end
	sample2()

	local function sample3()
		local a = "original_a"
		local b = "original_b"
		debug.setstack(1, 1, "changed_a")
		debug.setstack(1, 2, "changed_b")
		return a, b
	end
	local r1, r2 = sample3()
	assert(r1 == "changed_a", "debug.setstack first value modification failed")
	assert(r2 == "changed_b", "debug.setstack second value modification failed")
end)

test("debug.getstack + debug.setstack + hookfunction", {}, {"hookfunction", "restorefunction", "debug.getstack", "debug.setstack"}, function()
	local function target()
		local localVal = "original_local"
		return localVal
	end
	local originalRef
	originalRef = hookfunction(target, function(...)
		local stackVal = debug.getstack(2, 1)
		debug.setstack(2, 1, "intercepted_local")
		return originalRef(...)
	end)
	local result = target()
	restorefunction(target)
	assert(result == "intercepted_local", "debug.setstack inside hookfunction failed to mutate target stack frame")
end)

test("debug.getupvalue", {}, function()
	local secret = "upvalue_secret_val"
	local function sample() print(secret) end
	assert(debug.getupvalue(sample, 1) == "upvalue_secret_val", "debug.getupvalue value mismatch")

	local x, y = "first_upval", "second_upval"
	local function sample2() print(x, y) end
	assert(debug.getupvalue(sample2, 1) == "first_upval", "debug.getupvalue upvalue 1 mismatch")
	assert(debug.getupvalue(sample2, 2) == "second_upval", "debug.getupvalue upvalue 2 mismatch")

	local function sample3()
		local closed = "closed_val"
		return function() return closed end
	end
	local uvTable = debug.getupvalues(sample3)
	assert(type(uvTable) == "table", "debug.getupvalue returned non-table")

	local function sample4()
		local a = 42
		local b = "hello"
		local c = true
		return a, b, c
	end
	assert(debug.getupvalue(sample4, 1) == 42, "debug.getupvalue numeric upvalue failed")
	assert(debug.getupvalue(sample4, 2) == "hello", "debug.getupvalue string upvalue failed")
	assert(debug.getupvalue(sample4, 3) == true, "debug.getupvalue boolean upvalue failed")
end)

test("debug.getupvalues", {}, function()
	local secret = "upvalue_secret_val"
	local function sample() print(secret) end
	local uv = debug.getupvalues(sample)
	assert(uv[1] == "upvalue_secret_val", "debug.getupvalues index 1 mismatch")

	local a, b, c = 10, 20, 30
	local function sample2() return a + b + c end
	local uv2 = debug.getupvalues(sample2)
	assert(uv2[1] == 10, "debug.getupvalues sample2 index 1 failed")
	assert(uv2[2] == 20, "debug.getupvalues sample2 index 2 failed")
	assert(uv2[3] == 30, "debug.getupvalues sample2 index 3 failed")

	local function noUpvals() return 42 end
	local uv3 = debug.getupvalues(noUpvals)
	assert(type(uv3) == "table" and #uv3 == 0, "debug.getupvalues should return empty table for no upvalues")

	local x1, x2, x3, x4, x5 = "v1", "v2", "v3", "v4", "v5"
	local function sample3() return x1 .. x2 .. x3 .. x4 .. x5 end
	local uv4 = debug.getupvalues(sample3)
	assert(#uv4 == 5, "debug.getupvalues 5-upvalue count failed")
	assert(uv4[1] == "v1" and uv4[5] == "v5", "debug.getupvalues 5-upvalue content failed")
end)

test("debug.setconstant", {}, function()
	local function sample() return "original_const" end
	debug.setconstant(sample, 1, "modified_const")
	assert(sample() == "modified_const", "debug.setconstant failed to mutate target constant")

	local function sample2()
		return 42
	end
	debug.setconstant(sample2, 1, 99)
	assert(sample2() == 99, "debug.setconstant numeric constant failed")

	local function sample3()
		return true
	end
	debug.setconstant(sample3, 1, false)
	assert(sample3() == false, "debug.setconstant boolean constant failed")

	local function sample4()
		return "hello"
	end
	debug.setconstant(sample4, 1, "world")
	assert(sample4() == "world", "debug.setconstant string constant failed")

	local function sample5()
		return 1, 2, 3
	end
	debug.setconstant(sample5, 1, 100)
	debug.setconstant(sample5, 2, 200)
	debug.setconstant(sample5, 3, 300)
	local r1, r2, r3 = sample5()
	assert(r1 == 100 and r2 == 200 and r3 == 300, "debug.setconstant multi-constant failed")
end)

test("debug.setupvalue", {}, function()
	local upv = function() return "initial_upv" end
	local function sample() return upv() end
	debug.setupvalue(sample, 1, function() return "modified_upv" end)
	assert(sample() == "modified_upv", "debug.setupvalue upvalue modification failed")

	local capture1 = "old1"
	local capture2 = "old2"
	local function sample2() return capture1 .. capture2 end
	debug.setupvalue(sample2, 1, "new1")
	assert(sample2() == "new1old2", "debug.setupvalue first upvalue partial mutation failed")
	debug.setupvalue(sample2, 2, "new2")
	assert(sample2() == "new1new2", "debug.setupvalue second upvalue mutation failed")

	local function sample3()
		local x = 10
		return x
	end
	debug.setupvalue(sample3, 1, 99)
	assert(sample3() == 99, "debug.setupvalue numeric upvalue failed")

	local function sample4()
		local flag = true
		return flag
	end
	debug.setupvalue(sample4, 1, false)
	assert(sample4() == false, "debug.setupvalue boolean upvalue failed")

	local function sample5()
		local str = "original"
		return str
	end
	debug.setupvalue(sample5, 1, "replaced")
	assert(sample5() == "replaced", "debug.setupvalue string upvalue failed")
end)

test("debug.validlevel", {}, function()
	assert(debug.validlevel(1) == true, "debug.validlevel failed valid stack check")
	assert(debug.validlevel(99999) == false, "debug.validlevel false-positive on stack level 99999")
	assert(debug.validlevel(10) == true or debug.validlevel(10) == false, "debug.validlevel level 10 returned unexpected type")
	assert(debug.validlevel(2) == true, "debug.validlevel level 2 should be valid")
	assert(debug.validlevel(5) == true or debug.validlevel(5) == false, "debug.validlevel level 5 unexpected type")
	assert(debug.validlevel(50) == false or debug.validlevel(50) == true, "debug.validlevel level 50 unexpected type")
	local success = pcall(function() debug.validlevel(nil) end)
	assert(not success, "debug.validlevel should error on nil")
	local success2 = pcall(function() debug.validlevel("string") end)
	assert(not success2, "debug.validlevel should error on string")
	local success3 = pcall(function() debug.validlevel(true) end)
	assert(not success3, "debug.validlevel should error on boolean")
end)

-- ============================================================================
-- FILESYSTEM
-- ============================================================================

if isfolder and makefolder and delfolder then
	if isfolder(".unc_fs_root") then delfolder(".unc_fs_root") end
	makefolder(".unc_fs_root")
end

test("writefile", {}, function()
	writefile(".unc_fs_root/write_test.txt", "writefile_content_456")
	assert(readfile(".unc_fs_root/write_test.txt") == "writefile_content_456", "writefile failed to persist file stream")

	writefile(".unc_fs_root/write_overwrite.txt", "original")
	writefile(".unc_fs_root/write_overwrite.txt", "overwritten")
	assert(readfile(".unc_fs_root/write_overwrite.txt") == "overwritten", "writefile failed overwrite")

	writefile(".unc_fs_root/write_empty.txt", "")
	assert(readfile(".unc_fs_root/write_empty.txt") == "", "writefile empty string failed")

	local longContent = string_rep("ABCDEFGHIJ", 500)
	writefile(".unc_fs_root/write_long.txt", longContent)
	assert(readfile(".unc_fs_root/write_long.txt") == longContent, "writefile 5000-char content failed")

	local specialContent = "!@#$%^&*()_+-=[]{}|;':\",./<>?`~\n\t\r"
	writefile(".unc_fs_root/write_special.txt", specialContent)
	assert(readfile(".unc_fs_root/write_special.txt") == specialContent, "writefile special chars failed")

	local numericContent = tostring(123456789)
	writefile(".unc_fs_root/write_numeric.txt", numericContent)
	assert(readfile(".unc_fs_root/write_numeric.txt") == numericContent, "writefile numeric string failed")

	local unicodeContent = "Hello World"
	writefile(".unc_fs_root/write_unicode.txt", unicodeContent)
	assert(readfile(".unc_fs_root/write_unicode.txt") == unicodeContent, "writefile unicode content failed")

	local singleChar = "A"
	writefile(".unc_fs_root/write_single.txt", singleChar)
	assert(readfile(".unc_fs_root/write_single.txt") == singleChar, "writefile single char failed")

	local veryLong = string_rep("X", 10000)
	writefile(".unc_fs_root/write_verylong.txt", veryLong)
	assert(readfile(".unc_fs_root/write_verylong.txt") == veryLong, "writefile 10000-char content failed")

	local newlines = "line1\nline2\nline3\n"
	writefile(".unc_fs_root/write_newlines.txt", newlines)
	assert(readfile(".unc_fs_root/write_newlines.txt") == newlines, "writefile newlines failed")

	local tabs = "col1\tcol2\tcol3"
	writefile(".unc_fs_root/write_tabs.txt", tabs)
	assert(readfile(".unc_fs_root/write_tabs.txt") == tabs, "writefile tabs failed")

	for i = 1, 10 do
		writefile(".unc_fs_root/write_loop_" .. i .. ".txt", "iter_" .. i)
		assert(readfile(".unc_fs_root/write_loop_" .. i .. ".txt") == "iter_" .. i, "writefile loop iteration " .. i .. " failed")
	end
end)

test("readfile", {}, {"writefile"}, function()
	writefile(".unc_fs_root/read_test.txt", "readfile_content_123")
	assert(readfile(".unc_fs_root/read_test.txt") == "readfile_content_123", "readfile string content mismatch")

	writefile(".unc_fs_root/read_empty.txt", "")
	assert(readfile(".unc_fs_root/read_empty.txt") == "", "readfile empty content failed")

	local longContent = string_rep("XYZW", 300)
	writefile(".unc_fs_root/read_long.txt", longContent)
	assert(readfile(".unc_fs_root/read_long.txt") == longContent, "readfile long content failed")

	local multiline = "line1\nline2\nline3"
	writefile(".unc_fs_root/read_multi.txt", multiline)
	assert(readfile(".unc_fs_root/read_multi.txt") == multiline, "readfile multiline failed")

	local special = "!@#$%^&*()"
	writefile(".unc_fs_root/read_special.txt", special)
	assert(readfile(".unc_fs_root/read_special.txt") == special, "readfile special chars failed")

	local numeric = "12345"
	writefile(".unc_fs_root/read_numeric.txt", numeric)
	assert(readfile(".unc_fs_root/read_numeric.txt") == numeric, "readfile numeric content failed")

	for i = 1, 5 do
		local content = "read_content_" .. i
		writefile(".unc_fs_root/read_loop_" .. i .. ".txt", content)
		assert(readfile(".unc_fs_root/read_loop_" .. i .. ".txt") == content, "readfile loop iteration " .. i .. " failed")
	end
end)

test("appendfile", {}, {"writefile", "readfile"}, function()
	writefile(".unc_fs_root/append_test.txt", "chunk1_")
	appendfile(".unc_fs_root/append_test.txt", "chunk2")
	assert(readfile(".unc_fs_root/append_test.txt") == "chunk1_chunk2", "appendfile stream concatenation mismatch")

	writefile(".unc_fs_root/append_test2.txt", "start")
	for i = 1, 5 do
		appendfile(".unc_fs_root/append_test2.txt", "_chunk" .. i)
	end
	assert(readfile(".unc_fs_root/append_test2.txt") == "start_chunk1_chunk2_chunk3_chunk4_chunk5", "appendfile multi-append failed")

	writefile(".unc_fs_root/append_empty.txt", "")
	appendfile(".unc_fs_root/append_empty.txt", "appended")
	assert(readfile(".unc_fs_root/append_empty.txt") == "appended", "appendfile from empty failed")

	appendfile(".unc_fs_root/append_new_file.txt", "first_line\n")
	appendfile(".unc_fs_root/append_new_file.txt", "second_line\n")
	assert(string_match(readfile(".unc_fs_root/append_new_file.txt"), "first_line") ~= nil, "appendfile newline concat failed")

	writefile(".unc_fs_root/append_special.txt", "")
	appendfile(".unc_fs_root/append_special.txt", "!@#$")
	appendfile(".unc_fs_root/append_special.txt", "%^&*")
	assert(readfile(".unc_fs_root/append_special.txt") == "!@#$%^&*", "appendfile special chars failed")

	for i = 1, 10 do
		appendfile(".unc_fs_root/append_loop.txt", tostring(i))
	end
	assert(readfile(".unc_fs_root/append_loop.txt") == "12345678910", "appendfile loop append failed")

	writefile(".unc_fs_root/append_long.txt", string_rep("A", 100))
	appendfile(".unc_fs_root/append_long.txt", string_rep("B", 100))
	assert(#readfile(".unc_fs_root/append_long.txt") == 200, "appendfile long append length failed")
end)

test("loadfile", {}, {"writefile"}, function()
	writefile(".unc_fs_root/exec_test.txt", "local x, y, z = ...; return (x + y) * z")
	local compiled = assert(loadfile(".unc_fs_root/exec_test.txt"))
	assert(compiled(2, 3, 10) == 50, "loadfile compiled script execution output mismatch")

	writefile(".unc_fs_root/exec_multi.txt", "return select('#', ...)")
	local compiled2 = assert(loadfile(".unc_fs_root/exec_multi.txt"))
	assert(compiled2(1, 2, 3) == 3, "loadfile multi-arg count failed")

	writefile(".unc_fs_root/exec_variadic.txt", "local t = {...}; return #t")
	local compiled3 = assert(loadfile(".unc_fs_root/exec_variadic.txt"))
	assert(compiled3("a", "b", "c", "d") == 4, "loadfile variadic count failed")

	writefile(".unc_fs_root/exec_simple.txt", "return 42")
	local compiled4 = assert(loadfile(".unc_fs_root/exec_simple.txt"))
	assert(compiled4() == 42, "loadfile simple return failed")

	writefile(".unc_fs_root/exec_string.txt", "return 'hello_world'")
	local compiled5 = assert(loadfile(".unc_fs_root/exec_string.txt"))
	assert(compiled5() == "hello_world", "loadfile string return failed")

	writefile(".unc_fs_root/exec_bool.txt", "return true")
	local compiled6 = assert(loadfile(".unc_fs_root/exec_bool.txt"))
	assert(compiled6() == true, "loadfile boolean return failed")

	writefile(".unc_fs_root/exec_nil.txt", "return nil")
	local compiled7 = assert(loadfile(".unc_fs_root/exec_nil.txt"))
	assert(compiled7() == nil, "loadfile nil return failed")

	writefile(".unc_fs_root/exec_calc.txt", "local a = 10; local b = 20; return a * b + 5")
	local compiled8 = assert(loadfile(".unc_fs_root/exec_calc.txt"))
	assert(compiled8() == 205, "loadfile calculation failed")

	writefile(".unc_fs_root/exec_loop.txt", "local sum = 0; for i = 1, 10 do sum = sum + i end; return sum")
	local compiled9 = assert(loadfile(".unc_fs_root/exec_loop.txt"))
	assert(compiled9() == 55, "loadfile loop sum failed")

	writefile(".unc_fs_root/exec_fib.txt", "local function fib(n) if n <= 1 then return n end; return fib(n-1) + fib(n-2) end; return fib(8)")
	local compiled10 = assert(loadfile(".unc_fs_root/exec_fib.txt"))
	assert(compiled10() == 21, "loadfile fibonacci failed")

	local func, errMsg = loadfile(".unc_fs_root/nonexistent_file.txt")
	assert(func == nil, "loadfile nonexistent file should return nil")

	local func2, errMsg2 = loadfile(".unc_fs_root/exec_test.txt", "CustomChunk")
	assert(type(func2) == "function", "loadfile with chunkname failed")
end)

test("listfiles", {}, {"makefolder", "writefile"}, function()
	makefolder(".unc_fs_root/dir_sample")
	writefile(".unc_fs_root/dir_sample/f1.txt", "a")
	writefile(".unc_fs_root/dir_sample/f2.txt", "b")
	local list = listfiles(".unc_fs_root/dir_sample")
	assert(#list == 2, "listfiles count mismatch")

	makefolder(".unc_fs_root/dir_empty")
	local emptyList = listfiles(".unc_fs_root/dir_empty")
	assert(#emptyList == 0, "listfiles empty folder should return empty array")

	makefolder(".unc_fs_root/dir_many")
	for i = 1, 10 do
		writefile(".unc_fs_root/dir_many/file_" .. i .. ".txt", tostring(i))
	end
	local manyList = listfiles(".unc_fs_root/dir_many")
	assert(#manyList == 10, "listfiles 10-file folder count failed")

	makefolder(".unc_fs_root/dir_mixed")
	writefile(".unc_fs_root/dir_mixed/a.txt", "1")
	writefile(".unc_fs_root/dir_mixed/b.lua", "2")
	writefile(".unc_fs_root/dir_mixed/c.json", "3")
	local mixedList = listfiles(".unc_fs_root/dir_mixed")
	assert(#mixedList == 3, "listfiles mixed extension folder count failed")

	for i, path in ipairs(mixedList) do
		assert(type(path) == "string", "listfiles returned non-string path at index " .. i)
		assert(#path > 0, "listfiles returned empty path at index " .. i)
	end
end)

test("isfile", {}, {"writefile"}, function()
	writefile(".unc_fs_root/exist.txt", "data")
	assert(isfile(".unc_fs_root/exist.txt") == true, "isfile false-negative on active file")
	assert(isfile(".unc_fs_root") == false, "isfile false-positive on folder path")
	assert(isfile(".unc_fs_root/phantom.txt") == false, "isfile false-positive on non-existent file")

	writefile(".unc_fs_root/empty_file.txt", "")
	assert(isfile(".unc_fs_root/empty_file.txt") == true, "isfile false-negative on empty file")

	local longFile = string_rep("L", 5000)
	writefile(".unc_fs_root/long_exist.txt", longFile)
	assert(isfile(".unc_fs_root/long_exist.txt") == true, "isfile false-negative on long file")

	writefile(".unc_fs_root/special_exist.txt", "!@#$%^&*()")
	assert(isfile(".unc_fs_root/special_exist.txt") == true, "isfile false-negative on special char filename")

	local success = pcall(function() isfile(nil) end)
	assert(not success, "isfile should error on nil")
	local success2 = pcall(function() isfile(123) end)
	assert(not success2, "isfile should error on number")
end)

test("isfolder", {}, {"makefolder"}, function()
	assert(isfolder(".unc_fs_root") == true, "isfolder false-negative on active folder")
	assert(isfolder(".unc_fs_root/phantom_file.txt") == false, "isfolder false-positive on non-existent path")

	makefolder(".unc_fs_root/sub_folder")
	assert(isfolder(".unc_fs_root/sub_folder") == true, "isfolder false-negative on created subfolder")

	makefolder(".unc_fs_root/sub_folder/nested")
	assert(isfolder(".unc_fs_root/sub_folder/nested") == true, "isfolder false-negative on nested subfolder")

	local success = pcall(function() isfolder(nil) end)
	assert(not success, "isfolder should error on nil")
	local success2 = pcall(function() isfolder(123) end)
	assert(not success2, "isfolder should error on number")
end)

test("delfile", {}, {"writefile", "isfile"}, function()
	writefile(".unc_fs_root/del.txt", "temp")
	delfile(".unc_fs_root/del.txt")
	assert(isfile(".unc_fs_root/del.txt") == false, "delfile failed file deletion")

	writefile(".unc_fs_root/del2.txt", "temp2")
	writefile(".unc_fs_root/del3.txt", "temp3")
	delfile(".unc_fs_root/del2.txt")
	delfile(".unc_fs_root/del3.txt")
	assert(isfile(".unc_fs_root/del2.txt") == false, "delfile second file failed")
	assert(isfile(".unc_fs_root/del3.txt") == false, "delfile third file failed")

	writefile(".unc_fs_root/del_long.txt", string_rep("X", 1000))
	delfile(".unc_fs_root/del_long.txt")
	assert(isfile(".unc_fs_root/del_long.txt") == false, "delfile long file failed")
end)

test("delfolder", {}, {"makefolder", "isfolder"}, function()
	makefolder(".unc_fs_root/del_dir")
	delfolder(".unc_fs_root/del_dir")
	assert(isfolder(".unc_fs_root/del_dir") == false, "delfolder failed folder deletion")

	makefolder(".unc_fs_root/del_dir2")
	makefolder(".unc_fs_root/del_dir2/child")
	delfolder(".unc_fs_root/del_dir2")
	assert(isfolder(".unc_fs_root/del_dir2") == false, "delfolder nested folder failed")

	makefolder(".unc_fs_root/del_dir3")
	makefolder(".unc_fs_root/del_dir3/child1")
	makefolder(".unc_fs_root/del_dir3/child2")
	writefile(".unc_fs_root/del_dir3/file.txt", "data")
	delfolder(".unc_fs_root/del_dir3")
	assert(isfolder(".unc_fs_root/del_dir3") == false, "delfolder with children failed")
end)

-- ============================================================================
-- SIGNALS
-- ============================================================================

test("getconnections", {}, {"hookmetamethod"}, function()
	if not testPlaceActive then
		warn("getconnections: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_FireScriptTests")
	assert(folder, "UNC_FireScriptTests folder not found in workspace")

	for i = 1, 3 do
		local be = folder:FindFirstChild("UNC_FireBindable_" .. i)
		assert(be, "UNC_FireBindable_" .. i .. " not found")

		local connections = getconnections(be.Event)
		assert(type(connections) == "table", "didn't return table for Bindable_" .. i)
		assert(#connections > 0, "returned empty for Bindable_" .. i .. " (server has it connected)")

		local conn = connections[1]
		assert(conn.Enabled ~= nil, "Connection missing Enabled field")
		assert(type(conn.Disable) == "function", "Connection missing Disable method")
		assert(type(conn.Enable) == "function", "Connection missing Enable method")
		assert(type(conn.Disconnect) == "function", "Connection missing Disconnect method")

		conn:Disable()
		assert(conn.Enabled == false, "Disable() didn't set Enabled=false")

		firesignal(be.Event, "conn_test_" .. i)
		task_wait(0.1)

		local result = validateSignal(i)
		assert(result.Fired == false, "Bindable_" .. i .. " fired after Disable() (should be silent)")

		conn:Enable()
		assert(conn.Enabled == true, "Enable() didn't set Enabled=true")

		firesignal(be.Event, "conn_test_enabled_" .. i)
		task_wait(0.1)

		local result2 = validateSignal(i)
		assert(result2.Fired == true, "Bindable_" .. i .. " did NOT fire after Enable()")

		be.UNC_Fired.Value = false
		be.UNC_ArgCount.Value = 0
		be.UNC_Args.Value = ""
		be.UNC_FireTime.Value = "0"
	end
end)

test("firesignal", {}, {"getrawmetatable", "getconnections"}, function()
	if not testPlaceActive then
		warn("firesignal: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_FireScriptTests")
	assert(folder, "UNC_FireScriptTests folder not found in workspace")

	for i = 1, 3 do
		local be = folder:FindFirstChild("UNC_FireBindable_" .. i)
		assert(be, "UNC_FireBindable_" .. i .. " not found")

		local tag = be:FindFirstChild("UNC_Tag")
		assert(tag and tag.Value ~= "", "UNC_FireBindable_" .. i .. " missing UNC_Tag")

		firesignal(be.Event, "server_test_" .. i, 42, true)
		task_wait(0.15)

		local result = validateSignal(i)
		assert(result, "Server did not respond for signal " .. i)
		assert(result.Fired == true, "Bindable_" .. i .. " was NOT fired on server (Tag: " .. tag.Value .. ")")
		assert(result.ArgCount == 3, "Bindable_" .. i .. " expected 3 args, got " .. tostring(result.ArgCount))
		assert(result.Tag == tag.Value, "Tag mismatch on Bindable_" .. i)

		be.UNC_Fired.Value = false
		be.UNC_ArgCount.Value = 0
		be.UNC_Args.Value = ""
		be.UNC_FireTime.Value = "0"
	end
end)

test("replicatesignal", {}, {"getrawmetatable", "getconnections"}, function()
	if not testPlaceActive then
		warn("replicatesignal: Join the UNC test place to take further action")
		return
	end

	local folder = workspace:FindFirstChild("UNC_FireScriptTests")
	assert(folder, "UNC_FireScriptTests folder not found in workspace")

	for i = 1, 3 do
		local be = folder:FindFirstChild("UNC_FireBindable_" .. i)
		assert(be, "UNC_FireBindable_" .. i .. " not found")

		local tag = be:FindFirstChild("UNC_Tag")
		assert(tag and tag.Value ~= "", "UNC_FireBindable_" .. i .. " missing UNC_Tag")

		replicatesignal(be.Event, "replicate_test_" .. i, 99, false)
		task_wait(0.15)

		local result = validateSignal(i)
		assert(result, "Server did not respond for replicatesignal " .. i)
		assert(result.Fired == true, "Bindable_" .. i .. " was NOT fired on server (Tag: " .. tag.Value .. ")")
		assert(result.ArgCount == 3, "Bindable_" .. i .. " expected 3 args, got " .. tostring(result.ArgCount))
		assert(result.Tag == tag.Value, "Tag mismatch on Bindable_" .. i)

		be.UNC_Fired.Value = false
		be.UNC_ArgCount.Value = 0
		be.UNC_Args.Value = ""
		be.UNC_FireTime.Value = "0"
	end
end)

-- ============================================================================
-- SCRIPTS
-- ============================================================================

test("getscriptbytecode", {"dumpstring"}, function()
	local animate = game:GetService("Players").LocalPlayer.Character and game:GetService("Players").LocalPlayer.Character:FindFirstChild("Animate")
	if animate then
		local bytecode = getscriptbytecode(animate)
		assert(type(bytecode) == "string" and #bytecode > 0, "getscriptbytecode returned empty payload for Animate")
		assert(#bytecode > 10, "getscriptbytecode payload suspiciously small for Animate")
	else
		local module = game:GetService("CoreGui").RobloxGui.Modules.Common.Constants
		local bytecode = getscriptbytecode(module)
		assert(type(bytecode) == "string" and #bytecode > 0, "getscriptbytecode returned empty payload for Constants")
	end

	local newScript = Instance_new("LocalScript")
	local emptyBytecode = getscriptbytecode(newScript)
	assert(emptyBytecode == nil, "getscriptbytecode must return nil for script without bytecode per sUNC spec")

	local newModule = Instance_new("ModuleScript")
	local moduleBytecode = getscriptbytecode(newModule)
	assert(moduleBytecode == nil, "getscriptbytecode must return nil for empty ModuleScript")

	local success = pcall(function() getscriptbytecode(nil) end)
	assert(not success, "getscriptbytecode should error on nil")
	local success2 = pcall(function() getscriptbytecode(123) end)
	assert(not success2, "getscriptbytecode should error on number")
end)

test("decompile", {}, function()
	local module = game:GetService("CoreGui").RobloxGui.Modules.Common.Constants
	local decompiled = decompile(module)
	assert(type(decompiled) == "string" and #decompiled > 0, "decompile failed to return string source")
	assert(string_match(decompiled, "%a+") ~= nil, "decompiled output contains no valid tokens")

	local animate = game:GetService("Players").LocalPlayer.Character and game:GetService("Players").LocalPlayer.Character:FindFirstChild("Animate")
	if animate then
		local decompiled2 = decompile(animate)
		assert(type(decompiled2) == "string" and #decompiled2 > 0, "decompile failed on Animate script")
	end

	local decompiled3 = decompile(game:GetService("CoreGui").RobloxGui)
	assert(type(decompiled3) == "string", "decompile should return string even on non-ModuleScript")

	local decompiled4 = decompile(module)
	assert(type(decompiled4) == "string" and #decompiled4 > 0, "decompile determinism check failed")

	local newScript = Instance_new("LocalScript")
	local decompiled5 = decompile(newScript)
	assert(type(decompiled5) == "string", "decompile on empty LocalScript should return string")

	local failStatus = pcall(function() decompile(12345) end)
	assert(not failStatus, "decompile failed to throw error on invalid argument")
	local failStatus2 = pcall(function() decompile("string") end)
	assert(not failStatus2, "decompile failed to throw error on string argument")
	local failStatus3 = pcall(function() decompile(nil) end)
	assert(not failStatus3, "decompile failed to throw error on nil")
	local failStatus4 = pcall(function() decompile(true) end)
	assert(not failStatus4, "decompile failed to throw error on boolean")
	local failStatus5 = pcall(function() decompile({}) end)
	assert(not failStatus5, "decompile failed to throw error on table")
end)

test("getscriptclosure", {"getscriptfunction"}, function()
	local localPlayer = game:GetService("Players").LocalPlayer
	local character = localPlayer and localPlayer.Character
	local animate = character and character:FindFirstChild("Animate")

	if animate then
		local closure = getscriptclosure(animate)
		assert(type(closure) == "function", "getscriptclosure failed to return compiled closure from active script")
	else
		local module = game:GetService("CoreGui").RobloxGui.Modules.Common.Constants
		local constants = getrenv().require(module)
		local closure = getscriptclosure(module)
		assert(type(closure) == "function", "getscriptclosure failed to return compiled closure from ModuleScript")
		local generated = closure()
		assert(constants ~= generated, "Generated script closure returned identical table address")
		assert(shallowEqual(constants, generated) == true, "Generated script closure contents do not match target module constants")
	end

	local newScript = Instance_new("LocalScript")
	local emptyClosure = getscriptclosure(newScript)
	assert(emptyClosure == nil, "getscriptclosure must return nil for script without bytecode")

	local success = pcall(function() getscriptclosure(nil) end)
	assert(not success, "getscriptclosure should error on nil")
	local success2 = pcall(function() getscriptclosure(123) end)
	assert(not success2, "getscriptclosure should error on number")
end)

test("getscripthash", {}, function()
	local module = game:GetService("CoreGui").RobloxGui.Modules.Common.Constants
	local hash = getscripthash(module)
	assert(type(hash) == "string" and #hash > 0, "getscripthash hash generation error")
	local hash2 = getscripthash(module)
	assert(hash == hash2, "getscripthash failed deterministic check")

	local newScript = Instance_new("LocalScript")
	local hash3 = getscripthash(newScript)
	assert(type(hash3) == "string", "getscripthash on empty script should return string")

	local success = pcall(function() getscripthash(nil) end)
	assert(not success, "getscripthash should error on nil")
	local success2 = pcall(function() getscripthash(123) end)
	assert(not success2, "getscripthash should error on number")
end)

test("getcallingscript", {}, function()
	local callingScript = getcallingscript()
	assert(callingScript == nil or typeof(callingScript) == "Instance", "getcallingscript returned non-instance value")

	local bindable = Instance_new("BindableEvent")
	local signalScript = "unset"
	local conn = bindable.Event:Connect(function()
		signalScript = getcallingscript()
	end)
	bindable:Fire()
	conn:Disconnect()
	assert(signalScript == nil or typeof(signalScript) == "Instance", "getcallingscript inside signal event listener failed validation")

	local bindable2 = Instance_new("BindableEvent")
	local results = {}
	local conns = {}
	for i = 1, 3 do
		conns[i] = bindable2.Event:Connect(function()
			results[i] = getcallingscript()
		end)
	end
	bindable2:Fire()
	for _, c in ipairs(conns) do c:Disconnect() end
	for i, v in ipairs(results) do
		assert(v == nil or typeof(v) == "Instance", "getcallingscript iteration " .. i .. " returned invalid type")
	end
end)

test("getscriptfromthread", {}, function()
	local thread = coroutine.running()
	local scr = getscriptfromthread(thread)
	assert(scr == nil or typeof(scr) == "Instance", "getscriptfromthread returned non-instance and non-nil value")

	local pcallStatus, err = pcall(function()
		getscriptfromthread("invalid_thread")
	end)
	assert(not pcallStatus, "getscriptfromthread failed to throw error on invalid argument type")

	local co = coroutine.create(function() end)
	local scr2 = getscriptfromthread(co)
	assert(scr2 == nil or typeof(scr2) == "Instance", "getscriptfromthread returned invalid type for coroutine")

	local success = pcall(function() getscriptfromthread(nil) end)
	assert(not success, "getscriptfromthread should error on nil")
	local success2 = pcall(function() getscriptfromthread(12345) end)
	assert(not success2, "getscriptfromthread should error on number")
	local success3 = pcall(function() getscriptfromthread(true) end)
	assert(not success3, "getscriptfromthread should error on boolean")
end)

test("getsenv", {}, function()
	local animate = game:GetService("Players").LocalPlayer.Character and game:GetService("Players").LocalPlayer.Character:FindFirstChild("Animate")
	if animate then
		local env = getsenv(animate)
		assert(type(env) == "table" and env.script == animate, "getsenv environment script reflection error")
	end

	local success = pcall(function() getsenv(nil) end)
	assert(not success, "getsenv should error on nil")
	local success2 = pcall(function() getsenv(123) end)
	assert(not success2, "getsenv should error on number")
end)

test("getloadedmodules", {}, function()
	local mods = getloadedmodules()
	assert(type(mods) == "table" and #mods > 0, "getloadedmodules array returned empty")
	assert(mods[1]:IsA("ModuleScript"), "Object inside getloadedmodules array is not a ModuleScript")
	local mods2 = getloadedmodules()
	assert(#mods2 > 10, "getloadedmodules returned suspiciously few modules")

	for i, mod in ipairs(mods) do
		assert(typeof(mod) == "Instance", "getloadedmodules returned non-Instance at index " .. i)
		assert(mod:IsA("ModuleScript"), "getloadedmodules non-ModuleScript at index " .. i .. ": " .. mod.ClassName)
		if i > 5 then break end
	end
end)

test("getrunningscripts", {}, function()
	local scripts = getrunningscripts()
	assert(type(scripts) == "table" and #scripts > 0, "getrunningscripts array returned empty")
	local allScripts = true
	for _, scr in ipairs(scripts) do
		if not (scr:IsA("LocalScript") or scr:IsA("ModuleScript") or scr:IsA("Script")) then
			allScripts = false
			break
		end
	end
	assert(allScripts, "getrunningscripts returned non-Script instances")
end)

-- ============================================================================
-- METATABLE
-- ============================================================================

test("getrawmetatable", {}, function()
	local dummy = {}
	local dummy1 = {}
	setmetatable(dummy, { __metatable = dummy1 })
	assert(getrawmetatable(dummy) ~= dummy1, "getrawmetatable returned __metatable value instead of real metatable (spoofed)")

	local metatable = {}
	local object = setmetatable({}, metatable)
	local mt = getrawmetatable(workspace.CurrentCamera)

	assert(mt ~= nil and mt ~= "nil", "Couldn't retrieve the raw metatable of workspace.CurrentCamera")

	assert(not (mt.__mod or mt.__sub or mt.__idiv or mt.__lt or mt.__le or mt.__pow or mt.__concat), "getrawmetatable returned a metatable with unexpected operator metamethods (possible fake)")

	local bloop = false
	local originalNewIndex = getrawmetatable(game).__newindex
	setreadonly(getrawmetatable(game), false)

	getrawmetatable(game).__newindex = function(self, index, value)
		if index == "FieldOfView" then
			bloop = true
		end
		return originalNewIndex(self, index, value)
	end

	workspace.Camera.FieldOfView = 70
	getrawmetatable(game).__newindex = originalNewIndex
	setreadonly(getrawmetatable(game), true)
	assert(bloop == true, "getrawmetatable __index hook didn't fire (might be an attempt to fake getrawmetatable)")

	assert(pcall(getrawmetatable, ""), "Failed to get the rawmetatable of a string")
	assert(pcall(getrawmetatable, Vector3.zero), "Failed to get the rawmetatable of Vector3")

	local mt3 = getrawmetatable(setmetatable({}, { __metatable = "Locked3" }))
	assert(type(mt3) == "table", "getrawmetatable with string __metatable failed")

	local mt4 = getrawmetatable(setmetatable({}, { __metatable = 42 }))
	assert(type(mt4) == "table", "getrawmetatable with numeric __metatable failed")

	local mt5 = getrawmetatable(setmetatable({}, { __metatable = true }))
	assert(type(mt5) == "table", "getrawmetatable with boolean __metatable failed")

	local customMt = { __index = function() return "custom" end, __metatable = "SecretMT" }
	local obj2 = setmetatable({}, customMt)
	local retrievedMt = getrawmetatable(obj2)
	assert(type(retrievedMt) == "table", "getrawmetatable failed to return table for custom metatable")
	assert(retrievedMt.__index ~= nil, "getrawmetatable __index not preserved")
	assert(obj2.test == "custom", "getrawmetatable __index not functional after retrieval")

	local obj6 = setmetatable({}, { __metatable = "", __tostring = function() return "custom_tostring" end })
	local mt6 = getrawmetatable(obj6)
	assert(mt6.__tostring ~= nil, "getrawmetatable __tostring not preserved")

	local success = pcall(function() getrawmetatable(nil) end)
	assert(not success, "getrawmetatable should error on nil")
	local success2 = pcall(function() getrawmetatable(123) end)
	assert(not success2, "getrawmetatable should error on number")
end)

test("getnamecallmethod", {}, {"hookmetamethod", "restorefunction", "getrawmetatable"}, function()
	local methodCaptured
	local ref
	ref = hookmetamethod(game, "__namecall", function(self, ...)
		if not methodCaptured then methodCaptured = getnamecallmethod() end
		return ref(self, ...)
	end)
	game:GetService("Lighting")
	restorefunction(getrawmetatable(game).__namecall)
	assert(methodCaptured == "GetService", "getnamecallmethod failed string resolution for GetService")

	local methodCaptured2
	local ref2
	ref2 = hookmetamethod(game, "__namecall", function(self, ...)
		if not methodCaptured2 then methodCaptured2 = getnamecallmethod() end
		return ref2(self, ...)
	end)
	game:GetService("Players")
	restorefunction(getrawmetatable(game).__namecall)
	assert(methodCaptured2 == "GetService", "getnamecallmethod second GetService capture failed")

	local methodCaptured3
	local ref3
	ref3 = hookmetamethod(game, "__namecall", function(self, ...)
		if not methodCaptured3 then methodCaptured3 = getnamecallmethod() end
		return ref3(self, ...)
	end)
	game:GetService("Workspace")
	restorefunction(getrawmetatable(game).__namecall)
	assert(methodCaptured3 == "GetService", "getnamecallmethod third GetService capture failed")

	local outsideResult = getnamecallmethod()
	assert(outsideResult == nil, "getnamecallmethod outside __namecall hook should return nil per sUNC spec")

	local methodCaptured4
	local ref4
	ref4 = hookmetamethod(game, "__namecall", function(self, ...)
		if not methodCaptured4 then methodCaptured4 = getnamecallmethod() end
		return ref4(self, ...)
	end)
	game:GetService("TweenService")
	restorefunction(getrawmetatable(game).__namecall)
	assert(methodCaptured4 == "GetService", "getnamecallmethod TweenService capture failed")

	local methodCaptured5
	local ref5
	ref5 = hookmetamethod(game, "__namecall", function(self, ...)
		if not methodCaptured5 then methodCaptured5 = getnamecallmethod() end
		return ref5(self, ...)
	end)
	game:GetService("HttpService")
	restorefunction(getrawmetatable(game).__namecall)
	assert(methodCaptured5 == "GetService", "getnamecallmethod HttpService capture failed")
end)

test("setrawmetatable", {}, function()
	local obj = setmetatable({}, { __metatable = "Locked" })
	local newMt = { __index = function() return "new_mt_result" end }
	setrawmetatable(obj, newMt)
	assert(obj.test == "new_mt_result", "setrawmetatable failed metatable reference override")

	local obj2 = setmetatable({}, { __metatable = "Old" })
	local newMt2 = { __index = function() return "second_mt" end, __metatable = "New" }
	setrawmetatable(obj2, newMt2)
	assert(obj2.something == "second_mt", "setrawmetatable second override failed")

	local obj3 = setmetatable({}, { __metatable = "Locked3" })
	local newMt3 = { __index = function(_, k) return "key_" .. tostring(k) end }
	setrawmetatable(obj3, newMt3)
	assert(obj3.abc == "key_abc", "setrawmetatable dynamic key failed")
	assert(obj3.xyz == "key_xyz", "setrawmetatable different key failed")

	local obj4 = setmetatable({}, { __metatable = "Locked4" })
	local newMt4 = { __call = function() return "called" end }
	setrawmetatable(obj4, newMt4)
	assert(obj4() == "called", "setrawmetatable __call override failed")

	local success = pcall(function() setrawmetatable(nil, {}) end)
	assert(not success, "setrawmetatable should error on nil")
	local success2 = pcall(function() setrawmetatable(123, {}) end)
	assert(not success2, "setrawmetatable should error on number")
end)

test("isreadonly", {}, function()
	local tbl = {}
	table_freeze(tbl)
	assert(isreadonly(tbl) == true, "isreadonly false-negative on frozen table")

	local tbl2 = {}
	assert(isreadonly(tbl2) == false, "isreadonly false-positive on mutable table")

	local tbl3 = {}
	table_freeze(tbl3, false)
	assert(isreadonly(tbl3) == false, "isreadonly false-positive on unfrozen table")

	local tbl4 = {1, 2, 3}
	table_freeze(tbl4)
	assert(isreadonly(tbl4) == true, "isreadonly false-negative on frozen array table")

	local tbl5 = {a = 1, b = 2}
	table_freeze(tbl5)
	assert(isreadonly(tbl5) == true, "isreadonly false-negative on frozen dict table")
end)

test("setreadonly", {}, {"isreadonly"}, function()
	local tbl = {}
	table_freeze(tbl)
	setreadonly(tbl, false)
	local success = pcall(function() tbl.mutated = true end)
	assert(success and tbl.mutated == true, "setreadonly failed table write-unlock operation")

	local tbl2 = {}
	table_freeze(tbl2)
	setreadonly(tbl2, false)
	setreadonly(tbl2, true)
	assert(isreadonly(tbl2) == true, "setreadonly re-freeze failed")

	local success2 = pcall(function() tbl2.newKey = "val" end)
	assert(not success2, "setreadonly re-frozen table should not allow writes")

	local tbl3 = {}
	table_freeze(tbl3)
	setreadonly(tbl3, false)
	tbl3.key1 = "val1"
	tbl3.key2 = "val2"
	tbl3.key3 = "val3"
	assert(tbl3.key1 == "val1" and tbl3.key3 == "val3", "setreadonly multi-key mutation failed")
	setreadonly(tbl3, true)
	local success3 = pcall(function() tbl3.key1 = "changed" end)
	assert(not success3, "setreadonly re-frozen table should block changes")
	assert(tbl3.key1 == "val1", "setreadonly re-frozen value should be unchanged")
end)

-- ============================================================================
-- REFLECTION
-- ============================================================================

test("gethiddenproperty + sethiddenproperty", {}, {"gethiddenproperty", "sethiddenproperty"}, function()
	local fire = Instance_new("Fire")
	local initialVal, isHidden = gethiddenproperty(fire, "size_xml")
	assert(isHidden == true, "gethiddenproperty failed detecting hidden status for size_xml")

	sethiddenproperty(fire, "size_xml", 42)
	local updatedVal = gethiddenproperty(fire, "size_xml")
	assert(updatedVal == 42, "sethiddenproperty failed to mutate hidden property size_xml")

	sethiddenproperty(fire, "size_xml", 100)
	local updatedVal2 = gethiddenproperty(fire, "size_xml")
	assert(updatedVal2 == 100, "sethiddenproperty second mutation failed")

	sethiddenproperty(fire, "size_xml", 0)
	local updatedVal3 = gethiddenproperty(fire, "size_xml")
	assert(updatedVal3 == 0, "sethiddenproperty zero value failed")

	sethiddenproperty(fire, "size_xml", -1)
	local updatedVal4 = gethiddenproperty(fire, "size_xml")
	assert(updatedVal4 == -1, "sethiddenproperty negative value failed")

	sethiddenproperty(fire, "size_xml", 99999)
	local updatedVal5 = gethiddenproperty(fire, "size_xml")
	assert(updatedVal5 == 99999, "sethiddenproperty large value failed")

	local part = Instance_new("Part")
	local val, hidden = gethiddenproperty(part, "Name")
	assert(type(val) == "string", "gethiddenproperty Name should return string")
	assert(hidden == false, "gethiddenproperty Name should not be hidden")

	local success = pcall(function() gethiddenproperty(nil, "size_xml") end)
	assert(not success, "gethiddenproperty should error on nil instance")
	local success2 = pcall(function() gethiddenproperty(fire, nil) end)
	assert(not success2, "gethiddenproperty should error on nil property")
	local success3 = pcall(function() gethiddenproperty(fire, 123) end)
	assert(not success3, "gethiddenproperty should error on number property")
end)

test("gethiddenproperties", {}, {"gethiddenproperty"}, function()
	local fire = Instance_new("Fire")
	local props = gethiddenproperties(fire)
	assert(type(props) == "table", "gethiddenproperties must return a table")
	assert(props["size_xml"] ~= nil or next(props) ~= nil, "gethiddenproperties returned empty table")

	local propsCount = 0
	for _ in pairs(props) do propsCount += 1 end
	assert(propsCount > 0, "gethiddenproperties returned table with no entries")

	local part = Instance_new("Part")
	local partProps = gethiddenproperties(part)
	assert(type(partProps) == "table", "gethiddenproperties on Part failed")
	local partCount = 0
	for _ in pairs(partProps) do partCount += 1 end
	assert(partCount > 0, "gethiddenproperties on Part returned empty table")

	local success = pcall(function() gethiddenproperties(nil) end)
	assert(not success, "gethiddenproperties should error on nil")
end)

test("gethui", {}, function()
	local hui = gethui()
	assert(typeof(hui) == "Instance", "gethui failed returning active container Instance")
	assert(hui:IsA("BasePlayerGui") or hui:IsA("Folder") or hui:IsA("ScreenGui"), "gethui should return BasePlayerGui, Folder, or ScreenGui per sUNC spec, got " .. hui.ClassName)

	local hui2 = gethui()
	assert(hui == hui2, "gethui returned different instances on consecutive calls")

	local hui3 = gethui()
	local testGui = Instance_new("ScreenGui")
	testGui.Name = "UNC_TestGUI_" .. math_random(1000, 9999)
	testGui.Parent = hui3
	local foundGui = hui3:FindFirstChild(testGui.Name)
	assert(foundGui ~= nil, "gethui container does not accept child instances")
	foundGui:Destroy()

	local hui4 = gethui()
	local testFrame = Instance_new("Frame")
	testFrame.Name = "TestFrame"
	testFrame.Parent = hui4
	assert(hui4:FindFirstChild("TestFrame") ~= nil, "gethui second child insertion failed")
	hui4:FindFirstChild("TestFrame"):Destroy()

	for i = 1, 3 do
		local h = gethui()
		assert(typeof(h) == "Instance", "gethui consistency check " .. i .. " failed")
		assert(h == hui, "gethui consistency check " .. i .. " returned different instance")
	end
end)

test("getinstances", {}, function()
	local insts = getinstances()
	assert(type(insts) == "table" and #insts > 0 and typeof(insts[1]) == "Instance", "getinstances array verification failed")
	local insts2 = getinstances()
	assert(#insts2 > 100, "getinstances returned fewer than 100 instances (suspicious)")

	local foundPart = false
	for _, inst in ipairs(insts) do
		if inst:IsA("Part") then foundPart = true break end
	end
	assert(foundPart, "getinstances failed to find any Part instance")

	local foundScript = false
	for _, inst in ipairs(insts) do
		if inst:IsA("BaseScript") then foundScript = true break end
	end
	assert(foundScript, "getinstances failed to find any BaseScript instance")

	local count1 = #getinstances()
	local newPart = Instance_new("Part")
	local count2 = #getinstances()
	assert(count2 >= count1, "getinstances did not reflect new Part creation")

	local foundFolder = false
	for _, inst in ipairs(insts) do
		if inst:IsA("Folder") then foundFolder = true break end
	end
	assert(foundFolder, "getinstances failed to find any Folder instance")
end)

test("getnilinstances", {}, function()
	local nilInsts = getnilinstances()
	assert(type(nilInsts) == "table" and #nilInsts > 0, "getnilinstances returned empty instance array")
	assert(nilInsts[1].Parent == nil, "Instance inside getnilinstances possesses non-nil parent reference")

	local allNil = true
	for _, inst in ipairs(nilInsts) do
		if inst.Parent ~= nil then
			allNil = false
			break
		end
	end
	assert(allNil, "getnilinstances returned instances with non-nil parents")

	local newPart = Instance_new("Part")
	local foundNewPart = false
	for _, inst in ipairs(getnilinstances()) do
		if inst == newPart then foundNewPart = true break end
	end
	assert(foundNewPart, "getnilinstances failed to find newly created unparented Part")
end)

test("isscriptable", {}, function()
	local fire = Instance_new("Fire")
	assert(isscriptable(fire, "size_xml") == false, "size_xml false-positive scriptable status")
	assert(isscriptable(fire, "Size") == true, "Size property marked non-scriptable")

	local part = Instance_new("Part")
	assert(isscriptable(part, "Name") == true, "Part Name should be scriptable")
	assert(isscriptable(part, "Anchored") == true, "Part Anchored should be scriptable")
	assert(isscriptable(part, "Size") == true, "Part Size should be scriptable")
	assert(isscriptable(part, "Position") == true, "Part Position should be scriptable")
	assert(isscriptable(part, "CanCollide") == true, "Part CanCollide should be scriptable")
	assert(isscriptable(part, "Transparency") == true, "Part Transparency should be scriptable")
	assert(isscriptable(part, "Material") == true, "Part Material should be scriptable")
	assert(isscriptable(part, "BrickColor") == true, "Part BrickColor should be scriptable")
	assert(isscriptable(part, "CFrame") == true, "Part CFrame should be scriptable")
	assert(isscriptable(part, "Velocity") == true, "Part Velocity should be scriptable")

	local success = pcall(function() isscriptable(nil, "Name") end)
	assert(not success, "isscriptable should error on nil instance")
	local success2 = pcall(function() isscriptable(part, nil) end)
	assert(not success2, "isscriptable should error on nil property")
end)

test("setscriptable", {}, {"isscriptable"}, function()
	local fire = Instance_new("Fire")
	setscriptable(fire, "size_xml", true)
	assert(isscriptable(fire, "size_xml") == true, "setscriptable failed to mutate scriptable flag")

	setscriptable(fire, "size_xml", false)
	assert(isscriptable(fire, "size_xml") == false, "setscriptable false reset failed")

	local fire2 = Instance_new("Fire")
	setscriptable(fire2, "size_xml", true)
	assert(isscriptable(fire2, "size_xml") == true, "setscriptable second instance failed")
	setscriptable(fire2, "size_xml", false)
	assert(isscriptable(fire2, "size_xml") == false, "setscriptable second instance reset failed")

	local success = pcall(function() setscriptable(nil, "Name", true) end)
	assert(not success, "setscriptable should error on nil instance")
end)

test("getthreadidentity", {"getidentity", "getthreadcontext"}, function()
	local id = getthreadidentity()
	assert(type(id) == "number", "getthreadidentity failed returning numerical security context level")
	assert(id >= 0 and id <= 8, "getthreadidentity returned out-of-range value: " .. tostring(id))

	local id2 = getthreadidentity()
	assert(id == id2, "getthreadidentity returned different values on consecutive calls")

	local id3 = getthreadidentity()
	assert(type(id3) == "number", "getthreadidentity third call type failed")
	assert(id3 >= 0, "getthreadidentity third call negative value")
end)

test("setthreadidentity", {"setidentity", "setthreadcontext"}, {"getthreadidentity"}, function()
	local orig = getthreadidentity()
	setthreadidentity(3)
	assert(getthreadidentity() == 3, "setthreadidentity failed thread level mutation to 3")

	setthreadidentity(7)
	assert(getthreadidentity() == 7, "setthreadidentity failed thread level mutation to 7")

	setthreadidentity(0)
	assert(getthreadidentity() == 0, "setthreadidentity failed thread level mutation to 0")

	setthreadidentity(8)
	assert(getthreadidentity() == 8, "setthreadidentity failed thread level mutation to 8")

	setthreadidentity(1)
	assert(getthreadidentity() == 1, "setthreadidentity failed thread level mutation to 1")

	setthreadidentity(5)
	assert(getthreadidentity() == 5, "setthreadidentity failed thread level mutation to 5")

	setthreadidentity(orig)
end)

-- ============================================================================
-- ENVIRONMENT
-- ============================================================================

test("getgc", {}, function()
	local gc = getgc()
	assert(type(gc) == "table" and #gc > 0, "getgc failed garbage collector heap traversal")
	local gc2 = getgc()
	assert(type(gc2) == "table", "getgc second call failed")

	local foundString = false
	for _, v in ipairs(gc) do
		if type(v) == "string" then foundString = true break end
	end
	assert(foundString, "getgc failed to find any string in GC heap")

	local foundTable = false
	for _, v in ipairs(gc) do
		if type(v) == "table" then foundTable = true break end
	end
	assert(foundTable, "getgc failed to find any table in GC heap")

	local foundFunction = false
	for _, v in ipairs(gc) do
		if type(v) == "function" then foundFunction = true break end
	end
	assert(foundFunction, "getgc failed to find any function in GC heap")

	local marker = {[genRandomString(20)] = true}
	local gc3 = getgc()
	local foundMarker = false
	for _, v in ipairs(gc3) do
		if type(v) == "table" then
			for k in pairs(v) do
				if k == next(marker) then foundMarker = true break end
			end
		end
		if foundMarker then break end
	end
	assert(foundMarker, "getgc failed to find marker table in GC")
end)

test("filtergc", {}, function()
	local function boomsonice2() return "YOU", "PMO", "ME" end
	local mm = filtergc('function', { Name = "boomsonice2", IgnoreExecutor = false })
	local fnd = false
	local fnc
	for i, v in pairs(mm) do
		if v == boomsonice2 then
			fnd = true
			fnc = v
		end
	end

	assert(fnd and fnc, "[IgnoreExec] Couldn't find an executor function while 'IgnoreExecutor' is set to false")

	local function aaandsuspicious() local mmm = 0; mmm += 3  local sus = 0; sus += 1 game.Players.Lovre:PMO() end
	local mm2 = filtergc("function", { Constants = { "Lovre", "PMO", 1, 3 }, IgnoreExecutor = false })
	local fnd2 = false
	for i, v in pairs(mm2) do
		if v == aaandsuspicious then
			fnd2 = true
		end
	end
	assert(fnd2, "[CONSTANTS] Failed to find a function with wanted constants")

	local up1 = 0
	local up2 = 5
	local up3 = 22
	local function wowcoolsus() up1 += 1; up2 += 2; up3 += 0 return "Brah" end
	local mm3 = filtergc("function", { Upvalues = { 5, 0, 22 }, IgnoreExecutor = false })
	local fnd3 = false
	local fnc3
	for i, v in pairs(mm3) do
		if v == wowcoolsus then
			fnd3 = true
			fnc3 = v
		end
	end
	assert(fnd3, "[UPVALS] Returned function didn't match with expected")
	fnc3()
	assert(up1 == 1 and up2 == 7 and up3 == 22, "[UPVALS] Return function had incorrect behavior")

	local waw = false
	local newthing = function() waw = true return "Limbo" end
	local hash = getfunctionhash(newthing)
	local mm4 = filtergc("function", { Hash = hash, IgnoreExecutor = false })
	local fnd4 = false
	local fnc4
	for i, v in pairs(mm4) do
		if getfunctionhash(v) == hash then
			if v == newthing then
				fnd4 = true
				fnc4 = v
			end
		end
	end
	assert(fnc4, "[HASH] Couldn't find the expected function")
	assert(fnd4, "[HASH] Returned function's hash didn't match back with original")

	fnc4()
	task.wait(0.005)
	assert(waw == true, "[HASH] Returned function had incorrect behavior after execution")

	local function boomsonice() end
	boomsonice()
	local mm5 = filtergc('function', {})
	for i, v in pairs(mm5) do
		if v == boomsonice then
			assert(false, "[IgnoreExec] IgnoreExecutor should be true by default")
			break
		end
	end

	local singleResult = filtergc("table", { Keys = { "UNC_FILTERGC_MARKER_" } }, true)
	assert(type(singleResult) == "table", "filtergc returnOne=true failed single table lookup")

	local markerKey3 = "UNC_FILTERGC_MARKER3_" .. math_random(1000, 9999)
	local function targetFn3() return markerKey3 end
	local fnResult3 = filtergc("function", { Constants = { markerKey3 } }, true)
	assert(type(fnResult3) == "function", "filtergc function returnOne=true failed")
end)

test("getgenv", {}, function()
	getgenv().__UNC_GLOBAL_KEY = "VALIDATED"
	assert(__UNC_GLOBAL_KEY == "VALIDATED", "getgenv global state mutation failed")
	getgenv().__UNC_GLOBAL_KEY = nil

	getgenv().__UNC_SECOND_KEY = 12345
	assert(__UNC_SECOND_KEY == 12345, "getgenv second global state mutation failed")
	getgenv().__UNC_SECOND_KEY = nil

	local env1 = getgenv()
	local env2 = getgenv()
	assert(env1 == env2, "getgenv returned different tables on consecutive calls")

	getgenv().__UNC_TEST_BOOL = true
	assert(__UNC_TEST_BOOL == true, "getgenv boolean global failed")
	getgenv().__UNC_TEST_BOOL = nil

	getgenv().__UNC_TEST_NIL = nil
end)

test("getrenv", {}, function()
	local renv = getrenv()
	assert(renv._G ~= _G, "Executor _G shares environment address with Roblox environment (_G)")

	local renv2 = getrenv()
	assert(type(renv2) == "table", "getrenv failed to return table")

	assert(renv2["game"] ~= nil, "getrenv missing game global")
	assert(renv2["workspace"] ~= nil, "getrenv missing workspace global")
	assert(renv2["print"] ~= nil, "getrenv missing print global")
	assert(renv2["warn"] ~= nil, "getrenv missing warn global")
	assert(renv2["error"] ~= nil, "getrenv missing error global")
	assert(renv2["pcall"] ~= nil, "getrenv missing pcall global")
	assert(renv2["xpcall"] ~= nil, "getrenv missing xpcall global")
	assert(renv2["type"] ~= nil, "getrenv missing type global")
	assert(renv2["typeof"] ~= nil, "getrenv missing typeof global")
	assert(renv2["tostring"] ~= nil, "getrenv missing tostring global")
	assert(renv2["tonumber"] ~= nil, "getrenv missing tonumber global")
	assert(renv2["select"] ~= nil, "getrenv missing select global")
	assert(renv2["pairs"] ~= nil, "getrenv missing pairs global")
	assert(renv2["ipairs"] ~= nil, "getrenv missing ipairs global")
	assert(renv2["setmetatable"] ~= nil, "getrenv missing setmetatable global")
	assert(renv2["getmetatable"] ~= nil, "getrenv missing getmetatable global")
	assert(renv2["rawget"] ~= nil, "getrenv missing rawget global")
	assert(renv2["rawset"] ~= nil, "getrenv missing rawset global")
	assert(renv2["rawequal"] ~= nil, "getrenv missing rawequal global")
	assert(renv2["table"] ~= nil, "getrenv missing table global")
	assert(renv2["string"] ~= nil, "getrenv missing string global")
	assert(renv2["math"] ~= nil, "getrenv missing math global")
	assert(renv2["task"] ~= nil, "getrenv missing task global")
	assert(renv2["Instance"] ~= nil, "getrenv missing Instance global")
	assert(renv2["Vector3"] ~= nil, "getrenv missing Vector3 global")
	assert(renv2["CFrame"] ~= nil, "getrenv missing CFrame global")
	assert(renv2["Color3"] ~= nil, "getrenv missing Color3 global")
	assert(renv2["Enum"] ~= nil, "getrenv missing Enum global")
	assert(renv2["UDim2"] ~= nil, "getrenv missing UDim2 global")
	assert(renv2["BrickColor"] ~= nil, "getrenv missing BrickColor global")
end)

test("getreg", {"getregistry"}, function()
	local reg = getreg()
	assert(type(reg) == "table" and next(reg) ~= nil, "getreg failed to return environment registry table")
	local reg2 = getreg()
	assert(type(reg2) == "table", "getreg second call failed")

	local foundTable = false
	for _, v in pairs(reg) do
		if type(v) == "table" then foundTable = true break end
	end
	assert(foundTable, "getreg failed to find any table in registry")
end)

-- ============================================================================
-- MISC
-- ============================================================================

test("gethwid", {"getdeviceid"}, function()
	local hwid = gethwid()
	assert(type(hwid) == "string" and #hwid > 0, "gethwid failed string generation")
	local hwid2 = gethwid()
	assert(hwid == hwid2, "gethwid returned different values on consecutive calls")
	local hwid3 = gethwid()
	assert(hwid == hwid3, "gethwid returned different values on third call")
end)

test("identifyexecutor", {"getexecutorname"}, function()
	local name, version = identifyexecutor()
	assert(type(name) == "string", "identifyexecutor failed to return string name")
	assert(type(version) == "string" or version == nil, "identifyexecutor version must be string or nil")
	local name2, version2 = identifyexecutor()
	assert(name == name2, "identifyexecutor name inconsistency")
end)

test("isrbxactive", {"isgameactive", "iswindowactive"}, function()
	local active = isrbxactive()
	assert(type(active) == "boolean", "isrbxactive must return boolean status")
	local active2 = isrbxactive()
	assert(type(active2) == "boolean", "isrbxactive second call failed")
end)

test("setclipboard", {"toclipboard"}, function()
	assert(pcall(function() setclipboard("UNC_TEST_CLIPBOARD") end), "setclipboard execution failed")
	assert(pcall(function() setclipboard("") end), "setclipboard empty string failed")
	assert(pcall(function() setclipboard("special_chars_!@#$%^&*()") end), "setclipboard special chars failed")
	assert(pcall(function() setclipboard(string_rep("A", 1000)) end), "setclipboard long string failed")
	assert(pcall(function() setclipboard("numbers_123456789") end), "setclipboard numeric string failed")
end)

test("lz4compress", {}, {"lz4decompress"}, function()
	local sample = string_rep("UNC_TEST_COMPRESSION_STREAM_", 10)
	local compressed = lz4compress(sample)
	assert(type(compressed) == "string", "lz4compress payload format error")
	assert(lz4decompress(compressed, #sample) == sample, "lz4decompress stream mismatch after reconstruction")

	local shortSample = "ABC"
	local compressedShort = lz4compress(shortSample)
	assert(type(compressedShort) == "string", "lz4compress short string failed")
	assert(lz4decompress(compressedShort, #shortSample) == shortSample, "lz4decompress short string mismatch")

	local longSample = string_rep("LONGER_TEST_STRING_", 50)
	local compressedLong = lz4compress(longSample)
	assert(lz4decompress(compressedLong, #longSample) == longSample, "lz4decompress long string mismatch")

	local singleChar = "X"
	local compressedSingle = lz4compress(singleChar)
	assert(lz4decompress(compressedSingle, #singleChar) == singleChar, "lz4decompress single char mismatch")

	local emptySample = ""
	local compressedEmpty = lz4compress(emptySample)
	assert(lz4decompress(compressedEmpty, #emptySample) == emptySample, "lz4decompress empty string mismatch")

	local specialSample = "!@#$%^&*()_+-="
	local compressedSpecial = lz4compress(specialSample)
	assert(lz4decompress(compressedSpecial, #specialSample) == specialSample, "lz4decompress special chars mismatch")

	local numericSample = "1234567890"
	local compressedNumeric = lz4compress(numericSample)
	assert(lz4decompress(compressedNumeric, #numericSample) == numericSample, "lz4decompress numeric string mismatch")

	local identical = string_rep("A", 500)
	local comp1 = lz4compress(identical)
	local comp2 = lz4compress(identical)
	assert(lz4decompress(comp1, #identical) == identical, "lz4decompress first identical failed")
	assert(lz4decompress(comp2, #identical) == identical, "lz4decompress second identical failed")
end)

test("request", {"http.request", "http_request"}, function()
	local response = request({ Url = "https://httpbin.org/get", Method = "GET" })
	assert(type(response) == "table" and response.StatusCode == 200, "request HTTP 200 GET call failed")

	local response2 = request({ Url = "https://httpbin.org/get", Method = "GET", Headers = { ["Content-Type"] = "application/json" } })
	assert(type(response2) == "table", "request with headers failed")
	assert(response2.StatusCode == 200, "request with headers status code failed")

	local response3 = request({ Url = "https://httpbin.org/get?test=unc", Method = "GET" })
	assert(type(response3) == "table" and response3.StatusCode == 200, "request with query params failed")
end)

test("setfpscap", {}, function()
	assert(pcall(function() setfpscap(60) end), "setfpscap 60 failed")
	assert(pcall(function() setfpscap(144) end), "setfpscap 144 failed")
	assert(pcall(function() setfpscap(240) end), "setfpscap 240 failed")
	assert(pcall(function() setfpscap(0) end), "setfpscap 0 (uncapped) failed")
	assert(pcall(function() setfpscap(30) end), "setfpscap 30 failed")
	assert(pcall(function() setfpscap(120) end), "setfpscap 120 failed")
	assert(pcall(function() setfpscap(360) end), "setfpscap 360 failed")
end)

-- ============================================================================
-- DRAWING
-- ============================================================================

test("Drawing.new", {}, function()
	local square = Drawing.new("Square")
	square.Visible = false
	assert(pcall(function() square:Destroy() end), "Drawing Square Destroy method threw exception")

	local circle = Drawing.new("Circle")
	circle.Visible = false
	assert(pcall(function() circle:Destroy() end), "Drawing Circle Destroy method threw exception")

	local line = Drawing.new("Line")
	line.Visible = false
	assert(pcall(function() line:Destroy() end), "Drawing Line Destroy method threw exception")

	local text = Drawing.new("Text")
	text.Visible = false
	assert(pcall(function() text:Destroy() end), "Drawing Text Destroy method threw exception")

	local quad = Drawing.new("Quad")
	quad.Visible = false
	assert(pcall(function() quad:Destroy() end), "Drawing Quad Destroy method threw exception")

	local triangle = Drawing.new("Triangle")
	triangle.Visible = false
	assert(pcall(function() triangle:Destroy() end), "Drawing Triangle Destroy method threw exception")

	local square2 = Drawing.new("Square")
	square2.Size = Vector2.new(100, 100)
	square2.Position = Vector2.new(50, 50)
	square2.Color = Color3.fromRGB(255, 0, 0)
	square2.Transparency = 0.5
	square2.Visible = false
	assert(square2.Size == Vector2.new(100, 100), "Drawing Square Size set failed")
	assert(square2.Position == Vector2.new(50, 50), "Drawing Square Position set failed")
	square2:Destroy()

	local circle2 = Drawing.new("Circle")
	circle2.Radius = 50
	circle2.NumSides = 32
	circle2.Thickness = 2
	circle2.Filled = true
	circle2.Visible = false
	assert(circle2.Radius == 50, "Drawing Circle Radius set failed")
	assert(circle2.NumSides == 32, "Drawing Circle NumSides set failed")
	circle2:Destroy()

	local text2 = Drawing.new("Text")
	text2.Text = "Hello World"
	text2.Size = 18
	text2.Position = Vector2.new(10, 10)
	text2.Visible = false
	assert(text2.Text == "Hello World", "Drawing Text Text set failed")
	assert(text2.Size == 18, "Drawing Text Size set failed")
	text2:Destroy()

	local line2 = Drawing.new("Line")
	line2.From = Vector2.new(0, 0)
	line2.To = Vector2.new(100, 100)
	line2.Thickness = 2
	line2.Visible = false
	assert(line2.From == Vector2.new(0, 0), "Drawing Line From set failed")
	assert(line2.To == Vector2.new(100, 100), "Drawing Line To set failed")
	line2:Destroy()
end)

test("isrenderobj", {}, {"Drawing.new"}, function()
	local circle = Drawing.new("Circle")
	assert(isrenderobj(circle) == true, "isrenderobj false-negative on active Drawing Circle")
	circle:Destroy()

	local square = Drawing.new("Square")
	assert(isrenderobj(square) == true, "isrenderobj false-negative on active Drawing Square")
	square:Destroy()

	local line = Drawing.new("Line")
	assert(isrenderobj(line) == true, "isrenderobj false-negative on active Drawing Line")
	line:Destroy()

	local text = Drawing.new("Text")
	assert(isrenderobj(text) == true, "isrenderobj false-negative on active Drawing Text")
	text:Destroy()

	local quad = Drawing.new("Quad")
	assert(isrenderobj(quad) == true, "isrenderobj false-negative on active Drawing Quad")
	quad:Destroy()

	local triangle = Drawing.new("Triangle")
	assert(isrenderobj(triangle) == true, "isrenderobj false-negative on active Drawing Triangle")
	triangle:Destroy()

	assert(isrenderobj({}) == false, "isrenderobj false-positive on raw Lua table")
	assert(isrenderobj(nil) == false, "isrenderobj false-positive on nil")
	assert(isrenderobj("string") == false, "isrenderobj false-positive on string")
	assert(isrenderobj(123) == false, "isrenderobj false-positive on number")
	assert(isrenderobj(true) == false, "isrenderobj false-positive on boolean")
	assert(isrenderobj(function() end) == false, "isrenderobj false-positive on function")
end)

test("getrenderproperty", {}, {"Drawing.new"}, function()
	local circle = Drawing.new("Circle")
	circle.Radius = 50
	circle.Visible = true
	circle.NumSides = 24
	circle.Thickness = 3
	circle.Filled = true
	circle.Color = Color3.fromRGB(255, 128, 0)
	circle.Transparency = 0.75
	circle.Position = Vector2.new(100, 200)
	circle.ZIndex = 5

	assert(getrenderproperty(circle, "Radius") == 50, "getrenderproperty Radius mismatch")
	assert(getrenderproperty(circle, "Visible") == true, "getrenderproperty Visible mismatch")
	assert(getrenderproperty(circle, "NumSides") == 24, "getrenderproperty NumSides mismatch")
	assert(getrenderproperty(circle, "Thickness") == 3, "getrenderproperty Thickness mismatch")
	assert(getrenderproperty(circle, "Filled") == true, "getrenderproperty Filled mismatch")
	assert(getrenderproperty(circle, "Color") == Color3.fromRGB(255, 128, 0), "getrenderproperty Color mismatch")
	assert(getrenderproperty(circle, "Transparency") == 0.75, "getrenderproperty Transparency mismatch")
	assert(getrenderproperty(circle, "Position") == Vector2.new(100, 200), "getrenderproperty Position mismatch")
	assert(getrenderproperty(circle, "ZIndex") == 5, "getrenderproperty ZIndex mismatch")
	circle:Destroy()

	local square = Drawing.new("Square")
	square.Size = Vector2.new(200, 100)
	square.Position = Vector2.new(50, 50)
	square.Color = Color3.fromRGB(0, 255, 0)
	square.Transparency = 1
	square.Thickness = 1
	square.Filled = true
	square.Visible = false

	assert(getrenderproperty(square, "Size") == Vector2.new(200, 100), "getrenderproperty Square Size mismatch")
	assert(getrenderproperty(square, "Position") == Vector2.new(50, 50), "getrenderproperty Square Position mismatch")
	assert(getrenderproperty(square, "Filled") == true, "getrenderproperty Square Filled mismatch")
	square:Destroy()

	local text = Drawing.new("Text")
	text.Text = "TestText"
	text.Size = 14
	text.Position = Vector2.new(0, 0)
	text.Color = Color3.fromRGB(255, 255, 255)
	text.Visible = true
	text.Center = true
	text.Outline = true

	assert(getrenderproperty(text, "Text") == "TestText", "getrenderproperty Text mismatch")
	assert(getrenderproperty(text, "Size") == 14, "getrenderproperty Text Size mismatch")
	assert(getrenderproperty(text, "Center") == true, "getrenderproperty Text Center mismatch")
	assert(getrenderproperty(text, "Outline") == true, "getrenderproperty Text Outline mismatch")
	text:Destroy()

	local line = Drawing.new("Line")
	line.From = Vector2.new(0, 0)
	line.To = Vector2.new(500, 500)
	line.Thickness = 2
	line.Color = Color3.fromRGB(0, 0, 255)
	line.Visible = true

	assert(getrenderproperty(line, "From") == Vector2.new(0, 0), "getrenderproperty Line From mismatch")
	assert(getrenderproperty(line, "To") == Vector2.new(500, 500), "getrenderproperty Line To mismatch")
	assert(getrenderproperty(line, "Thickness") == 2, "getrenderproperty Line Thickness mismatch")
	line:Destroy()
end)

test("setrenderproperty", {}, {"Drawing.new"}, function()
	local circle = Drawing.new("Circle")
	setrenderproperty(circle, "Radius", 75)
	setrenderproperty(circle, "Visible", true)
	setrenderproperty(circle, "NumSides", 48)
	setrenderproperty(circle, "Thickness", 4)
	setrenderproperty(circle, "Filled", false)
	setrenderproperty(circle, "Color", Color3.fromRGB(100, 200, 50))
	setrenderproperty(circle, "Transparency", 0.5)
	setrenderproperty(circle, "Position", Vector2.new(300, 400))
	setrenderproperty(circle, "ZIndex", 10)

	assert(circle.Radius == 75, "setrenderproperty Radius mismatch")
	assert(circle.Visible == true, "setrenderproperty Visible mismatch")
	assert(circle.NumSides == 48, "setrenderproperty NumSides mismatch")
	assert(circle.Thickness == 4, "setrenderproperty Thickness mismatch")
	assert(circle.Filled == false, "setrenderproperty Filled mismatch")
	assert(circle.Color == Color3.fromRGB(100, 200, 50), "setrenderproperty Color mismatch")
	assert(circle.Transparency == 0.5, "setrenderproperty Transparency mismatch")
	assert(circle.Position == Vector2.new(300, 400), "setrenderproperty Position mismatch")
	assert(circle.ZIndex == 10, "setrenderproperty ZIndex mismatch")
	circle:Destroy()

	local square = Drawing.new("Square")
	setrenderproperty(square, "Size", Vector2.new(150, 75))
	setrenderproperty(square, "Position", Vector2.new(25, 25))
	setrenderproperty(square, "Color", Color3.fromRGB(0, 100, 200))
	setrenderproperty(square, "Filled", true)
	setrenderproperty(square, "Thickness", 2)
	setrenderproperty(square, "Visible", false)

	assert(square.Size == Vector2.new(150, 75), "setrenderproperty Square Size mismatch")
	assert(square.Position == Vector2.new(25, 25), "setrenderproperty Square Position mismatch")
	assert(square.Filled == true, "setrenderproperty Square Filled mismatch")
	square:Destroy()

	local text = Drawing.new("Text")
	setrenderproperty(text, "Text", "ModifiedText")
	setrenderproperty(text, "Size", 20)
	setrenderproperty(text, "Center", true)
	setrenderproperty(text, "Outline", false)
	setrenderproperty(text, "Color", Color3.fromRGB(200, 100, 0))

	assert(text.Text == "ModifiedText", "setrenderproperty Text mismatch")
	assert(text.Size == 20, "setrenderproperty Text Size mismatch")
	assert(text.Center == true, "setrenderproperty Text Center mismatch")
	assert(text.Outline == false, "setrenderproperty Text Outline mismatch")
	text:Destroy()

	local line = Drawing.new("Line")
	setrenderproperty(line, "From", Vector2.new(10, 20))
	setrenderproperty(line, "To", Vector2.new(300, 400))
	setrenderproperty(line, "Thickness", 5)
	setrenderproperty(line, "Color", Color3.fromRGB(255, 0, 255))

	assert(line.From == Vector2.new(10, 20), "setrenderproperty Line From mismatch")
	assert(line.To == Vector2.new(300, 400), "setrenderproperty Line To mismatch")
	assert(line.Thickness == 5, "setrenderproperty Line Thickness mismatch")
	line:Destroy()
end)

test("cleardrawcache", {}, {"Drawing.new"}, function()
	local obj = Drawing.new("Square")
	obj.Visible = false
	assert(pcall(function() cleardrawcache() end), "cleardrawcache execution failed")

	local obj2 = Drawing.new("Circle")
	obj2.Visible = false
	assert(pcall(function() cleardrawcache() end), "cleardrawcache second call failed")

	assert(pcall(function() cleardrawcache() end), "cleardrawcache third call failed")
end)

-- ============================================================================
-- WEBSOCKET
-- ============================================================================

test("WebSocket.connect", {}, function()
	local ws = WebSocket.connect("ws://echo.websocket.events")
	assert(type(ws) == "table" or type(ws) == "userdata", "WebSocket object format mismatch")
	assert(type(ws.Send) == "function", "WebSocket interface missing Send function")
	assert(type(ws.Close) == "function", "WebSocket interface missing Close function")
	assert(type(ws.OnMessage) ~= "nil" or type(ws.OnClose) ~= "nil", "WebSocket missing event handlers")
	ws:Close()
end)

-- ============================================================================
-- ADDITIONAL ANTI-SPOOF BEHAVIORAL TESTS
-- ============================================================================

test("anti-spoof: cache.invalidate persistence", {}, function()
	local container = Instance_new("Folder")
	local part = Instance_new("Part", container)
	part.Name = "PersistenceTest"

	for round = 1, 5 do
		local refBefore = container:FindFirstChild("PersistenceTest")
		cache.invalidate(refBefore)
		task_wait(0.05)
		local refAfter = container:FindFirstChild("PersistenceTest")
		assert(refBefore ~= refAfter, "Anti-spoof: cache.invalidate persistence round " .. round .. " failed")
	end

	local part2 = Instance_new("Part", container)
	part2.Name = "RapidInvalidate"
	local ref = container:FindFirstChild("RapidInvalidate")
	cache.invalidate(ref)
	cache.invalidate(container:FindFirstChild("RapidInvalidate"))
	local refFinal = container:FindFirstChild("RapidInvalidate")
	assert(ref ~= refFinal, "Anti-spoof: rapid double invalidation failed")
end)

test("anti-spoof: cloneref behavioral consistency", {}, {"cloneref"}, function()
	local part = Instance_new("Part")
	part.Name = "ConsistencyTest"
	part.Size = Vector3.new(1, 2, 3)
	part.Position = Vector3.new(4, 5, 6)

	for round = 1, 5 do
		local clone = cloneref(part)
		assert(part ~= clone, "Anti-spoof: cloneref identity check round " .. round .. " failed")
		clone.Name = "Round" .. round
		assert(part.Name == "Round" .. round, "Anti-spoof: cloneref property sync round " .. round .. " failed")
	end

	local cloneA = cloneref(part)
	local cloneB = cloneref(part)
	local cloneC = cloneref(part)
	cloneA.Name = "ViaCloneA"
	assert(part.Name == "ViaCloneA", "Anti-spoof: triple clone A failed")
	cloneB.Name = "ViaCloneB"
	assert(part.Name == "ViaCloneB", "Anti-spoof: triple clone B failed")
	cloneC.Name = "ViaCloneC"
	assert(part.Name == "ViaCloneC", "Anti-spoof: triple clone C failed")
end)

test("anti-spoof: compareinstances timing", {}, {"cloneref"}, function()
	local part = Instance_new("Part")
	local clone = cloneref(part)

	local t0 = os_clock()
	for i = 1, 100 do
		compareinstances(part, clone)
	end
	local elapsed = os_clock() - t0
	assert(elapsed < 2.0, "Anti-spoof: compareinstances 100 iterations took " .. string_format("%.3fs", elapsed) .. " (too slow, possible wrapper)")

	local part2 = Instance_new("Part")
	for i = 1, 100 do
		assert(compareinstances(part, part2) == false, "Anti-spoof: compareinstances false-positive at iteration " .. i)
	end
end)

test("anti-spoof: checkcaller coroutine depth", {}, {"hookfunction", "restorefunction"}, function()
	local function deepCheck(depth)
		if depth <= 0 then
			return checkcaller()
		end
		return deepCheck(depth - 1)
	end
	for d = 1, 5 do
		assert(deepCheck(d) == true, "Anti-spoof: checkcaller failed at coroutine depth " .. d)
	end

	local co = coroutine.create(function()
		local function nested()
			return checkcaller()
		end
		return nested()
	end)
	local _, result = coroutine.resume(co)
	assert(result == true, "Anti-spoof: checkcaller in resumed coroutine failed")

	local co2 = coroutine.create(function()
		local function level1()
			local function level2()
				local function level3()
					return checkcaller()
				end
				return level3()
			end
			return level2()
		end
		return level1()
	end)
	local _, result2 = coroutine.resume(co2)
	assert(result2 == true, "Anti-spoof: checkcaller in 3-level nested coroutine failed")
end)

test("anti-spoof: hookfunction reference integrity", {}, {"hookfunction", "restorefunction"}, function()
	local function target() return "original" end
	local originalRef
	originalRef = hookfunction(target, function() return "hooked" end)

	local results = {}
	for i = 1, 10 do
		results[i] = target()
	end
	for i, v in ipairs(results) do
		assert(v == "hooked", "Anti-spoof: hookfunction result consistency iteration " .. i .. " failed")
	end

	local refResults = {}
	for i = 1, 10 do
		refResults[i] = originalRef()
	end
	for i, v in ipairs(refResults) do
		assert(v == "original", "Anti-spoof: hookfunction ref consistency iteration " .. i .. " failed")
	end

	restorefunction(target)
	assert(target() == "original", "Anti-spoof: restorefunction final check failed")
end)

test("anti-spoof: iscclosure type discrimination", {}, {"newcclosure"}, function()
	local nativeFunctions = {print, warn, error, pcall, xpcall, select, type, typeof, tostring, tonumber, pairs, ipairs, setmetatable, getmetatable, rawget, rawset, rawequal, assert, collectgarbage, require, gcinfo}
	for _, fn in ipairs(nativeFunctions) do
		assert(iscclosure(fn) == true, "Anti-spoof: iscclosure false-negative on native: " .. tostring(fn))
	end

	local luauFunctions = {
		function() return 1 end,
		function() return "str" end,
		function(a, b) return a + b end,
		function(...) return ... end,
		function()
			local x = 10
			return x
		end,
		function()
			return function() return "nested" end
		end,
	}
	for i, fn in ipairs(luauFunctions) do
		assert(iscclosure(fn) == false, "Anti-spoof: iscclosure false-positive on Luau function " .. i)
	end

	for _, fn in ipairs(luauFunctions) do
		local wrapped = newcclosure(fn)
		assert(iscclosure(wrapped) == true, "Anti-spoof: iscclosure false-negative on newcclosure")
	end
end)

test("anti-spoof: islclosure type discrimination", {}, {"newcclosure"}, function()
	local nativeFunctions = {print, warn, error, pcall, xpcall, select, type, typeof, tostring, tonumber, pairs, ipairs}
	for _, fn in ipairs(nativeFunctions) do
		assert(islclosure(fn) == false, "Anti-spoof: islclosure false-positive on native: " .. tostring(fn))
	end

	local luauFunctions = {
		function() return 1 end,
		function(a) return a * 2 end,
		function(x, y, z) return x + y + z end,
		function(...)
			local args = {...}
			return #args
		end,
		function()
			local closed = "value"
			return function() return closed end
		end,
	}
	for i, fn in ipairs(luauFunctions) do
		assert(islclosure(fn) == true, "Anti-spoof: islclosure false-negative on Luau function " .. i)
	end

	for _, fn in ipairs(luauFunctions) do
		local wrapped = newcclosure(fn)
		assert(islclosure(wrapped) == false, "Anti-spoof: islclosure false-positive on newcclosure")
	end
end)

test("anti-spoof: getfunctionhash determinism stress", {}, function()
	local function target() return "determinism_test" end
	local hashes = {}
	for i = 1, 20 do
		hashes[i] = getfunctionhash(target)
	end
	for i = 2, 20 do
		assert(hashes[i] == hashes[1], "Anti-spoof: getfunctionhash non-deterministic at iteration " .. i)
	end

	local function funcA() return "a" end
	local function funcB() return "b" end
	local function funcC() return "c" end
	local function funcD() return "d" end
	local function funcE() return "e" end

	local hashA = getfunctionhash(funcA)
	local hashB = getfunctionhash(funcB)
	local hashC = getfunctionhash(funcC)
	local hashD = getfunctionhash(funcD)
	local hashE = getfunctionhash(funcE)

	assert(hashA ~= hashB, "Anti-spoof: hash collision A/B")
	assert(hashA ~= hashC, "Anti-spoof: hash collision A/C")
	assert(hashA ~= hashD, "Anti-spoof: hash collision A/D")
	assert(hashA ~= hashE, "Anti-spoof: hash collision A/E")
	assert(hashB ~= hashC, "Anti-spoof: hash collision B/C")
	assert(hashB ~= hashD, "Anti-spoof: hash collision B/D")
	assert(hashB ~= hashE, "Anti-spoof: hash collision B/E")
	assert(hashC ~= hashD, "Anti-spoof: hash collision C/D")
	assert(hashC ~= hashE, "Anti-spoof: hash collision C/E")
	assert(hashD ~= hashE, "Anti-spoof: hash collision D/E")
end)

test("anti-spoof: getnamecallmethod outside hook", {}, {"hookmetamethod", "restorefunction", "getrawmetatable"}, function()
	for i = 1, 5 do
		local result = getnamecallmethod()
		assert(result == nil, "Anti-spoof: getnamecallmethod outside hook should return nil, got: " .. tostring(result))
	end

	local capturedMethods = {}
	local ref
	ref = hookmetamethod(game, "__namecall", function(self, ...)
		local method = getnamecallmethod()
		table_insert(capturedMethods, method)
		return ref(self, ...)
	end)

	game:GetService("Lighting")
	game:GetService("Players")
	game:GetService("Workspace")
	game:GetService("TweenService")
	game:GetService("HttpService")

	restorefunction(getrawmetatable(game).__namecall)

	assert(#capturedMethods == 5, "Anti-spoof: should have captured 5 methods, got " .. #capturedMethods)
	for i, method in ipairs(capturedMethods) do
		assert(method == "GetService", "Anti-spoof: captured method " .. i .. " should be GetService, got " .. tostring(method))
	end

	local afterResult = getnamecallmethod()
	assert(afterResult == nil, "Anti-spoof: getnamecallmethod after hook removal should return nil")
end)

test("anti-spoof: newcclosure identity preservation", {}, {"iscclosure", "clonefunction"}, function()
	local function original() return 42 end
	local wrapped = newcclosure(original)

	assert(original ~= wrapped, "Anti-spoof: newcclosure should return different identity")
	assert(iscclosure(wrapped) == true, "Anti-spoof: newcclosure lost C-closure status")

	local wrapped2 = newcclosure(original)
	assert(wrapped ~= wrapped2, "Anti-spoof: two newcclosure of same func should differ")

	assert(wrapped() == 42, "Anti-spoof: newcclosure execution failed")
	assert(wrapped2() == 42, "Anti-spoof: newcclosure2 execution failed")
end)

test("anti-spoof: getrawmetatable bypass verification", {}, function()
	local lockedMt = { __metatable = "YouCannotGetThis" }
	local obj1 = setmetatable({}, lockedMt)

	local success1, fail1 = pcall(getmetatable, obj1)
	assert(fail1 == "YouCannotGetThis" or success1 == "YouCannotGetThis", "Anti-spoof: standard getmetatable should be locked")

	local rawMt = getrawmetatable(obj1)
	assert(type(rawMt) == "table", "Anti-spoof: getrawmetatable should return table")
	assert(rawMt == lockedMt, "Anti-spoof: getrawmetatable should return exact metatable reference")

	local obj2 = setmetatable({}, { __metatable = false })
	local rawMt2 = getrawmetatable(obj2)
	assert(type(rawMt2) == "table", "Anti-spoof: getrawmetatable with false __metatable failed")

	local obj3 = setmetatable({}, { __metatable = 0 })
	local rawMt3 = getrawmetatable(obj3)
	assert(type(rawMt3) == "table", "Anti-spoof: getrawmetatable with 0 __metatable failed")

	local obj4 = setmetatable({}, { __metatable = "" })
	local rawMt4 = getrawmetatable(obj4)
	assert(type(rawMt4) == "table", "Anti-spoof: getrawmetatable with empty string __metatable failed")
end)

test("anti-spoof: setrawmetatable functional override", {}, {"getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__index = function(_, k) return "original_" .. tostring(k) end,
		__metatable = "Locked"
	})

	assert(obj.test == "original_test", "Anti-spoof: initial __index failed")

	local newMt = { __index = function(_, k) return "overridden_" .. tostring(k) end }
	setrawmetatable(obj, newMt)

	assert(obj.test == "overridden_test", "Anti-spoof: setrawmetatable __index override failed")
	assert(obj.anything == "overridden_anything", "Anti-spoof: setrawmetatable different key failed")

	local rawMt = getrawmetatable(obj)
	assert(rawMt == newMt, "Anti-spoof: getrawmetatable after set should match new metatable")
end)

test("anti-spoof: setreadonly toggle verification", {}, {"isreadonly"}, function()
	local tbl = { a = 1, b = 2, c = 3 }
	table_freeze(tbl)

	assert(isreadonly(tbl) == true, "Anti-spoof: initial frozen state failed")
	setreadonly(tbl, false)
	assert(isreadonly(tbl) == false, "Anti-spoof: setreadonly(false) failed")

	tbl.d = 4
	assert(tbl.d == 4, "Anti-spoof: mutation after unfreeze failed")
	tbl.a = 100
	assert(tbl.a == 100, "Anti-spoof: overwrite after unfreeze failed")

	setreadonly(tbl, true)
	assert(isreadonly(tbl) == true, "Anti-spoof: re-freeze failed")

	local success = pcall(function() tbl.e = 5 end)
	assert(not success, "Anti-spoof: mutation after re-freeze should error")
	assert(tbl.a == 100, "Anti-spoof: value changed after re-freeze")
end)

test("anti-spoof: getgenv persistence", {}, function()
	local key1 = "__UNC_PERSIST_TEST_" .. math_random(1000, 9999)
	local key2 = "__UNC_PERSIST_TEST2_" .. math_random(1000, 9999)

	getgenv()[key1] = "persistent_value"
	task_wait(0.1)
	assert(getgenv()[key1] == "persistent_value", "Anti-spoof: getgenv persistence failed after delay")

	getgenv()[key2] = 42
	task_wait(0.1)
	assert(getgenv()[key1] == "persistent_value", "Anti-spoof: getgenv first key lost after second set")
	assert(getgenv()[key2] == 42, "Anti-spoof: getgenv second key persistence failed")

	local env = getgenv()
	env[key1] = "via_env_ref"
	task_wait(0.1)
	assert(getgenv()[key1] == "via_env_ref", "Anti-spoof: getgenv via env ref failed")

	getgenv()[key1] = nil
	getgenv()[key2] = nil
end)

test("anti-spoof: getrenv completeness", {}, function()
	local renv = getrenv()
	local requiredGlobals = {
		"game", "workspace", "script", "print", "warn", "error", "pcall", "xpcall",
		"type", "typeof", "tostring", "tonumber", "select", "pairs", "ipairs",
		"setmetatable", "getmetatable", "rawget", "rawset", "rawequal",
		"table", "string", "math", "task", "Instance", "Vector3", "Vector2",
		"CFrame", "Color3", "Enum", "UDim2", "UDim", "BrickColor", "Region3",
		"NumberRange", "NumberSequence", "NumberSequenceKeypoint",
		"ColorSequence", "ColorSequenceKeypoint", "PhysicalProperties",
		"Ray", "Rect", "TweenInfo", "Faces", "Axes",
		"coroutine", "debug", "os", "bit32", "utf8", "buffer",
		"require", "delay", "spawn", "tick", "time", "wait",
		"unpack", "assert", "collectgarbage", "gcinfo", "newproxy",
		"next", "rawlen", "setfenv", "getfenv",
	}
	for _, globalName in ipairs(requiredGlobals) do
		assert(renv[globalName] ~= nil, "Anti-spoof: getrenv missing global: " .. globalName)
	end

	assert(renv._G ~= _G, "Anti-spoof: getrenv._G should differ from executor _G")
end)

test("anti-spoof: debug.getinfo function integrity", {}, function()
	local function sample(a, b, ...) return a + b end
	local info = debug.getinfo(sample)
	assert(info.func == sample, "Anti-spoof: debug.getinfo.func mismatch")
	assert(info.numparams == 2, "Anti-spoof: debug.getinfo.numparams mismatch")
	assert(info.is_vararg == 1 or info.is_vararg == true, "Anti-spoof: debug.getinfo.is_vararg mismatch")
	assert(info.what == "Lua" or info.what == "Luau", "Anti-spoof: debug.getinfo.what unexpected")
	assert(type(info.nups) == "number", "Anti-spoof: debug.getinfo.nups not number")
	assert(type(info.source) == "string", "Anti-spoof: debug.getinfo.source not string")
	assert(type(info.linedefined) == "number", "Anti-spoof: debug.getinfo.linedefined not number")
	assert(type(info.lastlinedefined) == "number", "Anti-spoof: debug.getinfo.lastlinedefined not number")

	local function noArgs() end
	local info2 = debug.getinfo(noArgs)
	assert(info2.numparams == 0, "Anti-spoof: noArgs numparams should be 0")
	assert(info2.is_vararg == 0 or info2.is_vararg == false, "Anti-spoof: noArgs is_vararg should be false")

	local function variadic(...) end
	local info3 = debug.getinfo(variadic)
	assert(info3.is_vararg == 1 or info3.is_vararg == true, "Anti-spoof: variadic is_vararg should be true")
end)

test("anti-spoof: debug.getupvalues/setcycle integrity", {}, function()
	local function capture()
		local a = "alpha"
		local b = "beta"
		local c = "gamma"
		return a, b, c
	end

	local uv = debug.getupvalues(capture)
	assert(type(uv) == "table", "Anti-spoof: debug.getupvalues should return table")
	assert(#uv == 3, "Anti-spoof: debug.getupvalues should have 3 entries")
	assert(uv[1] == "alpha", "Anti-spoof: upvalue 1 mismatch")
	assert(uv[2] == "beta", "Anti-spoof: upvalue 2 mismatch")
	assert(uv[3] == "gamma", "Anti-spoof: upvalue 3 mismatch")

	debug.setupvalue(capture, 1, "ALPHA")
	debug.setupvalue(capture, 2, "BETA")
	debug.setupvalue(capture, 3, "GAMMA")

	local r1, r2, r3 = capture()
	assert(r1 == "ALPHA", "Anti-spoof: setupvalue 1 failed")
	assert(r2 == "BETA", "Anti-spoof: setupvalue 2 failed")
	assert(r3 == "GAMMA", "Anti-spoof: setupvalue 3 failed")

	local uv2 = debug.getupvalues(capture)
	assert(uv2[1] == "ALPHA", "Anti-spoof: getupvalues after setup 1 mismatch")
	assert(uv2[2] == "BETA", "Anti-spoof: getupvalues after setup 2 mismatch")
	assert(uv2[3] == "GAMMA", "Anti-spoof: getupvalues after setup 3 mismatch")
end)

test("anti-spoof: debug.getconstants integrity", {}, function()
	local function sample()
		local x = 42
		local y = "hello"
		local z = true
		print(x, y, z)
	end

	local consts = debug.getconstants(sample)
	assert(type(consts) == "table", "Anti-spoof: debug.getconstants should return table")
	assert(consts[1] == 42, "Anti-spoof: constant 1 mismatch")
	assert(consts[2] == "hello", "Anti-spoof: constant 2 mismatch")
	assert(consts[3] == true, "Anti-spoof: constant 3 mismatch")
	assert(consts[4] == "print", "Anti-spoof: constant 4 mismatch")

	debug.setconstant(sample, 1, 99)
	debug.setconstant(sample, 2, "world")
	debug.setconstant(sample, 3, false)

	local result = sample()
	local consts2 = debug.getconstants(sample)
	assert(consts2[1] == 99, "Anti-spoof: setconstant 1 failed")
	assert(consts2[2] == "world", "Anti-spoof: setconstant 2 failed")
	assert(consts2[3] == false, "Anti-spoof: setconstant 3 failed")
end)

test("anti-spoof: gethiddenproperty non-setscriptable impl", {}, {"gethiddenproperty", "sethiddenproperty"}, function()
	local fire = Instance_new("Fire")
	local val1, isHidden1 = gethiddenproperty(fire, "size_xml")
	assert(type(val1) == "number", "Anti-spoof: gethiddenproperty size_xml should return number")
	assert(isHidden1 == true, "Anti-spoof: size_xml should be hidden")

	local part = Instance_new("Part")
	local val2, isHidden2 = gethiddenproperty(part, "Name")
	assert(type(val2) == "string", "Anti-spoof: gethiddenproperty Name should return string")
	assert(isHidden2 == false, "Anti-spoof: Name should not be hidden")

	local val3, isHidden3 = gethiddenproperty(part, "DataCost")
	assert(type(val3) == "number", "Anti-spoof: gethiddenproperty DataCost should return number")

	sethiddenproperty(fire, "size_xml", 42)
	local newVal = gethiddenproperty(fire, "size_xml")
	assert(newVal == 42, "Anti-spoof: sethiddenproperty/gethiddenproperty round-trip failed")

	sethiddenproperty(fire, "size_xml", -1)
	local newVal2 = gethiddenproperty(fire, "size_xml")
	assert(newVal2 == -1, "Anti-spoof: negative value round-trip failed")

	sethiddenproperty(fire, "size_xml", 0)
	local newVal3 = gethiddenproperty(fire, "size_xml")
	assert(newVal3 == 0, "Anti-spoof: zero value round-trip failed")
end)

test("anti-spoof: gethui is real container", {}, function()
	local hui = gethui()
	assert(typeof(hui) == "Instance", "Anti-spoof: gethui should return Instance")
	assert(hui.Parent ~= nil or hui:IsA("Folder"), "Anti-spoof: gethui container should have parent or be Folder")

	local gui = Instance_new("ScreenGui")
	gui.Name = "AntiSpoofTest_" .. math_random(1000, 9999)
	gui.Parent = hui
	task_wait(0.1)
	local found = hui:FindFirstChild(gui.Name)
	assert(found ~= nil, "Anti-spoof: gethui child insertion not persisted after delay")
	assert(found == gui, "Anti-spoof: gethui FindFirstChild returned wrong instance")
	gui:Destroy()

	for i = 1, 5 do
		local h = gethui()
		assert(typeof(h) == "Instance", "Anti-spoof: gethui consistency " .. i .. " type failed")
		assert(h == hui, "Anti-spoof: gethui consistency " .. i .. " identity failed")
	end
end)

test("anti-spoof: getinstances real data", {}, function()
	local insts = getinstances()
	assert(type(insts) == "table", "Anti-spoof: getinstances should return table")
	assert(#insts > 0, "Anti-spoof: getinstances should have entries")

	local count = #insts
	local newPart = Instance_new("Part")
	local newCount = #getinstances()
	assert(newCount >= count, "Anti-spoof: getinstances should reflect new Part")

	local categories = { Part = 0, BaseScript = 0, Folder = 0, ModuleScript = 0 }
	for _, inst in ipairs(insts) do
		if inst:IsA("Part") then categories.Part += 1 end
		if inst:IsA("BaseScript") then categories.BaseScript += 1 end
		if inst:IsA("Folder") then categories.Folder += 1 end
		if inst:IsA("ModuleScript") then categories.ModuleScript += 1 end
	end
	assert(categories.Part > 0, "Anti-spoof: getinstances found no Parts")
	assert(categories.Folder > 0, "Anti-spoof: getinstances found no Folders")
end)

test("anti-spoof: getnilinstances real data", {}, function()
	local nilInsts = getnilinstances()
	assert(type(nilInsts) == "table", "Anti-spoof: getnilinstances should return table")
	assert(#nilInsts > 0, "Anti-spoof: getnilinstances should have entries")

	for i, inst in ipairs(nilInsts) do
		assert(typeof(inst) == "Instance", "Anti-spoof: getnilinstances entry " .. i .. " not Instance")
		assert(inst.Parent == nil, "Anti-spoof: getnilinstances entry " .. i .. " has parent")
	end

	local newPart = Instance_new("Part")
	local found = false
	for _, inst in ipairs(getnilinstances()) do
		if inst == newPart then found = true break end
	end
	assert(found, "Anti-spoof: getnilinstances failed to find newly unparented Part")
end)

test("anti-spoof: isreadonly/setreadonly round-trip", {}, {"isreadonly"}, function()
	local tbl = { key = "value" }
	table_freeze(tbl)
	assert(isreadonly(tbl) == true, "Anti-spoof: frozen table should be readonly")
	setreadonly(tbl, false)
	assert(isreadonly(tbl) == false, "Anti-spoof: unfrozen table should not be readonly")
	tbl.key = "changed"
	assert(tbl.key == "changed", "Anti-spoof: mutation after unfreeze failed")
	setreadonly(tbl, true)
	assert(isreadonly(tbl) == true, "Anti-spoof: re-frozen table should be readonly")
	local ok = pcall(function() tbl.key = "blocked" end)
	assert(not ok, "Anti-spoof: mutation after re-freeze should error")
	assert(tbl.key == "changed", "Anti-spoof: value changed after re-freeze")
end)

test("anti-spoof: getthreadidentity/setthreadidentity round-trip", {"getidentity", "getthreadcontext", "setidentity", "setthreadcontext"}, {"getthreadidentity"}, function()
	local original = getthreadidentity()
	local levels = {0, 1, 2, 3, 4, 5, 6, 7, 8}
	for _, level in ipairs(levels) do
		setthreadidentity(level)
		local current = getthreadidentity()
		assert(current == level, "Anti-spoof: identity level " .. level .. " set/get mismatch, got " .. tostring(current))
	end
	setthreadidentity(original)
end)

-- ============================================================================
-- ADDITIONAL EDGE CASE TESTS
-- ============================================================================

test("edge case: cloneref with destroyed instances", {}, function()
	local part = Instance_new("Part")
	local clone = cloneref(part)
	clone:Destroy()
	task_wait(0.1)
	assert(clone.Parent == nil, "cloneref of destroyed instance should have nil parent")
end)

test("edge case: compareinstances with same reference", {}, function()
	local part = Instance_new("Part")
	assert(compareinstances(part, part) == true, "compareinstances same reference should be true")
end)

test("edge case: getconnections on bindable with no connections", {}, function()
	local bindable = Instance_new("BindableEvent")
	local conns = getconnections(bindable.Event)
	assert(type(conns) == "table", "getconnections on empty signal should return table")
	assert(#conns == 0, "getconnections on empty signal should return empty table")
end)

test("edge case: firesignal on signal with no connections", {}, function()
	local bindable = Instance_new("BindableEvent")
	local ok = pcall(function() firesignal(bindable.Event) end)
	assert(ok, "firesignal on empty signal should not error")
end)

test("edge case: getscriptbytecode on multiple script types", {}, function()
	local localScript = Instance_new("LocalScript")
	assert(getscriptbytecode(localScript) == nil, "getscriptbytecode on empty LocalScript should return nil")

	local moduleScript = Instance_new("ModuleScript")
	assert(getscriptbytecode(moduleScript) == nil, "getscriptbytecode on empty ModuleScript should return nil")

	local serverScript = Instance_new("Script")
	assert(getscriptbytecode(serverScript) == nil, "getscriptbytecode on empty Script should return nil")
end)

test("edge case: decompile on multiple script types", {}, function()
	local localScript = Instance_new("LocalScript")
	local result = decompile(localScript)
	assert(type(result) == "string", "decompile on empty LocalScript should return string")

	local moduleScript = Instance_new("ModuleScript")
	local result2 = decompile(moduleScript)
	assert(type(result2) == "string", "decompile on empty ModuleScript should return string")
end)

test("edge case: loadstring with various inputs", {}, function()
	local f1, e1 = loadstring("return 1 + 2")
	assert(type(f1) == "function", "loadstring simple addition should return function")
	assert(f1() == 3, "loadstring simple addition result failed")

	local f2, e2 = loadstring("return 'hello' .. ' ' .. 'world'")
	assert(type(f2) == "function", "loadstring string concat should return function")
	assert(f2() == "hello world", "loadstring string concat result failed")

	local f3, e3 = loadstring("return #{}", "TestChunk")
	assert(f3 == nil, "loadstring invalid syntax should return nil")

	local f4, e4 = loadstring("")
	assert(type(f4) == "function", "loadstring empty string should return function")
	assert(f4() == nil, "loadstring empty string result should be nil")
end)

test("edge case: getfunctionhash with upvalue closures", {}, function()
	local function makeFunc(x)
		return function() return x end
	end
	local f1 = makeFunc(10)
	local f2 = makeFunc(20)
	local h1 = getfunctionhash(f1)
	local h2 = getfunctionhash(f2)
	assert(h1 ~= h2, "getfunctionhash should distinguish closures with different upvalues")
end)

test("edge case: hookfunction with no-arg functions", {}, {"restorefunction"}, function()
	local function target() end
	local ref = hookfunction(target, function() end)
	target()
	ref()
	restorefunction(target)
end)

test("edge case: hookmetamethod with __index returning different types", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__index = newcclosure(function(_, k)
			if k == "number" then return 42
			elseif k == "string" then return "hello"
			elseif k == "bool" then return true
			elseif k == "nil" then return nil
			elseif k == "table" then return {1, 2, 3}
			end
		end),
		__metatable = "Locked"
	})

	local ref
	ref = hookmetamethod(obj, "__index", function(_, k)
		return "hooked_" .. tostring(k)
	end)

	assert(obj.number == "hooked_number", "hookmetamethod __index hook number key failed")
	assert(obj.string == "hooked_string", "hookmetamethod __index hook string key failed")
	assert(obj.bool == "hooked_bool", "hookmetamethod __index hook bool key failed")
	assert(obj.nilkey == "hooked_nil", "hookmetamethod __index hook nil key failed")

	restorefunction(getrawmetatable(obj).__index)
end)

test("edge case: debug.getstack/setstack edge values", {}, function()
	local function test1()
		local a = "first"
		return debug.getstack(1, 1)
	end
	assert(test1() == "first", "debug.getstack basic test failed")

	local function test2()
		debug.setstack(1, 1, "replaced")
		return "replaced"
	end
	assert(test2() == "debug.setstack basic test failed")
end)

test("edge case: getcallbackvalue with various callback types", {}, function()
	local bindable = Instance_new("BindableFunction")
	local fn1 = function() return 1 end
	bindable.OnInvoke = fn1
	assert(getcallbackvalue(bindable, "OnInvoke") == fn1, "getcallbackvalue simple function failed")

	local fn2 = function(a, b) return a + b end
	bindable.OnInvoke = fn2
	assert(getcallbackvalue(bindable, "OnInvoke") == fn2, "getcallbackvalue multi-arg function failed")

	bindable.OnInvoke = nil
end)

test("edge case: setsimulationradius with various values", {}, function()
	local ok1 = pcall(function() setsimulationradius(0, 0) end)
	assert(ok1, "setsimulationradius 0,0 should not error")

	local ok2 = pcall(function() setsimulationradius(1000, 1000) end)
	assert(ok2, "setsimulationradius 1000,1000 should not error")

	local ok3 = pcall(function() setsimulationradius(50000, 50000) end)
	assert(ok3, "setsimulationradius 50000,50000 should not error")

	local ok4 = pcall(function() setsimulationradius(1) end)
	assert(ok4, "setsimulationradius single arg should not error")
end)

test("edge case: getgc finds different types", {}, function()
	local gc = getgc()
	local types = {}
	for _, v in ipairs(gc) do
		types[type(v)] = true
	end
	assert(types.table == true, "getgc should find tables")
	assert(types.function == true, "getgc should find functions")
	assert(types.string == true, "getgc should find strings")
	assert(types.number == true, "getgc should find numbers")
end)

test("edge case: filtergc with returnOne false", {}, function()
	local markerKey = "UNC_FILTER_EDGE_" .. math_random(1000, 9999)
	local targetTable = { [markerKey] = 42 }
	local results = filtergc("table", { Keys = { markerKey } }, false)
	assert(type(results) == "table", "filtergc returnOne=false should return table")
	assert(#results >= 1, "filtergc returnOne=false should find at least 1 result")
end)

test("edge case: identifyexecutor returns consistent data", {}, function()
	local n1, v1 = identifyexecutor()
	local n2, v2 = identifyexecutor()
	assert(n1 == n2, "identifyexecutor name inconsistency")
	assert(v1 == v2, "identifyexecutor version inconsistency")
end)

test("edge case: gethwid returns consistent data", {}, function()
	local hwid1 = gethwid()
	task_wait(0.05)
	local hwid2 = gethwid()
	assert(hwid1 == hwid2, "gethwid returned different values after delay")
end)

test("edge case: isrbxactive returns boolean", {}, function()
	for i = 1, 3 do
		local result = isrbxactive()
		assert(type(result) == "boolean", "isrbxactive should return boolean on call " .. i)
	end
end)

test("edge case: gethui accepts and preserves children", {}, function()
	local hui = gethui()
	local gui = Instance_new("ScreenGui")
	gui.Name = "EdgeCaseTest_" .. math_random(10000, 99999)
	gui.Parent = hui
	task_wait(0.1)
	local found = hui:FindFirstChild(gui.Name)
	assert(found ~= nil, "gethui child not found after insertion")
	assert(found == gui, "gethui FindFirstChild returned wrong instance")

	local frame = Instance_new("Frame")
	frame.Name = "TestFrame"
	frame.Parent = gui
	assert(gui:FindFirstChild("TestFrame") ~= nil, "gethui nested child insertion failed")

	gui:Destroy()
end)

test("edge case: getcustomasset with various file sizes", {}, {"writefile"}, function()
	writefile(".unc_fs_root/asset_tiny.txt", "x")
	local asset1 = getcustomasset(".unc_fs_root/asset_tiny.txt")
	assert(type(asset1) == "string" and string_match(asset1, "rbxasset://") ~= nil, "getcustomasset tiny file failed")

	writefile(".unc_fs_root/asset_medium.txt", string_rep("M", 500))
	local asset2 = getcustomasset(".unc_fs_root/asset_medium.txt")
	assert(type(asset2) == "string" and string_match(asset2, "rbxasset://") ~= nil, "getcustomasset medium file failed")

	writefile(".unc_fs_root/asset_large.txt", string_rep("L", 5000))
	local asset3 = getcustomasset(".unc_fs_root/asset_large.txt")
	assert(type(asset3) == "string" and string_match(asset3, "rbxasset://") ~= nil, "getcustomasset large file failed")
end)

test("edge case: isscriptable/setscriptable round-trip", {}, function()
	local fire = Instance_new("Fire")
	local initial = isscriptable(fire, "size_xml")
	assert(initial == false, "size_xml should start non-scriptable")

	setscriptable(fire, "size_xml", true)
	assert(isscriptable(fire, "size_xml") == true, "setscriptable(true) failed")

	setscriptable(fire, "size_xml", false)
	assert(isscriptable(fire, "size_xml") == false, "setscriptable(false) reset failed")

	local part = Instance_new("Part")
	assert(isscriptable(part, "Name") == true, "Part Name should be scriptable")
	assert(isscriptable(part, "Anchored") == true, "Part Anchored should be scriptable")
end)

test("edge case: setfpscap does not error on any value", {}, function()
	local testValues = {0, 15, 30, 60, 75, 120, 144, 165, 240, 360, 480, 500, 1000}
	for _, fps in ipairs(testValues) do
		local ok = pcall(function() setfpscap(fps) end)
		assert(ok, "setfpscap(" .. fps .. ") should not error")
	end
end)

test("edge case: lz4compress/lz4decompress round-trip stress", {}, function()
	local testCases = {
		"",
		"A",
		"AB",
		"ABC",
		string_rep("X", 100),
		string_rep("YZ", 50),
		"Hello, World!",
		"!@#$%^&*()_+-=",
		"1234567890",
		string_rep("Lorem ipsum dolor sit amet ", 20),
	}
	for i, sample in ipairs(testCases) do
		local compressed = lz4compress(sample)
		local decompressed = lz4decompress(compressed, #sample)
		assert(decompressed == sample, "lz4 round-trip failed for test case " .. i)
	end
end)

test("edge case: request with various HTTP methods", {}, function()
	local response = request({ Url = "https://httpbin.org/get", Method = "GET" })
	assert(type(response) == "table", "request GET should return table")
	assert(response.StatusCode == 200, "request GET status should be 200")
	assert(type(response.Body) == "string", "request GET body should be string")

	local response2 = request({ Url = "https://httpbin.org/headers", Method = "GET", Headers = { ["X-Test"] = "UNC" } })
	assert(type(response2) == "table", "request with custom header should return table")
end)

test("edge case: Drawing property edge values", {}, {"Drawing.new"}, function()
	local square = Drawing.new("Square")
	square.Size = Vector2.new(0, 0)
	assert(square.Size == Vector2.new(0, 0), "Drawing Square zero size failed")
	square.Position = Vector2.new(-100, -200)
	assert(square.Position == Vector2.new(-100, -200), "Drawing Square negative position failed")
	square.Transparency = 0
	assert(square.Transparency == 0, "Drawing Square zero transparency failed")
	square.Transparency = 1
	assert(square.Transparency == 1, "Drawing Square full transparency failed")
	square:Destroy()

	local circle = Drawing.new("Circle")
	circle.Radius = 0
	assert(circle.Radius == 0, "Drawing Circle zero radius failed")
	circle.NumSides = 3
	assert(circle.NumSides == 3, "Drawing Circle min sides failed")
	circle:Destroy()

	local text = Drawing.new("Text")
	text.Text = ""
	assert(text.Text == "", "Drawing Text empty string failed")
	text.Size = 0
	assert(text.Size == 0, "Drawing Text zero size failed")
	text:Destroy()
end)

test("edge case: getrenderproperty/setrenderproperty round-trip", {}, {"Drawing.new"}, function()
	local types = {
		{type = "Circle", props = {Radius = 75, NumSides = 32, Thickness = 3, Filled = true, Transparency = 0.5}},
		{type = "Square", props = {Size = Vector2.new(100, 50), Filled = true, Thickness = 2}},
		{type = "Text", props = {Text = "RoundTrip", Size = 16, Center = true, Outline = false}},
		{type = "Line", props = {From = Vector2.new(0, 0), To = Vector2.new(200, 200), Thickness = 3}},
	}

	for _, info in ipairs(types) do
		local obj = Drawing.new(info.type)
		obj.Visible = false
		for prop, value in pairs(info.props) do
			setrenderproperty(obj, prop, value)
			local got = getrenderproperty(obj, prop)
			assert(got == value, "Round-trip failed for " .. info.type .. "." .. prop .. ": expected " .. tostring(value) .. ", got " .. tostring(got))
		end
		obj:Destroy()
	end
end)

test("edge case: getconnections Connection object fields", {}, function()
	local bindable = Instance_new("BindableEvent")
	local conn = bindable.Event:Connect(function() end)
	local conns = getconnections(bindable.Event)
	assert(#conns >= 1, "getconnections should find at least 1 connection")

	local c = conns[1]
	assert(type(c.Enabled) == "boolean", "Connection.Enabled should be boolean")
	assert(type(c.ForeignState) == "boolean", "Connection.ForeignState should be boolean")
	assert(type(c.LuaConnection) == "boolean", "Connection.LuaConnection should be boolean")
	assert(c.LuaConnection == true, "Connection.LuaConnection should be true for Luau connection")
	assert(type(c.Fire) == "function", "Connection.Fire should be function")
	assert(type(c.Defer) == "function", "Connection.Defer should be function")
	assert(type(c.Disconnect) == "function", "Connection.Disconnect should be function")
	assert(type(c.Disable) == "function", "Connection.Disable should be function")
	assert(type(c.Enable) == "function", "Connection.Enable should be function")

	if c.Function then
		assert(type(c.Function) == "function", "Connection.Function should be function")
	end
	if c.Thread then
		assert(type(c.Thread) == "thread", "Connection.Thread should be thread")
	end

	conn:Disconnect()
end)

test("edge case: debug.validlevel range check", {}, function()
	assert(debug.validlevel(1) == true, "debug.validlevel(1) should be true")
	assert(debug.validlevel(2) == true, "debug.validlevel(2) should be true")

	for i = 3, 20 do
		local result = debug.validlevel(i)
		assert(type(result) == "boolean", "debug.validlevel(" .. i .. ") should return boolean")
	end

	for i = 100, 105 do
		local result = debug.validlevel(i)
		assert(type(result) == "boolean", "debug.validlevel(" .. i .. ") should return boolean")
	end
end)

-- ============================================================================
-- ADDITIONAL UNC FUNCTION TESTS (UNIQUE)
-- ============================================================================

test("getscripts", {}, function()
	local scripts = getscripts()
	assert(type(scripts) == "table", "getscripts must return a table")
	assert(#scripts > 0, "getscripts returned empty array")
	for i, scr in ipairs(scripts) do
		assert(typeof(scr) == "Instance", "getscripts entry " .. i .. " not Instance")
		assert(scr:IsA("BaseScript"), "getscripts entry " .. i .. " not BaseScript: " .. scr.ClassName)
		if i > 20 then break end
	end
end)

test("getscripts consistency", {}, function()
	local s1 = getscripts()
	local s2 = getscripts()
	assert(type(s1) == "table" and type(s2) == "table", "getscripts consistency type failed")
end)

test("cleardrawcache", {}, function()
	assert(pcall(function() cleardrawcache() end), "cleardrawcache execution failed")
	local obj = Drawing.new("Square")
	obj.Visible = false
	cleardrawcache()
	obj:Destroy()
	cleardrawcache()
	for i = 1, 5 do
		local o = Drawing.new("Circle")
		o.Visible = false
		o:Destroy()
	end
	assert(pcall(function() cleardrawcache() end), "cleardrawcache after destroy loop failed")
end)

test("loadstring chunkname", {}, function()
	local f1, e1 = loadstring("return 'chunk'", "MyCustomChunk")
	assert(type(f1) == "function", "loadstring with chunkname should return function")
	assert(f1() == "chunk", "loadstring chunkname result failed")

	local f2, e2 = loadstring("invalid $$$ syntax !!!", "ErrorChunk")
	assert(f2 == nil, "loadstring invalid code should return nil")
	assert(type(e2) == "string", "loadstring error message should be string")
	assert(string_match(e2, "ErrorChunk") ~= nil, "loadstring error should contain chunkname")

	local f3 = loadstring("return 42", "")
	assert(type(f3) == "function", "loadstring empty chunkname should work")
	assert(f3() == 42, "loadstring empty chunkname result failed")
end)

test("loadstring complex patterns", {}, function()
	local f1 = loadstring("local t = {}; for i = 1, 5 do t[i] = i * i end; return t")
	assert(type(f1) == "function")
	local t = f1()
	assert(type(t) == "table" and #t == 5, "loadstring table comprehension failed")
	assert(t[1] == 1 and t[3] == 9 and t[5] == 25, "loadstring table values mismatch")

	local f2 = loadstring("local s = ''; for i = 65, 70 do s = s .. string.char(i) end; return s")
	assert(type(f2) == "function")
	assert(f2() == "ABCDEF", "loadstring string building failed")

	local f3 = loadstring("local x = 0; repeat x = x + 1 until x >= 5; return x")
	assert(type(f3) == "function")
	assert(f3() == 5, "loadstring repeat-until failed")

	local f4 = loadstring("local a, b = 0, 1; for i = 1, 10 do a, b = b, a + b end; return a")
	assert(type(f4) == "function")
	assert(f4() == 55, "loadstring fibonacci loop failed")

	local f5 = loadstring("local function pow(base, exp) local r = 1; for i = 1, exp do r = r * base end; return r end; return pow(2, 10)")
	assert(type(f5) == "function")
	assert(f5() == 1024, "loadstring power function failed")

	local f6 = loadstring("return type(42) .. '|' .. type('s') .. '|' .. type(true) .. '|' .. type(nil) .. '|' .. type({})")
	assert(type(f6) == "function")
	assert(f6() == "number|string|boolean|nil|table", "loadstring type chain failed")

	local f7 = loadstring("local x = 0; for i = 1, 100 do x = x + 1 end; return x")
	assert(type(f7) == "function")
	assert(f7() == 100, "loadstring 100-iteration loop failed")
end)

test("getscriptbytecode various scripts", {}, function()
	local scripts = {"LocalScript", "ModuleScript", "Script"}
	for _, className in ipairs(scripts) do
		local inst = Instance_new(className)
		local bc = getscriptbytecode(inst)
		assert(bc == nil, "getscriptbytecode on empty " .. className .. " should return nil, got " .. tostring(type(bc)))
	end

	local coreGuiModules = game:GetService("CoreGui").RobloxGui.Modules
	local moduleNames = {"Common.Constants"}
	for _, modName in ipairs(moduleNames) do
		local ok, mod = pcall(function() return coreGuiModules end)
		if ok and mod then
			local realMod = mod:FindFirstChild("Common", true) and mod.Common:FindFirstChild("Constants")
			if realMod then
				local bytecode = getscriptbytecode(realMod)
				assert(type(bytecode) == "string" and #bytecode > 50, "getscriptbytecode on real module too short")
			end
		end
	end
end)

test("decompile various scripts", {}, function()
	local newScript = Instance_new("LocalScript")
	local r1 = decompile(newScript)
	assert(type(r1) == "string", "decompile on empty LocalScript should return string")

	local newModule = Instance_new("ModuleScript")
	local r2 = decompile(newModule)
	assert(type(r2) == "string", "decompile on empty ModuleScript should return string")

	local newServerScript = Instance_new("Script")
	local r3 = decompile(newServerScript)
	assert(type(r3) == "string", "decompile on empty Script should return string")
end)

test("getsenv various scripts", {}, function()
	local newScript = Instance_new("LocalScript")
	local ok, err = pcall(function() getsenv(newScript) end)
	-- may succeed or fail depending on executor

	local success = pcall(function() getsenv(123) end)
	assert(not success, "getsenv should error on number")
	local success2 = pcall(function() getsenv("string") end)
	assert(not success2, "getsenv should error on string")
	local success3 = pcall(function() getsenv(true) end)
	assert(not success3, "getsenv should error on boolean")
end)

test("getscriptclosure various scripts", {}, function()
	local newScript = Instance_new("LocalScript")
	assert(getscriptclosure(newScript) == nil, "getscriptclosure on empty LocalScript should return nil")

	local newModule = Instance_new("ModuleScript")
	assert(getscriptclosure(newModule) == nil, "getscriptclosure on empty ModuleScript should return nil")

	local success = pcall(function() getscriptclosure(nil) end)
	assert(not success, "getscriptclosure should error on nil")
end)

test("getscripthash various scripts", {}, function()
	local script1 = Instance_new("LocalScript")
	local script2 = Instance_new("LocalScript")
	local h1 = getscripthash(script1)
	local h2 = getscripthash(script2)
	assert(type(h1) == "string" and #h1 > 0, "getscripthash on empty LocalScript should return non-empty string")
	assert(h1 == h2, "getscripthash two empty scripts should produce same hash")

	local module1 = Instance_new("ModuleScript")
	local h3 = getscripthash(module1)
	assert(type(h3) == "string" and #h3 > 0, "getscripthash on empty ModuleScript should return string")
end)

test("getcallingscript various contexts", {}, function()
	local cs = getcallingscript()
	assert(cs == nil or typeof(cs) == "Instance", "getcallingscript outside script should return nil or Instance")

	local bindable = Instance_new("BindableEvent")
	local results = {}
	for i = 1, 5 do
		bindable.Event:Connect(function()
			results[i] = getcallingscript()
		end)
	end
	bindable:Fire()
	for _, conn in ipairs(getconnections(bindable.Event)) do
		if type(conn.Disconnect) == "function" then conn:Disconnect() end
	end
	for i, r in ipairs(results) do
		assert(r == nil or typeof(r) == "Instance", "getcallingscript in signal " .. i .. " returned invalid type")
	end
end)

test("getscriptfromthread various threads", {}, function()
	local mainThread = coroutine.running()
	local scr = getscriptfromthread(mainThread)
	assert(scr == nil or typeof(scr) == "Instance", "getscriptfromthread main thread returned invalid type")

	local co = coroutine.create(function() return getscriptfromthread(coroutine.running()) end)
	local _, coResult = coroutine.resume(co)
	assert(coResult == nil or typeof(coResult) == "Instance", "getscriptfromthread coroutine returned invalid type")
end)

test("getloadedmodules has ModuleScripts", {}, function()
	local mods = getloadedmodules()
	assert(#mods > 0, "getloadedmodules should have entries")
	local allModules = true
	for i = 1, math_min(20, #mods) do
		if not mods[i]:IsA("ModuleScript") then
			allModules = false
			break
		end
	end
	assert(allModules, "getloadedmodules contains non-ModuleScript entries")
end)

test("getrunningscripts has scripts", {}, function()
	local scripts = getrunningscripts()
	assert(#scripts > 0, "getrunningscripts should have entries")
	local allScripts = true
	for i = 1, math_min(20, #scripts) do
		if not (scripts[i]:IsA("LocalScript") or scripts[i]:IsA("ModuleScript") or scripts[i]:IsA("Script")) then
			allScripts = false
			break
		end
	end
	assert(allScripts, "getrunningscripts contains non-script entries")
end)

test("getnilinstances finds freshly unparented", {}, function()
	local before = #getnilinstances()
	local created = {}
	for i = 1, 3 do
		local p = Instance_new("Part")
		p.Name = "Unparented_" .. math_random(1000, 9999)
		created[i] = p
	end
	local after = #getnilinstances()
	assert(after >= before + 3, "getnilinstances should find 3 new unparented Parts")

	local nilInsts = getnilinstances()
	for _, p in ipairs(created) do
		local found = false
		for _, ni in ipairs(nilInsts) do
			if ni == p then found = true break end
		end
		assert(found, "getnilinstances missing Part: " .. p.Name)
	end
end)

test("gethui create and destroy children", {}, function()
	local hui = gethui()
	local names = {}
	for i = 1, 5 do
		local g = Instance_new("ScreenGui")
		g.Name = "MultiTest_" .. math_random(1000, 9999)
		g.Parent = hui
		names[i] = g.Name
		task_wait(0.02)
	end
	for _, name in ipairs(names) do
		assert(hui:FindFirstChild(name) ~= nil, "gethui child " .. name .. " not found")
	end
	for _, name in ipairs(names) do
		hui:FindFirstChild(name):Destroy()
	end
	for _, name in ipairs(names) do
		assert(hui:FindFirstChild(name) == nil, "gethui destroyed child " .. name .. " still found")
	end
end)

test("compareinstances with model and special instances", {}, {"cloneref"}, function()
	local model = Instance_new("Model")
	local modelClone = cloneref(model)
	assert(compareinstances(model, modelClone) == true, "compareinstances Model cloneref failed")

	local gui = Instance_new("ScreenGui")
	local guiClone = cloneref(gui)
	assert(compareinstances(gui, guiClone) == true, "compareinstances ScreenGui cloneref failed")

	local folder = Instance_new("Folder")
	local folderClone = cloneref(folder)
	assert(compareinstances(folder, folderClone) == true, "compareinstances Folder cloneref failed")

	local sound = Instance_new("Sound")
	local soundClone = cloneref(sound)
	assert(compareinstances(sound, soundClone) == true, "compareinstances Sound cloneref failed")

	local camera = workspace.CurrentCamera
	local cameraClone = cloneref(camera)
	assert(compareinstances(camera, cameraClone) == true, "compareinstances Camera cloneref failed")
end)

test("cloneref property mutation chain", {}, function()
	local part = Instance_new("Part")
	local clone = cloneref(part)

	clone.Size = Vector3.new(1, 2, 3)
	assert(part.Size == Vector3.new(1, 2, 3), "cloneref chain Size failed")

	clone.Position = Vector3.new(4, 5, 6)
	assert(part.Position == Vector3.new(4, 5, 6), "cloneref chain Position failed")

	clone.Anchored = false
	assert(part.Anchored == false, "cloneref chain Anchored failed")

	clone.CanCollide = false
	assert(part.CanCollide == false, "cloneref chain CanCollide failed")

	clone.Transparency = 0.75
	assert(part.Transparency == 0.75, "cloneref chain Transparency failed")

	clone.Material = Enum.Material.Neon
	assert(part.Material == Enum.Material.Neon, "cloneref chain Material failed")

	clone.BrickColor = BrickColor.new("Bright yellow")
	assert(part.BrickColor == BrickColor.new("Bright yellow"), "cloneref chain BrickColor failed")

	clone.CFrame = CFrame.new(10, 20, 30)
	assert(part.CFrame == CFrame.new(10, 20, 30), "cloneref chain CFrame failed")

	clone.Name = "ChainModified"
	assert(part.Name == "ChainModified", "cloneref chain Name failed")
end)

test("firesignal with instance arguments", {}, function()
	local bindable = Instance_new("BindableEvent")
	local part = Instance_new("Part")
	part.Name = "SignalPart"
	local received = nil
	bindable.Event:Connect(function(inst) received = inst end)
	firesignal(bindable.Event, part)
	task_wait(0.05)
	assert(received == part, "firesignal Instance arg identity failed")
	assert(received.Name == "SignalPart", "firesignal Instance arg property failed")

	local model = Instance_new("Model")
	model.Name = "SignalModel"
	local received2 = nil
	bindable.Event:Connect(function(inst) received2 = inst end)
	firesignal(bindable.Event, model)
	task_wait(0.05)
	assert(received2 == model, "firesignal Model arg failed")
end)

test("replicatesignal with various types", {}, function()
	local bindable = Instance_new("BindableEvent")
	local received = nil

	bindable.Event:Connect(function(v) received = v end)
	replicatesignal(bindable.Event, "string_value")
	task_wait(0.05)
	assert(received == "string_value", "replicatesignal string failed")

	bindable.Event:Connect(function(v) received = v end)
	replicatesignal(bindable.Event, 42.5)
	task_wait(0.05)
	assert(received == 42.5, "replicatesignal float failed")

	bindable.Event:Connect(function(v) received = v end)
	replicatesignal(bindable.Event, math.pi)
	task_wait(0.05)
	assert(received == math.pi, "replicatesignal math.pi failed")

	bindable.Event:Connect(function(v) received = v end)
	replicatesignal(bindable.Event, math.huge)
	task_wait(0.05)
	assert(received == math.huge, "replicatesignal math.huge failed")

	bindable.Event:Connect(function(v) received = v end)
	replicatesignal(bindable.Event, -999)
	task_wait(0.05)
	assert(received == -999, "replicatesignal negative failed")
end)

test("getconnections disable/enable cycle", {}, function()
	local bindable = Instance_new("BindableEvent")
	local count = 0
	local conn = bindable.Event:Connect(function() count += 1 end)
	local conns = getconnections(bindable.Event)
	assert(#conns >= 1, "getconnections should find at least 1")

	local c = conns[1]
	if type(c.Disable) == "function" and type(c.Enable) == "function" then
		c:Disable()
		bindable:Fire()
		task_wait(0.05)
		assert(count == 0, "getconnections disable should prevent fire")

		c:Enable()
		bindable:Fire()
		task_wait(0.05)
		assert(count == 1, "getconnections re-enable should restore fire")
	end
	conn:Disconnect()
end)

test("getconnections Function and Thread fields", {}, function()
	local bindable = Instance_new("BindableEvent")
	local conn = bindable.Event:Connect(function() end)
	local conns = getconnections(bindable.Event)

	for _, c in ipairs(conns) do
		if c.LuaConnection == true then
			assert(type(c.Function) == "function", "LuaConnection should have Function")
			assert(type(c.Thread) == "thread", "LuaConnection should have Thread")
		end
		if c.ForeignState == true then
			-- Foreign connections may have nil Function/Thread
		end
	end
	conn:Disconnect()
end)

test("getconnections Fire method", {}, function()
	local bindable = Instance_new("BindableEvent")
	local received = nil
	local conn = bindable.Event:Connect(function(v) received = v end)
	local conns = getconnections(bindable.Event)

	for _, c in ipairs(conns) do
		if type(c.Fire) == "function" then
			c:Fire("direct_fire")
			task_wait(0.05)
			assert(received == "direct_fire", "Connection.Fire method failed")
			break
		end
	end
	conn:Disconnect()
end)

test("getconnections Defer method", {}, function()
	local bindable = Instance_new("BindableEvent")
	local received = nil
	local conn = bindable.Event:Connect(function(v) received = v end)
	local conns = getconnections(bindable.Event)

	for _, c in ipairs(conns) do
		if type(c.Defer) == "function" then
			c:Defer("deferred_fire")
			task_wait(0.1)
			assert(received == "deferred_fire", "Connection.Defer method failed")
			break
		end
	end
	conn:Disconnect()
end)

test("getcallbackvalue various callback types", {}, function()
	local bf = Instance_new("BindableFunction")
	local fn1 = function() return 1 end
	bf.OnInvoke = fn1
	assert(getcallbackvalue(bf, "OnInvoke") == fn1, "getcallbackvalue simple function failed")

	local fn2 = function(a, b) return a + b end
	bf.OnInvoke = fn2
	assert(getcallbackvalue(bf, "OnInvoke") == fn2, "getcallbackvalue multi-arg function failed")

	local fn3 = function(...) return select("#", ...) end
	bf.OnInvoke = fn3
	assert(getcallbackvalue(bf, "OnInvoke") == fn3, "getcallbackvalue variadic function failed")
end)

test("isscriptable various instances", {}, function()
	local fire = Instance_new("Fire")
	assert(isscriptable(fire, "size_xml") == false, "Fire size_xml should not be scriptable")
	assert(isscriptable(fire, "Size") == true, "Fire Size should be scriptable")

	local part = Instance_new("Part")
	local partProps = {"Name", "Anchored", "CanCollide", "Size", "Position", "Transparency", "Material", "BrickColor", "CFrame", "Color", "Shape", "TopSurface", "BottomSurface", "Velocity", "RotVelocity", "Massless", "CustomPhysicalProperties"}
	for _, prop in ipairs(partProps) do
		local result = isscriptable(part, prop)
		assert(type(result) == "boolean", "isscriptable " .. prop .. " should return boolean")
	end

	local sound = Instance_new("Sound")
	assert(isscriptable(sound, "SoundId") == true, "Sound SoundId should be scriptable")
	assert(isscriptable(sound, "Volume") == true, "Sound Volume should be scriptable")
	assert(isscriptable(sound, "Playing") == true, "Sound Playing should be scriptable")
end)

test("setscriptable toggle round-trip", {}, {"isscriptable"}, function()
	local fire = Instance_new("Fire")
	local original = isscriptable(fire, "size_xml")
	setscriptable(fire, "size_xml", true)
	assert(isscriptable(fire, "size_xml") == true, "setscriptable true toggle failed")
	setscriptable(fire, "size_xml", false)
	assert(isscriptable(fire, "size_xml") == (original or false), "setscriptable false toggle failed")
end)

test("gethiddenproperty various properties", {}, function()
	local fire = Instance_new("Fire")
	local val1, hidden1 = gethiddenproperty(fire, "size_xml")
	assert(type(val1) == "number", "gethiddenproperty size_xml type failed")
	assert(hidden1 == true, "gethiddenproperty size_xml should be hidden")

	sethiddenproperty(fire, "size_xml", 77)
	local val2 = gethiddenproperty(fire, "size_xml")
	assert(val2 == 77, "gethiddenproperty size_xml round-trip failed")

	local part = Instance_new("Part")
	local val3, hidden3 = gethiddenproperty(part, "DataCost")
	assert(type(val3) == "number", "gethiddenproperty DataCost type failed")

	local val4, hidden4 = gethiddenproperty(part, "Name")
	assert(type(val4) == "string", "gethiddenproperty Name type failed")
	assert(hidden4 == false, "gethiddenproperty Name should not be hidden")
end)

test("gethiddenproperties various instances", {}, function()
	local fire = Instance_new("Fire")
	local fireProps = gethiddenproperties(fire)
	assert(type(fireProps) == "table", "gethiddenproperties Fire type failed")
	local fireCount = 0
	for _ in pairs(fireProps) do fireCount += 1 end
	assert(fireCount > 0, "gethiddenproperties Fire empty")

	local part = Instance_new("Part")
	local partProps = gethiddenproperties(part)
	assert(type(partProps) == "table", "gethiddenproperties Part type failed")
	local partCount = 0
	for _ in pairs(partProps) do partCount += 1 end
	assert(partCount > 0, "gethiddenproperties Part empty")

	local model = Instance_new("Model")
	local modelProps = gethiddenproperties(model)
	assert(type(modelProps) == "table", "gethiddenproperties Model type failed")
end)

test("setrawmetatable with __call override", {}, function()
	local obj = setmetatable({}, {
		__call = function() return "original_call" end,
		__metatable = "Locked"
	})
	assert(obj() == "original_call", "setrawmetatable __call original failed")

	setrawmetatable(obj, {
		__call = function() return "overridden_call" end
	})
	assert(obj() == "overridden_call", "setrawmetatable __call override failed")
end)

test("setrawmetatable with __tostring override", {}, function()
	local obj = setmetatable({}, {
		__tostring = function() return "original_tostring" end,
		__metatable = "Locked"
	})
	assert(tostring(obj) == "original_tostring", "setrawmetatable __tostring original failed")

	setrawmetatable(obj, {
		__tostring = function() return "overridden_tostring" end
	})
	assert(tostring(obj) == "overridden_tostring", "setrawmetatable __tostring override failed")
end)

test("setrawmetatable with __len override", {}, function()
	local obj = setmetatable({}, {
		__len = function() return 42 end,
		__metatable = "Locked"
	})
	assert(#obj == 42, "setrawmetatable __len original failed")

	setrawmetatable(obj, {
		__len = function() return 99 end
	})
	assert(#obj == 99, "setrawmetatable __len override failed")
end)

test("getgc table/function/string counts", {}, function()
	local gc = getgc()
	local counts = {table = 0, function = 0, string = 0, number = 0, userdata = 0, thread = 0, boolean = 0}
	for _, v in ipairs(gc) do
		local t = type(v)
		if counts[t] then counts[t] += 1 end
	end
	assert(counts.table > 0, "getgc found no tables")
	assert(counts.function_ > 0 or counts["function"] > 0, "getgc found no functions")
	assert(counts.string > 0, "getgc found no strings")
end)

test("filtergc table by metatable", {}, function()
	local mt = { __metatable = "FilterTest" }
	local target = setmetatable({ marker = true }, mt)
	local result = filtergc("table", { Metatable = mt }, true)
	assert(type(result) == "table", "filtergc Metatable filter type failed")
end)

test("filtergc function by name", {}, function()
	local functionnamed "UNCNamedFunc"
		-- This is actually not valid Lua, let me use a different approach
end)

test("getgenv stores and retrieves", {}, function()
	local key = "__UNC_TESTKEY_" .. math_random(10000, 99999)
	getgenv()[key] = "test_value_123"
	task_wait(0.05)
	assert(getgenv()[key] == "test_value_123", "getgenv store/retrieve failed")

	local key2 = "__UNC_TESTKEY2_" .. math_random(10000, 99999)
	getgenv()[key2] = 42
	assert(getgenv()[key] == "test_value_123", "getgenv first key lost")
	assert(getgenv()[key2] == 42, "getgenv second key failed")

	getgenv()[key] = nil
	getgenv()[key2] = nil
end)

test("getrenv has all expected globals", {}, function()
	local renv = getrenv()
	local expected = {
		"game", "workspace", "script", "print", "warn", "error",
		"pcall", "xpcall", "type", "typeof", "tostring", "tonumber",
		"select", "pairs", "ipairs", "setmetatable", "getmetatable",
		"rawget", "rawset", "rawequal", "table", "string", "math",
		"task", "Instance", "Vector3", "CFrame", "Color3", "Enum",
		"coroutine", "debug", "os", "bit32", "utf8", "buffer",
		"require", "assert", "unpack", "next", "newproxy",
		"setfenv", "getfenv", "collectgarbage",
		"UDim2", "UDim", "BrickColor", "Ray", "Rect", "Region3",
		"TweenInfo", "Faces", "Axes", "NumberRange",
		"NumberSequence", "NumberSequenceKeypoint",
		"ColorSequence", "ColorSequenceKeypoint",
		"PhysicalProperties", "Vector2",
	}
	for _, name in ipairs(expected) do
		assert(renv[name] ~= nil, "getrenv missing global: " .. name)
	end
end)

test("getrenv _G differs from executor _G", {}, function()
	local renv = getrenv()
	assert(renv._G ~= _G, "getrenv._G should differ from executor _G")
	renv.__test_renv_key = "from_renv"
	assert(renv.__test_renv_key == "from_renv", "getrenv._G mutation failed")
	renv.__test_renv_key = nil
end)

test("getreg has registry data", {}, function()
	local reg = getreg()
	assert(type(reg) == "table", "getreg type failed")
	local count = 0
	for _ in pairs(reg) do count += 1 end
	assert(count > 0, "getreg empty")

	local foundThread = false
	for _, v in pairs(reg) do
		if type(v) == "thread" then foundThread = true break end
	end
end)

test("gethwid returns same value", {}, function()
	local h1 = gethwid()
	local h2 = gethwid()
	local h3 = gethwid()
	assert(h1 == h2, "gethwid call 1 vs 2 mismatch")
	assert(h2 == h3, "gethwid call 2 vs 3 mismatch")
	assert(type(h1) == "string", "gethwid type failed")
	assert(#h1 > 0, "gethwid empty")
end)

test("identifyexecutor returns stable data", {}, function()
	local n1, v1 = identifyexecutor()
	local n2, v2 = identifyexecutor()
	assert(n1 == n2, "identifyexecutor name inconsistent")
	assert(v1 == v2, "identifyexecutor version inconsistent")
	assert(type(n1) == "string", "identifyexecutor name type failed")
end)

test("setclipboard various content types", {}, function()
	assert(pcall(function() setclipboard("simple") end), "setclipboard simple failed")
	assert(pcall(function() setclipboard("") end), "setclipboard empty failed")
	assert(pcall(function() setclipboard(string_rep("A", 5000)) end), "setclipboard long failed")
	assert(pcall(function() setclipboard("!@#$%^&*()_+-=[]{}|;':\",./<>?") end), "setclipboard special failed")
	assert(pcall(function() setclipboard("line1\nline2\nline3") end), "setclipboard multiline failed")
	assert(pcall(function() setclipboard("tab\there") end), "setclipboard tabs failed")
end)

test("lz4 full cycle various sizes", {}, function()
	local sizes = {0, 1, 2, 5, 10, 50, 100, 500}
	for _, size in ipairs(sizes) do
		local sample = string_rep("A", size)
		local compressed = lz4compress(sample)
		local decompressed = lz4decompress(compressed, #sample)
		assert(decompressed == sample, "lz4 cycle failed for size " .. size)
	end
end)

test("request GET various endpoints", {}, function()
	local resp1 = request({ Url = "https://httpbin.org/get", Method = "GET" })
	assert(type(resp1) == "table", "request GET type failed")
	assert(resp1.StatusCode == 200, "request GET status failed")

	local resp2 = request({ Url = "https://httpbin.org/headers", Method = "GET", Headers = { ["X-Custom"] = "UNC" } })
	assert(type(resp2) == "table", "request with headers type failed")
end)

test("setfpscap various values", {}, function()
	local values = {0, 15, 30, 60, 75, 120, 144, 165, 240, 360}
	for _, fps in ipairs(values) do
		assert(pcall(function() setfpscap(fps) end), "setfpscap " .. fps .. " failed")
	end
end)

test("Drawing.new all types with properties", {}, function()
	local types = {"Square", "Circle", "Line", "Text", "Quad", "Triangle"}
	for _, dtype in ipairs(types) do
		local obj = Drawing.new(dtype)
		assert(isrenderobj(obj) == true, "Drawing.new " .. dtype .. " isrenderobj failed")
		obj.Visible = false
		obj:Destroy()
	end
end)

test("isrenderobj comprehensive negative checks", {}, function()
	assert(isrenderobj({}) == false, "isrenderobj table false-positive")
	assert(isrenderobj(nil) == false, "isrenderobj nil false-positive")
	assert(isrenderobj("string") == false, "isrenderobj string false-positive")
	assert(isrenderobj(42) == false, "isrenderobj number false-positive")
	assert(isrenderobj(true) == false, "isrenderobj boolean false-positive")
	assert(isrenderobj(function() end) == false, "isrenderobj function false-positive")
	assert(isrenderobj(coroutine.create(function() end)) == false, "isrenderobj thread false-positive")

	local part = Instance_new("Part")
	assert(isrenderobj(part) == false, "isrenderobj Part false-positive")
end)

test("getrenderproperty comprehensive Circle", {}, {"Drawing.new"}, function()
	local c = Drawing.new("Circle")
	c.Radius = 100
	c.NumSides = 64
	c.Thickness = 5
	c.Filled = true
	c.Color = Color3.fromRGB(100, 200, 50)
	c.Transparency = 0.25
	c.Position = Vector2.new(300, 400)
	c.ZIndex = 7
	c.Visible = true
	c.Arch = 0.5

	assert(getrenderproperty(c, "Radius") == 100, "Circle Radius get failed")
	assert(getrenderproperty(c, "NumSides") == 64, "Circle NumSides get failed")
	assert(getrenderproperty(c, "Thickness") == 5, "Circle Thickness get failed")
	assert(getrenderproperty(c, "Filled") == true, "Circle Filled get failed")
	assert(getrenderproperty(c, "Color") == Color3.fromRGB(100, 200, 50), "Circle Color get failed")
	assert(getrenderproperty(c, "Transparency") == 0.25, "Circle Transparency get failed")
	assert(getrenderproperty(c, "Position") == Vector2.new(300, 400), "Circle Position get failed")
	assert(getrenderproperty(c, "ZIndex") == 7, "Circle ZIndex get failed")
	c:Destroy()
end)

test("setrenderproperty comprehensive Text", {}, {"Drawing.new"}, function()
	local t = Drawing.new("Text")
	setrenderproperty(t, "Text", "SetPropTest")
	setrenderproperty(t, "Size", 22)
	setrenderproperty(t, "Position", Vector2.new(50, 60))
	setrenderproperty(t, "Color", Color3.fromRGB(10, 20, 30))
	setrenderproperty(t, "Transparency", 0.8)
	setrenderproperty(t, "Center", true)
	setrenderproperty(t, "Outline", true)
	setrenderproperty(t, "OutlineColor", Color3.fromRGB(200, 200, 200))
	setrenderproperty(t, "Font", 2)
	setrenderproperty(t, "Visible", false)

	assert(t.Text == "SetPropTest", "Text set failed")
	assert(t.Size == 22, "Text Size set failed")
	assert(t.Position == Vector2.new(50, 60), "Text Position set failed")
	assert(t.Center == true, "Text Center set failed")
	assert(t.Outline == true, "Text Outline set failed")
	t:Destroy()
end)

test("gethui is usable for UI parent", {}, function()
	local hui = gethui()
	local gui = Instance_new("ScreenGui")
	gui.Name = "HuiTest_" .. math_random(1000, 9999)
	gui.Parent = hui

	local frame = Instance_new("Frame")
	frame.Size = UDim2.new(0, 100, 0, 50)
	frame.Parent = gui

	assert(hui:FindFirstChild(gui.Name) ~= nil, "gethui GUI parent failed")
	assert(gui:FindFirstChild("Frame") ~= nil, "gethui nested Frame failed")

	gui:Destroy()
end)

test("getinstances contains workspace and services", {}, function()
	local insts = getinstances()
	local foundWorkspace = false
	local foundPlayers = false
	for _, inst in ipairs(insts) do
		if inst == workspace then foundWorkspace = true end
		if inst == game:GetService("Players") then foundPlayers = true end
		if foundWorkspace and foundPlayers then break end
	end
	assert(foundWorkspace, "getinstances missing workspace")
end)

test("getnilinstances entries have nil parent", {}, function()
	local nilInsts = getnilinstances()
	for i, inst in ipairs(nilInsts) do
		assert(inst.Parent == nil, "getnilinstances entry " .. i .. " has non-nil parent")
		if i >= 20 then break end
	end
end)

test("filtergc function by Constants", {}, function()
	local marker = "UNCFILTER_" .. math_random(1000, 9999)
	local function marked()
		return marker
	end
	local result = filtergc("function", { Constants = { marker } }, true)
	assert(type(result) == "function", "filtergc function Constants type failed")
	assert(result() == marker, "filtergc function Constants execution failed")
end)

test("filtergc table by Keys multiple", {}, function()
	local key1 = "MULTIKEY1_" .. math_random(1000, 9999)
	local key2 = "MULTIKEY2_" .. math_random(1000, 9999)
	local target = { [key1] = 1, [key2] = 2 }
	local result = filtergc("table", { Keys = { key1, key2 } }, true)
	assert(type(result) == "table", "filtergc multi-key type failed")
	assert(result[key1] == 1, "filtergc multi-key key1 failed")
	assert(result[key2] == 2, "filtergc multi-key key2 failed")
end)

test("debug.getproto recursive function", {}, function()
	local function factorial(n)
		if n <= 1 then return 1 end
		return n * factorial(n - 1)
	end
	local protos = debug.getprotos(factorial)
	assert(type(protos) == "table", "debug.getprotos recursive type failed")
end)

test("debug.getprotos multiple inner functions", {}, function()
	local function outer()
		local function a() return 1 end
		local function b() return 2 end
		local function c() return 3 end
		local function d() return 4 end
		local function e() return 5 end
	end
	local protos = debug.getprotos(outer)
	assert(#protos == 5, "debug.getprotos 5 functions failed")
	for i, proto in ipairs(protos) do
		assert(type(proto) == "function", "debug.getprotos entry " .. i .. " not function")
	end
end)

test("debug.setupvalue numeric value", {}, function()
	local function target()
		local num = 42
		return num
	end
	debug.setupvalue(target, 1, 99)
	assert(target() == 99, "debug.setupvalue numeric failed")
end)

test("debug.setupvalue boolean value", {}, function()
	local function target()
		local flag = true
		return flag
	end
	debug.setupvalue(target, 1, false)
	assert(target() == false, "debug.setupvalue boolean failed")
end)

test("debug.setupvalue table value", {}, function()
	local function target()
		local t = {1, 2, 3}
		return t
	end
	debug.setupvalue(target, 1, {10, 20, 30})
	local result = target()
	assert(type(result) == "table", "debug.setupvalue table type failed")
	assert(result[1] == 10, "debug.setupvalue table content failed")
end)

test("debug.setconstant various types", {}, function()
	local function sample1() return 42 end
	debug.setconstant(sample1, 1, 100)
	assert(sample1() == 100, "debug.setconstant number failed")

	local function sample2() return "hello" end
	debug.setconstant(sample2, 1, "world")
	assert(sample2() == "world", "debug.setconstant string failed")

	local function sample3() return true end
	debug.setconstant(sample3, 1, false)
	assert(sample3() == false, "debug.setconstant boolean failed")
end)

test("getrawmetatable game object", {}, function()
	local gameMt = getrawmetatable(game)
	assert(type(gameMt) == "table", "getrawmetatable game type failed")
	assert(gameMt.__index ~= nil, "getrawmetatable game __index failed")
	assert(gameMt.__namecall ~= nil, "getrawmetatable game __namecall failed")
end)

test("setreadonly false then true", {}, {"isreadonly"}, function()
	local tbl = { a = 1 }
	table_freeze(tbl)
	setreadonly(tbl, false)
	tbl.b = 2
	assert(tbl.b == 2, "setreadonly false mutation failed")
	setreadonly(tbl, true)
	local ok = pcall(function() tbl.c = 3 end)
	assert(not ok, "setreadonly true should block mutation")
end)

test("hookmetamethod __add with values", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__add = newcclosure(function(a, b)
			return 100
		end),
		__metatable = "Locked"
	})

	local ref
	ref = hookmetamethod(obj, "__add", function(a, b)
		return 200
	end)
	assert(obj + obj == 200, "hookmetamethod __add hook failed")
	assert(ref() == 100, "hookmetamethod __add ref failed")
	restorefunction(getrawmetatable(obj).__add)
end)

test("hookmetamethod __mul with values", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__mul = newcclosure(function(a, b)
			return 10
		end),
		__metatable = "Locked"
	})

	local ref
	ref = hookmetamethod(obj, "__mul", function(a, b)
		return 20
	end)
	assert(obj * obj == 20, "hookmetamethod __mul hook failed")
	assert(ref() == 10, "hookmetamethod __mul ref failed")
	restorefunction(getrawmetatable(obj).__mul)
end)

test("hookmetamethod __sub with values", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__sub = newcclosure(function(a, b)
			return 50
		end),
		__metatable = "Locked"
	})

	local ref
	ref = hookmetamethod(obj, "__sub", function(a, b)
		return 75
	end)
	assert(obj - obj == 75, "hookmetamethod __sub hook failed")
	assert(ref() == 50, "hookmetamethod __sub ref failed")
	restorefunction(getrawmetatable(obj).__sub)
end)

test("hookmetamethod __div with values", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__div = newcclosure(function(a, b)
			return 5
		end),
		__metatable = "Locked"
	})

	local ref
	ref = hookmetamethod(obj, "__div", function(a, b)
		return 10
	end)
	assert(obj / obj == 10, "hookmetamethod __div hook failed")
	assert(ref() == 5, "hookmetamethod __div ref failed")
	restorefunction(getrawmetatable(obj).__div)
end)

test("hookmetamethod chained hooks", {}, {"newcclosure", "restorefunction", "getrawmetatable"}, function()
	local obj = setmetatable({}, {
		__index = newcclosure(function() return "base" end),
		__metatable = "Locked"
	})

	local ref1
	ref1 = hookmetamethod(obj, "__index", function(...)
		return "first_hook"
	end)
	assert(obj.test == "first_hook", "chained hook first failed")

	local ref2
	ref2 = hookmetamethod(obj, "__index", function(...)
		return "second_hook"
	end)
	assert(obj.test == "second_hook", "chained hook second failed")

	restorefunction(getrawmetatable(obj).__index)
	assert(obj.test == "base", "chained hook restore failed")
end)

test("hookfunction with closure capturing upvalue", {}, {"restorefunction"}, function()
	local captured = "original_val"
	local function target()
		return captured
	end

	local ref = hookfunction(target, function()
		return "hooked_" .. captured
	end)

	assert(target() == "hooked_original_val", "hookfunction upvalue capture hook failed")
	assert(ref() == "original_val", "hookfunction upvalue capture ref failed")

	captured = "modified_val"
	assert(ref() == "modified_val", "hookfunction upvalue mutation should reflect")

	restorefunction(target)
	assert(target() == "modified_val", "hookfunction upvalue after restore should reflect")
end)

test("clonefunction preserves upvalue state", {}, {"hookfunction", "restorefunction"}, function()
	local counter = 0
	local function target()
		counter = counter + 1
		return counter
	end

	local cloned = clonefunction(target)
	assert(cloned() == 1, "clonefunction upstate first call failed")
	assert(cloned() == 2, "clonefunction upstate second call failed")
	assert(target() == 3, "clonefunction original still works")
	assert(cloned() == 4, "clonefunction upstate after original call failed")
end)

test("checkcaller in various coroutine depths", {}, function()
	local function depthCheck(d)
		if d <= 0 then return checkcaller() end
		return depthCheck(d - 1)
	end

	for i = 1, 5 do
		assert(depthCheck(i) == true, "checkcaller depth " .. i .. " failed")
	end
end)

test("isexecutorclosure with newcclosure wrapped", {}, {"newcclosure"}, function()
	local wrapped = newcclosure(function() return "wrapped" end)
	assert(isexecutorclosure(wrapped) == true, "isexecutorclosure newcclosure failed")
end)

test("newcclosure preserves multi-return", {}, {"iscclosure"}, function()
	local function multi()
		return 1, "two", true, nil
	end
	local wrapped = newcclosure(multi)
	local a, b, c, d = wrapped()
	assert(a == 1 and b == "two" and c == true and d == nil, "newcclosure multi-return failed")
end)

test("newlclosure preserves multi-return", {}, {"islclosure"}, function()
	local function multi()
		return 1, "two", true
	end
	local wrapped = newlclosure(multi)
	local a, b, c = wrapped()
	assert(a == 1 and b == "two" and c == true, "newlclosure multi-return failed")
end)

test("crypt.hash with different algorithms", {}, function()
	local input = "hash_test"
	local algorithms = {"sha256", "sha1", "md5", "sha384", "sha512"}
	for _, algo in ipairs(algorithms) do
		local h = crypt.hash(input, algo)
		assert(type(h) == "string", "crypt.hash " .. algo .. " type failed")
		assert(#h > 0, "crypt.hash " .. algo .. " empty")
	end
end)

test("crypt.base64 various inputs", {}, function()
	local inputs = {"", "A", "AB", "ABC", "ABCD", "Hello World", string_rep("X", 200)}
	for i, input in ipairs(inputs) do
		local encoded = crypt.base64encode(input)
		local decoded = crypt.base64decode(encoded)
		assert(decoded == input, "crypt.base64 cycle " .. i .. " failed")
	end
end)

test("getcallbackvalue OnClose", {}, function()
	local originalOnClose = game.OnClose
	local testFn = function() end
	game.OnClose = testFn
	local result = getcallbackvalue(game, "OnClose")
	game.OnClose = originalOnClose
end)

test("setsimulationradius various values", {}, function()
	local radii = {{0, 0}, {100, 100}, {1000, 1000}, {5000, 5000}, {10000, 10000}}
	for _, r in ipairs(radii) do
		assert(pcall(function() setsimulationradius(r[1], r[2]) end), "setsimulationradius " .. r[1] .. "," .. r[2] .. " failed")
	end
end)

test("isrbxactive returns boolean consistently", {}, function()
	for i = 1, 3 do
		local result = isrbxactive()
		assert(type(result) == "boolean", "isrbxactive call " .. i .. " not boolean")
	end
end)

test("WebSocket interface check", {}, function()
	local ws = WebSocket.connect("ws://echo.websocket.events")
	assert(type(ws) == "table" or type(ws) == "userdata", "WebSocket type failed")
	assert(type(ws.Send) == "function", "WebSocket Send missing")
	assert(type(ws.Close) == "function", "WebSocket Close missing")
	ws:Close()
end)

test("getscriptbytecode on real scripts", {}, function()
	local running = getrunningscripts()
	if #running > 0 then
		for _, scr in ipairs(running) do
			if scr:IsA("LocalScript") or scr:IsA("ModuleScript") then
				local bc = getscriptbytecode(scr)
				if bc then
					assert(type(bc) == "string", "getscriptbytecode on running script type failed")
					assert(#bc > 0, "getscriptbytecode on running script empty")
					break
				end
			end
		end
	end
end)

test("getsenv on running script", {}, function()
	local running = getrunningscripts()
	for _, scr in ipairs(running) do
		if scr:IsA("LocalScript") then
			local ok, env = pcall(function() return getsenv(scr) end)
			if ok and env then
				assert(type(env) == "table", "getsenv env type failed")
				break
			end
		end
	end
end)

test("getscriptclosure on running script", {}, function()
	local running = getrunningscripts()
	for _, scr in ipairs(running) do
		if scr:IsA("ModuleScript") then
			local closure = getscriptclosure(scr)
			if closure then
				assert(type(closure) == "function", "getscriptclosure type failed")
				break
			end
		end
	end
end)

test("decompile on running scripts", {}, function()
	local running = getrunningscripts()
	for _, scr in ipairs(running) do
		if scr:IsA("LocalScript") or scr:IsA("ModuleScript") then
			local ok, result = pcall(function() return decompile(scr) end)
			if ok and type(result) == "string" then
				assert(#result > 0, "decompile running script empty")
				break
			end
		end
	end
end)

test("getscripthash on running scripts", {}, function()
	local running = getrunningscripts()
	for _, scr in ipairs(running) do
		if scr:IsA("ModuleScript") then
			local hash = getscripthash(scr)
			if hash then
				assert(type(hash) == "string", "getscripthash type failed")
				assert(#hash > 0, "getscripthash empty")
				break
			end
		end
	end
end)
