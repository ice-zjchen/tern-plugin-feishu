--!strict
local t = require("./t")
local sources = require("../src/core/image_sources")

t.test("trigger images are selected without unrelated thread pictures", function()
	local list = sources.describe({ id = "om_current", content = "[Image: img_current]", thread = {
		{ id = "om_other", content = "![Image](img_other)" },
		{ id = "om_current", content = "[Image: img_current]" },
	} }, "处理原消息")
	t.eq(#list, 2); t.eq(list[1].source_message_id, "om_current")
	t.eq(list[1].selected, true); t.eq(list[2].selected, false)
end)

t.test("an explicit older locator selects that picture rather than the latest", function()
	local list = sources.describe({ id = "om_current", content = "消息", thread = {
		{ id = "om_old", content = "[Image: img_old]" },
		{ id = "om_new", content = "[Image: img_new]" },
	} }, "查看 om_old 的截图")
	t.eq(list[1].selected, true); t.eq(list[2].selected, false)
end)

t.test("unreferenced pictures do not send an independent text task to vision", function()
	local list = sources.describe({ id = "om_current", content = "消息", thread = {
		{ id = "om_picture", content = "[Image: img_old]" },
	} }, "审查明确 MR")
	t.eq(list[1].selected, false)
	local recent = sources.describe({ id = "om_current", content = "消息", thread = {
		{ id = "om_old", content = "[Image: img_old]" },
		{ id = "om_new", content = "[Image: img_new]" },
	} }, "解释上面的截图")
	t.eq(recent[1].selected, false); t.eq(recent[2].selected, true)
end)

t.done()
