--!strict
-- A minimal test harness: `t.test(name, fn)` records a case; `t.done()` prints a
-- summary and exits non-zero when any case failed.

local t = {}

local passed, failed = 0, 0

function t.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local function show(v: any): string
	return if type(v) == "string" then string.format("%q", v) else tostring(v)
end

function t.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error((label or "value") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
	end
end

function t.errors(fn: () -> (), pattern: string)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error matching " .. pattern, 2)
	end
	if not string.find(tostring(err), pattern, 1, true) then
		error("error " .. show(tostring(err)) .. " does not contain " .. show(pattern), 2)
	end
end

function t.done()
	print(string.format("%d passed, %d failed", passed, failed))
	if failed > 0 then
		error("tests failed", 0)
	end
end

return t
