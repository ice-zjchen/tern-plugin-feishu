-- Host entry points: Tern callbacks only translate into runtime calls.
local tern = require("tern")
local runtime = require("./runtime")

-- Background work starts with the plugin; a broken snapshot is reported when a
-- workbench opens and retries the start.
pcall(runtime.start)

tern.block.define("inbox", {
	font = "sans",
	init = function(cx, _args, saved)
		local rt = runtime.attach(cx, saved)
		if _args[1] == "bot" then runtime.event(rt, { ev = "action", act = "view", value = "bot" }, cx) end
		return rt
	end,
	view = runtime.render,
	title = runtime.title,
	event = runtime.event,
	key = runtime.key,
	save = runtime.save,
})
