-- Business reads use the current user's identity; dedicated bot identity and
-- event-listener helpers explicitly select their profile. Credentials stay in CLI.

local tern = require("tern")

local lark = {}

local ENV = { LARKSUITE_CLI_NO_UPDATE_NOTIFIER = "1", LARKSUITE_CLI_NO_SKILLS_NOTIFIER = "1" }
local NOT_STARTED = "无法启动 lark-cli。请安装 CLI，或通过命令面板「飞书 Feishu / Lark：设置 lark-cli 路径」指定可执行文件。"

local function decode(text: string): any
	local ok, value = pcall(tern.json.decode, text)
	return if ok and type(value) == "table" then value else nil
end

-- A readable message from a failed envelope, naming any missing scopes.
local function failure(envelope: any, fallback: string): string
	local detail = envelope and envelope.error
	if type(detail) ~= "table" then
		return fallback
	end
	local message = tostring(detail.message or fallback)
	if type(detail.missing_scopes) == "table" then
		message = "缺少飞书权限：" .. table.concat(detail.missing_scopes, ", ")
			.. "\n请在终端运行：lark-cli auth login --scope \"" .. table.concat(detail.missing_scopes, " ") .. "\""
	elseif type(detail.hint) == "string" then
		message ..= "\n" .. detail.hint
	end
	return message
end

-- Runs `lark-cli args…`; `done` gets the envelope's data, or nil and an error.
local function run(args: { string }, opts: { stdin: string?, timeout_ms: number?, cwd: string? }?, done: (any, string?) -> ())
	local argv: { string } = { tern.kv.get("cli") or "lark-cli" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local options = {
		env = ENV,
		stdin = opts and opts.stdin,
		cwd = opts and opts.cwd,
		timeout_ms = (opts and opts.timeout_ms) or 60000,
	}
	local started = pcall(function()
		tern.process.run(argv, options, function(result)
			if result.timed_out then
				done(nil, "lark-cli 超时。")
				return
			end
			local envelope = decode(if result.status == 0 then result.stdout else result.stderr)
				or decode(result.stdout)
			if result.status ~= 0 or not envelope or envelope.ok ~= true then
				done(nil, failure(envelope, "lark-cli 调用失败（退出码 " .. tostring(result.status) .. "）。"))
				return
			end
			if envelope.identity ~= nil and envelope.identity ~= "user" then
				done(nil, "lark-cli 返回的不是用户身份。请在终端运行 lark-cli auth login。")
				return
			end
			done(envelope.data, nil)
		end)
	end)
	if not started then
		done(nil, NOT_STARTED)
	end
end

-- ISO 8601 with this machine's UTC offset, as the CLI's time flags want.
local function iso(at: number): string
	local utc = os.date("!*t", at) :: any
	utc.isdst = false
	local offset = os.difftime(at, os.time(utc))
	local sign = if offset < 0 then "-" else "+"
	offset = math.abs(offset)
	return os.date("%Y-%m-%dT%H:%M:%S", at)
		.. string.format("%s%02d:%02d", sign, offset // 3600, (offset % 3600) // 60)
end

-- The current user's open_id.
function lark.whoami(done: (string?, string?) -> ())
	local started = pcall(function()
		tern.process.run({ tern.kv.get("cli") or "lark-cli", "auth", "status" }, { env = ENV, timeout_ms = 20000 }, function(result)
			local status = decode(result.stdout)
			local user = status and status.identities and status.identities.user
			if type(user) == "table" and type(user.openId) == "string" then
				done(user.openId, nil)
			else
				done(nil, "lark-cli 未登录用户身份。请在终端运行 lark-cli auth login --domain im。")
			end
		end)
	end)
	if not started then
		done(nil, NOT_STARTED)
	end
end

export type SearchPage = { messages: { any }, has_more: boolean, page_token: string? }

-- One page of messages matching `filters` (CLI flags such as `--is-at-me`), from
-- `since` (epoch seconds) when given, continuing at `token` when given.
function lark.search(query: { filters: { string }, since: number?, token: string? }, done: (SearchPage?, string?) -> ())
	local args = { "im", "+messages-search", "--as", "user", "--page-size", "50", "--no-reactions", "--format", "json" }
	if query.since then
		table.insert(args, "--start")
		table.insert(args, iso(query.since))
	end
	for _, filter in query.filters do
		table.insert(args, filter)
	end
	if query.token then
		table.insert(args, "--page-token")
		table.insert(args, query.token)
	end
	run(args, nil, function(data, err)
		if err then
			done(nil, err)
			return
		end
		if type(data) ~= "table" or (data.messages ~= nil and type(data.messages) ~= "table") then
			done(nil, "消息响应格式不符合预期。请升级 lark-cli。")
			return
		end
		-- tern.json.decode drops null members, so `"messages": null` arrives as a
		-- missing field. Treat it as an empty page; pagination fields still apply.
		local messages = data.messages or {}
		for _, message in messages do
			if type(message) ~= "table" or type(message.message_id) ~= "string" then
				done(nil, "消息响应缺少有效的 message_id。请检查 lark-cli 版本。")
				return
			end
		end
		local more = data.has_more == true
		local token = if type(data.page_token) == "string" and data.page_token ~= "" then data.page_token else nil
		if more and not token then
			done(nil, "服务端仍有更多结果，但未返回有效分页游标。")
			return
		end
		done({ messages = messages, has_more = more, page_token = token }, nil)
	end)
end

-- Current user's group notification preferences, at most ten chats per request.
function lark.chat_settings(chat_ids: { string }, done: (any, string?) -> ())
	local found = {}
	local problem: string? = nil
	local function batch(at: number)
		if at > #chat_ids then
			done(found, problem)
			return
		end
		local ids = {}
		for i = at, math.min(at + 9, #chat_ids) do
			table.insert(ids, chat_ids[i])
		end
		run({
			"im", "chat.user_setting", "batch_query", "--as", "user", "--format", "json",
			"--data", tern.json.encode({ chat_ids = ids }),
		}, nil, function(data, err)
			if err then
				done(found, err)
				return
			end
			if type(data) ~= "table" or type(data.items) ~= "table" then
				done(found, "群免打扰设置响应格式不符合预期。请升级 lark-cli。")
				return
			end
			for _, pref in data.items do
				if type(pref) == "table" and type(pref.chat_id) == "string"
					and type(pref.is_muted) == "boolean" and type(pref.is_mute_at_all) == "boolean" then
					found[pref.chat_id] = pref
				end
			end
			for _, id in ids do
				if not found[id] then
					problem = "部分群免打扰设置无法读取，已暂时隐藏这些群的消息。"
				end
			end
			batch(at + 10)
		end)
	end
	batch(1)
end

-- Whether the current user has read each message, fifty ids per request. A message
-- the server can't determine is left out, and a failure keeps what came before it.
function lark.read_status(message_ids: { string }, done: ({ [string]: boolean }, string?) -> ())
	local found = {}
	local function batch(at: number)
		if at > #message_ids then
			done(found, nil)
			return
		end
		local ids = {}
		for i = at, math.min(at + 49, #message_ids) do
			table.insert(ids, message_ids[i])
		end
		run({
			"im", "+messages-read-status", "--as", "user", "--message-ids", table.concat(ids, ","), "--format", "json",
		}, nil, function(data, err)
			if err then
				done(found, err)
				return
			end
			if type(data) ~= "table" then
				done(found, "已读状态响应格式不符合预期。请升级 lark-cli。")
				return
			end
			for _, entry in (if type(data.items) == "table" then data.items else {}) do
				if type(entry) == "table" and type(entry.message_id) == "string" and type(entry.is_read) == "boolean" then
					found[entry.message_id] = entry.is_read
				end
			end
			batch(at + 50)
		end)
	end
	batch(1)
end

-- `count` messages of a chat, oldest first. With `until_time` (`YYYY-MM-DD
-- HH:MM`, the search results' create_time) only those up to that minute.
function lark.history(chat_id: string, count: number, until_time: string?, done: ({ any }?, string?) -> ())
	local args = {
		"im", "+chat-messages-list", "--as", "user", "--chat-id", chat_id, "--page-size", tostring(count),
		"--order", "desc", "--no-reactions", "--format", "json",
	}
	local y, mo, d, h, mi = string.match(until_time or "", "^(%d+)-(%d+)-(%d+) (%d+):(%d+)")
	if y then
		local at = os.time({
			year = tonumber(y) :: number, month = tonumber(mo) :: number, day = tonumber(d) :: number,
			hour = tonumber(h) :: number, min = tonumber(mi) :: number, sec = 59,
		})
		table.insert(args, "--end")
		table.insert(args, iso(at))
	end
	run(args, nil, function(data, err)
		if err or type(data) ~= "table" or type(data.messages) ~= "table" then
			done(nil, err or "会话历史格式不符合预期。")
			return
		end
		local oldest_first = {}
		for i = #data.messages, 1, -1 do
			table.insert(oldest_first, data.messages[i])
		end
		done(oldest_first, nil)
	end)
end

-- Today's agenda as the CLI returns it; an error means the agent goes without.
function lark.agenda(done: (any, string?) -> ())
	run({ "calendar", "+agenda", "--as", "user", "--format", "json" }, { timeout_ms = 30000 }, done)
end

-- Saves an image under the plugin's data folder; `done` gets the saved path,
-- relative to that folder. Only `img_…` keys are accepted, so a key cannot name
-- a path of its own.
function lark.download_image(message_id: string, key: string, done: (string?, string?) -> ())
	if not string.match(key, "^img_[%w_%-]+$") then
		done(nil, "图片 key 不合法：" .. key)
		return
	end
	run({
		"im", "+messages-resources-download", "--as", "user", "--message-id", message_id, "--file-key", key,
		"--type", "image", "--output", "images/" .. key, "--format", "json",
	}, { cwd = tern.plugin.data }, function(data, err)
		if err or type(data) ~= "table" or type(data.saved_path) ~= "string" then
			done(nil, err or "图片下载结果格式不符合预期。")
			return
		end
		local name = string.match(data.saved_path, "([^/\\]+)$")
		done(if name then "images/" .. name else nil, nil)
	end)
end

-- One message by id, shaped like a search result (chat name and type filled in),
-- read as the current user: the bot only points at it.
function lark.message(message_id: string, done: (any, string?) -> ())
	run({ "im", "+messages-mget", "--as", "user", "--message-ids", message_id, "--format", "json" }, nil, function(data, err)
		local message = if type(data) == "table" and type(data.messages) == "table" then data.messages[1] else nil
		if err or type(message) ~= "table" or message.message_id ~= message_id then
			done(nil, err or "读取指令所指的消息失败。")
			return
		end
		if type(message.sender) == "table" and message.sender.sender_type == nil then
			message.sender.sender_type = if message.sender.id_type == "app_id" then "app" else "user"
		end
		run({ "im", "chats", "get", "--as", "user", "--chat-id", tostring(message.chat_id), "--format", "json" }, nil, function(chat, chat_err)
			if chat_err or type(chat) ~= "table" then
				done(nil, chat_err or "读取消息所在会话失败。")
				return
			end
			message.chat_name = chat.name or message.chat_id
			message.chat_type = if chat.chat_mode == "p2p" then "p2p" else "group"
			done(message, nil)
		end)
	end)
end

-- Bot identity is scoped to its profile; mention IDs must match this exact ID.
function lark.bot_info(profile: string, done: (string?, string?) -> ())
	local started = pcall(function()
		tern.process.run({ tern.kv.get("cli") or "lark-cli", "--profile", profile, "api", "GET",
			"/open-apis/bot/v3/info", "--as", "bot", "--format", "json" }, { env = ENV, timeout_ms = 20000 }, function(result)
			local envelope = decode(result.stdout) or decode(result.stderr)
			local bot = envelope and envelope.data
			if result.status == 0 and envelope and envelope.ok == true and type(bot) == "table"
				and type(bot.open_id) == "string" and bot.open_id ~= "" then
				done(bot.open_id, nil)
			else
				done(nil, failure(envelope, "无法取得专用机器人的身份，请确认 profile、机器人能力及应用发布状态。"))
			end
		end)
	end)
	if not started then done(nil, NOT_STARTED) end
end

-- The bot's message stream for one bounded run: each event becomes a JSON file in
-- `dir` (relative to the plugin data folder, which must be the process cwd).
function lark.bot_events_argv(profile: string, dir: string, minutes: number): { string }
	return { tern.kv.get("cli") or "lark-cli", "--profile", profile, "event", "consume", "im.message.receive_v1",
		"--as", "bot", "--timeout", tostring(minutes) .. "m", "--output-dir", dir }
end

lark.ENV = ENV

-- The readable reason in a failed CLI's stderr: the (possibly pretty-printed)
-- JSON envelope runs from the first line starting with `{` to the last `}`.
function lark.error_of(stderr: string, fallback: string): string
	local from = string.find(stderr, "\n{") or (if string.sub(stderr, 1, 1) == "{" then 0 else nil)
	local to = string.match(stderr, ".*()}")
	local envelope = if from and to then decode(string.sub(stderr, from + 1, to)) else nil
	return if envelope and envelope.ok == false then failure(envelope, fallback) else fallback
end

return lark
