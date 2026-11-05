extends Control
## 标题页
##
## 姓名输入已改为「字符选择面板」（scenes/name_input_panel.tscn），
## 不再用 LineEdit，避免输入法下看不到候选字。

const NAME_PANEL := preload("res://scenes/name_input_panel.tscn")

@onready var _title: Label = %TitleLabel
@onready var _new_btn: Button = %NewGameButton
@onready var _continue_btn: Button = %ContinueButton
@onready var _quit_btn: Button = %QuitButton
@onready var _hint: Label = %HintLabel
@onready var _save_info: Label = %SaveInfoLabel

var _panel: Control = null


func _ready() -> void:
	_hint.text = ""
	_refresh_continue_button()

	_new_btn.pressed.connect(_on_new_pressed)
	_continue_btn.pressed.connect(_on_continue_pressed)
	_quit_btn.pressed.connect(_on_quit_pressed)

	if not DataManager.loaded:
		_hint.text = "数据加载失败：%s" % DataManager.last_error

	_new_btn.grab_focus.call_deferred()


func _refresh_continue_button() -> void:
	var has_save := GameState.has_any_save()
	_continue_btn.disabled = not has_save
	_save_info.text = GameState.get_save_summary() if has_save else "还没有存档"


func _on_new_pressed() -> void:
	if _panel != null:
		return
	_panel = NAME_PANEL.instantiate()
	add_child(_panel)
	_panel.name_confirmed.connect(_on_name_confirmed)
	_panel.cancelled.connect(_on_name_cancelled)


func _on_name_cancelled() -> void:
	_close_panel()
	_new_btn.grab_focus.call_deferred()


func _on_name_confirmed(name: String) -> void:
	_close_panel()
	GameManager.start_new_game(name)


func _close_panel() -> void:
	if _panel != null:
		_panel.queue_free()
		_panel = null


func _on_continue_pressed() -> void:
	if not GameManager.continue_game():
		_hint.text = "读档失败"
		_refresh_continue_button()


func _on_quit_pressed() -> void:
	GameManager.quit_game()
