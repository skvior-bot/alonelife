extends Node
## DataManager｜静态数据表
##
## 职责：把 data/ 下的 JSON 读进内存，供别的系统查询。
## 只读，不写回文件。运行时变化的数值一律放 GameState。
##
## 【重要】工具说明里写明：outer_life_events_v9.json 的 trigger 是字符串表达式，
## 不可以直接 eval。这里只做「字符串保存」，判定交给 EventSystem 的显式解析。

const PATH_GAME_DATA := "res://data/game_data.json"
const PATH_CATALOG := "res://data/entertainment_catalog_v9.json"
const PATH_EVENTS := "res://data/outer_life_events_v9.json"

signal tables_loaded()

var game_data: Dictionary = {}
var catalog: Dictionary = {}
var life_events: Dictionary = {}

## 作品按 id 建索引，方便图鉴和完成判定
var catalog_by_id: Dictionary = {}
## 生活事件按 id 建索引
var events_by_id: Dictionary = {}

var loaded: bool = false
var last_error: String = ""

## 行动表（ActionLibrary 的实例）。UI 用 DataManager.actions.actions_at(...) 取。
var actions: RefCounted = null

## 字符选择器（姓名 / 对话复用）
var text_input: RefCounted = null


func _ready() -> void:
	# 标题页就要能读「不能重名」等规则，所以启动时先读一次
	load_static_tables()
	var lib := load("res://scripts/managers/ActionLibrary.gd")
	if lib != null:
		actions = lib.new()
	var tik := load("res://scripts/managers/TextInputKit.gd")
	if tik != null:
		text_input = tik.new()


func load_static_tables() -> bool:
	last_error = ""
	game_data = _read_json(PATH_GAME_DATA)
	catalog = _read_json(PATH_CATALOG)
	life_events = _read_json(PATH_EVENTS)

	catalog_by_id.clear()
	for rec in _records_of(catalog):
		if rec.has("id"):
			catalog_by_id[String(rec["id"])] = rec

	events_by_id.clear()
	for ev in _records_of(life_events):
		if ev.has("id"):
			events_by_id[String(ev["id"])] = ev

	loaded = game_data.size() > 0
	if not loaded and last_error.is_empty():
		last_error = "game_data.json 读取为空"
	if loaded:
		tables_loaded.emit()
	else:
		push_error("DataManager: 静态数据加载失败 - %s" % last_error)
	return loaded


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		last_error = "找不到文件 %s" % path
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_error = "无法打开 %s" % path
		return {}
	var text := f.get_as_text()
	f.close()

	var parser := JSON.new()
	if parser.parse(text) != OK:
		last_error = "%s 第 %d 行: %s" % [path, parser.get_error_line(), parser.get_error_message()]
		return {}
	if parser.data is Dictionary:
		return parser.data
	last_error = "%s 顶层不是对象" % path
	return {}


## catalog 和 life_events 的记录都在 records / events 字段下，取不到了就退化为空
func _records_of(d: Dictionary) -> Array:
	for key in ["records", "events", "items"]:
		if d.has(key) and d[key] is Array:
			return d[key]
	return []


# ---------- 数值查询（集中在这里，避免各处硬编码字段路径） ----------

func get_initial_values() -> Dictionary:
	return game_data.get("玩家初始数值", {})


func get_four_dim_initial() -> Dictionary:
	var setting: Dictionary = game_data.get("玩家设定", {}).get("四维", {})
	var out := {}
	for dim in setting:
		out[dim] = float(setting[dim].get("初始", 0))
	return out


func get_four_dim_cap() -> Dictionary:
	var setting: Dictionary = game_data.get("玩家设定", {}).get("四维", {})
	var out := {}
	for dim in setting:
		out[dim] = float(setting[dim].get("上限", 0))
	return out


func get_reserved_names() -> Array:
	return game_data.get("玩家设定", {}).get("重要角色姓名不得重名", [])


func get_time_settings() -> Dictionary:
	return game_data.get("时间系统", {})


func get_stamina_settings() -> Dictionary:
	return game_data.get("体力系统（疲劳值）", {})


func get_inspiration_settings() -> Dictionary:
	return game_data.get("灵感系统（开发燃料）", {})


func get_completion_settings() -> Dictionary:
	return game_data.get("完成度系统", {})


func get_media_totals() -> Dictionary:
	return game_data.get("内容总量与灵感平衡", {})


func get_catalog_entry(id: String) -> Dictionary:
	return catalog_by_id.get(id, {})


func get_life_event(id: String) -> Dictionary:
	return events_by_id.get(id, {})


## 某类作品的全部条目（category 是「动画 / 游戏 / 小说 / 漫画」）
func get_catalog_by_category(category: String) -> Array:
	var out := []
	for rec in _records_of(catalog):
		if String(rec.get("category", "")) == category:
			out.append(rec)
	return out
