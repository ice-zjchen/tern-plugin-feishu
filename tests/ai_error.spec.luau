--!strict
local t = require("./t")
local ai_error = require("../src/shared/ai_error")

t.test("missing model reports backend environment and persistent provider configuration", function()
	for _, model in { "@smol", "litellm/deepseek-v4.1-flash" } do
		local value = ai_error.exit(1, 'Still starting after 10s\n  logs: /tmp/omp.log\nWarning: stale catalog\nModel "' .. model .. '" not found\n')
		t.eq(string.find(value, 'AI 程序退出码 1：Model "' .. model .. '" not found', 1, true), 1)
		t.eq(string.find(value, "models.yml", 1, true) ~= nil, true)
		t.eq(string.find(value, "环境变量", 1, true) ~= nil, true)
	end
end)

t.test("other process errors keep their original concise formatting", function()
	t.eq(ai_error.exit(2, "Warning: ignored\npermission denied\nmore detail"), "AI 程序退出码 2：permission denied")
	t.eq(ai_error.exit(1, ""), "AI 程序退出码 1：没有错误输出")
	t.eq(ai_error.exit(1, "Warning: ignored\nlogs: /tmp/log"), "AI 程序退出码 1：没有错误输出")
	t.eq(ai_error.exit(1, string.rep("x", 400)), "AI 程序退出码 1：" .. string.rep("x", 300))
end)

t.done()
