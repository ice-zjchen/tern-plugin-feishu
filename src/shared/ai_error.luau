--!strict
local ai_error = {}

function ai_error.exit(status: number, stderr: string): string
	local first = "没有错误输出"
	for line in string.gmatch(stderr, "[^\n]+") do
		if not string.find(line, "Still starting", 1, true) and not string.find(line, "logs:", 1, true)
			and not string.find(line, "Warning:", 1, true) then
			first = string.sub(line, 1, 300)
			break
		end
	end
	local message = "AI 程序退出码 " .. tostring(status) .. "：" .. first
	if string.match(first, '^Model ".-" not found') then
		message ..= "。请检查该 AI 程序的模型与 provider 配置；后台进程可能没有终端的环境变量。自定义服务地址请写入 omp 的 models.yml，不要只在 shell 中 export；@角色也需要能解析到可用模型。"
	end
	return message
end

return ai_error
