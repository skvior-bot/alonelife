extends Node
## ResourceManager｜开发结算与资源规则
##
## 数据源：game_data.json > 完成度系统 / 灵感系统 / 体力系统 / 课程系统
##
## 这里只算「一次开发产出多少」，不负责记状态（GameState 负责），
## 也不负责推进时间（TimeSystem 负责）。

## 连续开发同一维的小时数，用于心流系数。switch_dim 会清零。
var _flow_hours: int = 0
var _flow_dim: String = ""


## 体力效率系数（数据源：体力系统 > 效率档位）
func stamina_coefficient() -> float:
	return float(GameState.stamina_tier().get("效率系数", 1.0))


## 灵感系数：灵感为 0 时输出 ×0.5（数据源：完成度系统 > 灵感系数）
func inspiration_coefficient() -> float:
	return 1.0 if GameState.inspiration > 0 else 0.5


## 心流系数（数据源：完成度系统 > 心流系数）
func flow_coefficient(dim: String, consecutive_hours: int) -> float:
	if dim != _flow_dim:
		return 1.0
	if consecutive_hours <= 2:
		return 1.0
	if consecutive_hours == 3:
		return 1.05
	if consecutive_hours == 4:
		return 1.1
	if consecutive_hours == 5:
		return 1.15
	return 1.2


## 该维当前能达到的上限（百分点）。
## 规则：上限 = 占比 × min(1, 有效开发力 ÷ 门槛)
func dim_ceiling(dim: String) -> float:
	# 数据源 占比 是小数（程序 0.7），乘 100 换成百分点。
	# 已核验：程序练满 10 → 0.7×100×min(1,10/10) = 70%；
	# 美术 3 无同伴 → 0.15×100×(3/15) = 3%；
	# 满配合计 70+15+5+10 = 100%，与模拟器 share 70/15/5/10 一致。
	var cfg := DataManager.get_completion_settings()
	var share := float(cfg.get("构成", {}).get(dim, {}).get("占比", 0.0))
	var gate := float(cfg.get("能力天花板", {}).get("门槛", {}).get(dim, 1.0))
	var power := effective_ability(dim)
	if gate <= 0.0:
		return share * 100.0
	return share * 100.0 * minf(1.0, power / gate)


## 有效开发力 = 主角该维能力 + 该维同伴能力（只算已招募的）
func effective_ability(dim: String) -> float:
	var self_ability := float(GameState.dim_ability.get(dim, 0.0))
	return self_ability + companion_ability_for(dim)


func companion_ability_for(dim: String) -> float:
	var map := {"许眠": "美术", "唐梨": "音乐", "温野": "文案"}
	var ids := {"许眠": "xumian", "唐梨": "tangli", "温野": "wenye"}
	for cn in map:
		if map[cn] != dim:
			continue
		var cid: String = ids[cn]
		if not GameState.is_recruited(cid):
			return 0.0
		# 数据源：game_data.json > 同伴与好感 > 能力成长
		# 招募时 3 → 剧情1 5 → 剧情2 7 → 剧情3 9；满好感再升到 10
		var comp := GameState.get_companion(cid)
		var stage := int(comp.get("story_stage", 0))
		var aff := int(comp.get("affection", 0))
		var growth: Array = DataManager.game_data.get("同伴与好感", {}).get("能力成长", [])
		var ability := 3.0
		for g in growth:
			var label := String(g.get("阶段", ""))
			if label == "招募时":
				ability = float(g.get("能力", 3))
			elif label.begins_with("好感 20"):
				if stage >= 1: ability = float(g.get("能力", ability))
			elif label.begins_with("好感 40"):
				if stage >= 2: ability = float(g.get("能力", ability))
			elif label.begins_with("好感 60") and not label.contains("满好感"):
				if stage >= 3: ability = float(g.get("能力", ability))
		var aff_cap := int(DataManager.game_data.get("同伴与好感", {}).get("好感上限", 60))
		if aff >= aff_cap:
			for g in growth:
				if String(g.get("阶段", "")).contains("满好感"):
					ability = float(g.get("能力", ability))
		return ability
	return 0.0


## 这一维现在是否已经到上限
func is_dim_capped(dim: String) -> bool:
	var done := float(GameState.dim_done.get(dim, 0.0))
	return done >= dim_ceiling(dim) - 0.0001


## 估算一次开发（1 小时）能推进多少百分点。
## 只用于预览和实际结算，两边调用同一个函数，保证「看到的就是发生的」。
func estimate_dev_gain(dim: String, consecutive_hours: int = 1) -> float:
	var cfg := DataManager.get_completion_settings()
	var power := effective_ability(dim)
	# 每小时完成度(%) = 有效开发力 × 0.02%/点 × 各系数
	var base := power * 0.02
	var gain := base * stamina_coefficient() * inspiration_coefficient()
	gain *= flow_coefficient(dim, consecutive_hours)
	# 设备倍率：暂按 1.0（V10-2 接设备时再从 GameState 读）
	gain *= 1.0
	return gain


## 实际做一小时开发。返回本次结果，供 UI 显示。
func do_dev_hour(dim: String) -> Dictionary:
	if is_dim_capped(dim):
		return {"ok": false, "reason": "%s 已到上限" % dim, "gain": 0.0}

	var gain := estimate_dev_gain(dim, _flow_hours_for(dim) + 1)
	GameState.add_dim_progress(dim, gain)

	# 开发消耗灵感：每小时 -10（数据源：灵感系统 > 开发消耗）
	GameState.change_inspiration(-10)

	_record_flow(dim)

	# 第一次实际开发留一条记忆
	if not GameState.has_flag("FIRST_DEV_HOUR"):
		GameState.add_memory("FIRST_DEV_HOUR", "dev_first", "memory.dev.first", [], ["work"])

	return {
		"ok": true,
		"dim": dim,
		"gain": gain,
		"inspiration_after": GameState.inspiration,
		"capped": is_dim_capped(dim),
	}


func _flow_hours_for(dim: String) -> int:
	return _flow_hours if _flow_dim == dim else 0


func _record_flow(dim: String) -> void:
	if _flow_dim == dim:
		_flow_hours += 1
	else:
		_flow_dim = dim
		_flow_hours = 1


## 做别的事会中断心流（吃饭除外，按数据源原文）
func break_flow(except_meal: bool = false) -> void:
	if except_meal:
		return
	_flow_hours = 0
	_flow_dim = ""


func flow_state() -> Dictionary:
	return {"dim": _flow_dim, "hours": _flow_hours}


## 吃饭：从数据源读具体食物的体力与耗时
func food_info(food_key: String) -> Dictionary:
	return DataManager.get_stamina_settings().get("恢复", {}).get(food_key, {})


## 学习一小时：只有程序有高级书，其余维度靠同伴。
## 课程每节 +0.25（数据源：课程系统）
func do_course(dim: String, gain: float = 0.25) -> Dictionary:
	var cap: float = float(DataManager.get_four_dim_cap().get(dim, 0.0))
	var now: float = float(GameState.dim_ability.get(dim, 0.0))
	if now >= cap:
		return {"ok": false, "reason": "%s 已经到能力上限 %d" % [dim, int(cap)]}
	GameState.dim_ability[dim] = minf(now + gain, cap)
	GameState.state_changed.emit()
	return {"ok": true, "dim": dim, "ability": GameState.dim_ability[dim]}
