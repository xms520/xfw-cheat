/* GYZWCheat v1 - 光阴之外 (com.gyzw.gameios) JS 逻辑层
 * 引擎: Cocos Creator 2.x + V8 jsb (自定义 fork)
 * 挂点(全部来自明文还原的 assets/script/index.js):
 *  - BtDmgMgr.prototype.updateTargetHp(dmg,target,attacker,shield,skillId)  伤害总入口
 *  - BattleViewHelper.getBattleSpeed(scene) -> {trueSpeed}                 战斗逻辑帧+动画速度
 *  - AdHelper.isAdFree() -> bool                                           激励视频直接成功
 * EUnitType: Lord=1 Hero=2 Monster=3 Bullet=4 Trap=5 Tower=6 AffairNpc=7
 */
(function () {
  if (window.__GYZW) return;
  var F = { kill: false, inv: false, spd: 0, ad: false }; // spd: 0=官方 1=x2 2=x4 3=x8 4=x16
  var SPD = [1, 2, 4, 8, 16];
  var S = { kill: 0, hit: 0 };        // 统计
  var UTYPE_HERO = 2, UTYPE_MONSTER = 3;
  var patched = { dmg: false, spd: false, ad: false };

  function wlog(msg) {
    try {
      var t = new Date().toISOString().substr(11, 8);
      var p = jsb.fileUtils.getWritablePath() + "gyzw.log";
      var old = jsb.fileUtils.isFileExist(p) ? (jsb.fileUtils.getStringFromFile(p) || "") : "";
      jsb.fileUtils.writeStringToFile(old + "[" + t + "] " + msg + "\n", p);
    } catch (e) {}
  }

  function req(name) {
    try { return window.__require(name); } catch (e) { return null; }
  }

  // ---------- patch: 广告 ----------
  function patchAd() {
    if (patched.ad) return;
    var AH = req("AdHelper");
    if (!AH) return;
    try {
      AH.isAdFree = function () { return F.ad ? true : AH.__origAdFree ? AH.__origAdFree.call(this) : false; };
      // 保留原实现引用(只包一次)
      if (!AH.__origAdFree) AH.__origAdFree = function () { return false; };
      // 再补一手: playRewardVideoAd 里 isAdFree 之外还有 debug 广告分支, 主路径已覆盖
      patched.ad = true;
      wlog("patch AdHelper.isAdFree ok");
    } catch (e) { wlog("patchAd exc " + e); }
  }

  // ---------- patch: 战斗速度 ----------
  function patchSpeed() {
    if (patched.spd) return;
    var BVH = req("BattleViewHelper");
    if (!BVH || !BVH.getBattleSpeed) return;
    if (!BVH.__origGetBattleSpeed) BVH.__origGetBattleSpeed = BVH.getBattleSpeed;
    var orig = BVH.__origGetBattleSpeed;
    BVH.getBattleSpeed = function (scene) {
      var r = null;
      try { r = orig.call(this, scene); } catch (e) {}
      if (!r) r = { trueSpeed: 1 };
      if (F.spd > 0 && SPD[F.spd]) {
        r = Object.assign({}, r);
        r.trueSpeed = SPD[F.spd];
        if ("speed" in r) r.speed = SPD[F.spd];
        if ("name" in r) r.name = "x" + SPD[F.spd];
      }
      return r;
    };
    patched.spd = true;
    wlog("patch BattleViewHelper.getBattleSpeed ok");
  }

  // ---------- patch: 伤害(秒杀/无敌) ----------
  function patchDmg() {
    if (patched.dmg) return;
    var BDM = req("BtDmgMgr");
    if (!BDM || !BDM.prototype || !BDM.prototype.updateTargetHp) return;
    if (!BDM.prototype.__origUpdateTargetHp)
      BDM.prototype.__origUpdateTargetHp = BDM.prototype.updateTargetHp;
    var orig = BDM.prototype.__origUpdateTargetHp;
    BDM.prototype.updateTargetHp = function (dmg, target, attacker, shieldDecHp, skillId) {
      try {
        if (target && dmg < 0) {
          // 无敌: 己方(Lord=1/Hero=2)承伤直接吞掉
          if (F.inv && (target.type === 1 || target.type === UTYPE_HERO)) {
            S.hit++;
            return; // 不调原函数 = 无伤/不触发反击等后续
          }
          // 秒杀: 我方打怪 -> 一击打掉全部剩余HP(走正常死亡/掉落/统计流程)
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
    patched.dmg = true;
    wlog("patch BtDmgMgr.updateTargetHp ok");
  }

  // ---------- 轮询 patch ----------
  var tickN = 0;
  function tick() {
    tickN++;
    patchDmg(); patchSpeed(); patchAd();
    if (tickN === 3 || tickN === 30 || tickN % 300 === 0) {
      wlog("tick " + tickN + " patched:" + JSON.stringify(patched) + " flags:" + JSON.stringify(F));
    }
  }
  try {
    cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, tick);
  } catch (e) { wlog("director hook fail " + e); }
  try { setInterval(tick, 500); } catch (e) {}
  tick();
  try { setInterval(flushStats, 3000); } catch (e) {}

  // ---------- 统计落盘(native 状态行读取) ----------
  function flushStats() {
    try {
      jsb.fileUtils.writeStringToFile(JSON.stringify({ kill: S.kill, hit: S.hit, flags: F }),
        jsb.fileUtils.getWritablePath() + "gyzw_stats.json");
    } catch (e) {}
  }
  var _lastFlush = 0;
  function maybeFlush() {
    var now = Date.now();
    if (now - _lastFlush > 2000) { _lastFlush = now; flushStats(); }
  }

  // ---------- native 桥 ----------
  window.__GYZW = {
    ver: "v1",
    setFlag: function (k, v) {
      if (k in F) { F[k] = v; wlog("flag " + k + "=" + v); flushStats(); }
      if (k === "spd" && typeof v === "number") F.spd = v;
      return true;
    },
    getFlags: function () { return JSON.stringify(F); },
    getStats: function () { return JSON.stringify(S); },
    ping: function () { return "pong"; }
  };
  try {
    jsb.fileUtils.writeStringToFile("ok", jsb.fileUtils.getWritablePath() + "gyzw_injected.flag");
  } catch (e) {}
  wlog("GYZWCheat v1 injected, flags=" + JSON.stringify(F));
})();
