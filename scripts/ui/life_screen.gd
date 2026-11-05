extends Control
## 生活主界面（V10-2/3 重做版）
##
## 核心结构（作者 2026-11-05 确认）：
##   · 点击【物体】→ 在该物体下方弹出它的事件列表 → 选中事件 → 进结算器
##   · 点击物体不消耗时间；只有事件才消耗
##   · 结算器只在有待结算事件时才出现，小巧、贴着触发位置
##   · 点格子清空，后面的往前补
##   · 未解锁的东西不显示

@onready var _name_label: Label = %NameLabel
@onready var _day_label: Label = %DayLabel
@onready var _clock_label: Label = %ClockLabel
@onready var _period_label: Label = %PeriodLabel
@onready var _money_label: Label = %MoneyLabel
@onready var _stamina_label: Label = %StaminaLabel
@onready var _insp_label: Label = %InspLabel
@onready var _completion_label: Label = %CompletionLabel

@onready var _object_row: HBoxContainer = %ObjectRow
@onready var _location_label: Label = %LocationLabel
@onready var _clue_label: Label = %ClueLabel
@onready var _log_label: Label = %LogLabel

@onready var _popup: PanelContainer = %ActionPopup
@onready var _popup_title: Label = %PopupTitle
@onready var _popup_list: VBoxContainer = %PopupList
@onready var _popup_close: Button = %PopupClose

@onready var _travel_row: HBoxContainer = %TravelRow

@onready var _settle_panel: PanelContainer = %SettlePanel
@onready var _slots_row: HBoxContainer = %SlotsRow
@onready var _preview_label: Label = %PreviewLabel
@onready var _settle_btn: Button = %SettleButton
@onready var _clear_btn: Button = %ClearButton

@onready var _title_btn: Button = %TitleButton
@onready var _sleep_btn: Button = %SleepButton

var _pending: Array = []
var _slot_buttons: Array = []
var _current_object: String = ""

const LOCATIONS := ["apartment", "bookstore", "park", "convenience", "restaurant", "equipment"]


func _ready() -> void:
	_build_slots()
	_popup.visible = false
	_settle_panel.visible = false

	_popup_close.pressed.connect(_close_popup)
	_settle_btn.pressed.connect(_on_settle)
	_clear_btn.pressed.connect(_on_clear)
	_title_btn.pressed.connect(_on_back_to_title)
	_sleep_btn.pressed.connect(_on_sleep)

	GameState.state_changed.connect(_refresh_all)
	_clue_label.gui_input.connect(_on_clue_gui_input)
	_refresh_all()
	_log("第 1 天。屋子里有点乱，电脑还开着。")


func _build_slots() -> void:
	for i in 4:
		var b := Button.new()
		b.custom_minimum_size = Vector2(150, 30)
		b.add_theme_font_size_override("font_size", 12)
		b.text = "—"
		var idx := i
		b.pressed.connect(func(): _on_slot_clicked(idx))
		_slots_row.add_child(b)
		_slot_buttons.append(b)


# ---------- 刷新 ----------

func _refresh_all() -> void:
	_name_label.text = GameState.player_name
	_day_label.text = "第 %d 天" % GameState.day
	_clock_label.text = GameState.clock_text()
	_period_label.text = TimeSystem.current_period()
	_money_label.text = "¥%d" % GameState.money
	_stamina_label.text = "体力 %d" % int(GameState.stamina)
	_insp_label.text = "灵感 %d" % GameState.inspiration

	var parts: Array = []
	for d in ["程序", "美术", "音乐", "文案"]:
		parts.append("%s%.1f" % [d, float(GameState.dim_done.get(d, 0.0))])
	_completion_label.text = "完成度 %.1f%%　%s" % [GameState.total_completion(), "  ".join(parts)]

	_location_label.text = String(DataManager.actions.LOCATION_NAMES.get(GameState.location_id, ""))
	# 睡觉按钮只在出租屋常驻（作者 2026-11-06 确认）
	_sleep_btn.visible = GameState.location_id == "apartment"
	_build_objects()
	_build_travel()
	_refresh_clue()
	_refresh_slots()


## 该地点的可点物体。点物体本身不花时间。
func _build_objects() -> void:
	for c in _object_row.get_children():
		c.queue_free()

	for o in DataManager.actions.objects_at(GameState.location_id):
		var b := Button.new()
		b.text = String(o["label"])
		b.custom_minimum_size = Vector2(96, 34)
		b.add_theme_font_size_override("font_size", 14)
		var oid := String(o["id"])
		b.pressed.connect(func(): _open_object(oid))
		_object_row.add_child(b)


func _build_travel() -> void:
	for c in _travel_row.get_children():
		c.queue_free()

	var targets: Array = []
	for a in _pending:
		if a.has("target_location"):
			targets.append(String(a["target_location"]))

	for t in DataManager.actions.travel_options(GameState.location_id, targets):
		var b := Button.new()
		b.text = String(t["label"])
		b.custom_minimum_size = Vector2(88, 30)
		b.add_theme_font_size_override("font_size", 13)
		var act: Dictionary = t
		b.pressed.connect(func(): _add_to_pending(act))
		_travel_row.add_child(b)


func _refresh_clue() -> void:
	var loc := GameState.location_id
	var lines: Array = []
	match loc:
		"bookstore":
			if GameState.get_encounter("xumian") == "unseen":
				lines.append("折扣区有一本夹着铅笔批注的小册子。")
			if GameState.get_encounter("wenye") == "unseen":
				lines.append("书页里夹着一张写了台词的便签。")
		"park":
			if GameState.get_encounter("tangli") == "unseen":
				lines.append("长椅那边传来断断续续的旋律。")
		"convenience":
			if GameState.get_encounter("wenye") == "unseen":
				lines.append("留言板上贴着一张写满字的纸。")
	if lines.is_empty():
		_clue_label.text = ""
		_clue_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	_clue_label.text = "  ".join(lines) + "   （点击查看）"
	_clue_label.mouse_filter = Control.MOUSE_FILTER_STOP


# ---------- 物体弹层 ----------

func _open_object(oid: String) -> void:
	_current_object = oid
	_popup_title.text = String(DataManager.actions.OBJECT_NAMES.get(oid, oid))

	for c in _popup_list.get_children():
		c.queue_free()

	var acts: Array = DataManager.actions.actions_of(oid, GameState.location_id)
	if acts.is_empty():
		var l := Label.new()
		l.text = "现在没什么可做的。"
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		_popup_list.add_child(l)
	else:
		for a in acts:
			_popup_list.add_child(_make_action_button(a))

	_popup.visible = true


func _make_action_button(a: Dictionary) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 30)
	b.add_theme_font_size_override("font_size", 13)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT

	var disabled := bool(a.get("disabled", false))
	if disabled:
		b.text = "%s　（%s）" % [String(a.get("label", "")), String(a.get("disabled_reason", "现在做不了"))]
		b.disabled = true
	else:
		b.text = "%s　%s" % [String(a.get("label", "")), String(a.get("detail", ""))]
		var act: Dictionary = a
		b.pressed.connect(func(): _on_action_chosen(act))
	return b


func _close_popup() -> void:
	_popup.visible = false
	_current_object = ""


## 鼠标右键 = 取消/退出（常规操作）
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index != MOUSE_BUTTON_RIGHT:
		return
	if _popup.visible:
		_close_popup()
	elif _pending.size() > 0:
		_on_clear()
	accept_event()


func _on_action_chosen(a: Dictionary) -> void:
	# 睡觉是结束今天，不进结算器
	if String(a.get("kind", "")) == "sleep":
		_do_sleep()
		return
	_add_to_pending(a)


# ---------- 结算器 ----------

func _add_to_pending(a: Dictionary) -> void:
	if _pending.size() >= 4:
		_log("一批最多 4 项，先结算这一批。")
		return

	var check: Dictionary = EventSystem.can_add_from_action(a, _pending.size())
	if not bool(check.get("ok", false)):
		_log(String(check.get("reason", "")))
		return

	var bc: Dictionary = EventSystem.would_exceed_batch(_pending, a)
	if not bool(bc.get("ok", false)):
		_log(String(bc.get("reason", "")))
		return

	_pending.append(a)
	_close_popup()
	_refresh_all()


func _on_slot_clicked(idx: int) -> void:
	# 点格子清空，后面的往前补（作者要求）
	if idx < 0 or idx >= _pending.size():
		return
	_pending.remove_at(idx)
	_refresh_all()


func _refresh_slots() -> void:
	for i in 4:
		var b: Button = _slot_buttons[i]
		if i < _pending.size():
			b.text = String(_pending[i].get("label", ""))
			b.disabled = false
			b.add_theme_color_override("font_color", Color(0.11, 0.11, 0.11))
		else:
			b.text = "—"
			b.disabled = true

	# 结算器只在有事件时才出现
	_settle_panel.visible = not _pending.is_empty()
	_refresh_preview()


func _refresh_preview() -> void:
	if _pending.is_empty():
		return

	var total_min := 0
	var total_cost := 0
	for a in _pending:
		total_min += int(a.get("minutes", 0))
		total_cost += maxi(0, -int(a.get("money", 0)))

	var end_m := GameState.minute_of_day + total_min
	var cross := end_m >= 1440
	var end_clock := "%02d:%02d" % [(end_m % 1440) / 60, (end_m % 1440) % 60]

	var drain := 0.0
	for a in _pending:
		if bool(a.get("drains_stamina", true)) and not a.has("stamina_gain") and String(a.get("kind","")) != "snack":
			drain += int(a.get("minutes", 0)) / 60.0 * 6.0
		if a.has("stamina_gain"):
			drain -= float(a["stamina_gain"])
	var st_after := clampf(GameState.stamina - drain, 0.0, GameState.stamina_cap)

	var lines: Array = []
	lines.append("%d 分钟" % total_min)
	lines.append("%s%s" % [end_clock, "(跨天)" if cross else ""])
	lines.append("体力 %d" % int(st_after))
	if total_cost > 0:
		lines.append("¥%d" % total_cost)
	_preview_label.text = "  ·  ".join(lines)


func _on_clear() -> void:
	_pending.clear()
	_refresh_all()


func _on_settle() -> void:
	if _pending.is_empty():
		return

	var batch: Array = []
	for a in _pending:
		batch.append(DataManager.actions.to_settlement(a))

	var result: Dictionary = EventSystem.settle_batch(batch)
	if not bool(result.get("ok", false)):
		_log(String(result.get("reason", "")))
		return

	for line in result.get("lines", []):
		_log(String(line))

	_pending.clear()
	_refresh_all()


# ---------- 睡觉 ----------

## 睡觉（作者 2026-11-05 确认）：
##   · 在出租屋 → 点床，直接睡
##   · 不在出租屋 → 必须先回家，所以这里提示玩家回去
func _on_sleep() -> void:
	if _pending.size() > 0:
		_log("先把这一批结算掉再睡。")
		return
	if GameState.location_id != "apartment":
		_log("得先回家才能睡。")
		return
	_do_sleep()


func _do_sleep() -> void:
	TimeSystem.sleep()
	_log("睡了一觉。第 %d 天，%s。" % [GameState.day, GameState.clock_text()])
	_close_popup()
	_refresh_all()


func _on_back_to_title() -> void:
	GameState.save_to_slot("auto_last")
	GameManager.back_to_title()


# ---------- 线索相遇 ----------

func _on_clue_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var loc := GameState.location_id
	var target := ""
	match loc:
		"bookstore":
			if GameState.get_encounter("xumian") == "unseen": target = "xumian"
			elif GameState.get_encounter("wenye") == "unseen": target = "wenye"
		"park":
			if GameState.get_encounter("tangli") == "unseen": target = "tangli"
		"convenience":
			if GameState.get_encounter("wenye") == "unseen": target = "wenye"
	if target.is_empty():
		return
	var text := _meet_text(target)
	GameState.mark_met(target)
	_log(text)
	_refresh_clue()


func _meet_text(cid: String) -> String:
	match cid:
		"xumian": return "你翻到那本画册。旁边的女生抬头：「那个……有点旧了。」她说她叫许眠。"
		"tangli": return "你听完才走。她抬头，以为你在等找零。「不用给钱。」她说她叫唐梨。"
		"wenye": return "便签上的字很密。写它的人就在旁边：「别念出来。」她叫温野。"
		_: return "你们说上了话。"


# ---------- 日志 ----------

func _log(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	if _log_label.text.is_empty():
		_log_label.text = text
	else:
		_log_label.text = text + "\n" + _log_label.text
	var lines := _log_label.text.split("\n")
	if lines.size() > 5:
		_log_label.text = "\n".join(lines.slice(0, 5))
