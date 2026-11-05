extends Control
## 名字输入面板（字符选择式）
##
## 作者 2026-11-05 要求：
##   · 面板不要太大，内容尽量填满，留间隔但整体居中
##   · 关键信息要有高亮/闪烁，不能信息密度太低
##   · 右上角要有 X 关闭；鼠标右键 = 取消
##   · 输入法看不到候选字 —— 所以不用 LineEdit，全部点选
##   · 与《孤独之旅》对话输入复用同一套 TextInputKit

signal name_confirmed(name: String)
signal cancelled()

const PRESET_NAME := "陆知行"
const GRID_COLUMNS := 16

@onready var _close_btn: Button = %CloseButton
@onready var _name_preview: Label = %NamePreview
@onready var _hint: Label = %NameHint
@onready var _pinyin_row: HBoxContainer = %PinyinRow
@onready var _char_grid: GridContainer = %CharGrid
@onready var _symbol_row: HBoxContainer = %SymbolRow
@onready var _symbol_label: Label = %SymbolLabel
@onready var _backspace_btn: Button = %BackspaceButton
@onready var _clear_btn: Button = %ClearNameButton
@onready var _confirm_btn: Button = %NameConfirmButton
@onready var _cancel_btn: Button = %NameCancelButton
@onready var _title_label: Label = %TitleText

var _current: String = ""
var _active_pinyin: String = ""
var _blink_time: float = 0.0
var _blink_on: bool = true


func _ready() -> void:
	_char_grid.columns = GRID_COLUMNS
	_setup_pinyin_row()

	_backspace_btn.pressed.connect(_on_backspace)
	_clear_btn.pressed.connect(_on_clear)
	_confirm_btn.pressed.connect(_on_confirm)
	_cancel_btn.pressed.connect(_cancel)
	_close_btn.pressed.connect(_cancel)

	_current = PRESET_NAME
	_refresh()
	_confirm_btn.grab_focus.call_deferred()


func _process(delta: float) -> void:
	# 关键信息闪烁：确认按钮可用时轻微呼吸，提示「可以按了」
	_blink_time += delta
	if _blink_time >= 0.7:
		_blink_time = 0.0
		_blink_on = not _blink_on
		if not _confirm_btn.disabled:
			var c := Color(1, 1, 1) if _blink_on else Color(0.72, 0.72, 0.72)
			_confirm_btn.add_theme_color_override("font_color", c)
		# 名字预览也轻微呼吸，强调这是当前输入
		_name_preview.modulate.a = 1.0 if _blink_on else 0.82


func _unhandled_input(event: InputEvent) -> void:
	# 鼠标右键 = 取消（常规操作）
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_cancel()
		accept_event()


func _cancel() -> void:
	cancelled.emit()


# ---------- 拼音条 ----------

func _setup_pinyin_row() -> void:
	var groups := ["", "a", "b", "c", "d", "e", "f", "g", "h", "j", "k", "l", "m",
		"n", "o", "p", "q", "r", "s", "t", "w", "x", "y", "z"]
	for g in groups:
		var b := Button.new()
		b.text = "全部" if String(g).is_empty() else String(g).to_upper()
		b.custom_minimum_size = Vector2(0, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 12)
		var key := String(g)
		b.pressed.connect(_on_pinyin_pressed.bind(key))
		_pinyin_row.add_child(b)


func _on_pinyin_pressed(prefix: String) -> void:
	_active_pinyin = prefix
	_refresh_grid()


# ---------- 刷新 ----------

func _refresh() -> void:
	_name_preview.text = _current if not _current.is_empty() else "——"
	var check: Dictionary = DataManager.text_input.validate_name(_current)
	var ok := bool(check.get("ok", false))

	if ok:
		_hint.text = "按「就叫这个」开始"
		_hint.add_theme_color_override("font_color", Color(0.35, 0.52, 0.35))
	else:
		_hint.text = String(check.get("reason", ""))
		_hint.add_theme_color_override("font_color", Color(0.72, 0.36, 0.36))

	_confirm_btn.disabled = not ok
	if not ok:
		_confirm_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

	_refresh_grid()


func _refresh_grid() -> void:
	for c in _char_grid.get_children():
		c.queue_free()

	var groups: Dictionary = DataManager.text_input.grouped_by_pinyin(_active_pinyin)
	var keys: Array = groups.keys()
	keys.sort()

	for py in keys:
		for ch in groups[py]:
			var b := Button.new()
			b.text = String(ch)
			b.custom_minimum_size = Vector2(0, 30)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_font_size_override("font_size", 15)
			var chr := String(ch)
			b.pressed.connect(func(): _append(chr))
			_char_grid.add_child(b)


func _append(ch: String) -> void:
	_current += ch
	_refresh()


func _on_backspace() -> void:
	if _current.length() > 0:
		_current = _current.substr(0, _current.length() - 1)
		_refresh()


func _on_clear() -> void:
	_current = ""
	_refresh()


func _on_confirm() -> void:
	var check: Dictionary = DataManager.text_input.validate_name(_current)
	if not bool(check.get("ok", false)):
		_hint.text = String(check.get("reason", ""))
		return
	name_confirmed.emit(String(check["name"]))
