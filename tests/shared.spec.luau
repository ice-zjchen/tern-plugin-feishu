--!strict
local t = require("./t")
local text = require("../src/shared/text")
local template = require("../src/shared/template")
local time = require("../src/shared/time")
local markup = require("../src/shared/markup")

t.test("markup finds unique image keys up to the limit and cleans them", function()
	local s = "a ![Image](img_1) b ![x](img_2) ![Image](img_1) ![y](img_3)"
	local keys = markup.images(s, 2)
	t.eq(#keys, 2)
	t.eq(keys[1], "img_1")
	t.eq(keys[2], "img_2")
	t.eq(markup.clean("hi ![Image](img_1)"), "hi [图片]")
end)

t.test("CLI image labels and Markdown preserve shared source order without bare-key guesses", function()
	local s = "[Image: img_first] ![Image](img_second) [Image: img_first] [Image: img_third] bare img_not_resource"
	local keys = markup.images(s, 3)
	t.eq(keys[1], "img_first"); t.eq(keys[2], "img_second"); t.eq(keys[3], "img_third")
	t.eq(#keys, 3)
	t.eq(markup.clean(s), "[图片] [图片] [图片] [图片] bare img_not_resource")
	t.eq(#markup.images("img_not_resource", 4), 0)
end)

t.test("markup.mentions_all recognises every CLI form", function()
	t.eq(markup.mentions_all("@_all 开会"), true)
	t.eq(markup.mentions_all('<at user_id="all">所有人</at>'), true)
	t.eq(markup.mentions_all("@everyone"), true)
	t.eq(markup.mentions_all("@张三"), false)
end)

-- text: UTF-16 offsets around astral characters (an emoji is two code units).
t.test("text.len counts UTF-16 code units", function()
	t.eq(text.len("a中😀"), 4)
end)

t.test("text.key edits around a surrogate pair", function()
	local field = { text = "a😀b", cursor = 3 }
	t.eq(text.key(field, { name = "backspace" }), true)
	t.eq(field.text, "ab")
	t.eq(field.cursor, 1)
	text.key(field, { name = "paste", text = "中" })
	t.eq(field.text, "a中b")
	t.eq(field.cursor, 2)
end)

t.test("text.key ignores modified and control keys", function()
	local field = { text = "x", cursor = 1 }
	t.eq(text.key(field, { name = "c", text = "c", meta = true }), false)
	t.eq(text.key(field, { name = "enter" }), false)
	t.eq(field.text, "x")
end)

t.test("text.fit cuts by display cells", function()
	t.eq(text.fit("  中文  标题  ", 20), "中文 标题")
	t.eq(text.fit("中文中文中文", 5), "中文…")
end)

t.test("text.is_chat_link allows only Feishu/Lark chat applinks", function()
	t.eq(text.is_chat_link("https://applink.feishu.cn/client/chat/open?openChatId=x"), true)
	t.eq(text.is_chat_link("https://applink.larksuite.com/client/chat/open?x"), true)
	t.eq(text.is_chat_link("lark://x"), false)
	t.eq(text.is_chat_link("https://evil.example/https://applink.feishu.cn/client/chat/open?"), false)
	t.eq(text.is_chat_link(nil), false)
end)

-- template: blocks and single-pass substitution.
t.test("template.parse splits named blocks and trims them", function()
	local blocks = template.parse("intro\n\n<!-- @one -->\n\nA {{x}}\n\n<!-- @two -->\nB\n")
	t.eq(blocks.main, "intro")
	t.eq(blocks.one, "A {{x}}")
	t.eq(blocks.two, "B")
end)

t.test("template.render does not re-scan inserted values", function()
	t.eq(template.render("<{{a}}>", { a = "{{a}}" }), "<{{a}}>")
end)

t.test("template.render rejects missing and unused variables", function()
	t.errors(function() template.render("{{a}}", {}) end, "缺少变量：a")
	t.errors(function() template.render("x", { a = "1" }) end, "没有使用变量：a")
end)

t.test("template.parse rejects a repeated block", function()
	t.errors(function() template.parse("<!-- @a -->\n1\n<!-- @a -->\n2") end, "提示词块重复：a")
end)

-- time: calendar days relative to `now`.
t.test("time.format uses calendar days", function()
	local now = os.time({ year = 2026, month = 11, day = 7, hour = 0, min = 30, sec = 0 })
	t.eq((time.format("2026-11-07 00:10", now)), "00:10")
	t.eq((time.format("2026-11-06 23:50", now)), "昨天 23:50")
	t.eq((time.format("2026-10-01 09:00", now)), "10月1日 09:00")
	t.eq((time.format("2025-10-01 09:00", now)), "2025年10月1日 09:00")
	t.eq((time.format("garbage", now)), "garbage")
end)

t.done()
