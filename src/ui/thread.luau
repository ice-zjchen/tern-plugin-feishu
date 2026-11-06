local p = require("./primitives")
local status = require("../core/status")
local markup = require("../shared/markup")
local time = require("../shared/time")
local ui, t, line = p.ui, p.t, p.line

local thread = {}
local INLINE_MESSAGES = 4

local function images(model: any, message: any): any
	local nodes = {}
	if model.cfg.settings.show_images and not message.deleted then
		for _, key in markup.images(tostring(message.content), 4) do
			local image = model.images[key]
			if image and image.blob then
				table.insert(nodes, ui.node("image", { key = key, blob = image.blob, role = "fl.image", alt = "消息图片", max = { h = "14lines" } }))
			elseif image and image.failed then
				table.insert(nodes, line({ t("[图片加载失败]", "muted") }, { key = key }))
			else
				table.insert(nodes, line({ t(if image then "[图片加载中…]" else "[图片未加载，重新选择消息或刷新]", "muted") }, { key = key }))
			end
		end
	end
	return ui.node("col", { key = "images", gap = "xs" }, nodes)
end

local function messages(item: any): { any }
	return item.thread or { { sender = item.name, time = item.time, content = item.content, id = item.latest_id or item.id, deleted = item.deleted } }
end

local function message_node(model: any, key: string, message: any, hit: boolean): any
	local timestamp, full_time = time.format(tostring(message.time))
	return ui.node("col", { key = key, role = if hit then "fl.msg.hit" else "fl.msg", gap = "xs" }, {
		ui.node("row", { justify = "between", gap = "sm", wrap = true }, {
			line({ t(message.sender, "strong") }),
			line({ t(timestamp, "muted") }, { title = full_time }),
		}),
		line(if message.deleted then { t("[消息已撤回]", "muted") } else markup.clean(tostring(message.content)), { role = "fl.msg.text" }),
		images(model, message),
	})
end

local function window(list: { any }, item: any): (number, number)
	local total, hit = #list, #list
	for i, message in list do
		if message.id == (item.latest_id or item.id) then
			hit = i
		end
	end
	local first = math.max(1, total - INLINE_MESSAGES + 1)
	if hit < first then
		return hit, math.min(total, hit + INLINE_MESSAGES - 1)
	end
	return first, total
end

local function scope(item: any): string
	return (if item.chat_type == "p2p" then "私聊" else item.chat) .. " · 触发消息及其上下文"
end

function thread.render(model: any, item: any): any
	local list = messages(item)
	local first, last = window(list, item)
	local actions: { any } = {}
	if last - first + 1 < #list then
		table.insert(actions, ui.button("全部 " .. tostring(#list) .. " 条", { key = "all", size = "sm", variant = "quiet", actions = { click = "open-thread" } }))
	end
	table.insert(actions, ui.button("在飞书打开", { key = "open", size = "sm", variant = "quiet", actions = { click = "open" } }))
	local children: { any } = {
		ui.node("row", { key = "head", role = "fl.context.head", justify = "between", gap = "sm", wrap = true }, {
			line({ t("原始对话", "strong") }),
			ui.node("row", { key = "actions", gap = "xs" }, actions),
		}),
		line({ t(scope(item), "muted") }, { role = "fl.context.meta" }),
	}
	for i = first, last do
		table.insert(children, message_node(model, "msg_" .. tostring(i), list[i], status.is_trigger(item, list[i].id)))
	end
	if item.thread_error then
		table.insert(children, line({ t("未能读取会话上下文：" .. item.thread_error, "muted") }))
	end
	return ui.node("col", { key = "thread", role = "fl.context.thread", gap = "sm" }, children)
end

function thread.quote(model: any, item: any): any
	local children: { any } = {
		line(if item.deleted then { t("[消息已撤回]", "muted") } else markup.clean(tostring(item.content)), { key = "text", role = "fl.msg.text" }),
		images(model, item),
	}
	local actions: { any } = {}
	local count = #messages(item)
	if count > 1 then
		table.insert(actions, ui.button("查看全部 " .. tostring(count) .. " 条对话", { key = "all", size = "sm", variant = "quiet", actions = { click = "open-thread" } }))
	end
	table.insert(actions, ui.button("在飞书打开", { key = "open", size = "sm", variant = "quiet", actions = { click = "open" } }))
	table.insert(children, ui.node("row", { key = "actions", gap = "xs", wrap = true }, actions))
	return ui.node("col", { key = "quote", role = "fl.quote", gap = "xs" }, children)
end

function thread.dialog(model: any, item: any): any
	local list = messages(item)
	local children: { any } = {
		ui.button("关闭", { key = "close", variant = "quiet", keys = { "esc" }, actions = { click = "close-thread" } }),
		line({ t(scope(item) .. " · " .. tostring(#list) .. " 条", "muted") }, { key = "scope" }),
	}
	for i, message in list do
		table.insert(children, message_node(model, "msg_" .. tostring(i), message, status.is_trigger(item, message.id)))
	end
	return ui.col({ ui.node("overlay", {
		key = "thread", head = "原始对话", meta = { t(item.name .. " · " .. item.chat, "muted") }, size = "lg", modal = true,
		["end"] = "layer.thread.close",
	}, children) })
end

return thread
