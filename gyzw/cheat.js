/* GYZWCheat v4-test - 光阴之外 JS 逻辑层 (无互联锁测试版)
 * v4 新增:
 *  1. 自动拾取: 绕过 AutoPickup(1026) 权限, 定时 pickUpAllDropItems -> 服务器发奖
 *  2. 解锁主线: patch sectTire 配置 levelMainLimit=9999 (解除 UI 灰锁, 服务器是否放行未知)
 *  3. GM 面板: IS_OPEN_GM=true 显示 GM 按钮 + 直调 GmModel.C_Gm (服务器验权, 大概率被拒)
 * 保留 v2: 命名导出挂点 + 上下文重建自愈 + 反作弊规避(__GYZW 非 frida 特征)
 */
(function () {
  if (window.__GYZW && window.__GYZW.ver === "v4") return;
  var F = { kill: false, inv: false, spd: 0, ad: false, pick: false, lvl: false, gm: false };
  var SPD = [1, 2, 4, 8, 16];
  var S = { kill: 0, hit: 0, pick: 0 };
  var UTYPE_HERO = 2, UTYPE_MONSTER = 3;
  var patched = { dmg: false, spd: false, ad: false, lvl: false, gm: false };

  function wlog(msg) {
    try {
      var t = new Date().toISOString().substr(11, 8);
      var p = jsb.fileUtils.getWritablePath() + "gyzw.log";
      var old = jsb.fileUtils.isFileExist(p) ? (jsb.fileUtils.getStringFromFile(p) || "") : "";
      if (old.length > 60000) old = old.substr(old.length - 30000);
      jsb.fileUtils.writeStringToFile(old + "[" + t + "] " + msg + "\n", p);
    } catch (e) {}
  }

  function getMod(name, sub) {
    try {
      var m = window.__require(name);
      if (!m) return null;
      if (sub) return m[sub] || null;
      return m;
    } catch (e) { return null; }
  }

  // ---------- patch: 广告 ----------
  function patchAd() {
    var AH = getMod("AdHelper", "AdHelper") || getMod("AdHelper");
    if (!AH || typeof AH.isAdFree !== "function") return;
    if (AH.__gyzwW) { patched.ad = true; return; }
    var orig = AH.isAdFree;
    AH.isAdFree = function () {
      try { if (F.ad) return true; } catch (e) {}
      return orig.apply(this, arguments);
    };
    AH.__gyzwW = orig;
    patched.ad = true;
    wlog("patch AdHelper.isAdFree ok(v4)");
  }

  // ---------- patch: 战斗速度 ----------
  function patchSpeed() {
    var BVH = getMod("BattleViewHelper", "BattleViewHelper") || getMod("BattleViewHelper");
    if (!BVH || typeof BVH.getBattleSpeed !== "function") return;
    if (BVH.__gyzwW) { patched.spd = true; return; }
    var orig = BVH.getBattleSpeed;
    BVH.getBattleSpeed = function (scene) {
      var r = null;
      try { r = orig.apply(this, arguments); } catch (e) {}
      if (!r) r = { trueSpeed: 1 };
      if (F.spd > 0 && SPD[F.spd]) {
        r = Object.assign({}, r);
        r.trueSpeed = SPD[F.spd];
        if ("speed" in r) r.speed = SPD[F.spd];
        if ("name" in r) r.name = "x" + SPD[F.spd];
      }
      return r;
    };
    BVH.__gyzwW = orig;
    patched.spd = true;
    wlog("patch BattleViewHelper.getBattleSpeed ok(v4)");
  }

  // ---------- patch: 伤害(秒杀/无敌) ----------
  function patchDmg() {
    var BDM = getMod("BtDmgMgr", "default") || getMod("BtDmgMgr");
    if (!BDM || !BDM.prototype || typeof BDM.prototype.updateTargetHp !== "function") return;
    if (BDM.prototype.__gyzwW) { patched.dmg = true; return; }
    var orig = BDM.prototype.updateTargetHp;
    BDM.prototype.updateTargetHp = function (dmg, target, attacker, shieldDecHp, skillId) {
      try {
        if (target && dmg < 0) {
          if (F.inv && (target.type === 1 || target.type === UTYPE_HERO)) {
            S.hit++;
            return;
          }
          if (F.kill && target.type === UTYPE_MONSTER && attacker &&
            (attacker.type === UTYPE_HERO || attacker.type === 1)) {
            dmg = -(target.curHp || 0) - 1;
            S.kill++;
            maybeFlush();
          }
        }
      } catch (e) { wlog("dmg exc " + e); }
      return orig.call(this, dmg, target, attacker, shieldDecHp, skillId);
    };
    BDM.prototype.__gyzwW = orig;
    patched.dmg = true;
    wlog("patch BtDmgMgr.updateTargetHp ok(v4)");
  }

  // ---------- patch: 解锁主线(境界封印) ----------
  // ConfMgr.getConf("sectTire") 返回配置表; 把 levelMainLimit 改大到 99999
  // ⚠️ 仅解除客户端 UI 锁, 服务器是否放行 msg_mainlevel_begin 未知
  function patchLvl() {
    var CM = getMod("ConfMgr") || getMod("ConfMgr", "confMgr");
    if (!CM) {
      // confMgr 是命名导出
      var mm = getMod("ConfMgr");
      if (mm && mm.confMgr) CM = mm.confMgr;
    }
    if (!CM || typeof CM.getConf !== "function") return;
    if (patched.lvl) return;
    var tbl = null;
    try { tbl = CM.getConf("sectTire"); } catch (e) {}
    if (!tbl) return;
    var changed = 0;
    try {
      if (tbl.length !== undefined) { // array by index
        for (var i = 0; i < tbl.length; i++) {
          if (tbl[i] && typeof tbl[i].levelMainLimit === "number") {
            tbl[i].levelMainLimit = 99999;
            changed++;
          }
        }
      } else { // object keyed by id
        for (var k in tbl) {
          if (tbl[k] && typeof tbl[k].levelMainLimit === "number") {
            tbl[k].levelMainLimit = 99999;
            changed++;
          }
        }
      }
    } catch (e) { wlog("lvl exc " + e); }
    patched.lvl = true;
    wlog("patch sectTire.levelMainLimit ok(v4) x" + changed);
  }

  // ---------- patch: GM 面板显示 ----------
  function patchGm() {
    if (patched.gm) return;
    var mc = getMod("MyConfig") || getMod("MyConfig", "MyConfig") || getMod("MyConfig", "myConfig");
    var cfg = null;
    if (mc) {
      cfg = mc.myConfig || mc.MyConfig || (typeof mc === "object" && mc.IS_DEBUG !== undefined ? mc : null);
    }
    if (!cfg) return;
    try {
      cfg.IS_OPEN_GM = true;   // 主城顶部 GM 按钮显示
      cfg.IS_DEBUG = false;    // 保持关闭避免触发额外调试 UI/服务器标记
    } catch (e) { return; }
    patched.gm = true;
    wlog("patch MyConfig.IS_OPEN_GM ok(v4)");
  }

  // ---------- 自动拾取 ----------
  // 更稳: 直接 wrap MainMapView._pickUpAllDropItems 的权限检查,
  // hasRight(AutoPickup) 恒 true -> 复用游戏自身的完整拾取逻辑(含两 field 分组遍历)
  function patchPick() {
    var MMV = getMod("MainMapView");
    if (!MMV || !MMV.prototype || !MMV.prototype._pickUpAllDropItems) return false;
    if (MMV.prototype.__gyzwPick) return true;
    var RM = getMod("RightsModel") || getMod("RightsModel", "RightsModel");
    if (!RM || !RM.prototype || !RM.prototype.hasRight) return false;
    // hasRight(1026 AutoPickup) 恒 true (F.pick 开启时)
    var origHas = RM.prototype.hasRight;
    RM.prototype.hasRight = function (rightId) {
      try { if (F.pick && rightId === 1026) return true; } catch (e) {}
      return origHas.call(this, rightId);
    };
    RM.prototype.__gyzwPick = origHas;
    // 保存引用供 pickLoop 直调实例方法
    window.__gyzwMainMapViewCtor = MMV;
    patched.pick = true;
    wlog("patch RightsModel.hasRight(AutoPickup) ok(v4)");
    return true;
  }

  // 每 4s 一次自动拾取: 找到 MainMapView 实例后走游戏原版逻辑
  function autoPick() {
    if (!F.pick || !patched.pick) return;
    try {
      var ctor = window.__gyzwMainMapViewCtor;
      if (!ctor || !ctor.prototype) return;
      // 实例查找: 遍历场景节点拿 MainMapView 组件
      var scene = cc.director.getScene();
      if (!scene) return;
      var found = null;
      var walk = function (node) {
        if (found || !node) return;
        var comp = node.getComponent && node.getComponent(ctor);
        if (comp) { found = comp; return; }
        var ch = node.children;
        for (var i = 0; ch && i < ch.length; i++) walk(ch[i]);
      };
      walk(scene);
      if (!found) return;
      // 模拟权限同步事件: 游戏原版 _pickUpAllDropItems(data) 只读 data.rightList 或 hasRight
      // hasRight 已被我们恒真, 直接传空 data 即可
      found._pickUpAllDropItems({});
    } catch (e) { wlog("pick exc " + e); }
  }

  // 每 4s 一次自动拾取(拾取请求本身有服务器去重, 不怕重复)
  function pickLoop() {
    if (F.pick) { patchPick(); autoPick(); }
  }

  // ---------- 统计落盘 ----------
  function flushStats() {
    try {
      jsb.fileUtils.writeStringToFile(JSON.stringify({ ts: Date.now(), kill: S.kill, hit: S.hit, pick: S.pick, flags: F, patched: patched }),
        jsb.fileUtils.getWritablePath() + "gyzw_stats.json");
    } catch (e) {}
  }
  var _lastFlush = 0;
  function maybeFlush() {
    var now = Date.now();
    if (now - _lastFlush > 2000) { _lastFlush = now; flushStats(); }
  }

  // ---------- 轮询 patch ----------
  var tickN = 0;
  function tick() {
    tickN++;
    patchDmg(); patchSpeed(); patchAd();
    if (F.lvl) patchLvl();
    if (F.gm) patchGm();
    if (F.pick) patchPick();
    if (tickN === 3 || tickN === 30 || tickN % 600 === 0) {
      wlog("tick " + tickN + " patched:" + JSON.stringify(patched));
    }
  }
  try {
    cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, tick);
  } catch (e) { wlog("director hook fail " + e); }
  try { setInterval(tick, 500); } catch (e) {}
  try { setInterval(pickLoop, 3000); } catch (e) {}
  try { setInterval(flushStats, 3000); } catch (e) {}
  tick();
  flushStats();

  // ---------- GM 面板直调(native 面板调) ----------
  function sendGm(cmd, args) {
    var GM = getMod("GmModel") || getMod("GmModel", "GmModel");
    if (!GM || !GM.prototype || !GM.prototype.C_Gm) { wlog("gm: model not found"); return false; }
    try {
      // C_Gm 是实例方法, 需要 GmModel 实例: 走 ModelMgr 拿
      var MM = getMod("ModelMgr") || getMod("ModelMgr", "modelMgr");
      var inst = null;
      if (MM) {
        var mmm = MM.modelMgr || MM;
        try { inst = mmm.get(26); } catch (e) {} // EModelType.Gm 未知, 尝试
      }
      if (inst && inst.C_Gm) {
        var full = cmd + (args && args.length ? "(" + args.join(",") + ")" : "");
        inst.C_Gm(full);
        wlog("gm sent: " + full);
        return true;
      }
      wlog("gm: instance not found");
      return false;
    } catch (e) { wlog("gm exc " + e); return false; }
  }

  // ---------- native 桥 ----------
  window.__GYZW = {
    ver: "v4",
    setFlag: function (k, v) {
      if (k in F) { F[k] = v; wlog("flag " + k + "=" + v); flushStats(); }
      return true;
    },
    gm: sendGm,
    getFlags: function () { return JSON.stringify(F); },
    getStats: function () { return JSON.stringify(S); },
    ping: function () { return "pong-v4"; }
  };
  try {
    jsb.fileUtils.writeStringToFile("ok", jsb.fileUtils.getWritablePath() + "gyzw_injected.flag");
  } catch (e) {}
  wlog("GYZWCheat v4 injected, flags=" + JSON.stringify(F));
})();
