extends Node
## EventSystem｜四格结算器
##
## 数据源：game_data.json > 时间系统 > 结算器
## 规则记住三条：
##   1. 一批最多 4 项，**这是批量上限，不是每日行动次数上限**
##   2. 一批合计 ≤ 1000 分钟，超了要拆两批
##   3. 确认后一口气算完，不可打断；小动画可跳过
##
## 结算前必须能回答 结算器预览（UI 必须显示）里的六件事。

signal batch_settled(result: Dictionary)

const MAX_ITEMS := 4
const MAX_BATCH_MINUTES := 1000
const MINUTES_PER_DAY := 1440

## 本批结算的完成度增量。_apply_action_effect 往里累加，settle_batch 读出来。
var _batch_dim_gain: Dictionary = {}


## 加入结算器前的检查。返回 {ok, reason}
func can_add(action: Dictionary, current_count: int) -> Dictionary:
	if current_count >= MAX_ITEMS:
		return {"ok": false, "reason": "一批最多 %d 项，先结算这一批" % MAX_ITEMS}

	var total := pending_minutes(action)
	# 只看这一项本身是否超过单批上限
	if total > MAX_BATCH_MINUTES:
		return {"ok": false, "reason": "单项就超过一批上限"}

	# 地点关门检查
	if action.has("require_location"):
		var loc := String(action["require_location"])
		if not TimeSystem.is_open(loc):
			return {"ok": false, "reason": "%s 现在关着" % loc}

	# 金钱检查
	var cost := int(action.get("cost", 0))
	if cost > 0 and GameState.money < cost:
		return {"ok": false, "reason": "钱不够（需要 %d，现有 %d）" % [cost, GameState.money]}

	return {"ok": true}


## UI 传进来的是 ActionLibrary 的原始行动字典，这里做一次检查
func can_add_from_action(action: Dictionary, current_count: int) -> Dictionary:
	if current_count >= MAX_ITEMS:
		return {"ok": false, "reason": "一批最多 %d 项" % MAX_ITEMS}

	var settlement: Dictionary = DataManager.actions.to_settlement(action)

	# 地点关门
	if action.has("require_location"):
		var loc := String(action["require_location"])
		if not TimeSystem.is_open(loc):
			return {"ok": false, "reason": "%s 现在关着" % loc}

	# 钱够不够
	var cost := int(settlement.get("cost", 0))
	if cost > 0 and GameState.money < cost:
		return {"ok": false, "reason": "钱不够（需要 %d，现有 %d）" % [cost, GameState.money]}

	# 单项时长上限
	if pending_minutes(settlement) > MAX_BATCH_MINUTES:
		return {"ok": false, "reason": "单项超过一批上限"}

	return {"ok": true}


## 还没去的地方才给「前往」选项；已经在待结算里要去的地方，不再重复列出
func already_going_to(pending: Array, target_location: String) -> bool:
	for a in pending:
		var aid := String(a.get("id", ""))
		if aid == "goto_%s" % target_location:
			return true
	# 如果待结算最后一项就是去别处，且当前地点天然不等于目标，仍需允许
	return false


## 如果再把这一项放进去，整批会不会超过 1000 分钟
func would_exceed_batch(pending: Array, new_action: Dictionary) -> Dictionary:
	var total := 0
	for a in pending:
		total += int(DataManager.actions.to_settlement(a).get("minutes", 0))
	total += int(DataManager.actions.to_settlement(new_action).get("minutes", 0))
	if total > MAX_BATCH_MINUTES:
		return {"ok": false, "reason": "这批合计会到 %d 分钟，超过上限 %d，请先结算" % [total, MAX_BATCH_MINUTES]}
	return {"ok": true, "total": total}


func pending_minutes(action: Dictionary) -> int:
	return int(action.get("minutes", 0))


## 批量检查：整批总时长是否超过 1000 分钟
func validate_batch(actions: Array) -> Dictionary:
	if actions.size() > MAX_ITEMS:
		return {"ok": false, "reason": "一批最多 %d 项" % MAX_ITEMS}
	var total := 0
	var total_cost := 0
	for a in actions:
		total += pending_minutes(a)
		total_cost += int(a.get("cost", 0))

	if total > MAX_BATCH_MINUTES:
		return {"ok": false, "reason": "这批合计 %d 分钟，超过上限 %d，请拆成两批" % [total, MAX_BATCH_MINUTES]}

	# 关键：一批里多项都要花钱时，必须按**合计**判断，否则后面的项会把钱扣成负数
	if total_cost > GameState.money:
		return {"ok": false,
			"reason": "这批一共要花 %d 元，现在只有 %d 元，钱不够" % [total_cost, GameState.money]}

	return {"ok": true, "total_minutes": total, "total_cost": total_cost}


## 结算前预览。对应 结算器预览（UI 必须显示）里的六项。
func preview_batch(actions: Array) -> Dictionary:
	var total_minutes := 0
	var total_cost := 0
	var stamina_drain := 0.0
	for a in actions:
		total_minutes += pending_minutes(a)
		total_cost += int(a.get("cost", 0))
		if bool(a.get("drains_stamina", true)):
			stamina_drain += float(pending_minutes(a)) / 60.0 * 6.0

	var end_minute: int = GameState.minute_of_day + total_minutes
	var cross_midnight: bool = end_minute >= MINUTES_PER_DAY
	var remaining_stamina := clampf(GameState.stamina - stamina_drain, 0.0, GameState.stamina_cap)

	var out := {
		"total_minutes": total_minutes,
		"total_cost": total_cost,
		"end_clock": _minutes_to_clock(end_minute % MINUTES_PER_DAY),
		"cross_midnight": cross_midnight,
		"stamina_after": remaining_stamina,
		"dim_gain": {},              # 由具体行动填充
		"inspiration_after": GameState.inspiration,
	}
	return out


func _minutes_to_clock(m: int) -> String:
	return "%02d:%02d" % [m / 60, m % 60]


## 真正执行一批。确认后不可打断。
func settle_batch(actions: Array) -> Dictionary:
	var check := validate_batch(actions)
	if not bool(check.get("ok", false)):
		return {"ok": false, "reason": String(check.get("reason", ""))}

	# 兜底：确认整批总花费不超过现有金钱，避免中途出现负数
	var verify_cost := 0
	for a in actions:
		verify_cost += int(a.get("cost", 0))
	if verify_cost > GameState.money:
		return {"ok": false, "reason": "钱不够（整批需要 %d，现有 %d）" % [verify_cost, GameState.money]}

	var log_lines: Array = []
	var total_minutes := 0
	var total_cost := 0
	_batch_dim_gain.clear()

	# 一批里可能连排多次「前往同一地点」。第一次到了之后人就在那了，
	# 后面的重复前往不该再花时间（作者 2026-11-05 指出）。
	var visited_this_batch: Dictionary = {}

	for a in actions:
		var minutes := pending_minutes(a)

		var action_id_check := String(a.get("action_id", ""))
		if action_id_check.begins_with("goto_"):
			var target_check := action_id_check.substr(5)
			if visited_this_batch.has(target_check):
				minutes = 0            # 已经在这了，不重复耗时
			else:
				visited_this_batch[target_check] = true

		total_minutes += minutes
		total_cost += int(a.get("cost", 0))

		# 扣钱
		if int(a.get("cost", 0)) > 0:
			GameState.change_money(-int(a["cost"]))

		# 体力消耗
		if bool(a.get("drains_stamina", true)):
			GameState.change_stamina(-(minutes / 60.0) * 6.0)

		# 行动自身的即时效果
		if a.has("stamina_gain"):
			GameState.change_stamina(float(a["stamina_gain"]))
		if a.has("inspiration_gain"):
			GameState.change_inspiration(int(a["inspiration_gain"]))

		# 收入
		if a.has("money_gain"):
			GameState.change_money(int(a["money_gain"]))

		# 行动自身的特殊效果（学习 / 看作品 / 买设备 / 移动 / 打工计数）
		var extra := _apply_action_effect(a)
		if not extra.is_empty():
			log_lines.append(extra)

	# 统一推进时间（这样跨天只结算一次）
	TimeSystem.spend_seconds(total_minutes)

	var result := {
		"ok": true,
		"count": actions.size(),
		"total_minutes": total_minutes,
		"total_cost": total_cost,
		"dim_gain": _batch_dim_gain.duplicate(),
		"lines": log_lines,
	}
	batch_settled.emit(result)
	return result


## 读生活事件定义。注意：trigger 是字符串表达式，这里**不做 eval**。
## 判定交给 evaluate_trigger 的显式解析。
func get_event(event_id: String) -> Dictionary:
	return DataManager.get_life_event(event_id)


## 显式解析触发表达式。只支持 && 连接的一组条件，不引进脚本求值。
## 支持形如 knows_xumian / !XM01_done / machine_upgrade_count>=1
func evaluate_trigger(expr: String) -> bool:
	if expr.strip_edges().is_empty():
		return true
	for clause in expr.split("&&"):
		if not _eval_clause(clause.strip_edges()):
			return false
	return true


func _eval_clause(clause: String) -> bool:
	if clause.is_empty():
		return true

	var negate := false
	if clause.begins_with("!"):
		negate = true
		clause = clause.substr(1).strip_edges()

	var ok := false

	# 比较式：a >= b / a > b / a == b
	for op in [">=", "<=", "==", ">", "<"]:
		if clause.contains(op):
			var sides := clause.split(op)
			if sides.size() == 2:
				var left := _resolve_value(sides[0].strip_edges())
				var right := float(sides[1].strip_edges())
				match op:
					">=": ok = left >= right
					"<=": ok = left <= right
					"==": ok = is_equal_approx(left, right)
					">": ok = left > right
					"<": ok = left < right
				return ok != negate
			break

	# 布尔标志
	ok = _resolve_flag(clause)
	return ok != negate


func _resolve_value(name: String) -> float:
	match name:
		"machine_upgrade_count":
			return float(GameState.owned_equipment.size())
		"day":
			return float(GameState.day)
		"money":
			return float(GameState.money)
		_:
			return 0.0


func _resolve_flag(name: String) -> bool:
	# 已记录的事件标志
	if GameState.flags.has(name):
		return true

	match name:
		"knows_xumian":
			return GameState.get_encounter("xumian") == "met"
		"knows_tangli":
			return GameState.get_encounter("tangli") == "met"
		"knows_wenye":
			return GameState.get_encounter("wenye") == "met"
		"recruited_xumian":
			return GameState.is_recruited("xumian")
		"recruited_tangli":
			return GameState.is_recruited("tangli")
		"recruited_wenye":
			return GameState.is_recruited("wenye")
		"any_companion_known":
			return (GameState.get_encounter("xumian") == "met"
				or GameState.get_encounter("tangli") == "met"
				or GameState.get_encounter("wenye") == "met")
		"any_companion_contact":
			return any_companion_known()
		"visited_bookstore_again":
			return GameState.daily_count("visit_bookstore") >= 1
		"bookstore_revisit":
			return GameState.daily_count("visit_bookstore") >= 1
		"park_visit":
			return GameState.location_id == "park"
		"visit_store_again":
			return GameState.daily_count("visit_convenience") >= 1
		"art_draft_exists":
			return GameState.flags.has("has_art_draft")
		"music_draft_exists":
			return GameState.flags.has("has_music_draft")
		"script_revision_exists":
			return GameState.flags.has("has_script_revision")
		"store_work_done":
			return GameState.daily_count("work_convenience") >= 1
		"restaurant_meal":
			return GameState.daily_count("meal_restaurant") >= 1
		"finished_any_book":
			return GameState.flags.has("finished_any_book")
	return false


func any_companion_known() -> bool:
	return (GameState.get_encounter("xumian") == "met"
		or GameState.get_encounter("tangli") == "met"
		or GameState.get_encounter("wenye") == "met")


## 处理具体行动类型的副作用。返回一行日志文字，没有就返回空串。
func _apply_action_effect(a: Dictionary) -> String:
	var action_id := String(a.get("action_id", ""))
	if action_id.is_empty():
		return ""

	# 移动
	if action_id.begins_with("goto_"):
		var target := action_id.substr(5)
		GameState.location_id = target
		GameState.bump_daily("visit_%s" % target)
		GameState.add_memory("VISITED_%s" % target.to_upper(), "location_visited",
			"memory.visit.%s" % target, [], ["place"])
		return "到了%s。" % _location_cn(target)

	# 开发
	if action_id.begins_with("dev_"):
		var dim := String(a.get("dim", ""))
		if not dim.is_empty():
			var r := ResourceManager.do_dev_hour(dim)
			if bool(r.get("ok", false)):
				var g := float(r.get("gain", 0.0))
				_batch_dim_gain[dim] = float(_batch_dim_gain.get(dim, 0.0)) + g
				return "%s +%.2f%%，灵感剩 %d。" % [dim, g, GameState.inspiration]
			return String(r.get("reason", ""))

	# 看作品
	if action_id.begins_with("media_"):
		var media_id := action_id.substr(6)
		var r := GameState.watch_media(media_id)
		if not bool(r.get("ok", false)):
			return String(r.get("reason", ""))
		var txt := "《%s》%d/%d，灵感 +%d。" % [
			String(r.get("title", media_id)), int(r.get("progress", 0)),
			int(r.get("steps", 5)), int(r.get("gain", 0))]
		if bool(r.get("finished", false)):
			txt += "  看完了。"
		return txt

	# 吃零食：从库存扣，且每种各自的每日上限独立计算（不再共用 3 次）
	if action_id.begins_with("eat_"):
		var key := action_id.substr(4)
		if not GameState.consume_inventory(key):
			return "身上没有%s了。" % key
		GameState.bump_daily("eat_%s" % key)
		return "吃了%s。" % key

	# 散步
	if action_id == "walk":
		GameState.bump_daily("walk")
		return "走了一圈，脑子清楚了些。"

	# 餐馆
	if action_id == "meal_restaurant":
		GameState.bump_daily("meal_restaurant")
		return "吃了一顿正经饭。"

	# 打工
	if action_id.begins_with("work_"):
		GameState.bump_daily(action_id)
		return "打了三小时工，¥150 到手。"

	# 学习
	if action_id.begins_with("course_"):
		var dim2 := String(a.get("dim", ""))
		var r2 := ResourceManager.do_course(dim2, 0.25)
		if bool(r2.get("ok", false)):
			return "%s 能力 → %.2f。" % [dim2, float(r2.get("ability", 0.0))]
		return String(r2.get("reason", ""))

	# 买设备
	if a.has("equip_id"):
		if a.has("money_cost") and GameState.money < int(a["money_cost"]):
			return "钱不够。"
		GameState.add_equipment(String(a["equip_id"]))
		return "买下了。工作台变了。"

	# 买书（必须排在通用 buy_ 之前判断）
	if action_id.begins_with("buy_book_"):
		var tgt := action_id.substr(9)
		GameState.owned_equipment.append("book_%s" % tgt)
		return "买了书，放书架上了。"

	# 买零食：进库存，不当场吃（作者要求）
	if action_id.begins_with("buy_"):
		var buy_key := action_id.substr(4)
		GameState.add_to_inventory(buy_key)
		return "买了%s，放包里了。现在身上有 %d 个。" % [buy_key, GameState.inventory_count(buy_key)]

	return ""


func _location_cn(id: String) -> String:
	var names := {
		"apartment": "出租屋", "bookstore": "书店", "park": "公园",
		"convenience": "便利店", "restaurant": "餐馆", "equipment": "设备店",
	}
	return String(names.get(id, id))
