extends Node
## GameState｜运行时状态与存读档
##
## 这里是**唯一**可以写游戏进度的地方。静态表在 DataManager，只读。
##
## 存档格式对齐 data/experience_log_contract_v10.example.json：
## 记忆日志是「事件标志 + 可见状态」，不引入任何新的计量资源。

signal state_changed()
signal day_changed(day: int)
signal memory_added(entry: Dictionary)

const SAVE_VERSION := 1
const SAVE_DIR := "user://saves"

# ---------- 基础状态 ----------
var player_name: String = ""
var day: int = 1
var total_days: int = 100
## 当天已过分钟数，从 00:00 起算。显示时换算成时钟。
var minute_of_day: int = 0
var money: int = 0
var stamina: float = 100.0
var stamina_cap: float = 100.0
var inspiration: int = 0

## 当前位置 id：apartment / bookstore / park / convenience / restaurant / equipment
var location_id: String = "apartment"

# ---------- 开发完成度 ----------
## 各维已完成的百分点
var dim_done: Dictionary = {"程序": 0.0, "美术": 0.0, "音乐": 0.0, "文案": 0.0}
## 各维能力值（主角自身）
var dim_ability: Dictionary = {}
## 已解锁的课程等级
var course_level: Dictionary = {}

# ---------- 同伴状态（v10：四个状态必须分开） ----------
## char_id -> { "encounter": "unseen|noticed|met", "invited": bool, "recruited": bool, "story_stage": int, "affection": int, "mood": "普通" }
var companions: Dictionary = {}

# ---------- 作品与痕迹 ----------
## media_id -> 已看次数（0~5）
var media_progress: Dictionary = {}
## media_id -> 是否已写完成短评
var media_completed: Dictionary = {}
## 已购买设备 id 列表
var owned_equipment: Array = []
## 是否已买过游戏（游戏类需要购买）
var purchased_media: Array = []
## 身上的零食库存：{ "泡面": 2, "面包": 1 }（买回来放着，不是当场吃）
var inventory: Dictionary = {}

# ---------- 经历日志（回忆的来源） ----------
var memory_log: Array = []
## 事件标志，防止一次性事件重复记录
var flags: Dictionary = {}

# ---------- 当天计数（睡觉时清零） ----------
var daily: Dictionary = {}


# ---------- 初始化 ----------

func reset_to_new_game(name: String) -> void:
	player_name = name
	day = 1
	total_days = 100
	minute_of_day = 0
	location_id = "apartment"
	memory_log.clear()
	flags.clear()
	daily.clear()
	media_progress.clear()
	media_completed.clear()
	owned_equipment.clear()
	purchased_media.clear()
	inventory.clear()
	companions.clear()
	for cid in ["xumian", "tangli", "wenye"]:
		companions[cid] = {
			"encounter": "unseen",
			"invited": false,
			"recruited": false,
			"story_stage": 0,
			"affection": 0,
			"mood": "普通",
		}
	_apply_initial_values()
	_apply_starting_time()
	state_changed.emit()


func _apply_initial_values() -> void:
	var init := DataManager.get_initial_values()
	money = int(init.get("金钱", 600))
	stamina = float(init.get("体力", 100))
	stamina_cap = 100.0
	inspiration = int(init.get("灵感", 20))
	total_days = int(init.get("总天数上限", 100))

	dim_ability = DataManager.get_four_dim_initial()
	for dim in dim_ability:
		dim_done[dim] = 0.0

	# 开局完成度按四维分配写入（默认 12 / 2 / 0 / 1，合计 15%）
	var alloc: Dictionary = init.get("完成度四维分配", {})
	for dim in alloc:
		if dim_done.has(dim):
			dim_done[dim] = float(alloc[dim])

	for cid in companions:
		companions[cid]["affection"] = int(init.get("同伴好感度", {}).get(cid, 0))


func _apply_starting_time() -> void:
	# 数据源：时间系统 > 初始时间 = "10:30"
	var start_text := String(DataManager.get_time_settings().get("初始时间", "10:30"))
	minute_of_day = _clock_to_minutes(start_text)


func _clock_to_minutes(text: String) -> int:
	var parts := text.split(":")
	if parts.size() != 2:
		return 0
	return int(parts[0]) * 60 + int(parts[1])


# ---------- 时间与资源 ----------

func clock_text() -> String:
	var h := minute_of_day / 60
	var m := minute_of_day % 60
	return "%02d:%02d" % [h, m]


func total_completion() -> float:
	var total := 0.0
	for dim in dim_done:
		total += float(dim_done[dim])
	return total


func stamina_tier() -> Dictionary:
	# 数据源：体力系统 > 效率档位
	var tiers: Array = DataManager.get_stamina_settings().get("效率档位", [])
	for t in tiers:
		var label := String(t.get("体力", ""))
		if label.contains("~"):
			var bounds := label.split("~")
			var lo := float(bounds[0])
			var hi := float(bounds[1])
			if stamina >= lo and stamina <= hi:
				return t
		elif label == "0" and stamina <= 0.0:
			return t
	return {"效率系数": 0.0, "状态": "未知"}


## 消耗时间。跨过 24:00 时推进到第二天（数据源：时间系统 > 结算器 > 中途碰到的事）
func advance_minutes(minutes: int) -> void:
	minute_of_day += minutes
	while minute_of_day >= 1440:
		minute_of_day -= 1440
		roll_to_next_day()
	state_changed.emit()


## 跨到第二天。由 advance_minutes 自动调用，睡眠也直接调用。
func roll_to_next_day() -> void:
	day += 1
	stamina_cap = 100.0
	daily.clear()
	# 睡醒 +10 灵感（数据源：灵感系统 > 获取 > 睡醒）
	inspiration = mini(inspiration + 10, 100)
	day_changed.emit(day)


func change_money(delta: int) -> void:
	money += delta
	state_changed.emit()


func change_stamina(delta: float) -> void:
	stamina = clampf(stamina + delta, 0.0, stamina_cap)
	state_changed.emit()


func change_inspiration(delta: int) -> void:
	inspiration = clampi(inspiration + delta, 0, 100)
	state_changed.emit()


func add_dim_progress(dim: String, amount: float) -> void:
	if dim_done.has(dim):
		dim_done[dim] = float(dim_done[dim]) + amount
		state_changed.emit()


## 买一份零食放身上
func add_to_inventory(item_key: String, amount: int = 1) -> void:
	inventory[item_key] = int(inventory.get(item_key, 0)) + amount
	state_changed.emit()


## 吃掉一份。返回是否成功。
func consume_inventory(item_key: String) -> bool:
	var have := int(inventory.get(item_key, 0))
	if have <= 0:
		return false
	inventory[item_key] = have - 1
	state_changed.emit()
	return true


func inventory_count(item_key: String) -> int:
	return int(inventory.get(item_key, 0))


func daily_count(key: String) -> int:
	return int(daily.get(key, 0))


func bump_daily(key: String, by: int = 1) -> void:
	daily[key] = daily_count(key) + by


# ---------- 同伴状态（v10 四状态分开） ----------

func get_companion(cid: String) -> Dictionary:
	return companions.get(cid, {})


func get_encounter(cid: String) -> String:
	return String(get_companion(cid).get("encounter", "unseen"))


## 只有玩家主动交谈才调用这个。不能因为日程经过就自动置为 met。
func mark_met(cid: String) -> bool:
	if not companions.has(cid):
		return false
	if get_encounter(cid) == "met":
		return false
	companions[cid]["encounter"] = "met"
	add_memory("MET_%s" % cid.to_upper(), "companion_met", "memory.met.%s" % cid, [], ["companion"])
	state_changed.emit()
	return true


func mark_noticed(cid: String) -> bool:
	if not companions.has(cid):
		return false
	if get_encounter(cid) != "unseen":
		return false
	companions[cid]["encounter"] = "noticed"
	state_changed.emit()
	return true


## 招募必须两步：玩家发出邀请 + 玩家确认，才能置 recruited
func mark_recruited(cid: String) -> bool:
	if not companions.has(cid):
		return false
	if get_encounter(cid) != "met":
		return false
	companions[cid]["invited"] = true
	companions[cid]["recruited"] = true
	add_memory("RECRUIT_%s" % cid.to_upper(), "companion_recruited", "memory.recruit.%s" % cid, [], ["companion"])
	state_changed.emit()
	return true


func is_recruited(cid: String) -> bool:
	return bool(get_companion(cid).get("recruited", false))


# ---------- 作品与痕迹 ----------

func media_view_count(media_id: String) -> int:
	return int(media_progress.get(media_id, 0))


## 看一次作品。返回实际获得的信息，供 UI 显示。
func watch_media(media_id: String) -> Dictionary:
	var rec := DataManager.get_catalog_entry(media_id)
	if rec.is_empty():
		return {"ok": false, "reason": "作品不存在"}

	var steps := int(rec.get("steps", 5))
	var seen := media_view_count(media_id)
	if seen >= steps:
		# 进度满后不再产出灵感（数据源：灵感系统 > 防刷）
		return {"ok": false, "reason": "这部已经看完了", "gain": 0, "progress": seen}

	media_progress[media_id] = seen + 1
	var gain := int(rec.get("inspiration_per_action", 0))
	change_inspiration(gain)

	var finished := (seen + 1) >= steps
	if finished and not bool(media_completed.get(media_id, false)):
		media_completed[media_id] = true
		add_memory("MEDIA_COMPLETE_%s" % media_id, "entertainment_complete",
			"memory.media.%s" % media_id, [], ["solo", "entertainment"])
	state_changed.emit()
	return {
		"ok": true,
		"gain": gain,
		"progress": media_progress[media_id],
		"steps": steps,
		"finished": finished,
		"title": String(rec.get("title", media_id)),
	}


func is_media_completed(media_id: String) -> bool:
	return bool(media_completed.get(media_id, false))


func add_equipment(equip_id: String) -> void:
	if not owned_equipment.has(equip_id):
		owned_equipment.append(equip_id)
		add_memory("EQUIPMENT_%s" % equip_id.to_upper(), "equipment_bought",
			"memory.equipment.%s" % equip_id, [], ["equipment"])
	state_changed.emit()


# ---------- 经历日志 ----------

## 记录一条真实发生过的经历。同一个 event_id 只记一次（首次里程碑语义）。
func add_memory(event_id: String, kind: String, summary_key: String,
		participants: Array = [], tags: Array = []) -> void:
	if flags.has(event_id):
		return
	flags[event_id] = true
	var entry := {
		"schema_version": SAVE_VERSION,
		"entry_id": "memory_%03d_%04d" % [int(day), memory_log.size() + 1],
		"event_id": event_id,
		"day": day,
		"minute_of_day": minute_of_day,
		"location_id": location_id,
		"participants": participants,
		"kind": kind,
		"summary_key": summary_key,
		"asset_key": "",
		"tags": tags,
		"choice_id": null,
		"state_delta_refs": [],
	}
	memory_log.append(entry)
	memory_added.emit(entry)
	state_changed.emit()


func has_flag(event_id: String) -> bool:
	return bool(flags.get(event_id, false))


## 七日回望：挑 3～5 条真实发生的片段。
## 规则见 回忆闪回_数据与演出接口_v10.md 第三节：
## 优先里程碑、不同 kind 分散、最早与最近各尽量一条、没有高级事件时回退到普通经历。
func pick_recap_entries(max_count: int = 5) -> Array:
	if memory_log.is_empty():
		return []
	var picked: Array = []
	var used_kinds: Dictionary = {}

	# 第一轮：按里程碑优先，同 kind 先不重复
	for entry in memory_log:
		if picked.size() >= max_count:
			break
		var kind := String(entry.get("kind", ""))
		if used_kinds.has(kind):
			continue
		used_kinds[kind] = true
		picked.append(entry)

	# 第二轮：不够就按时间顺序补，仍然不重复 entry
	if picked.size() < max_count:
		for entry in memory_log:
			if picked.size() >= max_count:
				break
			if not picked.has(entry):
				picked.append(entry)

	picked.sort_custom(func(a, b):
		if int(a["day"]) == int(b["day"]):
			return int(a["minute_of_day"]) < int(b["minute_of_day"])
		return int(a["day"]) < int(b["day"]))
	return picked


# ---------- 存读档 ----------

func save_to_slot(slot: String) -> bool:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	var payload := {
		"save_version": SAVE_VERSION,
		"player_name": player_name,
		"day": day,
		"total_days": total_days,
		"minute_of_day": minute_of_day,
		"money": money,
		"stamina": stamina,
		"stamina_cap": stamina_cap,
		"inspiration": inspiration,
		"location_id": location_id,
		"dim_done": dim_done,
		"dim_ability": dim_ability,
		"course_level": course_level,
		"companions": companions,
		"media_progress": media_progress,
		"media_completed": media_completed,
		"owned_equipment": owned_equipment,
		"purchased_media": purchased_media,
		"inventory": inventory,
		"memory_log": memory_log,
		"flags": flags,
		"daily": daily,
		"saved_at": Time.get_datetime_string_from_system(),
	}

	var path := "%s/%s.json" % [SAVE_DIR, slot]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("GameState: 无法写入存档 %s" % path)
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


func load_from_slot(slot: String) -> bool:
	var path := "%s/%s.json" % [SAVE_DIR, slot]
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()

	var parser := JSON.new()
	if parser.parse(text) != OK:
		push_error("GameState: 存档解析失败 %s" % path)
		return false
	if not (parser.data is Dictionary):
		return false

	var d: Dictionary = parser.data
	player_name = String(d.get("player_name", "玩家"))
	day = int(d.get("day", 1))
	total_days = int(d.get("total_days", 100))
	minute_of_day = int(d.get("minute_of_day", 630))
	money = int(d.get("money", 600))
	stamina = float(d.get("stamina", 100.0))
	stamina_cap = float(d.get("stamina_cap", 100.0))
	inspiration = int(d.get("inspiration", 20))
	location_id = String(d.get("location_id", "apartment"))
	dim_done = d.get("dim_done", dim_done)
	dim_ability = d.get("dim_ability", dim_ability)
	course_level = d.get("course_level", {})
	companions = d.get("companions", companions)
	media_progress = d.get("media_progress", {})
	media_completed = d.get("media_completed", {})
	owned_equipment = d.get("owned_equipment", [])
	purchased_media = d.get("purchased_media", [])
	inventory = d.get("inventory", {})
	memory_log = d.get("memory_log", [])
	flags = d.get("flags", {})
	daily = d.get("daily", {})
	state_changed.emit()
	day_changed.emit(day)
	return true


func has_any_save() -> bool:
	return FileAccess.file_exists("%s/auto_last.json" % SAVE_DIR)


func get_save_summary() -> String:
	var path := "%s/auto_last.json" % SAVE_DIR
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary):
		return ""
	return "%s · 第 %d 天" % [String(d.get("player_name", "")), int(d.get("day", 1))]
