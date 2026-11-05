extends Node
## TimeSystem｜时间推进与时间段
##
## 数据源：game_data.json > 时间系统
## 原则：时间是唯一硬资源。**没有「每天只能做 N 件事」的限制。**
## 四格只是「一批结算的上限」，一天可以结算任意多次。

signal period_changed(period_name: String)
signal day_started(day: int)
signal time_advanced(minutes: int)

const MINUTES_PER_DAY := 1440
const SLEEP_MINUTES := 480

## 时间段表在 _ready 时从数据源读取
var periods: Array = []


func _ready() -> void:
	periods = DataManager.get_time_settings().get("时间段", [])


## 当前时间段名称：早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上 / 深夜（七段，来自数据源）
func current_period() -> String:
	if periods.is_empty():
		periods = DataManager.get_time_settings().get("时间段", [])
	var minute: int = GameState.minute_of_day
	for p in periods:
		var start := _clock_to_minutes(String(p.get("开始", "00:00")))
		var end := _clock_to_minutes(String(p.get("结束", "00:00")))
		# 深夜跨 24:00，按 1440 处理
		if end == 0:
			end = MINUTES_PER_DAY
		if minute >= start and minute < end:
			return String(p.get("名称", ""))
	# 兜底：数据源缺表时按七段口径给一个合理值，不返回已废弃的「朝/昼/夕/夜」
	return "深夜" if minute < 360 else "晚上"


func _clock_to_minutes(text: String) -> int:
	var parts := text.split(":")
	if parts.size() != 2:
		return 0
	return int(parts[0]) * 60 + int(parts[1])


## 推进时间，并在跨时段时发信号（自动存档挂在这个信号上）
func spend_seconds(minutes: int) -> bool:
	if minutes <= 0:
		return false
	var before_period := current_period()
	var before_day := GameState.day

	GameState.advance_minutes(minutes)

	if GameState.day != before_day:
		day_started.emit(GameState.day)

	var after_period := current_period()
	if after_period != before_period:
		period_changed.emit(after_period)

	time_advanced.emit(minutes)
	return true


## 睡觉：回满体力，**跳到次日 08:00**
##
## 注意：不能简单「加 480 分钟」。数据源写的 480 是睡眠时长，
## 但玩家可能 10:30 就睡（+480 只有 18:30，还没跨天）。
## 睡觉的语义是「结束今天」，所以这里直接推进到下一天。
func sleep() -> void:
	# 睡觉语义是「结束今天」，不是「往后加 480 分钟」——
	# 玩家可能 10:30 就睡，加 480 只会到 18:30，还没跨天。
	GameState.minute_of_day = 8 * 60
	GameState.roll_to_next_day()
	GameState.stamina = GameState.stamina_cap
	period_changed.emit(current_period())
	GameState.state_changed.emit()


## 某个地点现在是否开放。地点名用中文，和 时间段 表里的字段对应。
## 某个地点现在是否开放。
## 某个地点现在是否开放。优先读 game_data.json > 时间系统 > 营业时间。
## 支持跨夜（便利店 08:00-次日 02:00）和全天开放（公园不关）。
func is_open(location_cn: String) -> bool:
	var biz: Dictionary = DataManager.get_time_settings().get("营业时间", {})
	if biz.has(location_cn):
		var b: Dictionary = biz[location_cn]
		if bool(b.get("全天", false)):
			return true
		var cur: int = GameState.minute_of_day
		# 跨夜营业
		if b.has("开始") and b.has("结束次日"):
			var sm := _clock_to_minutes(String(b["开始"]))
			var em := _clock_to_minutes(String(b["结束次日"]))
			return cur >= sm or cur < em
		# 普通起止
		if b.has("开始"):
			var sm2 := _clock_to_minutes(String(b["开始"]))
			var raw_end := String(b.get("结束", "24:00"))
			var em2 := _clock_to_minutes(raw_end) if raw_end != "24:00" else 1440
			return cur >= sm2 and cur < em2
		# 多时间窗（吃饭/打工）
		var win: Array = []
		win.append_array(b.get("吃饭", []))
		win.append_array(b.get("打工", []))
		for w in win:
			var parts := String(w).split("-")
			if parts.size() == 2:
				if cur >= _clock_to_minutes(parts[0]) and cur <= _clock_to_minutes(parts[1]):
					return true
		return false

	# 没配营业时间的，退回按时间段表判断
	var period := current_period()
	for p in periods:
		if String(p.get("名称", "")) != period:
			continue
		if not p.has(location_cn):
			return true
		var v := String(p[location_cn]).strip_edges()
		return not (v.is_empty() or v == "关闭")
	return true


## 从一段文字里抽出所有 HH:MM-HH:MM 时间窗，返回 [[起, 止], ...]
func _parse_time_windows(text: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("(\\d{1,2}):(\\d{2})\\s*[-~]\\s*(\\d{1,2}):(\\d{2})")
	for m in re.search_all(text):
		out.append([
			int(m.get_string(1)) * 60 + int(m.get_string(2)),
			int(m.get_string(3)) * 60 + int(m.get_string(4)),
		])
	return out


## 给 UI 用的一行状态，例如「餐馆：关闭」
func open_state_text(location_cn: String) -> String:
	return "开放" if is_open(location_cn) else "关闭"


## 是否会跨过 24:00（结算前预览用）
func will_cross_midnight(minutes: int) -> bool:
	return GameState.minute_of_day + minutes >= MINUTES_PER_DAY


func minutes_to_midnight() -> int:
	return maxi(0, MINUTES_PER_DAY - GameState.minute_of_day)
