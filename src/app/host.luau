-- Host entry points: Tern callbacks only translate into runtime calls.
local tern = require("tern")
local runtime = require("./runtime")

tern.block.define("inbox", {
	font = "sans",
	init = function(cx, _args, saved)
		return runtime.attach(cx, saved)
	end,
	view = runtime.render,
	title = runtime.title,
	event = runtime.event,
	key = runtime.key,
	save = runtime.save,
})
