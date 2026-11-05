extends Node
## GameManager｜全局入口与生命周期
##
## 职责：只做「谁在跑、往哪切场景、什么时候存」。
## 不存游戏数据（那是 GameState），不算时间（那是 TimeSystem）。

signal game_started(player_name: String)
signal scene_changed(scene_path: String)

const TITLE_SCENE := "res://scenes/title_screen.tscn"
const LIFE_SCENE := "res://scenes/life_screen.tscn"

## 当前玩家姓名。空字符串 = 还没有开局。
var player_name: String = ""

## 是否正处在「已开局、可以推进时间」的状态
var in_game: bool = false


func _ready() -> void:
	# 自动存档走 TimeSystem 的时段切换信号
	if TimeSystem and TimeSystem.has_signal("period_changed"):
		TimeSystem.period_changed.connect(_on_period_changed)


## 校验玩家填写的姓名：2～3 个汉字，且不与既有角色重名
func validate_player_name(raw: String) -> Dictionary:
	var name := raw.strip_edges()
	if name.is_empty():
		return {"ok": false, "reason": "名字不能为空"}

	var char_count := 0
	for ch in name:
		# 只允许汉字（CJK 统一表意文字基本区 + 扩展A）
		var code: int = ch.unicode_at(0)
		var is_hanzi := (code >= 0x4E00 and code <= 0x9FFF) or (code >= 0x3400 and code <= 0x4DBF)
		if not is_hanzi:
			return {"ok": false, "reason": "只能填汉字"}
		char_count += 1

	if char_count < 2 or char_count > 3:
		return {"ok": false, "reason": "姓名需要 2～3 个汉字"}

	# 不得与既有角色重名（数据源见 game_data.json > 玩家设定 > 重要角色姓名不得重名）
	var reserved: Array = DataManager.get_reserved_names()
	if reserved.has(name):
		return {"ok": false, "reason": "这个姓名已被角色使用"}

	return {"ok": true, "name": name}


## 开新档：设定姓名，重置全部状态，进入 Day 1
func start_new_game(name: String) -> void:
	player_name = name
	GameState.reset_to_new_game(name)
	DataManager.load_static_tables()
	in_game = true
	game_started.emit(name)
	change_scene(LIFE_SCENE)


## 从存档继续
func continue_game(slot: String = "auto_last") -> bool:
	if not GameState.load_from_slot(slot):
		return false
	player_name = GameState.player_name
	in_game = true
	game_started.emit(player_name)
	change_scene(LIFE_SCENE)
	return true


func change_scene(path: String) -> void:
	if not ResourceLoader.exists(path):
		push_error("GameManager: 场景不存在 %s" % path)
		return
	get_tree().change_scene_to_file(path)
	scene_changed.emit(path)


func back_to_title() -> void:
	in_game = false
	change_scene(TITLE_SCENE)


func _on_period_changed(_period_name: String) -> void:
	if in_game:
		GameState.save_to_slot("auto_last")


## 退出游戏前把当前进度落盘，避免玩家直接关窗口丢档
func quit_game() -> void:
	if in_game:
		GameState.save_to_slot("auto_last")
	get_tree().quit()
