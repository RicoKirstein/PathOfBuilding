-- Path of Building
--
-- Module: MCP Bridge Script
-- Runs inside the bridge subscript (see Modules/McpServer.lua). This file is read
-- as text and passed to LaunchSubScript; it is not LoadModule'd.
--
-- The subscript owns nothing but a listening socket. Every request it reads is
-- handed to the main thread through the blocking PoBMcpRPC round trip, which the
-- host answers from the frame pump, and the answer is written straight back to
-- the client. Keeping all build access on the main thread is what makes it safe
-- to mutate the build the user has open while they are looking at it.
--
local port = ...

local socket = require("socket")

-- Requests and responses are newline-delimited JSON. JSON encoders escape literal
-- newlines, so a message is always exactly one line no matter what item text or
-- build notes it carries.
local LINE_TERMINATOR = "\n"
-- Long enough that an idle connection costs almost nothing, short enough that
-- disabling the server in Options takes effect immediately
local POLL_INTERVAL = 0.25

local listener = socket.tcp4()
if not listener then
	PoBMcpRPC("fatal", "could not create a socket")
	return "failed"
end
-- Without this a restart within the TIME_WAIT window fails to rebind the port
listener:setoption("reuseaddr", true)

-- Loopback only, deliberately: this is an unauthenticated channel with full
-- control over the open build, and it has no business being reachable off-box
local bound, bindErr = listener:bind("127.0.0.1", port)
if not bound then
	listener:close()
	PoBMcpRPC("fatal", string.format("could not bind 127.0.0.1:%d (%s)", port, tostring(bindErr)))
	return "failed"
end
local listening, listenErr = listener:listen(4)
if not listening then
	listener:close()
	PoBMcpRPC("fatal", string.format("could not listen on 127.0.0.1:%d (%s)", port, tostring(listenErr)))
	return "failed"
end
listener:settimeout(POLL_INTERVAL)
PoBMcpRPC("listening", tostring(port))

-- luasocket sends what it can and reports how far it got; large responses (a full
-- output dump runs to tens of kilobytes) routinely need more than one call
local function sendAll(client, text)
	local total = #text
	local sent = 0
	while sent < total do
		local lastSent, err, partialSent = client:send(text, sent + 1)
		if lastSent then
			sent = lastSent
		elseif err == "timeout" then
			sent = partialSent or sent
		else
			return false, err
		end
	end
	return true
end

local function serveClient(client)
	client:settimeout(POLL_INTERVAL)
	-- A line can arrive split across several timed-out reads; luasocket hands back
	-- what it consumed so far as the third return value
	local pending = ""
	while true do
		local line, err, partial = client:receive("*l")
		if line then
			local request = pending .. line
			pending = ""
			local control, response = PoBMcpRPC("request", request)
			if response then
				local ok, sendErr = sendAll(client, response .. LINE_TERMINATOR)
				if not ok then
					ConPrintf("MCP bridge: failed to send response (%s)", tostring(sendErr))
					return "closed"
				end
			end
			if control == "quit" then
				return "quit"
			end
		elseif err == "timeout" then
			pending = pending .. (partial or "")
			if PoBMcpRPC("poll") == "quit" then
				return "quit"
			end
		else
			-- "closed" and everything else: the client is gone
			return "closed"
		end
	end
end

while true do
	local client = listener:accept()
	if client then
		PoBMcpRPC("connected")
		local outcome = serveClient(client)
		client:close()
		PoBMcpRPC("disconnected")
		if outcome == "quit" then
			break
		end
	elseif PoBMcpRPC("poll") == "quit" then
		break
	end
end

listener:close()
return "quit"
