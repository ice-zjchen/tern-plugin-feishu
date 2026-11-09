local p = require("./primitives")
local thread = require("./thread")
local status = require("../core/status")
local markup = require("../shared/markup")
local time = require("../shared/time")
local ui, t, line, folded, kv_row = p.ui, p.t, p.line, p.folded, p.kv_row

local detail = {}

local function short_path(model: any, path: string): string
	local home = model.cfg.home
	return if home and string.sub(path, 1, #home) == home then "~" .. string.sub(path, #home + 1) else path
end

function detail.record(model: any, item: any): any?
	local run = item.analysis.run
	if not run then
		local judgment = item.analysis.judgment
		if not judgment or judgment.manual then
			return nil
		end
		local configured_model = model.cfg.settings.model_analysis
		local workspace = model.cfg.settings.workspace
		return folded("run", "分析记录 · 未记录", {
			line({ t("这条的分析没有留下记录。下面是当前设置，不一定是当时用的。", "muted") }),
			ui.kv({
				kv_row("模型", if configured_model ~= "" then configured_model else "默认"),
				kv_row("Workspace", { t(if workspace ~= "" then workspace else "插件数据目录", "path") }),
			}),
		})
	end
	local steps, failed = #run.steps + (run.more_steps or 0), 0
	for _, step in run.steps do
		failed += if step.failed then 1 else 0
	end
	local folder = run.cwd and string.match(run.cwd, "([^/]+)/*$")
	local summary = (run.model or "模型未知") .. " · " .. (folder or "目录未知") .. " · "
		.. (if steps > 0 then tostring(steps) .. " 次工具" else "未调用工具")
	local children: { any } = {}
	if steps == 0 then
		table.insert(children, line({ t("没有调用工具，直接根据消息判断。", "muted") }, { key = "no-steps" }))
	end
	for i, step in run.steps do
		table.insert(children, line({
			t(step.tool, "strong"),
			if step.target then " " .. step.target else "",
			if step.failed then t(" 失败", "warning") else "",
		}, { key = "step_" .. tostring(i), role = "fl.run.step" }))
	end
	if (run.more_steps or 0) > 0 then
		table.insert(children, line({ t("还有 " .. tostring(run.more_steps) .. " 次未列出", "muted") }, { key = "more" }))
	end
	local rows = {
		kv_row("模型", (if run.provider then run.provider .. " / " else "") .. (run.model or "未知")),
		kv_row("思考强度", if run.thinking and run.thinking ~= "default" then run.thinking else "默认"),
		kv_row("Workspace", { t(if run.cwd then short_path(model, run.cwd) else "未知", "path") }),
		kv_row("Skills", if run.skills then { t(short_path(model, run.skills), "path") } else "沿用默认配置"),
		kv_row("内容", if run.incremental then "沿用会话，只发送新消息" else "新会话，完整上下文"),
		kv_row("时间", tostring(run.at or "未知") .. " · 用时 " .. tostring(run.seconds or 0) .. " 秒"),
	}
	if (run.cost or 0) > 0 then
		table.insert(rows, kv_row("费用", string.format("$%.4f", run.cost)))
	end
	table.insert(children, ui.kv(rows))
	return folded("run", "分析记录 · " .. summary .. (if failed > 0 then " · " .. tostring(failed) .. " 次失败" else ""), children)
end

function detail.why(item: any): string?
	local judgment = item.analysis.judgment
	return if judgment and not judgment.manual and judgment.why ~= "" then judgment.why else nil
end

local function analysis_block(model: any, item: any): any
	local judgment = item.analysis.judgment
	local s = status.of(item)
	local where = if item.chat_type == "p2p" then "私聊" else item.chat
	local timestamp, full_time = time.format(item.time)
	local byline = (if judgment and not judgment.manual then judgment.pri .. " · " else "") .. item.name .. " · " .. where .. " · " .. timestamp
	if item.sender_type ~= "user" then
		byline ..= " · " .. (if item.sender_type == "bot" then "机器人" else "身份未知")
	end
	if item.via and item.via ~= "" then
		byline ..= " · " .. item.via
	end
	local tools: { any } = {}
	if s ~= "task_starting" and s ~= "task_working" and not status.settled(item) then
		table.insert(tools, ui.button(if s == "snoozed" then "移回待处理" else "稍后", { key = "snooze", size = "sm", variant = "quiet", keys = { "s" }, actions = { click = "snooze" } }))
		if status.next_action(item).key ~= "archive" and s ~= "task_done" then
			table.insert(tools, ui.button("归档", { key = "archive", size = "sm", variant = "quiet", keys = { "x" }, actions = { click = "archive" } }))
		end
	end
	local title = if judgment and not judgment.manual and judgment.summary ~= "" then judgment.summary else markup.clean(item.content)
	local children: { any } = {
		line({ t(title, "strong") }, { key = "title", role = "fl.summary.title" }),
		ui.node("row", { key = "top", justify = "between", gap = "md", wrap = true }, {
			line({ t(byline, "muted") }, { key = "meta", role = "fl.summary.meta", title = full_time }),
			ui.node("row", { key = "tools", gap = "xs" }, tools),
		}),
	}
	local followup = status.followup(item)
	if followup then
		table.insert(children, line({ t(followup, "warning") }, { key = "followup" }))
	end
	if judgment and judgment.manual then
		table.insert(children, line({ t("这条由你处理，AI 没有判断过。", "muted") }))
	elseif s == "failed" then
		table.insert(children, line({ t("分析失败：" .. tostring(item.analysis.error), "warning") }))
		table.insert(children, ui.node("row", { key = "retry" }, {
			ui.button("重试分析", { actions = { click = "retry" } }),
		}))
	elseif s == "running" then
		local stopping = item.analysis.stopping == true
		table.insert(children, line({ t(if stopping then "正在停止分析…" else "正在判断这条消息…", "info") }))
		table.insert(children, ui.node("row", { key = "stop" }, {
			ui.button(if stopping then "停止中…" else "停止分析", { key = "stop", variant = "quiet", keys = { "p" },
				disabled = stopping, busy = stopping, actions = { click = "stop" } }),
		}))
	elseif s == "queued" and (item.analysis.settle_at or 0) > model.cfg.now then
		table.insert(children, line({ t("对话还在继续，停一会儿再判断。", "muted") }))
	elseif not judgment and not item.disposition then
		local why = if s == "manual" then "按设置，这条不交给 AI 分析。"
			elseif not model.cfg.settings.agent_enabled then "自动分析已关闭。"
			else "这条消息还没有分析，选中后会排队。"
		table.insert(children, line({ t(why, "muted") }))
	end
	return ui.node("col", { key = "analysis", role = "fl.summary", gap = "sm" }, children)
end

local function correction(model: any, kind: string?): any
	local label = if kind == "deep" then "让 AI 改判断、任务说明或执行 Workspace，不会开始任务"
		elseif kind == "reply" then "让 AI 改这条回复或判断"
		else "让 AI 调整判断"
	local placeholder = if kind == "reply" then "例如：语气正式一点；或者这条要深入处理"
		elseif kind == "deep" then "例如：只读排查；改在 /绝对路径 执行；改回默认目录"
		else "例如：不用深入，回一句就行"
	return ui.node("col", { key = "correction", role = "fl.correction", gap = "sm" }, {
		line({ t(label, "muted") }),
		ui.node("row", { key = "input", role = "fl.correction.row", gap = "sm" }, {
			ui.node("input", {
				key = "field", role = "fl.command", text = model.command, cursor = model.command_cursor,
				placeholder = placeholder,
			}),
			ui.button("发送", { key = "run", variant = "quiet", actions = { click = "run-command" }, busy = model.talking ~= nil }),
		}),
	})
end

local function primary_button(item: any, variant: string): any
	local action = status.next_action(item)
	local props: any = {
		key = "primary", role = "fl.primary", variant = variant, actions = { click = "primary" },
		disabled = action.key == "none", busy = item.preparing ~= nil,
	}
	if status.needs_confirm(item) then
		-- Deliberately no shortcut: a stray `a` must not start this task.
		props.actions = { click = "confirm-task" }
		return ui.button("确认并开始任务", props)
	end
	props.keys = { "a" }
	return ui.button(action.label, props)
end

local function task_card(model: any, item: any, facts: any): any
	local s = status.of(item)
	local children: { any } = {}
	if item.task and item.task.workspace then
		table.insert(children, line({ t("执行 Workspace：", "muted"), t(short_path(model, item.task.workspace), "path") }, { key = "workspace" }))
	end
	local function head(title: string)
		table.insert(children, line({ t(title, "strong") }, { key = "head", role = "fl.task.title" }))
	end
	local function buttons(...)
		table.insert(children, ui.node("row", { key = "actions", role = "fl.actions", gap = "sm", wrap = true }, { ... }))
	end
	if s == "task_done" then
		head("任务本轮结果 · 请核对")
		table.insert(children, line({ t("这是任务里 AI 的原话。本轮结束不代表任务完成。", "muted") }))
		local result = item.task and item.task.result
		if result and string.find(result, "%S") then
			table.insert(children, line(result, { key = "result", role = "fl.result" }))
		else
			table.insert(children, line({ t("这一轮没有文字结果，请到任务页查看。", "muted") }))
		end
		buttons(
			primary_button(item, "primary"),
			ui.button("确认完成并归档", { key = "archive", variant = "quiet", keys = { "x" }, actions = { click = "archive" } })
		)
	elseif s == "task_waiting" then
		head("任务在等你回复")
		table.insert(children, line("问题在任务页里，回答也在那里进行。"))
		buttons(primary_button(item, "primary"))
	elseif s == "task_closed" then
		head("任务页已关闭")
		table.insert(children, line("任务可能没做完。可以重新打开，或者确认后归档。"))
		buttons(primary_button(item, "primary"))
	else
		head(if s == "task_starting" then "任务启动中" else "任务执行中")
		table.insert(children, line("不用在这里等。任务需要你回复或本轮结束时，这条会回到「待处理」。"))
		table.insert(children, line({ t("要补充要求，到任务页里说。这里的内容到不了正在运行的任务。", "muted") }))
		buttons(primary_button(item, "quiet"))
	end
	if item.task and item.task.new_messages > 0 then
		table.insert(children, line({ t("任务开始后又有 " .. tostring(item.task.new_messages) .. " 条新消息，不会自动发到任务里。需要的话到任务页里补充。", "warning") }, { key = "task-new" }))
	end
	if s ~= "task_done" and status.kind(item) == "deep" and string.find(facts.draft, "%S") then
		table.insert(children, folded("scope", "执行中的任务", { line(facts.draft, { role = "fl.plan" }) }))
	end
	return ui.node("col", { key = "reply", role = "fl.task", gap = "md" }, children)
end

local function next_block(model: any, item: any, facts: any): any
	if item.disposition == "doing" then
		return task_card(model, item, facts)
	end
	local s = status.of(item)
	local settled = status.settled(item)
	local kind = status.kind(item)
	local editable = kind == "deep" or kind == "reply"
	local title = if settled then status.LABELS[s][1]
		elseif kind == "deep" then "需要深入处理"
		elseif kind == "reply" then (if s == "handoff" then "待你发送" else "回复给 " .. item.name)
		else "下一步"
	local children: { any } = { line({ t(title, "strong") }, { key = "head", role = "fl.task.title" }) }
	local stale = status.stale(item)
	if stale then
		table.insert(children, line({ t("有新消息。下面是上次的判断，新的判断出来前不能使用。", "warning") }, { key = "stale" }))
	end
	if editable and not settled then
		-- Keep this direct child and editable: clicks emit focus for draft edit mode.
		table.insert(children, ui.node("editor", {
			key = "draft", role = "fl.draft", text = facts.draft, cursor = model.draft_cursor,
			readonly = stale, maxLines = 7,
			placeholder = if kind == "deep" then "任务说明" else "回复内容",
		}))
		if kind == "deep" then
			local workspace = status.task_workspace(item)
			local default = model.cfg.settings.workspace
			local display = if workspace ~= "" then workspace elseif default ~= "" then default else "插件数据目录"
			table.insert(children, line({ t("执行 Workspace：", "muted"), t(short_path(model, display), "path"),
				t(if workspace == "" then "（默认）" else "", "muted") }, { key = "workspace", role = "fl.workspace" }))
			table.insert(children, line({ t("可在下方对话修改执行目录；开始任务即确认此目录和上面的任务说明。", "muted") }))
		end
	elseif settled then
		if string.find(facts.draft, "%S") then
			table.insert(children, line(facts.draft, { key = "draft-text", role = "fl.plan" }))
		end
	else
		local why = if s == "running" or s == "queued" then "判断完成后，这里会出现下一步。"
			elseif s == "failed" then "可以重试分析，或者自己手写回复。"
			elseif kind == "fyi" then detail.why(item) or "这条不用处理。"
			else "可以自己手写回复。"
		table.insert(children, line({ t(why, "muted") }))
	end
	if not settled and kind ~= "deep" then
		local workspace = status.task_workspace(item)
		local default = model.cfg.settings.workspace
		local display = if workspace ~= "" then workspace elseif default ~= "" then default else "插件数据目录"
		table.insert(children, line({ t("手动任务 Workspace：", "muted"), t(short_path(model, display), "path"),
			t(if workspace == "" then "（默认）" else "", "muted") }, { key = "workspace", role = "fl.workspace" }))
		table.insert(children, line({ t("可在下方对话修改目录；手动开任务会使用此目录。", "muted") }))
	end
	if stale then
		-- The notice above replaces actions on the previous judgment.
	elseif kind == "deep" and not settled and status.needs_confirm(item) then
		table.insert(children, ui.node("col", { key = "risk", role = "fl.risk", gap = "xs" }, {
			line({ t(if item.task_workspace_unconfirmed then "旧任务目录无法安全迁移，请重新确认上面的执行 Workspace。" else "对方要的动作：" .. item.analysis.judgment.risk, "warning strong") }),
			line({ t("上面的要求只是任务说明，不是权限限制。任务按项目配置运行，有权限时可能真的执行。", "muted") }),
		}))
	elseif kind == "deep" and not settled then
		table.insert(children, line({ t("确认后在新的任务页运行，开始前可以先改。", "muted") }))
	end
	if item.spoken then
		table.insert(children, line({
			t(if item.disposition == "handoff" then "可能已回复，待你确认：" else "已记录的回复：", "muted"),
			item.spoken,
		}, { key = "spoken", role = "fl.spoken" }))
		if item.disposition == "handoff" then
			table.insert(children, ui.node("row", { key = "confirm" }, {
				ui.button("确认这是我的回复", { key = "reply", actions = { click = "confirm-reply" } }),
			}))
		end
	end
	if not settled then
		local buttons: { any } = {}
		if status.next_action(item).key ~= "none" or item.preparing ~= nil then
			table.insert(buttons, primary_button(item, "primary"))
		end
		if s ~= "running" and not stale then
			table.insert(buttons, ui.button(if kind == "deep" then "修改要求" elseif editable then "修改" else "手写回复", { key = "edit", variant = "quiet", keys = { "e" }, actions = { click = "edit" } }))
		end
		if not editable then
			local judgment = item.analysis.judgment
			if s == "manual" or (judgment and judgment.manual) then
				table.insert(buttons, ui.button("让 AI 分析", { key = "force", variant = "quiet", keys = { "g" }, actions = { click = "force" } }))
			end
			table.insert(buttons, ui.button("手动开任务", { key = "omp", variant = "quiet", keys = { "o" }, title = "不按 AI 的判断，带上这条消息开一个任务页，等你下指令", actions = { click = "open-task" } }))
		end
		table.insert(children, ui.node("row", { key = "actions", role = "fl.actions", gap = "sm", wrap = true }, buttons))
	end
	if status.can_adjust(item) then
		table.insert(children, correction(model, kind))
	end
	return ui.node("col", { key = "reply", role = "fl.task", gap = "md" }, children)
end

local function conversation(model: any, item: any): any
	local children = {}
	for _, entry in item.talk do
		table.insert(children, line({
			t(if entry.me then "你  " else "AI  ", if entry.me then "accent" else "info"), entry.text,
		}, { role = "fl.talk" }))
	end
	if model.talking == item.id then
		table.insert(children, line({ t("AI 正在回答…", "info") }))
	end
	return ui.node("col", { key = "conversation", role = "fl.conversation", gap = "sm" }, children)
end

function detail.render(model: any, facts: any, wide: boolean): any
	local item = facts.item
	local children = {}
	if item then
		table.insert(children, analysis_block(model, item))
		if not wide then
			table.insert(children, thread.quote(model, item))
		end
		table.insert(children, next_block(model, item, facts))
		local why = detail.why(item)
		if not wide and why and status.kind(item) ~= "fyi" then
			table.insert(children, folded("why", "判断理由", { line(why, { role = "fl.context.text" }) }))
		end
		if not wide then
			local record = detail.record(model, item)
			if record then
				table.insert(children, record)
			end
		end
		if status.kind(item) == "deep" and not item.disposition and string.find(facts.reply_draft, "%S") then
			table.insert(children, folded("quick-reply", "先回一句", {
				line(facts.reply_draft, { role = "fl.quick.reply" }),
				ui.button("复制回复", { key = "copy", size = "sm", variant = "quiet", keys = { "c" }, actions = { click = "copy" } }),
			}))
		end
		table.insert(children, conversation(model, item))
	else
		table.insert(children, line({ t("选择队列里的一条消息，查看判断和下一步。", "muted") }, { role = "fl.empty" }))
	end
	return ui.node("col", { key = "right", role = "fl.detail", gap = "lg" }, children)
end

return detail
