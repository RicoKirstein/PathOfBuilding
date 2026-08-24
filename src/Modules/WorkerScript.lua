-- Path of Building
--
-- Module: Worker Script
-- Program run inside calculation worker subscripts (see Modules/WorkerPool.lua).
-- This file is read as text and passed to LaunchSubScript; it is not LoadModule'd.
-- The worker builds a full headless copy of the program, then loops requesting
-- work from the main thread; the PoBWorkerPoolRPC call blocks (cheaply, inside
-- the host) until the main thread's frame pump answers it.
--
local workerId, srcPath = ...

-- Prevents the worker's own Launch.lua from behaving like the main application
POB_IS_WORKER = true
-- Main.lua reads the interpreter's command-line args table, which subscript
-- states do not have
arg = { }

-- The process working directory belongs to the main script (it points at the user
-- folder after startup), so anchor all relative paths to the src directory
local rawLoadfile = loadfile
local function resolve(name)
	if name:match("^%a:[/\\]") or name:match("^[/\\]") then
		return name
	end
	return srcPath .. "/" .. name
end
function loadfile(name)
	return rawLoadfile(resolve(name))
end
local rawDofile = dofile
function dofile(name)
	return rawDofile(resolve(name))
end
-- Data files are also read with relative io.open (e.g. Data/ModFoulbornMap.jsonc)
local rawOpen = io.open
function io.open(name, mode)
	return rawOpen(resolve(name), mode)
end
-- The calc modules load each other with require since the class rework, and
-- require searches package.path: the host gives the main state a path that
-- includes the script directory, but a subscript state does not get one, so
-- without this the environment load dies at require("Modules.CalcBase")
package.path = srcPath .. "/?.lua;" .. package.path

-- HeadlessWrapper replaces the whole host API with stubs, including file
-- functions a subscript genuinely has. Keep the real ones and put them back
-- afterwards, or anything loaded by path fails in here while working fine on the
-- main thread.
local hostFuncs = { }
for _, name in ipairs({ "NewFileSearch", "Inflate", "Deflate", "GetTime", "MakeDir", "GetRuntimePath" }) do
	hostFuncs[name] = _G[name]
end

local ok, err = pcall(dofile, "HeadlessWrapper.lua")
if not ok then
	PoBWorkerPoolRPC(workerId, "fatal", 0, nil, "environment load failed: " .. tostring(err))
	return "failed"
end
if not loadBuildFromXML then
	PoBWorkerPoolRPC(workerId, "fatal", 0, nil, "environment incomplete: " .. tostring(mainObject and mainObject.promptMsg))
	return "failed"
end
for name, hostFunc in pairs(hostFuncs) do
	_G[name] = hostFunc
end
-- The headless stub returns "", which breaks TimelessJewelData loading
function GetScriptPath()
	return srcPath
end

-- Timeless Jewel LUTs are found with NewFileSearch and decompressed with
-- Inflate. If the host gave the subscript neither, the stubs (nil handle, empty
-- string) make the LUT unloadable, PassiveSpec:BuildAllDependsAndPaths throws,
-- and every job in this worker then dies on a nil misc calculator -- silently,
-- since a failed job just leaves its candidate on the caller's baseline value.
-- The main thread has the real functions and writes the decompressed .bin next
-- to the .zip, so point the search at that cache. Only the modified time is
-- faked: a .bin that is missing or truncated still falls through to the (dead)
-- decompress path rather than yielding wrong data.
if not hostFuncs.NewFileSearch then
	local searchHandle = { }
	searchHandle.__index = searchHandle
	function searchHandle:GetFileName() return self.name end
	function searchHandle:GetFileModifiedTime() return self.modified end
	function searchHandle:GetFileSize() return self.size end
	function searchHandle:NextFile() return false end
	function NewFileSearch(pattern)
		-- Only exact paths are answerable without a real directory search
		if pattern:match("[*?]") then
			return nil
		end
		local file = io.open(pattern, "rb")
		if not file then
			return nil
		end
		local size = file:seek("end")
		file:close()
		return setmetatable({
			name = pattern:match("([^/\\]*)$"),
			size = size,
			-- Rank an existing .bin above the .zip it was decompressed from
			modified = pattern:match("%.bin$") and 1 or 0,
		}, searchHandle)
	end
end

local dkjson = require("dkjson")

-- Job handlers and patch application live in a shared module so the test suite
-- can verify them against the interactive calculations they mirror
local workerJobs = LoadModule("Modules/WorkerJobs")
local jobHandlers = workerJobs.handlers

local revision = -1
local lastJobId, lastResultJson
while true do
	local cmd, a, b, c = PoBWorkerPoolRPC(workerId, "ready", revision, lastJobId, lastResultJson)
	lastJobId, lastResultJson = nil, nil
	if cmd == nil or cmd == "quit" then
		return "quit"
	elseif cmd == "sync" then
		local okLoad, errLoad = pcall(loadBuildFromXML, b, "worker")
		if okLoad then
			revision = a
		else
			PoBWorkerPoolRPC(workerId, "fatal", revision, nil, "build sync failed: " .. tostring(errLoad))
			return "failed"
		end
	elseif cmd == "patch" then
		-- Incremental sync: re-load only the changed build sections into the live
		-- build. Far cheaper than a full build reload; any failure falls back to
		-- one. The patch document arrives in the same argument slot as the full
		-- build XML of a "sync" command.
		local okPatch, errPatch = pcall(workerJobs.ApplyPatch, b)
		if okPatch then
			revision = a
		else
			-- Response intentionally ignored; the next "ready" round trip will be
			-- answered with a full sync
			PoBWorkerPoolRPC(workerId, "patchfail", revision, nil, tostring(errPatch))
		end
	elseif cmd == "job" then
		local okJob, result = pcall(function()
			local payload = dkjson.decode(c)
			local handler = jobHandlers[b]
			return handler and handler(payload) or { workerError = "unknown job kind: " .. tostring(b) }
		end)
		lastJobId = a
		lastResultJson = dkjson.encode(okJob and result or { workerError = tostring(result) })
		-- Keep the state's share of the process memory arena bounded, but a full
		-- collection is far too slow to run per shard
		if collectgarbage("count") > 300000 then
			collectgarbage("collect")
		end
	end
	-- cmd == "wait": loop immediately; the next call blocks until the main thread
	-- has something new for this worker
end
