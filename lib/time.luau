-- lark-cli returns local wall-clock times as YYYY-MM-DD HH:MM.
local time = {}
local WEEKDAYS = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

-- Calendar days, not elapsed 24-hour periods (DST days can be 23 or 25 hours).
local function day_number(date: any): number
	local year = date.year - 1
	return year * 365 + year // 4 - year // 100 + year // 400 + date.yday
end

function time.format(value: string, now: number?): (string, string)
	local y, mo, d, h, mi = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)")
	if not y then
		return value, value
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local hour, minute = tonumber(h) :: number, tonumber(mi) :: number
	local at = os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
	local date = os.date("*t", at) :: any
	if date.year ~= year or date.month ~= month or date.day ~= day or hour > 23 or minute > 59 then
		return value, value
	end
	local today = os.date("*t", now or os.time()) :: any
	local age = day_number(today) - day_number(date)
	local clock = h .. ":" .. mi
	if age == 0 then
		return clock, value
	elseif age == 1 then
		return "昨天 " .. clock, value
	elseif age >= 2 and age < 7 then
		return WEEKDAYS[date.wday] .. " " .. clock, value
	end
	local prefix = if year == today.year then "" else y .. "年"
	return prefix .. tostring(month) .. "月" .. tostring(day) .. "日 " .. clock, value
end

return time
