import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const source = readFileSync(new URL('../src/app/bot.luau', import.meta.url), 'utf8');
const fixture = String.raw`
local SOURCE = [====[
${source}
]====]
local READY = "[event] ready event_key=im.message.receive_v1\n"
local function fixture()
	local f = { files = {}, dirs = {}, kv = {}, values = {}, reports = {}, timers = {}, runs = {}, identities = {}, stops = {}, delivered = {}, read_fail = {}, remove_fail = {} }
	local tern = {
		plugin = { data = "data" },
		kv = { get = function(key) return f.kv[key] end, set = function(key, value) f.kv[key] = value end },
		fs = {
			mkdir = function(path) if f.mkdir_fail then error("mkdir failed") end; f.dirs[path] = true end,
			exists = function(path) return f.dirs[path] == true or f.files[path] ~= nil end,
			read = function(path, limit)
				if f.read_fail[path] or f.files[path] == nil then error("read failed") end
				return string.sub(f.files[path], 1, limit or #f.files[path])
			end,
			list = function(path)
				if f.list_fail then error("list failed") end
				local names = {}
				for file in f.files do
					local prefix = path .. "/"
					if string.sub(file, 1, #prefix) == prefix then
						local name = string.sub(file, #prefix + 1)
						if not string.find(name, "/", 1, true) then table.insert(names, name) end
					end
				end
				return names
			end,
			remove = function(path) if f.remove_fail[path] then error("remove failed") end; f.files[path] = nil end,
		},
		json = { decode = function(body)
			if body == "scalar" then return 17 end
			if not f.values[body] then error("invalid or partial JSON") end
			return f.values[body]
		end },
		timer = function(ms, fn)
			local timer = { ms = ms, fn = fn, cancelled = false }
			function timer:cancel() self.cancelled = true end
			table.insert(f.timers, timer)
			return timer
		end,
	}
	local lark = {
		ENV = { BOT_TEST = "yes" },
		bot_info = function(profile, done) table.insert(f.identities, { profile = profile, done = done }) end,
		bot_events_argv = function(profile, dir, minutes)
			return { "lark-cli", "--profile", profile, "event", "consume", "im.message.receive_v1", "--as", "bot", "--timeout", tostring(minutes) .. "m", "--output-dir", dir }
		end,
		error_of = function(stderr, fallback)
			return if string.find(stderr, '"ok":false', 1, true) then "structured CLI failure" else fallback
		end,
	}
	local proc = {
		run = function(kind, argv, options, done)
			if f.start_fail then return nil end
			local token = "token-" .. tostring(#f.runs + 1)
			table.insert(f.runs, { kind = kind, argv = argv, options = options, done = done, token = token })
			f.files[argv[4]] = ""
			return token
		end,
		stop = function(token) table.insert(f.stops, token); return true end,
	}
	local chunk = assert(loadstring(SOURCE, "@src/app/bot.luau"))
	setfenv(chunk, setmetatable({ require = function(path)
		if path == "tern" then return tern elseif path == "../services/lark" then return lark elseif path == "../services/proc" then return proc end
		error("unexpected dependency " .. path)
	end }, { __index = getfenv() }))
	f.bot = chunk()
	function f.sync(profile, current)
		return f.bot.sync(current, profile, function(message) table.insert(f.reports, { message = message }) end)
	end
	function f.resolve(id, err, index, name) f.identities[index or #f.identities].done(id, err, if id then name or ("应用-" .. id) else nil) end
	function f.fire(index)
		local timer = f.timers[index or #f.timers]
		assert(not timer.cancelled)
		timer.fn()
	end
	function f.ready(listener, extra) f.files[listener.diagnostics] = READY .. (extra or "") end
	function f.message(id)
		return { type = "im.message.receive_v1", message_id = id or "om_message", chat_id = "oc_group", chat_type = "group", message_type = "text", sender_id = "ou_owner", sender_type = "user", content = "@Bot plain text, not JSON", mentions = { { id = "ou_bot", key = "@_user_1", name = "Bot" } } }
	end
	function f.put(listener, name, value)
		local path = "data/" .. listener.dir .. "/" .. name
		if type(value) == "string" then f.files[path] = value
		else
			local body = "json:" .. path
			f.values[body], f.files[path] = value, body
		end
		return path
	end
	function f.drain(deliver) f.bot.drain(deliver or function(event) table.insert(f.delivered, event) end) end
	function f.report() return f.reports[#f.reports].message end
	function f.started(profile)
		local listener = f.sync(profile or "dedicated")
		f.resolve("ou_bot")
		f.ready(listener)
		return listener
	end
	return f
end
`;

function check(name, scenario) {
	test(name, () => {
		const directory = mkdtempSync(join(tmpdir(), 'feishu-bot-test-'));
		try {
			const path = join(directory, 'bot.spec.luau');
			writeFileSync(path, fixture + '\n' + scenario);
			const result = spawnSync('luau', [path], { encoding: 'utf8', timeout: 10_000 });
			assert.ifError(result.error);
			assert.equal(result.status, 0, result.stdout + result.stderr);
		} finally {
			rmSync(directory, { recursive: true, force: true });
		}
	});
}

check('identity and a complete CLI ready line gate delivery of flat processed events', String.raw`
local f = fixture()
local listener = f.sync("dedicated")
assert(#f.runs == 0 and #f.identities == 1 and listener.open_id == nil)
local event = f.message()
local path = f.put(listener, "100_12_1.json", event)
f.drain(); assert(#f.delivered == 0 and f.files[path] ~= nil)
f.resolve("ou_bot")
assert(listener.open_id == "ou_bot" and listener.name == "应用-ou_bot" and #f.runs == 1)
local argv = f.runs[1].argv
assert(argv[1] == "/bin/sh" and argv[3] == 'exec "$@" 2>"$0"' and argv[#argv] == listener.dir)
assert(f.runs[1].options.cwd == "data" and f.runs[1].options.timeout_ms == 31 * 60000)
f.files[listener.diagnostics] = string.sub(READY, 1, #READY - 1)
f.drain(); assert(#f.delivered == 0 and listener.ready == false)
f.files[listener.diagnostics] ..= "\n"
f.drain()
assert(#f.delivered == 1 and f.delivered[1] == event and f.files[path] == nil and f.report() == nil)
assert(f.delivered[1].content == "@Bot plain text, not JSON" and f.delivered[1].mentions[1].id == "ou_bot")
f.drain(); assert(#f.delivered == 1)
`);

check('identity errors retry without spawning an unidentified consumer', String.raw`
local f = fixture()
local listener = f.sync("missing-profile")
f.resolve(nil, "profile unavailable")
assert(#f.runs == 0 and f.report() == "profile unavailable" and f.timers[1].ms == 60000)
f.fire()
assert(#f.identities == 2 and listener.open_id == nil)
f.resolve("ou_bot")
assert(#f.runs == 1 and listener.open_id == "ou_bot")
`);

check('switching profiles and switching back never consumes an earlier generation', String.raw`
local f = fixture()
local old = f.started("old")
local old_token = old.token
local path = f.put(old, "100_12_1.json", f.message("om_old"))
local new = f.sync("new", old)
assert(old.stopped and old.open_id == nil and old.name == nil and f.stops[1] == old_token and new.dir ~= old.dir)
f.resolve("ou_new", nil, nil, "真实返回的新机器人名")
assert(new.name == "真实返回的新机器人名")
f.ready(new)
f.put(old, "101_12_2.json", f.message("om_late_old"))
f.put(new, "102_13_1.json", f.message("om_new"))
f.drain()
assert(#f.delivered == 1 and f.delivered[1].message_id == "om_new" and f.files[path] ~= nil)
local reports, timers = #f.reports, #f.timers
f.runs[1].done({ status = 1, stderr = "old failure" })
assert(#f.reports == reports and #f.timers == timers)
local again = f.sync("old", new)
assert(again.dir ~= old.dir and again.dir ~= new.dir)
f.resolve("ou_old"); f.ready(again); f.drain()
assert(#f.delivered == 1)
assert(f.sync("", again) == nil)
f.drain(); assert(#f.delivered == 1)
`);

check('a late identity response cannot start a stopped profile', String.raw`
local f = fixture()
local old = f.sync("old")
local new = f.sync("new", old)
f.resolve("ou_old", nil, 1)
assert(#f.runs == 0 and old.open_id == nil)
f.resolve("ou_new", nil, 2)
assert(#f.runs == 1 and new.open_id == "ou_new")
`);

check('switching during a drain stops delivery from the captured old file list', String.raw`
local f = fixture()
local old = f.started("old")
f.put(old, "100_12_1.json", f.message("om_first"))
local remaining = f.put(old, "200_12_2.json", f.message("om_remaining"))
local count, new = 0, nil
f.drain(function()
	count += 1
	new = f.sync("new", old)
	f.resolve("ou_new"); f.ready(new)
end)
assert(count == 1 and f.files[remaining] ~= nil)
f.put(new, "300_13_1.json", f.message("om_new"))
f.drain()
assert(#f.delivered == 1 and f.delivered[1].message_id == "om_new")
`);

check('partial, unreadable, oversized and structurally malformed files remain recoverable', String.raw`
local f = fixture()
local listener = f.started()
local name = "100_12_1.json"
local path = f.put(listener, name, "{partial")
f.drain(); assert(f.files[path] == "{partial" and #f.delivered == 0 and f.report() ~= nil)
f.put(listener, name, f.message())
f.read_fail[path] = true
f.drain(); assert(f.files[path] ~= nil and #f.delivered == 0)
f.read_fail[path] = nil
f.files[path] = string.rep("x", 1024 * 1024 + 1)
f.drain(); assert(#f.files[path] > 1024 * 1024 and #f.delivered == 0)
f.put(listener, name, { ok = true, data = f.message() })
f.drain(); assert(f.files[path] ~= nil and #f.delivered == 0)
f.files[path] = "scalar"
f.drain(); assert(f.files[path] ~= nil and #f.delivered == 0)
for _, mutate in {
	function(event) event.mentions = "not an array" end,
	function(event) event.mentions = { { id = {} } } end,
	function(event) event.mentions = { invalid = { id = "ou_bot" } } end,
	function(event) event.content = {} end,
	function(event) event.reply_to = {} end,
	function(event) event.message_id = "" end,
	function(event) event.chat_id = nil end,
	function(event) event.message_type = 7 end,
	function(event) event.sender_type = "unknown" end,
} do
	local invalid = f.message(); mutate(invalid)
	f.put(listener, name, invalid)
	f.drain(); assert(f.files[path] ~= nil and #f.delivered == 0)
end
f.put(listener, name, f.message())
f.drain(); assert(f.files[path] == nil and #f.delivered == 1 and f.report() == nil)
`);

check('event ordering, delivery failures and removal retries do not silently lose events', String.raw`
local f = fixture()
local listener = f.started()
local late = f.put(listener, "200_12_2.json", f.message("om_later"))
local early = f.put(listener, "100_12_1.json", f.message("om_earlier"))
f.drain(function() error("handler failed") end)
assert(f.files[early] ~= nil and f.files[late] ~= nil and f.report() ~= nil)
f.remove_fail[early] = true
f.drain()
assert(#f.delivered == 2 and f.delivered[1].message_id == "om_earlier" and f.delivered[2].message_id == "om_later")
assert(f.files[early] ~= nil and f.files[late] == nil)
f.drain(); assert(#f.delivered == 2 and f.files[early] ~= nil)
f.remove_fail[early] = nil
f.drain(); assert(#f.delivered == 2 and f.files[early] == nil and f.report() == nil)
`);

check('CLI integrity warnings survive successful events and clean bounded reconnects', String.raw`
local f = fixture()
local listener = f.started()
f.ready(listener, "WARN: event seq gap 1->3, missed 1 events (dropped by bus backpressure)\n")
f.put(listener, "100_12_1.json", f.message())
f.drain()
assert(listener.ready and #f.delivered == 1 and string.find(f.report(), "seq gap", 1, true))
local log = listener.diagnostics
f.files[log] ..= "[event] exited — received 1 event(s) in 1800s (reason: timeout)\n"
f.runs[1].done({ status = 0 })
assert(f.timers[#f.timers].ms == 1 and f.files[log] == nil)
f.fire()
assert(#f.runs == 2 and #f.identities == 1 and listener.ready == false)
f.ready(listener); f.drain()
assert(listener.ready and string.find(f.report(), "seq gap", 1, true))
`);

check('zero exit without readiness, signal exits, process errors and timeout failures retry', String.raw`
for _, kind in { "no-ready", "signal", "nonzero", "timed-out", "missing-log" } do
	local f = fixture()
	local listener = f.started()
	if kind == "no-ready" then f.files[listener.diagnostics] = "" end
	if kind == "signal" then f.files[listener.diagnostics] ..= "[event] exited — received 0 event(s) in 1s (reason: signal)\n" end
	if kind == "nonzero" then f.files[listener.diagnostics] ..= '{"ok":false,"error":{"message":"failed"}}\n' end
	if kind == "missing-log" then f.read_fail[listener.diagnostics] = true end
	f.runs[1].done({ status = if kind == "nonzero" then 3 else 0, timed_out = kind == "timed-out" })
	assert(f.timers[#f.timers].ms == 60000 and f.report() ~= nil)
	if kind == "nonzero" then assert(f.report() == "structured CLI failure") end
end
`);

check('filesystem setup, listing and spawn failures are visible and recoverable', String.raw`
local f = fixture()
f.mkdir_fail = true
local listener = f.sync("dedicated")
assert(#f.identities == 0 and #f.runs == 0 and f.report() ~= nil)
f.mkdir_fail = false
f.fire(); f.resolve("ou_bot"); f.ready(listener)
f.list_fail = true
f.drain(); assert(f.report() ~= nil)
f.list_fail = false
f.drain(); assert(f.report() == nil)
local g = fixture()
g.start_fail = true
local failed = g.sync("dedicated"); g.resolve("ou_bot")
assert(failed.token == nil and g.report() ~= nil and g.timers[#g.timers].ms == 60000)
g.start_fail = false
g.fire(); assert(#g.runs == 1)
`);

check('directory collisions, unknown JSON filenames and diagnostic truncation stay observable', String.raw`
local f = fixture()
f.dirs["data/bot-events/listener-1"] = true
local listener = f.started()
assert(listener.dir == "bot-events/listener-2")
local path = f.put(listener, "unknown.json", f.message())
f.drain(); assert(f.files[path] ~= nil and #f.delivered == 0 and f.report() ~= nil)
f.files[path] = nil
f.ready(listener, string.rep("x", 1024 * 1024))
f.drain()
assert(listener.ready and string.find(f.report(), "读取上限", 1, true))
`);
