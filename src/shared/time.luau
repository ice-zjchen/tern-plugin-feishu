--!strict
-- lark-cli returns local wall-clock times as YYYY-MM-DD HH:MM[:SS].
local time = {}

local WEEKDAYS = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

type Date = { year: number, month: number, day: number, yday: number, wday: number }

-- Calendar days, not elapsed 24-hour periods (DST days can be 23 or 25 hours).
local function day_number(date: Date): number
	local year = date.year - 1
	return year * 365 + year // 4 - year // 100 + year // 400 + date.yday
end

local function local_date(at: number): Date
	return os.date("*t", at) :: any
end

-- Epoch seconds of a lark-cli timestamp, or nil when it isn't one.
function time.parse(value: string): number?
	local y, mo, d, h, mi, s = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):?(%d*)")
	if not (y and mo and d and h and mi) then
		return nil
	end
	return os.time({
		year = tonumber(y) :: number, month = tonumber(mo) :: number, day = tonumber(d) :: number,
		hour = tonumber(h) :: number, min = tonumber(mi) :: number, sec = tonumber(s) or 0,
	})
end

-- The short label for a message time and the full text for its tooltip: today
-- `14:30`, yesterday `昨天 14:30`, the past week `周二 14:30`, this year
-- `10月28日 14:30`, earlier years with the year.
function time.format(value: string, now: number?): (string, string)
	local y, mo, d, h, mi = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)")
	if not (y and mo and d and h and mi) then
		return value, value
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local hour, minute = tonumber(h) :: number, tonumber(mi) :: number
	local date = local_date(os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 }))
	if date.year ~= year or date.month ~= month or date.day ~= day or hour > 23 or minute > 59 then
		return value, value
	end
	local today = local_date(now or os.time())
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
