-- One bounded consumer per dedicated bot. Each listener generation owns its
-- files, so a stopped profile can never feed a replacement listener.
local tern = require("tern")
local lark = require("../services/lark")
local proc = require("../services/proc")

local bot = {}
local DIR = "bot-events"
local EVENT = "im.message.receive_v1"
local RUN_MINUTES = 30
local RETRY_MS = 60000
local MAX_EVENT_BYTES = 1024 * 1024
local MAX_DIAGNOSTIC_BYTES = 1024 * 1024
local READY = "[event] ready event_key=" .. EVENT
local OPTIONAL_TEXT = { "content", "reply_to", "root_id", "thread_id", "event_id", "timestamp", "create_time", "update_time", "id" }
local MENTION_TEXT = { "id", "key", "name" }

export type Listener = {
	profile: string, open_id: string?, name: string?, token: string?, retry: any, stopped: boolean,
	dir: string?, run: number, diagnostics: string?, diagnostic_offset: number,
	ready: boolean, exit_reason: string?, integrity: string?, run_error: string?, file_error: string?,
	report: (string?) -> (), reported: boolean, notice: string?, delivered: { [string]: boolean },
}
local active: Listener? = nil

local function publish(listener: Listener)
	if active ~= listener or listener.stopped then return end
	local pending = if not listener.open_id then "正在确认机器人身份…"
		elseif not listener.ready then "机器人监听启动中（等待 CLI 就绪标记）…" else nil
	local notice = listener.file_error or listener.run_error or listener.integrity or pending
	if not listener.reported or listener.notice ~= notice then
		listener.reported, listener.notice = true, notice
		listener.report(notice)
	end
end

local function stop(listener: Listener)
	listener.stopped = true
	listener.open_id, listener.name = nil, nil
	if listener.retry then listener.retry:cancel(); listener.retry = nil end
	if listener.token then proc.stop(listener.token) end
end

local function directory(): string
	tern.fs.mkdir(tern.plugin.data .. "/" .. DIR)
	local sequence = tern.kv.get("bot-listener-sequence")
	if type(sequence) ~= "number" or sequence < 0 or sequence >= 2 ^ 53 or sequence % 1 ~= 0 then sequence = 0 end
	local dir
	repeat
		sequence += 1
		dir = DIR .. "/listener-" .. tostring(sequence)
	until not tern.fs.exists(tern.plugin.data .. "/" .. dir)
	tern.kv.set("bot-listener-sequence", sequence)
	tern.fs.mkdir(tern.plugin.data .. "/" .. dir)
	return dir
end

-- Tern buffers subprocess stderr until exit. Redirecting it to a per-run file
-- preserves CLI ready/drop signals for the regular drain poll, without a pipe
-- or a second background process. Only complete lines are consumed while live.
local function diagnostics(listener: Listener, finished: boolean?): string?
	if not listener.diagnostics then return nil end
	local ok, body = pcall(tern.fs.read, listener.diagnostics, MAX_DIAGNOSTIC_BYTES + 1)
	if not ok or type(body) ~= "string" then return nil end
	if #body > MAX_DIAGNOSTIC_BYTES then
		listener.integrity = "机器人监听诊断超过读取上限，后续完整性状态未知。"
	end
	local from = listener.diagnostic_offset + 1
	while from <= #body do
		local newline = string.find(body, "\n", from, true)
		if not newline and not finished then break end
		local line = string.sub(body, from, if newline then newline - 1 else #body)
		line = string.gsub(line, "\r$", "")
		if line == READY then listener.ready = true
		elseif string.sub(line, 1, 5) == "WARN:" and not listener.integrity then
			listener.integrity = "机器人事件流完整性告警：" .. string.sub(line, 1, 400)
		elseif string.match(line, "^%[event%] exited ") then
			listener.exit_reason = string.match(line, "%(reason: ([%a]+)%)")
		end
		from = if newline then newline + 1 else #body + 1
	end
	listener.diagnostic_offset = from - 1
	return body
end

-- Keeps exactly one listener for the selected profile. Identity must resolve
-- before consume starts. report(nil) means an observed CLI ready marker, never
-- merely a successfully spawned process. Warnings survive clean reconnects.
function bot.sync(current: Listener?, profile: string, report: (string?) -> ()): Listener?
	if current and current.profile == profile and not current.stopped then active = current; return current end
	if current then stop(current) end
	active = nil
	if profile == "" then
		if current then report(nil) end
		return nil
	end
	local listener: Listener = { profile = profile, stopped = false, run = 0, diagnostic_offset = 0,
		ready = false, report = report, reported = false, delivered = {} }
	active = listener
	local start
	local function retry(err: string)
		listener.run_error = err
		publish(listener)
		listener.retry = tern.timer(RETRY_MS, start)
	end
	local function consume()
		if listener.stopped or active ~= listener then return end
		listener.run += 1
		listener.ready, listener.exit_reason, listener.run_error = false, nil, nil
		listener.diagnostic_offset = 0
		listener.diagnostics = tern.plugin.data .. "/" .. listener.dir .. "/stderr-" .. tostring(listener.run) .. ".log"
		local argv = { "/bin/sh", "-c", 'exec "$@" 2>"$0"', listener.diagnostics }
		for _, arg in lark.bot_events_argv(profile, listener.dir, RUN_MINUTES) do table.insert(argv, arg) end
		publish(listener)
		listener.token = proc.run("bot", argv,
			{ cwd = tern.plugin.data, env = lark.ENV, timeout_ms = (RUN_MINUTES + 1) * 60000 }, function(result)
				listener.token = nil
				if listener.stopped or active ~= listener then return end
				local log = diagnostics(listener, true)
				local stderr = (result.stderr or "") .. "\n" .. (log or "")
				if result.status == 0 and not result.timed_out and listener.ready and listener.exit_reason == "timeout" then
					publish(listener)
					listener.retry = tern.timer(1, start)
				else
					local fallback = if not log then "无法读取机器人监听诊断，监听状态未知。"
						elseif result.status == 0 and not result.timed_out then "机器人监听未正常完成（缺少就绪标记或提前退出）。"
						else "机器人事件监听退出（退出码 " .. tostring(result.status) .. "）。"
					retry(lark.error_of(stderr, fallback))
				end
				if log then pcall(tern.fs.remove, listener.diagnostics) end
				listener.diagnostics = nil
			end)
		if not listener.token then retry("无法启动 lark-cli 监听机器人消息。") end
	end
	start = function()
		listener.retry = nil
		if listener.stopped or active ~= listener then return end
		if not listener.dir then
			local ok, dir = pcall(directory)
			if not ok then retry("无法创建隔离的机器人事件目录：" .. tostring(dir)); return end
			listener.dir = dir
		end
		listener.run_error = nil
		if listener.open_id then consume(); return end
		publish(listener)
		lark.bot_info(profile, function(open_id, err, name)
			if listener.stopped or active ~= listener then return end
			if type(open_id) ~= "string" or open_id == "" then retry(err or "无法确认机器人身份。"); return end
			listener.open_id, listener.name = open_id, name
			consume()
		end)
	end
	publish(listener)
	start()
	return listener
end

local function valid(event: any): boolean
	if type(event) ~= "table" or event.type ~= EVENT
		or type(event.message_id) ~= "string" or event.message_id == ""
		or type(event.chat_id) ~= "string" or event.chat_id == ""
		or type(event.message_type) ~= "string" or event.message_type == ""
		or type(event.sender_id) ~= "string" or event.sender_id == ""
		or (event.sender_type ~= "user" and event.sender_type ~= "bot")
		or (event.chat_type ~= "p2p" and event.chat_type ~= "group") then return false end
	for _, field in OPTIONAL_TEXT do
		if event[field] ~= nil and type(event[field]) ~= "string" then return false end
	end
	if event.mentions ~= nil then
		if type(event.mentions) ~= "table" then return false end
		for index, mention in event.mentions do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #event.mentions
				or type(mention) ~= "table" then return false end
			for _, field in MENTION_TEXT do
				if mention[field] ~= nil and type(mention[field]) ~= "string" then return false end
			end
		end
	end
	return true
end

-- The CLI's DirSink writes the processed, flat schema directly (not an API
-- envelope), as <UnixNano>_<pid>_<seq>.json using non-atomic os.WriteFile.
-- Unreadable, oversized, malformed and callback-failed files therefore stay for
-- a later poll; successful deliveries are acknowledged before removal retries.
function bot.drain(deliver: (any) -> ())
	local listener = active
	if not listener or listener.stopped or not listener.open_id or not listener.dir then return end
	diagnostics(listener)
	publish(listener)
	if not listener.ready then return end
	local folder = tern.plugin.data .. "/" .. listener.dir
	local ok, names = pcall(tern.fs.list, folder)
	if not ok then listener.file_error = "无法读取机器人事件目录：" .. tostring(names); publish(listener); return end
	table.sort(names)
	local failure = nil
	for _, name in names do
		if listener.stopped or active ~= listener then return end
		if not string.match(name, "^%d+_%d+_%d+%.json$") then
			if string.match(name, "%.json$") then failure = failure or ("机器人事件文件名不符合 CLI 契约，已保留：" .. name) end
			continue
		end
		local path = folder .. "/" .. name
		if not listener.delivered[name] then
			local read, body = pcall(tern.fs.read, path, MAX_EVENT_BYTES + 1)
			local decoded, event = false, nil
			if read and type(body) == "string" and #body <= MAX_EVENT_BYTES then decoded, event = pcall(tern.json.decode, body) end
			if not decoded or not valid(event) then
				failure = failure or ("机器人事件文件未完整读取或格式无效，已保留重试：" .. name)
				continue
			end
			local delivered = pcall(deliver, event)
			if not delivered then failure = failure or ("机器人事件处理失败，已保留重试：" .. name); continue end
			listener.delivered[name] = true
		end
		if pcall(tern.fs.remove, path) then listener.delivered[name] = nil
		else failure = failure or ("机器人事件已处理，但无法删除文件：" .. name) end
	end
	listener.file_error = failure
	publish(listener)
end

return bot
