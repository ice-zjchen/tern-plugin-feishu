local tern = require("tern")
tern.command({ id = "open", title = "飞书 · 原生界面评审稿", run = function(cx)
	cx:new_block("feishu-native-review.review", {}, "tab")
end })
