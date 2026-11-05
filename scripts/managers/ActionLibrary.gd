extends RefCounted
## ActionLibrary｜交互树 + 事件定义
##
## 核心结构（作者 2026-11-05 确认，对应 交互与UI.md 第六节）：
##
##   点击【物体】→ 展开该物体的【事件列表】→ 选中具体事件 → 进入结算器
##
## 点击物体本身**不消耗时间**，只有事件才消耗。
## 所以这里分成两层：
##   objects_at(location)  返回该地点有哪些可点的物体（不耗时）
##   actions_of(object)    返回某个物体能做什么（这才是事件，会耗时）
##
## 数值来源：document/事件管理.md + data/game_data.json

const OBJECT_NAMES := {
	"computer": "电脑", "phone": "手机", "bed": "床", "bookshelf": "书架",
	"door": "门", "window": "窗", "desk": "工作台", "fridge": "冰箱",
	"shelf": "货架", "counter": "柜台", "bench": "长椅", "path": "步道",
	"menu": "菜单", "machine_shelf": "设备货架",
}

const LOCATION_NAMES := {
	"apartment": "出租屋",
	"bookstore": "书店",
	"park": "公园",
	"convenience": "便利店",
	"restaurant": "餐馆",
	"equipment": "设备店",
}

## 每个地点有哪些可点物体。不含「门」——门在底部作为地点切换。
const LOCATION_OBJECTS := {
	"apartment": ["computer", "phone", "bed", "bookshelf", "fridge"],
	"bookstore": ["shelf", "counter"],
	"park": ["bench", "path"],
	"convenience": ["shelf", "counter"],
	"restaurant": ["menu"],
	"equipment": ["machine_shelf"],
}

const TRAVEL := {
	"apartment->bookstore": 10,
	"apartment->equipment": 15,
	"apartment->restaurant": 10,
	"apartment->convenience": 5,
	"apartment->park": 10,
	"bookstore->equipment": 5,
	"equipment->bookstore": 5,
}


## 该地点可以点哪些物体
func objects_at(location_id: String) -> Array:
	var out: Array = []
	for oid in LOCATION_OBJECTS.get(location_id, []):
		out.append({
			"id": String(oid),
			"label": String(OBJECT_NAMES.get(oid, oid)),
		})
	return out


## 某个物体展开后有哪些事件
func actions_of(object_id: String, location_id: String) -> Array:
	match object_id:
		"computer": return _computer_actions()
		"phone": return _phone_actions()
		"bed": return _bed_actions()
		"bookshelf": return _bookshelf_actions()
		"fridge": return _fridge_actions()
		"shelf":
			if location_id == "bookstore":
				return _bookstore_shelf_actions()
			return _convenience_shelf_actions()
		"counter":
			if location_id == "bookstore":
				return _bookstore_counter_actions()
			return _convenience_counter_actions()
		"bench": return _bench_actions()
		"path": return _path_actions()
		"menu": return _menu_actions()
		"machine_shelf": return _equipment_actions()
		_: return []


# ---------- 出租屋 ----------

func _computer_actions() -> Array:
	var out: Array = []

	# 开发：四维
	for dim in ["程序", "美术", "音乐", "文案"]:
		var capped := ResourceManager.is_dim_capped(dim)
		var est := ResourceManager.estimate_dev_gain(dim, 1)
		var ceiling := ResourceManager.dim_ceiling(dim)
		var ability := ResourceManager.effective_ability(dim)
		out.append({
			"id": "dev_%s" % dim,
			"label": "%s开发" % dim,
			"minutes": 60,
			"stamina": -6.0,
			"inspiration": -10,
			"dim": dim,
			"kind": "dev",
			"group": "开发",
			"disabled": capped,
			"disabled_reason": "已到上限 %.1f%%" % ceiling,
			"detail": "+%.2f%%　有效力 %.1f / 上限 %.1f%%" % [est, ability, ceiling],
		})

	# 娱乐：只列出**已拥有/免费**且没看完的
	out.append_array(_entertainment_actions())
	return out


func _entertainment_actions() -> Array:
	var out: Array = []
	var categories := ["动画", "游戏", "小说", "漫画"]
	for cat in categories:
		# 每类只给一部「下一部能看的」，避免一次铺太多（#15）
		var pick := _next_unfinished(cat)
		if pick.is_empty():
			continue
		var rec := DataManager.get_catalog_entry(pick)
		var media_id := String(rec.get("id", pick))
		var minutes := int(rec.get("action_minutes", 30))
		var insp := int(rec.get("inspiration_per_action", 0))
		var steps := int(rec.get("steps", 5))
		var seen := GameState.media_view_count(media_id)
		out.append({
			"id": "media_%s" % media_id,
			"label": "%s《%s》" % [_media_verb(cat), String(rec.get("title", media_id))],
			"minutes": minutes,
			"stamina": -3.0,
			"inspiration": insp,
			"kind": "media",
			"group": "娱乐",
			"media_id": media_id,
			"detail": "%d/%d　灵感 +%d" % [seen, steps, insp],
		})
	return out


func _phone_actions() -> Array:
	# 手机本身不耗时；这里先给「看自己的状态」与「发视频」两个最小项
	return [{
		"id": "phone_check",
		"label": "看一下手机",
		"minutes": 0,
		"stamina": 0.0,
		"kind": "free",
		"drains_stamina": false,
		"detail": "不花时间",
	}]


func _bed_actions() -> Array:
	# 睡觉是「结束今天」，不走结算器，由 UI 直接处理（#8：必须在床边才能睡）
	return [{
		"id": "sleep",
		"label": "睡觉",
		"minutes": 0,
		"stamina": 0.0,
		"kind": "sleep",
		"drains_stamina": false,
		"detail": "结束今天，体力回满",
	}]


func _bookshelf_actions() -> Array:
	var out: Array = []
	# 只有已买的高级书才出现（#15：未解锁不提前显示）
	for book in _advanced_books():
		var key := "book_%d" % int(book["target"])
		if not GameState.owned_equipment.has(key):
			continue
		if float(GameState.dim_ability.get("程序", 0)) >= float(book["target"]) + 1:
			continue
		out.append({
			"id": "read_book_%d" % int(book["target"]),
			"label": "读《%s》一节" % String(book["name"]),
			"minutes": 60,
			"stamina": -6.0,
			"kind": "course",
			"dim": "程序",
			"group": "看书",
			"detail": "程序 +0.25",
		})
	return out


func _fridge_actions() -> Array:
	# 冰箱里只有**已经买回来**的零食（#9：买了要留在身上，不能当场吃）
	var out: Array = []
	for key in GameState.inventory:
		var count := int(GameState.inventory[key])
		if count <= 0:
			continue
		var info := _snack_info(key)
		if info.is_empty():
			continue
		out.append({
			"id": "eat_%s" % key,
			"label": "吃%s" % key,
			"minutes": int(info.get("时长min", 5)),
			"stamina": float(info.get("体力", 0)),
			"kind": "snack",
			"group": "吃东西",
			"drains_stamina": false,
			"detail": "体力 +%d　还剩 %d 个" % [int(info.get("体力", 0)), count],
		})
	return out


# ---------- 书店 ----------

func _bookstore_shelf_actions() -> Array:
	var out: Array = []
	# 免费课：只有在能力还没到对应区间时才出现
	for dim in ["程序", "美术", "音乐", "文案"]:
		var ab := float(GameState.dim_ability.get(dim, 0))
		if ab < 4.0:
			out.append(_course_action(dim, "初级", 90))
		elif ab < 7.0:
			out.append(_course_action(dim, "中级", 90))

	# 高级书：只在程序还没练满时出现（#15）
	if float(GameState.dim_ability.get("程序", 0)) < 10.0:
		for book in _advanced_books():
			var tgt := int(book["target"])
			if float(GameState.dim_ability.get("程序", 0)) < tgt:
				out.append({
					"id": "buy_book_%d" % tgt,
					"label": "买《%s》" % String(book["name"]),
					"minutes": 5,
					"stamina": -1.0,
					"money": -int(book["price"]),
					"kind": "buy_book",
					"group": "买书",
					"require_location": "书店",
					"detail": "程序 %d→%d　¥%d" % [tgt, tgt + 1, int(book["price"])],
				})
	return out


func _course_action(dim: String, level: String, minutes: int) -> Dictionary:
	return {
		"id": "course_%s_%s" % [dim, level],
		"label": "%s%s课" % [dim, level],
		"minutes": minutes,
		"stamina": -9.0,
		"kind": "course",
		"dim": dim,
		"group": "上课",
		"require_location": "书店",
		"detail": "能力 +0.25　免费",
	}


func _bookstore_counter_actions() -> Array:
	return []


# ---------- 公园 ----------

func _bench_actions() -> Array:
	return []


func _path_actions() -> Array:
	var used := GameState.daily_count("walk")
	return [{
		"id": "walk",
		"label": "散步",
		"minutes": 60,
		"stamina": -6.0,
		"inspiration": 8,
		"kind": "walk",
		"group": "走走",
		"disabled": used >= 1,
		"disabled_reason": "今天已经散过步了",
		"detail": "灵感 +8　每天 1 次",
	}]


# ---------- 便利店 ----------

func _convenience_shelf_actions() -> Array:
	# 买零食：买回去放着，不当场吃（#9）
	var out: Array = []
	for key in ["面包", "泡面", "巧克力", "可乐", "能量饮料"]:
		var info := _snack_info(key)
		if info.is_empty():
			continue
		var price := int(info.get("价格", 0))
		out.append({
			"id": "buy_%s" % key,
			"label": "买%s" % key,
			"minutes": 5,
			"stamina": -1.0,
			"money": -price,
			"kind": "buy_snack",
			"group": "买吃的",
			"require_location": "便利店",
			"detail": "¥%d　带回去吃" % price,
		})
	return out


func _convenience_counter_actions() -> Array:
	return [{
		"id": "work_convenience",
		"label": "便利店打工",
		"minutes": 180,
		"stamina": -18.0,
		"inspiration": 5,
		"money": 150,
		"kind": "work",
		"group": "打工",
		"require_location": "便利店",
		"detail": "3 小时　¥150　灵感 +5",
	}]


# ---------- 餐馆 ----------

func _menu_actions() -> Array:
	return [{
		"id": "meal_restaurant",
		"label": "吃餐馆套餐",
		"minutes": 90,
		"stamina": 35.0,
		"money": -30,
		"kind": "meal",
		"group": "吃饭",
		"drains_stamina": false,
		"require_location": "餐馆",
		"detail": "体力 +35　¥30",
	}]


# ---------- 设备店 ----------

func _equipment_actions() -> Array:
	var out: Array = []
	var cfg: Dictionary = DataManager.game_data.get("设备与配件（2026 年当代配置）", {})

	for m in cfg.get("整机（四档，换新取代旧的）", []):
		var price := int(m.get("价格", 0))
		if price <= 0:
			continue
		var mid := "machine_%d" % price
		var unlock_day := _parse_unlock_day(String(m.get("解锁", "")))
		# #15：还没到解锁天数就完全不显示
		if GameState.day < unlock_day:
			continue
		if GameState.owned_equipment.has(mid):
			continue
		out.append({
			"id": mid,
			"label": "买%s" % String(m.get("名称", "")),
			"minutes": 15,
			"stamina": -1.0,
			"money": -price,
			"kind": "equipment",
			"group": "整机",
			"equip_id": mid,
			"detail": "¥%d　%s" % [price, String(m.get("效果", ""))],
		})

	for m in cfg.get("配件（可叠在整机上）", []):
		var price2 := int(m.get("价格", 0))
		if price2 <= 0:
			continue
		var pid := "part_%s" % String(m.get("名称", "")).replace(" ", "")
		if GameState.owned_equipment.has(pid):
			continue
		out.append({
			"id": pid,
			"label": "买%s" % String(m.get("名称", "")),
			"minutes": 5,
			"stamina": -1.0,
			"money": -price2,
			"kind": "equipment",
			"group": "配件",
			"equip_id": pid,
			"detail": "¥%d　%s" % [price2, String(m.get("效果", ""))],
		})
	return out


# ---------- 地点切换 ----------

func travel_options(from_id: String, pending_targets: Array = []) -> Array:
	var out: Array = []
	for to_id in LOCATION_NAMES:
		if to_id == from_id:
			continue
		# 已经在待结算里去过的地点不再重复列出（#7）
		if pending_targets.has(to_id):
			continue
		out.append({
			"id": "goto_%s" % to_id,
			"label": "去%s" % LOCATION_NAMES[to_id],
			"minutes": travel_minutes(from_id, to_id),
			"stamina": -1.0,
			"kind": "travel",
			"group": "出门",
			"target_location": to_id,
		})
	return out


func travel_minutes(from_id: String, to_id: String) -> int:
	var key := "%s->%s" % [from_id, to_id]
	if TRAVEL.has(key):
		return int(TRAVEL[key])
	var a := int(TRAVEL.get("%s->apartment" % from_id, 10))
	var b := int(TRAVEL.get("apartment->%s" % to_id, 10))
	return a + b


# ---------- 共用 ----------

func _snack_info(key: String) -> Dictionary:
	var recovery: Dictionary = DataManager.get_stamina_settings().get("恢复", {})
	return recovery.get(key, {})


func _media_verb(cat: String) -> String:
	match cat:
		"动画": return "看"
		"游戏": return "玩"
		"小说": return "读"
		"漫画": return "看"
		_: return "看"


func _next_unfinished(cat: String) -> String:
	for rec in DataManager.get_catalog_by_category(cat):
		var id := String(rec.get("id", ""))
		if id.is_empty():
			continue
		if GameState.media_view_count(id) < int(rec.get("steps", 5)):
			return id
	return ""


func _advanced_books() -> Array:
	return [
		{"name": "游戏编程模式", "price": 800, "target": 7},
		{"name": "重构", "price": 800, "target": 8},
		{"name": "实时渲染", "price": 800, "target": 9},
	]


func _parse_unlock_day(text: String) -> int:
	var re := RegEx.new()
	re.compile("(\\d+)")
	var m := re.search(text)
	if m == null:
		return 0
	return int(m.get_string(1))


## 把行动翻译成结算器用的字典
func to_settlement(action: Dictionary) -> Dictionary:
	var d := {
		"label": String(action.get("label", "")),
		"minutes": int(action.get("minutes", 0)),
		"drains_stamina": bool(action.get("drains_stamina", true)),
		"action_id": String(action.get("id", "")),
	}
	if action.has("stamina"):
		var st := float(action["stamina"])
		if st < 0:
			d["drains_stamina"] = true
		else:
			d["drains_stamina"] = false
			d["stamina_gain"] = st
	if action.has("inspiration"):
		var ins := int(action["inspiration"])
		var is_dev := String(action.get("kind", "")) == "dev"
		if ins != 0 and not is_dev:
			d["inspiration_gain"] = ins
	if action.has("money"):
		var cost := -int(action["money"])
		if cost > 0:
			d["cost"] = cost
		elif cost < 0:
			d["money_gain"] = -cost
	if action.has("dim"):
		d["dim"] = String(action["dim"])
	return d
