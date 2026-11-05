local tern = require("tern")
local ui = tern.ui

require("./lib/inbox")

local function running(cx)
	for _, pane in tern.pane.list() do
		if pane.pane == cx.pane then return true end
	end
	return false
end

local function page(state)
	return state.pages[state.index]
end

local function selected(state)
	local current = page(state)
	return current and current.messages[state.selected]
end

local function decode(text)
	local ok, value = pcall(tern.json.decode, text)
	return if ok and type(value) == "table" then value else nil
end

local function fail(state, cx, message)
	state.loading = false
	state.error = message
	cx:render()
end

-- Only one request can run per block. Commit a new page only after success,
-- leaving the previous page and its cursor available if fetching fails.
local function fetch(state, cx, refresh)
	if state.loading or not running(cx) then return end
	local current = page(state)
	if not refresh and (not current or not current.has_more) then return end
	local token = if refresh then nil else current.page_token
	state.loading, state.error = true, nil
	state.pendingRefresh = refresh
	local argv = {
		tern.kv.get("cli") or "lark-cli", "im", "+messages-search",
		"--as", "user", "--is-at-me", "--page-size", "50",
		"--no-reactions", "--format", "json",
	}
	if token then
		table.insert(argv, "--page-token")
		table.insert(argv, token)
	end
	local started = pcall(function()
		tern.process.run(argv, {
			timeout_ms = 60000,
			env = { LARKSUITE_CLI_NO_UPDATE_NOTIFIER = "1", LARKSUITE_CLI_NO_SKILLS_NOTIFIER = "1" },
		}, function(result)
			if not running(cx) then return end
			if result.timed_out then
				fail(state, cx, "请求超时（60 秒）。按 R 重新检索，或点击重试继续当前页。")
				return
			end
			local envelope = decode(if result.status == 0 then result.stdout else result.stderr)
			if not envelope or envelope.ok ~= true or result.status ~= 0 then
				local detail = envelope and envelope.error
				local message = "lark-cli 调用失败。请在终端运行消息检索命令检查登录、权限和 CLI 版本。"
				if type(detail) == "table" then
					message = tostring(detail.message or message)
					if type(detail.hint) == "string" then message ..= "\n" .. detail.hint end
					if type(detail.missing_scopes) == "table" then
						message ..= "\n缺少权限：" .. table.concat(detail.missing_scopes, ", ")
					end
				end
				fail(state, cx, message)
				return
			end
			local data = envelope.data
			if envelope.identity ~= "user" or type(data) ~= "table" or type(data.messages) ~= "table"
				or type(data.has_more) ~= "boolean" then
				fail(state, cx, "消息响应格式不符合预期，或返回的不是用户身份。请升级 lark-cli。")
				return
			end
			if data.has_more then
				if type(data.page_token) ~= "string" or data.page_token == "" then
					fail(state, cx, "服务端仍有更多结果，但未返回有效分页游标；未标记为全部加载。")
					return
				end
				if not refresh and state.tokens[data.page_token] then
					fail(state, cx, "服务端重复返回分页游标。按 R 重新检索；未标记为全部加载。")
					return
				end
			end
			for _, message in data.messages do
				if type(message) ~= "table" or type(message.message_id) ~= "string" then
					fail(state, cx, "消息响应缺少有效的 message_id。请检查 lark-cli 版本。")
					return
				end
			end
			if refresh then state.pages, state.tokens, state.index = {}, {}, 0 end
			table.insert(state.pages, data)
			state.index = #state.pages
			if data.has_more then state.tokens[data.page_token] = true end
			state.selected = if #data.messages > 0 then 1 else 0
			state.loading, state.error = false, nil
			cx:render()
		end)
	end)
	if not started then
		fail(state, cx, "无法启动 lark-cli。请安装 CLI，或通过命令面板「飞书：设置 lark-cli 路径」指定可执行文件；远程会话需在主机上配置。")
	end
end

local function navigate(state, cx, direction)
	if state.loading then return end
	local target = state.index + direction
	if target >= 1 and target <= #state.pages then
		state.index, state.selected, state.error = target, 1, nil
	elseif direction == 1 then
		fetch(state, cx, false)
	end
end

local function openMessage(state, cx)
	local message = selected(state)
	if not message then return end
	local link = message.message_app_link
	-- Never execute arbitrary protocols supplied by message content.
	if type(link) == "string" and (
		string.match(link, "^https://applink%.feishu%.cn/client/chat/open%?")
		or string.match(link, "^https://applink%.larksuite%.com/client/chat/open%?")
	) then
		cx:open(link)
	else
		cx:toast("error", "该消息没有可用的原消息链接", message.message_id)
	end
end

local function sender(message)
	local from = message.sender
	return if type(from) == "table" then tostring(from.name or from.id or "未知发送者") else "未知发送者"
end

tern.block.define("mentions", {
	font = "sans",
	init = function(cx)
		local state = { pages = {}, tokens = {}, index = 0, selected = 0, loading = false }
		fetch(state, cx, true)
		return state
	end,
	title = function() return "飞书 @我的消息" end,
	view = function(state)
		local current = page(state)
		local children = {
			ui.text({ ui.span("@我的消息", "title strong") }),
			ui.text({ ui.span("全部可检索历史 · 含 @所有人 · 当前飞书用户", "muted") }),
		}
		if state.loading then table.insert(children, ui.progress(nil, "正在检索飞书消息…")) end
		if state.error then
			table.insert(children, ui.card({ ui.span("检索失败", "error") }, {
				ui.text(state.error),
				ui.button("重试", { key = "retry", actions = { click = "retry" }, disabled = state.loading }),
			}))
		end
		if current then
			local rows = {}
			for index, message in current.messages do
				table.insert(rows, {
					id = tostring(index),
					cells = {
						tostring(message.create_time or ""), sender(message),
						tostring(message.chat_name or message.chat_id or "未知会话"),
						if message.deleted then "[消息已撤回]" else tostring(message.content or "[无正文]"),
					},
				})
			end
			local listing = ui.table({
				{ id = "time", head = "时间", priority = 2 },
				{ id = "sender", head = "发送者", priority = 3 },
				{ id = "chat", head = "会话", priority = 1 },
				{ id = "content", head = "消息", grow = 1, priority = 4 },
			}, rows, { selectable = true, selected = tostring(state.selected), empty = "这一页没有匹配消息" })
			listing.p = listing.p or {}
			listing.p.key = "table"
			table.insert(children, ui.node("scroll", { key = "messages", max = { h = "18lines" } }, { listing }))
			local message = selected(state)
			if message then
				table.insert(children, ui.card(sender(message), {
					ui.text({ ui.span(tostring(message.chat_name or message.chat_id or "") .. " · " .. tostring(message.create_time or ""), "muted") }),
					ui.text(if message.deleted then "[消息已撤回]" else tostring(message.content or "[无正文]")),
					ui.row({
						ui.button("在飞书中打开", { key = "open", variant = "primary", keys = { "enter" }, actions = { click = "open-message" } }),
						ui.button("复制正文", { key = "copy", keys = { "c" }, actions = { click = "copy-message" }, disabled = message.deleted == true }),
					}),
				}, { key = "detail" }))
			end
			if not current.has_more and state.index == #state.pages then
				table.insert(children, ui.text({ ui.span("已到达全部可检索结果末尾", "muted") }))
			end
		elseif not state.loading and not state.error then
			table.insert(children, ui.text("没有 @我的消息"))
		end
		return {
			main = ui.col(children),
			dock = ui.col({ ui.row({
				ui.button("刷新", { key = "refresh", keys = { "r" }, actions = { click = "refresh" }, disabled = state.loading }),
				ui.button("上一页", { key = "previous", keys = { "p" }, actions = { click = "previous" }, disabled = state.loading or state.index <= 1 }),
				ui.button("下一页", { key = "next", keys = { "n" }, actions = { click = "next" }, disabled = state.loading or not current or (state.index == #state.pages and not current.has_more) }),
				ui.text({ ui.span("第 " .. tostring(state.index) .. " 页 · 本页 " .. tostring(if current then #current.messages else 0) .. " 条", "muted") }),
			}) }),
		}
	end,
	event = function(state, ev, cx)
		if ev.ev == "select" or ev.ev == "activate" then
			local index = tonumber(ev.item)
			local current = page(state)
			if current and index and current.messages[index] then state.selected = index end
			if ev.ev == "activate" then openMessage(state, cx) end
		elseif ev.ev == "action" then
			if ev.act == "refresh" then fetch(state, cx, true)
			elseif ev.act == "retry" then fetch(state, cx, state.pendingRefresh)
			elseif ev.act == "next" then navigate(state, cx, 1)
			elseif ev.act == "previous" then navigate(state, cx, -1)
			elseif ev.act == "open-message" then openMessage(state, cx)
			elseif ev.act == "copy-message" then
				local message = selected(state)
				if message and not message.deleted then cx:copy(tostring(message.content or "")) end
			end
		end
	end,
	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then return false end
		if key.name == "r" then fetch(state, cx, true)
		elseif key.name == "n" or key.name == "right" then navigate(state, cx, 1)
		elseif key.name == "p" or key.name == "left" then navigate(state, cx, -1)
		elseif key.name == "enter" then openMessage(state, cx)
		elseif key.name == "c" then
			local message = selected(state)
			if message and not message.deleted then cx:copy(tostring(message.content or "")) end
		elseif key.name == "j" or key.name == "down" or key.name == "k" or key.name == "up" then
			local current = page(state)
			if not current or #current.messages == 0 then return false end
			local step = if key.name == "j" or key.name == "down" then 1 else -1
			state.selected = math.clamp(state.selected + step, 1, #current.messages)
		else return false end
		return true
	end,
	-- Message bodies and pagination cursors deliberately aren't persisted to disk.
})
