"""数值模拟器：按天推进 100 天，跑几条路线，看钱、灵感、完成度能不能算通。

用法：python3 -I tools/sim.py            -> 打印报告
      python3 -I tools/sim.py --md 路径  -> 同时写成 markdown

数字来自 data/game_data.json + 待做清单.md 第一、二节。凡是文档没定、这里自己假设的，
都放在 CFG 里并标了「假设」。第 14 天母亲电话只发放分支剧情道具，不影响经济或关键数值，因此不纳入数值模拟。
"""
import datetime as dt
import sys
from copy import deepcopy

# ---------------------------------------------------------------- 参数
CFG = {
    "days": 100,
    "start_date": dt.date(2026, 5, 28),
    "awake_min": 18 * 60,                      # 06:00~24:00（作者 2026-11-06 的新七段）
    "sleep_min": 4 * 60,                       # 作者要求：每天至少睡 4 小时
    "dev_cap_min": 5 * 60,                     # 每天最多开发 5 小时（模拟玩家体力/注意力上限，避免一天爆肝）
    "money": 600, "insp": 20, "insp_max": 100,
    # 序章 15%：待做清单写的是 10/3/0/2，超过天花板，这里用建议值 12/2/0/1
    "start_done": {"prog": 12, "art": 2, "mus": 0, "txt": 1},
    "share": {"prog": 70, "art": 15, "mus": 5, "txt": 10},
    "threshold": {"prog": 10, "art": 15, "mus": 13, "txt": 14},   # = 满配 -1，留一点容错
    "hero": {"prog": 7, "art": 3, "mus": 1, "txt": 2},
    "hero_max": {"prog": 10, "art": 6, "mus": 4, "txt": 5},
    "rate": 0.02,                               # %/点/小时
    "flow": [1.0, 1.0, 1.05, 1.10, 1.15, 1.20],  # 第 1..6+ 小时
    "stamina_drain": 6,
    "insp_dev": 10,
    # 吃饭（假设）：午饭餐馆 + 晚饭泡面。往返 20 分钟算进午饭
    "meals": [(110, 35, 30), (15, 6, 6)],
    "auto_life_min": 4 * 60,                   # 每天自动扣的生活杂事（通勤/洗漱/发呆）；吃饭另算，合计约 6 小时
    "rent": [(1, 150), (60, 200)],              # 第 N 天起每周房租
    "work": {"min": 180, "money": 150, "insp": 5},   # 与数据框架、事件管理一致：3 小时
    "work_weekdays": {0, 2, 3, 4, 5},           # 便利店 一三五，餐馆 四六
    "rain_days": {13, 20, 21, 25, 28, 29, 34, 37, 41, 42, 48, 60, 67, 76, 77, 88},
    "stream": {"min": 60, "base": 50, "k": 0.05},
    "video": {"min": 30, "k": 0.05, "fans": 10},
    "fans": 100,
    # 课程：每节 +0.25。初/中级免费 90 分钟，高级 60 分钟，高级书 800 元一本 = 4 节
    "course": {"low_min": 90, "high_min": 60, "book": 800, "per_book": 4, "per_day": 2},
    # 娱乐：(名称, 每次分钟, 每次灵感, 部数, 每部价格)
    "fun": [("动画", 30, 6, 20, 0), ("小说", 30, 5, 12, 40), ("漫画", 30, 5, 5, 26),
            ("游戏", 60, 10, 13, 100)],
    "walk": (60, 8),                            # 散步：文档没上限
    "walk_cap_per_day": 1,
    # 同伴
    "companion_dim": {"许眠": "art", "唐梨": "mus", "温野": "txt"},
    "recruit_at": {"许眠": 30, "温野": 30, "唐梨": 50},   # 完成度（假设：按章节）
    "chat": {"min": 15, "aff": 1, "insp": 3},
    "outing": {"min": 180, "aff": 10, "insp": 15, "stamina": 15},
    "story": {"min": 120, "insp": 10, "gates": [20, 40, 60]},
    "outings_per_story": 2,                     # 每段个人剧情之前要一起出门几次
    "ability_by_stage": [3, 5, 7, 9],           # 招募 / 剧情1 / 剧情2 / 剧情3；满好感后 10
    "cowork_weekdays": {0, 1, 2, 3, 4},         # 周一至周五；周末不能一起制作
    "merge": {2: 1.15, 3: 1.30},                # 合流，只乘速度，不进天花板（假设）
    # 内层：到 30/70/90% 各进一次，占游戏内小时
    "inner": {30: 8, 70: 8, 90: 8, 100: 8},   # 每次进内层占外层 8 小时（一个整夜）
    # 设备：(名称, 价格, 最早天数, 效果)
    "machines": [("二手整机", 1800, 10, 1.4), ("主流台式", 5200, 35, 1.8),
                 ("双屏工作站", 11000, 65, 2.2)],
    "parts": [("机械键盘", 300, {"prog": 1.10}), ("2K副屏", 1100, {"prog": 1.10, "txt": 1.05}),
              ("数位板", 900, {"art": 1.15}), ("正版素材", 400, {"art": 1.10, "txt": 1.10}),
              ("监听耳机", 1300, {"mus": 1.20}), ("校色显示器", 2200, {"art": 1.20}),
              ("人体工学椅", 1300, {"_stamina": 1}), ("降噪耳机", 900, {"_insp": 2})],
}

ALL3 = ["许眠", "唐梨", "温野"]

ROUTES = {
    # 基线
    "独狼（不招）":            {"recruit": [], "raise": []},
    "招三人但不培养":          {"recruit": ALL3, "raise": []},
    # 只招一人（其他人完全不招）
    "只招许眠":                {"recruit": ["许眠"], "raise": ["许眠"]},
    "只招唐梨":                {"recruit": ["唐梨"], "raise": ["唐梨"]},
    "只招温野":                {"recruit": ["温野"], "raise": ["温野"]},
    # 招三人，只养一人
    "招三养许眠":              {"recruit": ALL3, "raise": ["许眠"]},
    "招三养唐梨":              {"recruit": ALL3, "raise": ["唐梨"]},
    "招三养温野":              {"recruit": ALL3, "raise": ["温野"]},
    # 招三人，养两人（双养）
    "招三养许眠+唐梨":         {"recruit": ALL3, "raise": ["许眠", "唐梨"]},
    "招三养许眠+温野":         {"recruit": ALL3, "raise": ["许眠", "温野"]},
    "招三养唐梨+温野":         {"recruit": ALL3, "raise": ["唐梨", "温野"]},
    # 只招两人并养满
    "只招许眠+唐梨":           {"recruit": ["许眠", "唐梨"], "raise": ["许眠", "唐梨"]},
    "只招许眠+温野":           {"recruit": ["许眠", "温野"], "raise": ["许眠", "温野"]},
    "只招唐梨+温野":           {"recruit": ["唐梨", "温野"], "raise": ["唐梨", "温野"]},
    # 全满
    "三人全满":                {"recruit": ALL3, "raise": ALL3},
}

DIMS = ["prog", "art", "mus", "txt"]
DIM_CN = {"prog": "程序", "art": "美术", "mus": "音乐", "txt": "文案"}


def stamina_mult(s):
    if s >= 80: return 1.0
    if s >= 50: return 0.85
    if s >= 20: return 0.65
    if s >= 1: return 0.35
    return 0.0


class Sim:
    def __init__(self, cfg, route):
        self.c, self.r = cfg, route
        self.money, self.insp, self.fans = cfg["money"], cfg["insp"], cfg["fans"]
        self.done = dict(cfg["start_done"])
        self.hero = dict(cfg["hero"])
        self.mult, self.parts, self.machine_i = 1.0, [], -1
        self.fun_left = [[n, m, g, cnt * 5, price, 0] for n, m, g, cnt, price in cfg["fun"]]
        self.material = 0          # 玩过/看过的次数 = 能播的素材
        self.streams = self.videos = 0
        self.comp = {}             # 名字 -> dict
        self.inner_done = set()
        self.hours = {k: 0.0 for k in ["开发", "课程", "娱乐", "散步", "打工", "直播视频",
                                       "社交", "吃饭移动", "内层"]}
        self.starved = 0.0         # 灵感 0 时硬写的小时（保留作参考）
        self.last_dev_day = 0      # 上次实际开发的那一天
        self.max_gap_days = 0      # 最长「距上次开发」天数
        self.starve_days = 0       # 以「天」为口径的断供天数
        self.min_money, self.fail = self.money, None
        self.milestones, self.log = {}, []
        self.books = 0
        self.idle = 0.0

    # ---- 工具
    def total(self): return sum(self.done.values())

    def part_mult(self, dim):
        m = 1.0
        for _, _, eff in self.parts:
            m *= eff.get(dim, 1.0)
        return m

    def part_flat(self, key):
        return sum(eff.get(key, 0) for _, _, eff in self.parts)

    def comp_ability(self, name):
        c = self.comp[name]
        if c["stage"] >= 3 and c["aff"] >= 60: return 10
        return self.c["ability_by_stage"][c["stage"]]

    def team(self, dim, present=True):
        p = self.hero[dim]
        for n, c in self.comp.items():
            if self.c["companion_dim"][n] == dim and present:
                p += self.comp_ability(n)
        return p

    def cap(self, dim):
        return self.c["share"][dim] * min(1, self.team(dim) / self.c["threshold"][dim])

    def merge(self):
        """合流：三人里最被冷落的那个人，决定你们三个能一起做多快。"""
        if not self.comp: return 1.0
        low = min(c["aff"] for c in self.comp.values()) if len(self.comp) == 3 else 0
        return min(1.15, 1.0 + 0.025 * (low // 10))

    def rent_today(self, day):
        amt = 0
        for start, v in self.c["rent"]:
            if day >= start: amt = v
        return amt

    # ---- 一天
    def run_day(self, day):
        c = self.c
        date = c["start_date"] + dt.timedelta(days=day - 1)
        wd, rain = date.weekday(), day in c["rain_days"]
        # 睡眠落在 00:00-06:00 夜间，本就不在 awake_min（06:00-24:00）里，不重复扣
        self.t, self.stam = c["awake_min"], self.stam_start

        if day % 7 == 0:
            rent = self.rent_today(day)
            if self.money < rent:
                self.fail = f"第 {day} 天交不起房租（{self.money} < {rent}）"
                return False
            self.money -= rent

        # 内层（上一天跨过阈值，今天进去）
        for th, h in c["inner"].items():
            if th in self.pending_inner:
                self.pending_inner.discard(th)
                self.spend(h * 60, "内层", stamina=False)

        if c["auto_life_min"]:
            self.spend(c["auto_life_min"], "吃饭移动", stamina=False)
        for m, s, cost in c["meals"]:
            self.spend(m, "吃饭移动", stamina=False)
            self.stam = min(100, self.stam + s); self.money -= cost

        self.buy(day)
        self.recruit(day)

        if wd in c["work_weekdays"] and not rain and self.want_money(day):
            self.spend(c["work"]["min"], "打工")
            self.money += c["work"]["money"]; self.add_insp(c["work"]["insp"])

        self.social(day)
        self.courses()

        if self.material > self.streams and self.t >= 60:
            self.spend(c["stream"]["min"], "直播视频")
            self.money += c["stream"]["base"] + int(self.fans * c["stream"]["k"])
            self.fans += 20 + int(self.content_k() * 40); self.streams += 1
        if self.material > self.videos and self.t >= 30:
            self.spend(c["video"]["min"], "直播视频")
            self.money += int(self.fans * c["video"]["k"]); self.fans += c["video"]["fans"]
            self.videos += 1

        self.develop(day, wd)
        self.min_money = min(self.min_money, self.money)
        self.insp = min(c["insp_max"], self.insp + 10)

        # 作者 2026-11-06 新口径：灵感断供按「距上次开发的天数」衡量，不以小时计。
        # 隔 3~4 天没开发算一次断供，超过 4 天就是明显卡住。
        if self.last_dev_day > 0:
            gap = day - self.last_dev_day
            if gap > self.max_gap_days:
                self.max_gap_days = gap
            if gap >= 3:
                self.starve_days += 1
        return True

    def content_k(self):
        return (self.team("txt") + self.team("art")) / 20

    def spend(self, minutes, cat, stamina=True):
        self.t -= minutes
        self.hours[cat] += minutes / 60
        if stamina:
            drain = self.c["stamina_drain"] - self.part_flat("_stamina")
            self.stam = max(0, self.stam - drain * minutes / 60)

    def add_insp(self, v): self.insp = min(self.c["insp_max"], self.insp + v)

    def reserve(self, day):
        return 2 * self.rent_today(day) + 7 * sum(m[2] for m in self.c["meals"])

    def next_target(self, day):
        for i, (n, p, d0, m) in enumerate(self.c["machines"]):
            if i > self.machine_i: return p
        for n, p, eff in self.c["parts"]:
            if n not in [x[0] for x in self.parts]: return p
        return 0

    def want_money(self, day):
        return self.money < self.reserve(day) + self.next_target(day) + 800

    def buy(self, day):
        c = self.c
        # 高级课的书：程序到 7 就要，一共 3 本
        high_need = sum(max(0, self.c["hero_max"][d] - 7) for d in DIMS) / 0.25
        while self.books * c["course"]["per_book"] < high_need and \
                self.money - c["course"]["book"] >= self.reserve(day):
            self.money -= c["course"]["book"]; self.books += 1
        for i, (n, p, d0, m) in enumerate(c["machines"]):
            if i == self.machine_i + 1 and day >= d0 and self.money - p >= self.reserve(day):
                self.money -= p; self.mult = m; self.machine_i = i
                self.log.append(f"第{day}天 买{n}")
        owned = [x[0] for x in self.parts]
        for n, p, eff in c["parts"]:
            if n not in owned and self.money - p >= self.reserve(day) + self.next_machine_gap(day):
                self.money -= p; self.parts.append((n, p, eff)); self.log.append(f"第{day}天 买{n}")

    def next_machine_gap(self, day):
        i = self.machine_i + 1
        if i < len(self.c["machines"]) and day + 10 >= self.c["machines"][i][2]:
            return self.c["machines"][i][1]
        return 0

    def recruit(self, day):
        for n in self.r["recruit"]:
            if n not in self.comp and self.total() >= self.c["recruit_at"][n]:
                self.comp[n] = {"aff": 0, "stage": 0, "outings": 0}
                self.log.append(f"第{day}天 招到{n}")

    def social(self, day):
        c = self.c
        for n in self.r["raise"]:
            if n not in self.comp: continue
            p = self.comp[n]
            if p["aff"] < 60:
                self.spend(c["chat"]["min"], "社交")
                p["aff"] = min(60, p["aff"] + c["chat"]["aff"]); self.add_insp(c["chat"]["insp"])
        # 个人剧情
        for n in self.r["raise"]:
            if n not in self.comp: continue
            p = self.comp[n]
            gates = c["story"]["gates"]
            if p["stage"] < 3 and p["aff"] >= gates[p["stage"]] and p["outings"] >= c["outings_per_story"]:
                self.spend(c["story"]["min"], "社交")
                p["stage"] += 1; p["outings"] = 0; self.add_insp(c["story"]["insp"])
                self.log.append(f"第{day}天 {n} 剧情{p['stage']}")
                return
        # 一起出门：每天最多 1 次，给最落后的人
        cand = [(self.comp[n]["aff"], n) for n in self.r["raise"]
                if n in self.comp and (self.comp[n]["aff"] < 60 or self.comp[n]["outings"] < c["outings_per_story"])
                and self.comp[n]["stage"] < 3]
        days_left = c["days"] - day
        if cand:
            aff, n = min(cand)
            p = self.comp[n]
            need = 60 - aff
            if need > days_left * 0.6 or p["outings"] < c["outings_per_story"] or day % 3 == 0:
                self.spend(c["outing"]["min"], "社交")
                self.stam = max(0, self.stam - c["outing"]["stamina"] + 18)
                p["aff"] = min(60, p["aff"] + c["outing"]["aff"]); p["outings"] += 1
                self.add_insp(c["outing"]["insp"])

    def courses(self):
        c = self.c["course"]
        for _ in range(c["per_day"]):
            ok = []
            for d in DIMS:
                if self.hero_max_gap(d) <= 0: continue
                if self.hero[d] >= 7:
                    used = sum(max(0, self.hero[x] - 7) for x in DIMS) / 0.25
                    if used >= self.books * c["per_book"]: continue
                ok.append(d)
            if not ok: return
            # 先上「离天花板最近、每点最值钱」的那一维
            dim = max(ok, key=lambda d: self.c["share"][d] / self.c["threshold"][d])
            m = c["high_min"] if self.hero[dim] >= 7 else c["low_min"]
            if self.t < m + 240: return
            self.spend(m, "课程")
            self.hero[dim] = round(self.hero[dim] + 0.25, 2)

    def hero_max_gap(self, d): return self.c["hero_max"][d] - self.hero[d]

    def refuel(self, day):
        """灵感不够一小时开发时，找最省时间的娱乐。"""
        best = None
        for f in self.fun_left:
            n, m, g, left, price, bought = f
            if left <= 0: continue
            if price and not bought and self.money - price < self.reserve(day): continue
            rate = g / m
            if best is None or rate > best[0]: best = (rate, f)
        walk_ok = self.c["walk_cap_per_day"] is None or self.walks_today < self.c["walk_cap_per_day"]
        wm, wg = self.c["walk"]
        if best and (best[0] >= wg / wm or not walk_ok):
            f = best[1]
            if f[4] and f[5] == 0:
                self.money -= f[4]; f[5] = 1
            if self.t < f[1]: return False
            self.spend(f[1], "娱乐"); self.add_insp(f[2]); f[3] -= 1
            if f[3] % 5 == 0: f[5] = 0       # 一部看完，下一部要另买
            self.material += 1
            return True
        if walk_ok and self.t >= wm:
            self.spend(wm, "散步"); self.add_insp(wg); self.walks_today += 1
            return True
        return False

    def develop(self, day, wd):
        c = self.c
        cowork = wd in c["cowork_weekdays"]
        flow_i, cur = 0, None
        dev_budget = min(self.t, c.get("dev_cap_min", 9999))
        dev_used = 0
        while self.t >= 60 and dev_used < dev_budget:
            need = c["insp_dev"] - self.part_flat("_insp")
            if self.insp < need and self.refuel(day):
                flow_i = 0; continue
            gains = {}
            for d in DIMS:
                room = self.cap(d) - self.done[d]
                if room <= 1e-9: continue
                p = self.team(d, present=cowork)
                g = p * c["rate"] * self.mult * self.part_mult(d)
                if d != "prog" and cowork and self.comp: g *= self.merge()
                gains[d] = (min(g, room), room)
            if not gains:
                self.idle += self.t / 60; break
            d = max(gains, key=lambda k: gains[k][0])
            if cur is not None and d == cur and gains[d][1] > 1e-9:
                pass
            else:
                flow_i = 0 if d != cur else flow_i
            if d != cur: flow_i, cur = 0, d
            f = c["flow"][min(flow_i, len(c["flow"]) - 1)]
            im = 1.0 if self.insp >= need else 0.5
            if im < 1: self.starved += 1
            g = gains[d][0] / min(1, 1) * stamina_mult(self.stam) * im * f
            g = min(g, self.cap(d) - self.done[d])
            self.done[d] += g
            self.insp = max(0, self.insp - need)
            self.last_dev_day = day
            self.spend(60, "开发"); flow_i += 1; dev_used += 60
            for th in c["inner"]:
                if self.total() >= th and th not in self.inner_done:
                    self.inner_done.add(th); self.pending_inner.add(th)
            for th in (30, 60, 70, 85, 90, 100):
                if self.total() >= th - 1e-6 and th not in self.milestones:
                    self.milestones[th] = day

    def run(self):
        self.stam_start, self.pending_inner = 100, set()
        for day in range(1, self.c["days"] + 1):
            self.walks_today = 0
            if not self.run_day(day): break
        return self


def ending(sim, route):
    if sim.fail: return "坏结局（回家）"
    t = sim.total()
    full = route["raise"] and len(route["raise"]) == 3 and all(
        sim.comp.get(n, {}).get("stage", 0) == 3 and sim.comp[n]["aff"] >= 60 for n in route["raise"])
    if t >= 99.95 and full: return "真结局"
    if t >= 85: return "好结局"
    if t >= 60: return "普通结局"
    return "坏结局"


def report(cfg=CFG, title="基准"):
    out = [f"### {title}", "",
           "| 路线 | 完成度 | 程序/美术/音乐/文案 | 到 30/70/85/100% 的天 | 结局 | 最低余额 | 第100天余额 | 粉丝 | 最长不开发天数 | 断供天数 | 闲置小时 |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    details = []
    for name, r in ROUTES.items():
        s = Sim(deepcopy(cfg), r).run()
        ms = "/".join(str(s.milestones.get(k, "—")) for k in (30, 70, 85, 100))
        dims = "/".join(f"{s.done[d]:.1f}" for d in DIMS)
        out.append(f"| {name} | {s.total():.1f}% | {dims} | {ms} | {ending(s, r)} | {s.min_money} | {s.money} | {s.fans} | {s.max_gap_days} | {s.starve_days} | {s.idle:.0f} |")
        hrs = "、".join(f"{k} {v:.0f}" for k, v in s.hours.items() if v)
        details.append(f"- **{name}** 工时：{hrs}（合计 {sum(s.hours.values()):.0f} 小时）")
        if s.fail: details.append(f"  - {s.fail}")
    return "\n".join(out + [""] + details + [""])


if __name__ == "__main__":
    from copy import deepcopy
    text = ["# 数值模拟结果", "",
            "> 由 `tools/sim.py` 生成。数字按一套固定策略跑出来，看趋势，别当精确值。",
            "> 改数先改本文件顶部的 CFG，跑一遍，再改 `data/game_data.json`。", ""]
    text.append(report(CFG, "最终方案"))
    a = deepcopy(CFG); a["stream"]["k"] = 0.25
    text.append(report(a, "对比 1：直播收入不压（50 + 粉丝 x 0.25）—— 钱多到没意义"))
    b = deepcopy(CFG); b["auto_life_min"] = 0
    text.append(report(b, "对比 2：不自动扣生活时间（每天多 4 小时）—— 时间太松"))
    c = deepcopy(CFG); c["threshold"] = {d: 1 for d in DIMS}
    text.append(report(c, "对比 3：去掉能力天花板 —— 一个人也能做满，主题被推翻"))
    md = "\n".join(text)
    print(md)
    if "--md" in sys.argv:
        open(sys.argv[sys.argv.index("--md") + 1], "w", encoding="utf-8").write(md)
