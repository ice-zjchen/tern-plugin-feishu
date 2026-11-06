-- Native interaction draft only. Fictional data, no Feishu / OMP / approval calls.
-- Information order: what was asked -> what omp may do -> one next action.
-- Every field below exists today, except `risk`, which needs one new analysis output field.
local tern = require("tern")
local ui = tern.ui
local function s(value, token) return ui.span(value, token) end
local function text(value, key, role)
	return ui.node("text", {key=key, role=role, spans=if type(value)=="string" then {value} else value})
end
local function row(key, children, props)
	local p=props or {}; p.key=key
	return ui.node("row", p, children)
end
local function button(label, action, props)
	local p=props or {}; p.actions={click=action}
	return ui.button(label,p)
end
local function section(key, title, children, collapsed, meta)
	local node=ui.section(title,children)
	node.p=node.p or {}
	node.p.key=key
	node.p.collapsed=collapsed
	node.p.collapsible=true
	node.p.meta=meta
	return node
end
-- How many messages the side column shows before it hands over to the modal.
local INLINE_MESSAGES = 4
local cases = {
	{ title="陈工请你通过发布单 4839，今天要灰度", name="陈工", chat="发布需求群", time="14:32", kind="task", stage="attention", reason="待交办",
		why="请求的是通过发布单，但消息只说明配置已提交，影响范围和发布条件还没有核验。",
		risk="通过发布单",
		plan="核验发布单 4839 的配置变更与影响范围，把结论和不确定的地方告诉我。不要把“已提交”当作“已发布”，不要自行通过这张单。",
		result="查询了发布单 4839，页面上可见的发布条件都已满足。\n影响范围没有确认：变更说明里没有列出受影响的集群。\n没有通过这张单。",
		thread={
			{name="刘工", time="14:20", text="切换方案已确认，配置已经提交。请结合发布单中的变更内容核验，影响范围不清楚的地方先确认，不要把“已提交”当作“已发布”。"},
			{name="陈工", time="14:32", text="@我 帮忙通过这张发布单，灰度今天要上。", hit=true},
		} },
	{ title="确认周五前能否交付", name="周工", chat="私聊", time="13:05", kind="reply", stage="attention", reason="待回复",
		why="对方要安排联调，在等你的时间承诺。没有把握时，先给出明确的反馈时间。",
		draft="我先确认剩余工作量，今天下班前给你一个明确时间。",
		thread={{name="周工", time="13:05", text="这周五前能交付吗？我需要安排联调。", hit=true}} },
	{ title="合并请求被分支冲突阻塞", name="李工", chat="日常协作群", time="14:11", kind="task", stage="attention", reason="待交办",
		why="需要读代码才能判断冲突如何解决，回一句解决不了。",
		plan="检查这条合并请求的冲突与变更背景，给出修复方案。涉及不明确的业务取舍时询问我。",
		quick="在看了，核验后同步结果。",
		thread={
			{name="赵工", time="13:40", text="这条合并请求今天能进主干吗？测试环境在等。"},
			{name="李工", time="13:46", text="本地跑过了，CI 也是绿的。"},
			{name="赵工", time="13:52", text="那就等评审了。"},
			{name="孙工", time="14:02", text="我这边刚合了配置中心的改动，可能会碰到同一个文件。"},
			{name="李工", time="14:08", text="确实冲突了，集中在路由配置和两个测试文件。"},
			{name="孙工", time="14:09", text="路由那块以我的为准，但测试你得看一下。"},
			{name="李工", time="14:11", text="分支有冲突，rebase 后才能合入，帮忙看一下。", hit=true},
		} },
	{ title="线上登录又报错，怀疑与上周改动有关", name="王工", chat="私聊", time="11:47", kind="blocked", stage="attention", reason="omp 等你",
		why="需要查日志和近期变更才能定位，回一句解决不了。",
		plan="定位登录失败的原因，核验近期变更与错误日志。",
		thread={{name="王工", time="11:47", text="登录又报错了，怀疑跟上周的改动有关。", hit=true}} },
	{ title="梳理回调重试的异常路径", name="刘工", chat="服务端协作群", time="11:20", kind="task", stage="working", reason="omp 执行中",
		why="需要读代码才能回答，回一句解决不了。",
		plan="梳理回调重试的异常路径，定位缺少兜底的环节。",
		thread={{name="刘工", time="11:20", text="看一下回调重试失败后的处理逻辑。", hit=true}} },
	{ title="下周分享材料，周一再看", name="吴工", chat="团队通知群", time="10:20", kind="reply", stage="later", reason="稍后处理",
		why="不紧急，周一再看也来得及。",
		draft="周一看完后给你反馈。",
		thread={{name="吴工", time="10:20", text="下周分享材料已更新，有空帮忙看一下。", hit=true}} },
	{ title="确认灰度范围", name="林工", chat="灰度讨论群", time="09:40", kind="reply", stage="done", reason="已回复",
		why="你已确认回复并归档。",
		draft="按确认的范围推进。",
		thread={{name="林工", time="09:40", text="确认本轮灰度的覆盖范围。", hit=true}} },
}
local function current(state) return state.items[state.selected] end
local function visible(state)
	local found={}
	for i,item in state.items do
		if item.stage==state.view and (state.source=="all" or (state.source=="dm" and item.chat=="私聊") or (state.source=="mention" and item.chat~="私聊")) then
			table.insert(found,i)
		end
	end
	return found
end
local function select_first(state)
	local list=visible(state)
	if not table.find(list,state.selected) then state.selected=list[1] end
	state.editing=false
end
local function list_panel(state)
	local entries={}
	for _,i in visible(state) do
		local item=state.items[i]
		table.insert(entries,ui.node("col",{key="m"..i,role=if i==state.selected then "review.item.selected" else "review.item",title=item.title,gap="xs",actions={click="select="..i}}, {
			row("headline", {text(item.title,"title","review.item.title"),text({s(item.time,"muted")},"time","review.item.time")},{justify="between",gap="sm"}),
			row("meta", {text({s(item.name.." · "..item.chat,"muted")},"sender","review.item.sender"),text({s(item.reason,if item.kind=="blocked" or item.kind=="result" then "warning" else "muted")},"reason","review.item.reason")},{justify="between",gap="sm"}),
		}))
	end
	if #entries==0 then table.insert(entries,text({s("这里暂时没有需要处理的事项。","muted")},"empty")) end
	local filters={}
	for _,entry in {{"all","全部"},{"mention","@我"},{"dm","私聊"}} do
		table.insert(filters,button(entry[2],"source="..entry[1],{key=entry[1],size="sm",variant="quiet",on=state.source==entry[1]}))
	end
	return ui.node("col",{key="queue",role="review.queue",gap="none"}, {
		row("filters",filters,{role="review.filters",gap="sm"}),
		ui.node("scroll",{key="items",role="review.items",grow=1},entries),
		row("quiet", {text({s("可忽略 2 条","muted")},"ignored"),button("查看","ignored",{key="show",size="sm",variant="quiet"})},{role="review.queue.foot",justify="between"}),
	})
end

-- One message of the conversation. The message that put this item in the queue stands out.
local function message(key, entry)
	return ui.node("col",{key=key,role=if entry.hit then "review.msg.hit" else "review.msg",gap="xs"},{
		row("head",{text({s(entry.name,"strong")},"name"),text({s(entry.time,"muted")},"time")},{justify="between",gap="sm"}),
		text(entry.text,"body","review.msg.text"),
	})
end
local function conversation_scope(item)
	return item.chat.." · 触发消息及其上下文"
end
-- The side column shows the conversation itself, so it can be read beside the plan.
-- Only a conversation too long for it gets the modal, and only then the button.
local function background(state,item)
	local total=#item.thread
	local first=math.max(1,total-INLINE_MESSAGES+1)
	local children={
		row("messages-head",{
			text({s("原始对话","strong")},"title"),
			if total>INLINE_MESSAGES then button("较早 "..tostring(first-1).." 条","inspect=conversation",{key="open",size="sm",variant="quiet"}) else nil,
		},{justify="between",gap="sm"}),
		text({s(conversation_scope(item),"muted")},"scope"),
	}
	for i=first,total do
		table.insert(children,message("msg"..i,item.thread[i]))
	end
	table.insert(children,ui.rule(""))
	table.insert(children,text({s("判断理由","strong")},"why-title"))
	table.insert(children,text(item.why,"why","review.context.text"))
	table.insert(children,ui.rule(""))
	table.insert(children,row("environment-head",{
		text({s("运行环境","strong")},"title"),
		button("查看","inspect=environment",{key="open",size="sm",variant="quiet"}),
	},{justify="between",gap="sm"}))
	table.insert(children,text({s("work-os","path"),s(" · 沿用项目策略","muted")},"environment"))
	return ui.node("col",{key="context",role="review.context",gap="lg"},children)
end

local function inspection(state)
	if not state.dialog then return nil end
	local item=state.items[state.dialog.item]
	local kind=state.dialog.kind
	local title=if kind=="conversation" then "原始对话" else "运行环境"
	local content={
		button("关闭","close-inspection",{key="close",variant="quiet",keys={"esc"}}),
	}
	if kind=="conversation" then
		table.insert(content,text({s(conversation_scope(item).." · "..tostring(#item.thread).." 条","muted")},"scope"))
		for i,entry in item.thread do
			table.insert(content,message("msg"..i,entry))
		end
	else
		table.insert(content,ui.kv({
			{{s("Workspace","muted")},{s("~/work-os","path")}},
			{{s("工具与权限","muted")},{"沿用项目配置"}},
			{{s("本稿行为","muted")},{"仅展示交互，不执行任务或访问业务系统"}},
		}))
	end
	return ui.col({ui.node("overlay",{
		key="inspection",head=title,meta={s(item.name.." · "..item.chat,"muted")},size="lg",modal=true,
		["end"]="layer.inspection.close",
	},content)})
end

-- Talks to the analysis session, which can change the judgment, the draft and the task.
-- It cannot reach a running omp tab, so states with a task in a tab don't offer it.
local function adjust(key, label, placeholder)
	return ui.node("col",{key=key,role="review.adjust",gap="sm"},{
		text({s(label,"muted")},"label"),
		row("input",{
			ui.node("input",{key="field",role="review.adjust.field",text="",placeholder=placeholder}),
			button("发送","adjust",{key="send",variant="quiet"}),
		},{gap="sm"}),
	})
end
local function has_adjust(item)
	return item.stage=="attention" and (item.kind=="task" or item.kind=="reply") or item.stage=="later"
end
local function main_action(state,item)
	local children={}
	local title
	if item.stage=="done" then
		title="已处理"
		table.insert(children,text(item.why,"done"))
		table.insert(children,button("重新放回待处理","reopen",{key="reopen",variant="quiet"}))
	elseif item.kind=="reply" then
		title="回复给 "..item.name
		table.insert(children,ui.node("editor",{key="draft",text=item.draft,readonly=not state.editing,maxLines=4,role="review.editor"}))
		table.insert(children,row("actions",{button("复制并去回复","copy",{key="copy",variant="primary",keys={"a"}}),button("修改","edit",{key="edit",variant="quiet",keys={"e"}})},{gap="sm",wrap=true}))
		if item.possible_reply then
			table.insert(children,text({s("示例：检测到可能的回复，核对后再标记完成。","warning")},"candidate"))
			table.insert(children,button("确认已回复","complete",{key="confirm",variant="quiet"}))
		end
		table.insert(children,ui.rule(""))
		table.insert(children,adjust("adjust","让 omp 改这条回复","例如：语气正式一点，并说明周四前给时间"))
	elseif item.kind=="blocked" then
		title="omp 在等你"
		table.insert(children,text("它的问题在 omp tab 里，回答也在那里进行。","question"))
		table.insert(children,button("到 omp 回答","jump",{key="resume",variant="primary",keys={"a"}}))
		table.insert(children,section("scope","已交办的任务",{text(item.plan,"plan","review.plan")},true))
	elseif item.kind=="result" then
		title="omp 本轮结果 · 请核对"
		table.insert(children,text({s("这是 omp 的原话。本轮结束不代表任务完成。","muted")},"note"))
		table.insert(children,text(item.result,"result","review.result"))
		table.insert(children,row("actions",{button("继续到 omp","resume",{key="continue",variant="primary",keys={"a"}}),button("确认完成并归档","complete",{key="complete",variant="quiet"})},{gap="sm",wrap=true}))
	elseif item.stage=="working" then
		title="omp 正在处理"
		table.insert(children,text("不需要留在这里等待。omp 等你，或本轮结束时，这条会回到「需要我」。","why"))
		table.insert(children,text({s("要补充要求，到 omp tab 里说。这里的内容到不了正在运行的任务。","muted")},"where"))
		table.insert(children,button("跳到 omp","jump",{key="back",variant="quiet",keys={"a"}}))
		table.insert(children,section("scope","已交办的任务",{text(item.plan,"plan","review.plan")},true))
	else
		title="交给 omp 处理"
		if state.editing then
			table.insert(children,ui.node("editor",{key="plan",text=item.plan,readonly=false,maxLines=5,role="review.editor"}))
		else
			table.insert(children,text(item.plan,"plan","review.plan"))
		end
		if item.risk then
			-- No shortcut on purpose: a stray `a` must not start this one.
			table.insert(children,ui.node("col",{key="risk",role="review.risk",gap="xs"},{
				text({s("对方要的动作：","warning"),s(item.risk,"warning strong")},"action"),
				text({s("上面的要求只是任务说明，不是权限限制。omp 按项目配置运行，有权限时可能真的执行。","muted")},"limit"),
			}))
		end
		local go=if item.risk then {key="go",variant="primary"} else {key="go",variant="primary",keys={"a"}}
		table.insert(children,row("actions",{button(if item.risk then "确认，交给 omp" else "交给 omp","handoff",go),button("修改要求","edit",{key="edit",variant="quiet",keys={"e"}}),button("自己处理","self",{key="self",variant="quiet"})},{gap="sm",wrap=true}))
		table.insert(children,ui.rule(""))
		table.insert(children,adjust("adjust","让 omp 改判断或任务说明，不会启动任务","例如：不用深入，回一句就行"))
	end
	return ui.card(title,children,{key="next",role="review.next"})
end
local function workspace(state,cx)
	local item=current(state)
	if not item then return ui.node("col",{key="workspace",role="review.workspace"},{text({s("当前没有需要你处理的事项。","muted")},"empty")}) end
	local children={
		text({s(item.title,"title strong")},"title","review.title"),
		row("top",{text({s(item.name.." · "..item.chat.." · "..item.time,"muted")},"byline","review.byline"),row("tools",{button("稍后","later",{key="later",size="sm",variant="quiet"}),button("归档","complete",{key="archive",size="sm",variant="quiet"})},{gap="sm"})},{justify="between",gap="md",wrap=true}),
	}
	-- Without the side column, what was asked stays on screen: never hand off blind.
	if cx.cols<170 then
		local trigger=item.thread[#item.thread]
		table.insert(children,ui.node("col",{key="quote",role="review.quote",gap="xs"},{
			text(trigger.text,"body","review.msg.text"),
			if #item.thread>1 then button("查看全部 "..tostring(#item.thread).." 条对话","inspect=conversation",{key="conversation",size="sm",variant="quiet"}) else nil,
		}))
	end
	table.insert(children,main_action(state,item))
	if cx.cols<170 then
		table.insert(children,section("why","判断理由",{text(item.why,"why","review.context.text")},true))
	end
	if item.quick and item.stage=="attention" and item.kind=="task" then
		table.insert(children,section("quickreply","先回一句",{text(item.quick,"draft"),button("复制回复","copy",{key="copy",variant="quiet",size="sm"})},true))
	end
	return ui.node("col",{key="workspace",role="review.workspace",gap="none"},{
		ui.node("scroll",{key="scroll",role="review.main.scroll",grow=1},{ui.node("col",{key="reading",role="review.reading",gap="md"},children)}),
	})
end
tern.block.define("review",{
	font="sans",features={"edit"},
	init=function() return {items=cases,selected=1,view="attention",source="all",dialog=nil,editing=false,flash="评审稿 · 示例数据，不连接业务服务"} end,
	title=function() return "飞书 · 事项工作台稿" end,
	view=function(state,cx)
		local tabs={}
		for _,entry in {{"attention","需要我"},{"working","处理中"},{"later","稍后"},{"done","已处理"}} do
			local n=0; for _,item in state.items do if item.stage==entry[1] then n+=1 end end
			table.insert(tabs,button(entry[2].." "..n,"view="..entry[1],{key=entry[1],variant="quiet",on=state.view==entry[1]}))
		end
		local parts={list_panel(state),workspace(state,cx)}
		if current(state) and cx.cols>=170 then table.insert(parts,background(state,current(state))) end
		local item=current(state)
		local keys=if item and has_adjust(item) then "j/k 选择   a 下一步   e 修改   / 让 omp 调整" else "j/k 选择   a 下一步"
		return {
			main=ui.node("col",{role="review.root",gap="none"},{
				row("bar",{row("tabs",tabs,{gap="sm"}),row("tools",{button("刷新","refresh",{key="refresh",size="sm",variant="quiet"}),button("设置","settings",{key="settings",size="sm",variant="quiet"})},{gap="sm"})},{role="review.bar",justify="between",wrap=true}),
				ui.node(if cx.cols<110 then "col" else "row",{key="body",role=if cx.cols<110 then "review.body.stack" else "review.body",gap="none",align="stretch"},parts),
			}),
			dock=row("foot",{text({s(state.flash,"muted")},"flash"),text({s(keys,"muted")},"keys")},{role="review.footer",justify="between",gap="md",wrap=true}),
			layer=inspection(state),
		}
	end,
	event=function(state,ev,cx)
		local item=current(state)
		if state.dialog then
			if ev.ev=="action" and ev.act=="close-inspection" then state.dialog=nil end
			return
		end
		if ev.ev=="action" then
			if ev.act=="select" then state.selected=tonumber(ev.value);state.editing=false
			elseif ev.act=="view" then state.view=ev.value;select_first(state)
			elseif ev.act=="source" then state.source=ev.value;select_first(state)
			elseif item and ev.act=="inspect" then state.dialog={kind=ev.value,item=state.selected}
			elseif ev.act=="edit" then state.editing=not state.editing
			elseif item and ev.act=="handoff" then item.stage="working";item.kind="task";item.reason="omp 执行中";state.view="working";state.flash="预览交办状态 · 未启动真实 omp"
			elseif item and (ev.act=="jump" or ev.act=="resume") then state.flash="预览跳转 · 真实版本打开这条的 omp tab"
			elseif ev.act=="adjust" then state.flash="预览 · 真实版本发给分析会话，更新判断、回复稿或任务说明"
			elseif item and ev.act=="complete" then item.stage="done";state.flash="已在稿件中标为处理完成";select_first(state)
			elseif item and ev.act=="later" then item.stage="later";select_first(state)
			elseif item and ev.act=="reopen" then item.stage="attention";state.view="attention"
			elseif item and ev.act=="copy" then item.possible_reply=true;state.flash="演示回复交接；未访问飞书或剪贴板"
			elseif item and ev.act=="self" then state.dialog={kind="conversation",item=state.selected}
			else state.flash="评审稿 · 此操作未连接真实服务" end
		elseif ev.ev=="edit" then state.flash="演示编辑要求，不执行任务" end
	end,
	key=function(state,key)
		if state.dialog then
			if key.name=="escape" then state.dialog=nil end
			return true
		end
		local k=key.text or key.name
		if k=="1" then state.view="attention";state.source="all";state.selected=1;state.items[1].stage="attention";state.items[1].kind="task";state.items[1].reason="待交办"
		elseif k=="2" then state.view="attention";state.source="all";state.selected=2
		elseif k=="3" then state.view="attention";state.source="all";state.selected=4;state.items[4].stage="attention";state.items[4].kind="blocked";state.items[4].reason="omp 等你"
		elseif k=="4" then state.view="working";state.source="all";state.selected=5
		elseif k=="5" then state.view="attention";state.source="all";state.selected=1;state.items[1].stage="attention";state.items[1].kind="result";state.items[1].reason="本轮结束 / 待确认"
		elseif k=="6" then state.view="attention";state.source="all";state.selected=3
		elseif k=="j" or k=="k" then local list=visible(state);local at=table.find(list,state.selected) or 1;state.selected=list[math.clamp(at+(if k=="j" then 1 else -1),1,math.max(1,#list))]
		elseif k=="e" then state.editing=not state.editing
		else return false end
		return true
	end,
})
