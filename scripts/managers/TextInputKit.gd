extends RefCounted
## TextInputKit｜字符选择器（姓名 / 对话通用）
##
## 设计目标（作者 2026-11-05 提出）：
##   1. 不做纯键盘输入，改为「预设字表 + 选择」，避免输入法看不到候选字的问题
##   2. 支持拼音检索：输入 pinyin 片段筛出候选字
##   3. 不限字数、不限语言；只排除游戏角色名与屏蔽词
##   4. 与《孤独之旅》的对话输入复用同一套逻辑
##
## 数据文件：data/name_chars.json
## 结构：
##   { "汉字": [ { "c": "陆", "py": "lu" }, ... ],
##     "符号": ["·", "•", "-"],
##     "屏蔽词": ["..."] }

const CHARS_PATH := "res://data/name_chars.json"

## 全部可选字符，按拼音排序
var chars: Array = []
## 符号表
var symbols: Array = []
## 屏蔽词（完整词组，比对时用于整体拦截）
var blocked_words: Array = []
## 角色名，不允许玩家取
var reserved_names: Array = []

var _loaded := false


func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var d := _read_json(CHARS_PATH)
	for item in d.get("汉字", []):
		if item is Dictionary and item.has("c"):
			chars.append({"c": String(item.get("c", "")), "py": String(item.get("py", ""))})
	symbols = d.get("符号", [])
	blocked_words = d.get("屏蔽词", [])
	reserved_names = DataManager.get_reserved_names()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("TextInputKit: 找不到 %s，使用空表" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parser := JSON.new()
	if parser.parse(f.get_as_text()) != OK:
		f.close()
		return {}
	f.close()
	return parser.data if parser.data is Dictionary else {}


## 按拼音前缀筛字。空串返回全部。
func search(pinyin_prefix: String) -> Array:
	ensure_loaded()
	var key := pinyin_prefix.strip_edges().to_lower()
	if key.is_empty():
		return chars
	var out: Array = []
	for item in chars:
		if String(item["py"]).begins_with(key):
			out.append(item)
	return out


## 校验一个最终名字。只拦「与角色重名」和「屏蔽词」，不限字数与语言。
func validate_name(name: String) -> Dictionary:
	ensure_loaded()
	var text := name.strip_edges()
	if text.is_empty():
		return {"ok": false, "reason": "名字不能为空"}

	# 与角色重名
	if reserved_names.has(text):
		return {"ok": false, "reason": "这个名字已经在故事里有人用了"}

	# 屏蔽词：只要包含就算
	for w in blocked_words:
		var word := String(w)
		if not word.is_empty() and text.contains(word):
			return {"ok": false, "reason": "换个名字吧"}

	return {"ok": true, "name": text}


## 供 UI 使用：返回「拼音 → [字...]」的分组，方便做成横排
func grouped_by_pinyin(prefix: String = "") -> Dictionary:
	var groups := {}
	for item in search(prefix):
		var py := String(item["py"])
		if not groups.has(py):
			groups[py] = []
		groups[py].append(String(item["c"]))
	return groups
