-- Path of Building
--
-- Module: MCP Server
-- Exposes the build that is currently open to an external Model Context Protocol
-- client (see ../../pob-mcp for the client half). A subscript owns a loopback
-- socket and does nothing but relay newline-delimited JSON; every request is
-- executed here, on the main thread, against the live build objects.
--
-- Running the commands on the main thread rather than in the subscript is the
-- whole point of the arrangement: edits land in the build the user is looking at,
-- the UI redraws them on the next frame, and Ctrl+Z reverts them, because they go
-- through exactly the same code paths as a click.
--
-- The module can get loaded more than once; every user must share one server, or
-- two of them would fight over the port and the global RPC entry point
if mainMcpServer then
	return mainMcpServer
end

local dkjson = require("dkjson")

local mcpCommands = LoadModule("Modules/McpCommands")
-- The trade commands live in their own module because they need a frame pump,
-- which McpCommands deliberately has no notion of. They are registered onto the
-- command table this server dispatches against, and pumped from OnFrame.
local mcpTrade = LoadModule("Modules/McpTrade").Register(mcpCommands)

local server = {
	started = false,
	subId = nil,
	port = nil,
	listening = false,
	clientConnected = false,
	requestCount = 0,
	errorCount = 0,
	lastError = nil,
	stopRequested = false,
}

local DEFAULT_PORT = 49080

function server:DesiredPort()
	local port = tonumber(main and main.mcpServerPort) or DEFAULT_PORT
	if port < 1024 or port > 65535 then
		return DEFAULT_PORT
	end
	return math.floor(port)
end

function server:IsEnabled()
	return (main and main.mcpServerEnabled) and true or false
end

local function log(fmt, ...)
	ConPrintf("MCP server: " .. fmt, ...)
end

function server:Start()
	if self.started or self.unavailable then
		return
	end
	local scriptFile = io.open(GetScriptPath() .. "/Modules/McpBridgeScript.lua", "r")
	if not scriptFile then
		log("cannot read the bridge script; server not started")
		return
	end
	local script = scriptFile:read("*a")
	scriptFile:close()
	self.started = true
	self.stopRequested = false
	self.listening = false
	self.port = self:DesiredPort()
	self.launchedPort = self.port
	local subId = LaunchSubScript(script, "PoBMcpRPC", "ConPrintf", self.port)
	if not subId then
		-- A stubbed LaunchSubScript (headless, tests) can never run the bridge;
		-- give up permanently rather than retrying it on every frame
		self.started = false
		self.unavailable = true
		log("subscripts are unavailable in this environment; server not started")
		return
	end
	self.subId = subId
	launch:RegisterSubScript(subId, function()
		self:BridgeStopped()
	end)
end

-- Asks the bridge to shut down. It notices on its next poll, at most a quarter of
-- a second later; there is no way to interrupt a blocked socket call from here.
function server:Stop()
	if not self.started then
		return
	end
	self.stopRequested = true
end

function server:BridgeStopped()
	self.started = false
	self.subId = nil
	self.listening = false
	self.clientConnected = false
	self.stopRequested = false
end

-- Called every frame from Main
function server:OnFrame()
	local enabled = self:IsEnabled()
	if enabled and not self.started then
		-- LaunchSubScript reads its arguments from the main thread's Lua state, so
		-- it must not be called from inside a coroutine; OnFrame always is one
		self:Start()
	elseif self.started and (not enabled or self:DesiredPort() ~= self.launchedPort) then
		self:Stop()
	end
	if self.started and self.subId and not IsSubScriptRunning(self.subId) then
		self:BridgeStopped()
	end
	-- Trade jobs are asynchronous by nature — mod weighting is a coroutine and the
	-- HTTP requests are spaced out by the rate limiter — so they make progress
	-- here rather than inside the request that started them. Pumped regardless of
	-- whether the bridge is up, so a job survives a client reconnect.
	local ok, err = pcall(mcpTrade.Pump)
	if not ok then
		self.lastError = tostring(err)
		log("trade pump: %s", tostring(err))
	end
end

function server:Status()
	return {
		enabled = self:IsEnabled(),
		running = self.started and true or false,
		listening = self.listening,
		port = self.port,
		clientConnected = self.clientConnected,
		requestCount = self.requestCount,
		errorCount = self.errorCount,
		lastError = self.lastError,
	}
end

-- Introspection over the wire, so a client can discover what this build of the
-- program supports without a version handshake
mcpCommands.commands["server.status"] = function(params)
	return server:Status()
end

-- Restarts the Lua state, which is the only way a change to a source file takes
-- effect: LoadModule re-executes files but nothing re-reads them once loaded.
-- Same thing F5 does. The flag is read on the next frame, so this request still
-- gets its answer out before the process tears down; the client's connection dies
-- with the bridge and is expected to reconnect.
mcpCommands.commands["server.reload"] = function(params)
	if not launch.devMode then
		error("reloading is only available in developer mode, which this copy of Path of Building is not running in; restart it by hand to pick up source changes", 0)
	end
	local build = main and main.mode == "BUILD" and main.modes.BUILD
	if build and build.unsaved and not params.discardUnsaved then
		error("the open build has unsaved changes that a reload would discard; save it first, or pass discardUnsaved=true", 0)
	end
	launch.doRestart = "Restarting (requested over the MCP bridge)..."
	return {
		restarting = true,
		note = "Path of Building is reloading its scripts. The bridge goes down with it and comes back a moment later; reconnect and retry.",
	}
end

----------------------
-- Request handling --
----------------------

local function encodeResponse(response)
	local ok, encoded = pcall(dkjson.encode, response)
	if ok and encoded then
		return encoded
	end
	-- A result that cannot be serialized is a bug in a handler, but it must not
	-- take down the connection: answer with something the client can parse
	return dkjson.encode({
		id = response.id,
		ok = false,
		error = "the result of this command could not be encoded as JSON: " .. tostring(encoded),
	})
end

function server:HandleRequest(requestJson)
	local request, _, decodeErr = dkjson.decode(requestJson)
	if type(request) ~= "table" then
		self.errorCount = self.errorCount + 1
		return encodeResponse({ ok = false, error = "malformed request: " .. tostring(decodeErr) })
	end
	self.requestCount = self.requestCount + 1
	local handler = mcpCommands.commands[request.cmd]
	if not handler then
		self.errorCount = self.errorCount + 1
		return encodeResponse({
			id = request.id,
			ok = false,
			error = "unknown command '" .. tostring(request.cmd) .. "'; send {\"cmd\":\"help\"} for the list",
		})
	end
	-- Nothing a client sends may crash the program the user has their build open
	-- in, so every handler runs under pcall and errors come back as data
	local ok, result = pcall(handler, request.params or { })
	if not ok then
		self.errorCount = self.errorCount + 1
		self.lastError = tostring(result)
		return encodeResponse({ id = request.id, ok = false, error = tostring(result) })
	end
	return encodeResponse({ id = request.id, ok = true, result = result })
end

-- The bridge subscript's only entry point into the main thread.
-- Returns (control, payload); control is "quit" when the bridge should shut down.
function PoBMcpRPC(kind, payload)
	local control = server.stopRequested and "quit" or "ok"
	if kind == "request" then
		local ok, response = pcall(server.HandleRequest, server, payload)
		if not ok then
			-- HandleRequest is already defensive; this is the last resort
			response = dkjson.encode({ ok = false, error = "internal bridge error: " .. tostring(response) })
		end
		return control, response
	elseif kind == "listening" then
		server.listening = true
		log("listening on 127.0.0.1:%s", tostring(payload))
	elseif kind == "connected" then
		server.clientConnected = true
	elseif kind == "disconnected" then
		server.clientConnected = false
	elseif kind == "fatal" then
		server.lastError = tostring(payload)
		server.listening = false
		log("%s", tostring(payload))
	end
	return control
end

mainMcpServer = server
return server
