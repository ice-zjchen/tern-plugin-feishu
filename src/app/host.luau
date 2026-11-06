-- Host entry points: Tern callbacks only translate into runtime calls.
local tern = require("tern")
local runtime = require("./runtime")

tern.block.define("inbox", {
	font = "sans",
	init = function(cx, _args, saved)
		local rt = runtime.attach(cx, saved)
		if _args[1] == "history" then runtime.event(rt, { ev = "action", act = "history" }, cx) end
		return rt
	end,
	view = runtime.render,
	title = runtime.title,
	event = runtime.event,
	key = runtime.key,
	save = runtime.save,
})
