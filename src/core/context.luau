--!strict
-- A context plan describes missing data, not semantic/topic similarity. Native
-- judge probabilities are evidence, not calibrated accuracy or an authorization.
local context = {}
export type Plan = "none" | "message" | "conversation" | "unknown"
export type Need = "required" | "not_required" | "unknown"
export type Choice = { choice: Need, probabilities: { [string]: number }? }
export type Answer = { plan: Plan, materials: Choice, discussion: Choice }

function context.use_vision(evidence: { any }): boolean
	for _, entry in evidence do
		if entry.selected == true then return true end
	end
	return false
end

local function resolved(materials: Choice, discussion: Choice): Answer
	local plan: Plan = if materials.choice == "unknown" or discussion.choice == "unknown" then "unknown"
		elseif discussion.choice == "required" then "conversation"
		elseif materials.choice == "required" then "message" else "none"
	return { plan = plan, materials = materials, discussion = discussion }
end

local function parse_choice(value: any, name: string): (Choice?, string?)
	if type(value) ~= "table" or value.type ~= "choice"
		or (value.choice ~= "required" and value.choice ~= "not_required" and value.choice ~= "unknown") then
		return nil, "判断工具返回了无效的 " .. name .. " 需求"
	end
	if type(value.probabilities) ~= "table" then return nil, name .. " 判断没有返回选择概率" end
	local total = 0
	for _, key in { "required", "not_required", "unknown" } do
		local p = value.probabilities[key]
		if type(p) ~= "number" or p ~= p or p < 0 or p > 1 then return nil, name .. " 选择概率无效" end
		total += p
	end
	if math.abs(total - 1) > 0.02 then return nil, name .. " 选择概率之和无效" end
	return { choice = value.choice, probabilities = table.clone(value.probabilities) }, nil
end

function context.parse(value: any): (Answer?, string?)
	if type(value) ~= "table" then return nil, "判断工具没有返回材料和讨论需求" end
	local materials, material_error = parse_choice(value.materials, "materials")
	if not materials then return nil, material_error end
	local discussion, discussion_error = parse_choice(value.discussion, "discussion")
	if not discussion then return nil, discussion_error end
	return resolved(materials, discussion), nil
end

-- Vision returns explicit requirements, not native judge distributions. Do not
-- invent confidence/probability values for a model's textual assessment.
function context.from_vision(value: any): (Answer?, string?)
	if type(value) ~= "table" then return nil, "视觉判断未返回材料与讨论需求" end
	for _, key in { "materials", "discussion" } do
		if value[key] ~= "required" and value[key] ~= "not_required" and value[key] ~= "unknown" then
			return nil, "视觉判断返回了无效的 " .. key .. " 需求"
		end
	end
	return resolved({ choice = value.materials }, { choice = value.discussion }), nil
end

-- A locator scopes retrieval; it never proves the located contents are known.
function context.has_locator(task: string, message_id: string): boolean
	if message_id == "" then return false end
	local offset = 1
	while true do
		local first, last = string.find(task, message_id, offset, true)
		if not first or not last then return false end
		local before = if first > 1 then string.sub(task, first - 1, first - 1) else ""
		local after = string.sub(task, last + 1, last + 1)
		if not string.find(before, "[%w_-]") and not string.find(after, "[%w_-]") then return true end
		offset = last + 1
	end
end

function context.blocker(answer: Answer, evidence_array: { any }): string?
	if answer.plan == "unknown" then
		return "仍无法确定任务的材料或讨论需求；请明确缺少的内容，不会自动扩大聊天检索。"
	end
	if answer.materials.choice == "required" then
		for _, evidence in evidence_array do
			if evidence.selected ~= false and evidence.status ~= "inspected" then
				return "任务需要材料，但相关图片未能读取并核实；请提供可读图片或其内容后重试。"
			end
		end
	end
	return nil
end

return context
