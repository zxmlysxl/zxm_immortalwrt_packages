-- znetcontrol 通用主题配色（主题无关：kucat / bootstrap / material / 默认主题均可用）
--
-- 机制：两套配色（浅色默认 + 暗色覆盖），运行时检测当前页面实际生效的模式后
-- 注入对应那套 CSS 变量，插件内所有写死颜色全部改为 var(--znc-*) 引用。
-- 不绑定任何具体主题，也不依赖某个主题的 UCI 配置：
--   检测优先级：
--     ① <html data-mode="dark|light">（任何主题可自行声明，预留扩展点）
--     ② 读主题 :root 的 --primary-rgbbody 变量实测明暗（kucat 暗色=33,45,60，
--        亮色=244,245,247；bootstrap/material 没这个变量则跳过）
--     ③ prefers-color-scheme 系统偏好兜底
--     ④ 默认 light
-- 用法：
--   htm 视图顶部:  <%- include("znetcontrol/theme") -%>  （或直接 require 后调用 znc.css_default() 等）
--   CSS:           所有颜色写 var(--znc-xxx, 浅色值)
--   JS 初始化:     znc.apply()  （检测 + 注入暗色块）

local M = {}

-- 颜色 token：{ 浅色值, 暗色值 }
M.tok = {
	table_bg        = { "rgba(255,255,255,0.92)", "rgba(30,34,40,0.92)" },
	table_header_bg = { "#f1f3f5",                "rgba(255,255,255,0.10)" },
	box_bg          = { "rgba(0,0,0,0.03)",       "rgba(255,255,255,0.07)" },
	primary_text    = { "#2d3748",                 "#e4e4e4" },
	primary_bg      = { "#eef4fb",                 "rgba(64,120,244,0.12)" },
	primary_border  = { "#c5d8f2",                 "rgba(64,120,244,0.40)" },
	secondary_text  = { "#718096",                 "#a0a0a0" },
	border          = { "rgba(0,0,0,0.08)",       "rgba(255,255,255,0.15)" },
	hover_bg        = { "rgba(0,0,0,0.03)",       "rgba(255,255,255,0.07)" },
	card_bg         = { "#ffffff",                 "#23272e" },
	code_bg         = { "rgba(0,0,0,0.06)",       "rgba(255,255,255,0.08)" },
	log_bg          = { "#ffffff",                 "#17191d" },
	log_text        = { "#1a202c",                 "#f0f0f0" },
	log_info        = { "#2563eb",                 "#9cdcfe" },
	log_info_bg     = { "rgba(37,99,235,0.05)",      "rgba(156,220,254,0.08)" },
	log_ts          = { "#1e40af",                 "#569cd6" },
	log_ok          = { "#155724",                 "#6a9955" },
	log_warn        = { "#856404",                 "#ffcc00" },
	log_err         = { "#a62121",                 "#ce9178" },
	log_stat        = { "#0f766e",                 "#4ec9b0" },
	-- 管控解除/规则移除用橙色，与"添加生效"(绿)形成对比
	log_removed     = { "#c2410c",                 "#d7ba7d" },
	log_border      = { "rgba(0,0,0,0.10)",       "rgba(255,255,255,0.20)" },
	input_bg        = { "#ffffff",                 "rgba(255,255,255,0.08)" },
	input_border    = { "rgba(0,0,0,0.25)",       "rgba(255,255,255,0.25)" },
	success_bg      = { "#d4edda",                 "rgba(40,167,69,0.18)" },
	success_text    = { "#155724",                 "#4fd67a" },
	success_border  = { "#c3e6cb",                 "rgba(40,167,69,0.45)" },
	warn_bg         = { "#fff3cd",                 "rgba(255,193,7,0.16)" },
	warn_text       = { "#856404",                 "#ffd75e" },
	warn_border     = { "#ffeeba",                 "rgba(255,193,7,0.40)" },
	danger_bg       = { "#f8d7da",                 "rgba(220,53,69,0.18)" },
	danger_text     = { "#721c24",                 "#ff8a95" },
	danger_border   = { "#f5c6cb",                 "rgba(220,53,69,0.45)" },
	badge_shadow    = { "inset 0 -2px 4px rgba(0,0,0,0.06)", "inset 0 -2px 4px rgba(0,0,0,0.35)" },
}

local function sorted_names()
	local names = {}
	for name in pairs(M.tok) do table.insert(names, name) end
	table.sort(names)
	return names
end

-- 生成 :root CSS 变量块；mode = 'light' | 'dark'
function M.root(mode, sel)
	local idx = (mode == 'dark') and 2 or 1
	sel = sel or ":root"
	local out = { sel .. " {" }
	for _, name in ipairs(sorted_names()) do
		-- 变量名用连字符: token 名 log_bg -> --znc-log-bg
		-- (htm 里一律用 var(--znc-log-bg) 引用, 下划线会导致全部落空 fallback)
		local var = name:gsub("_", "-")
		table.insert(out, string.format("  --znc-%s: %s;", var, M.tok[name][idx]))
	end
	table.insert(out, "}")
	return table.concat(out, "\n")
end

-- 浅色默认值 CSS（写进页面 <style>，暗色检测到时注入同名变量块覆盖）
function M.css_default()
	return M.root("light")
end

-- JSON 字符串转义（用于把 CSS 块嵌进 JS）
local function json_escape(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	return '"' .. s .. '"'
end

-- 检测函数 JS（内嵌进页面 <script>）
M.js_detect = [[
// 配色模式存储键: znc_mode = 'dark' | 'light' | 不存在=自动
function znetcontrolGetOverride(){
  try {
    var v = window.localStorage.getItem('znc_mode');
    if (v === 'dark' || v === 'light') return v;
  } catch (e) {}
  return null;
}
function znetcontrolSetOverride(v){
  try {
    if (v === 'dark' || v === 'light') window.localStorage.setItem('znc_mode', v);
    else window.localStorage.removeItem('znc_mode');
  } catch (e) {}
}
function znetcontrolParseColor(c) {
  if (!c || c.indexOf('rgb') !== 0) return null;
  var m = c.match(/[0-9.]+/g);
  if (!m || m.length < 3) return null;
  var a = m.length > 3 ? parseFloat(m[3]) : 1;
  if (a <= 0.5) return null;
  return [parseFloat(m[0]), parseFloat(m[1]), parseFloat(m[2])];
}
function znetcontrolLum(c) {
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
// 从内容容器往上找第一个不透明背景 = 用户眼睛看到的底色
function znetcontrolContentBg(){
  var el = document.querySelector('.cbi-map') || document.body || document.documentElement;
  while (el && el.nodeType === 1) {
    var c = znetcontrolParseColor(getComputedStyle(el).backgroundColor);
    if (c) return c;
    el = el.parentElement;
  }
  return null;
}
// 供页面显示的实测信息
function znetcontrolProbe(){
  var o = {mode:null, bg:null, bodyBg:null, bodyColor:null, lum:null};
  try { o.bodyBg = getComputedStyle(document.body).backgroundColor; } catch(e){}
  try { o.bodyColor = getComputedStyle(document.body).color; } catch(e){}
  var bg = znetcontrolContentBg();
  if (bg) { o.bg = 'rgb('+Math.round(bg[0])+', '+Math.round(bg[1])+', '+Math.round(bg[2])+')'; o.lum = Math.round(znetcontrolLum(bg)); }
  o.mode = znetcontrolDetectMode();
  return o;
}
function znetcontrolDetectMode(){
  // 1) 手动覆盖 (localStorage, 页面上的开关写入)
  var ov = znetcontrolGetOverride();
  if (ov) return ov;
  // 2) URL 强制: ?znc=dark / ?znc=light
  try {
    var q = (window.location.search || '') + (window.location.hash || '');
    var mm = q.match(/[?&]znc=(dark|light)/);
    if (mm) return mm[1];
  } catch (e) {}
  // 3) 主题显式声明
  var dm = document.documentElement.getAttribute('data-mode');
  if (dm === 'dark' || dm === 'light') return dm;
  // 4) 实测内容区实际背景色 (最可靠: 看到什么就是什么)
  var bg = znetcontrolContentBg();
  if (bg) return znetcontrolLum(bg) < 128 ? 'dark' : 'light';
  // 5) 实测页面文字色: 文字亮 => 暗色主题
  try {
    var tc = znetcontrolParseColor(getComputedStyle(document.body).color);
    if (tc) return znetcontrolLum(tc) < 128 ? 'light' : 'dark';
  } catch (e) {}
  // 6) 系统偏好
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
  // 7) 默认
  return 'light';
}
]]

-- 应用函数 JS：检测 + 注入暗色变量块
function M.js_apply()
	-- 暗色块选择器用 :root:root (优先级 0,2,0 > 亮色块 :root 的 0,1,0),
	-- 且必须插到 body 末尾 —— 页面默认亮色 :root 块写在 body 里,
	-- 同优先级时靠后声明者才生效, 插 head 会被 body 里的亮色块反向覆盖。
	local json = json_escape(M.root("dark", ":root:root"))
	return string.format([[
function znetcontrolApplyTheme() {
  var mode = znetcontrolDetectMode();
  var existing = document.getElementById('znetcontrol-theme-style');
  if (existing) existing.remove();
  if (mode === 'dark') {
    var s = document.createElement('style');
    s.id = 'znetcontrol-theme-style';
    s.textContent = %s;
    (document.body || document.head).appendChild(s);
  }
  document.documentElement.setAttribute('data-zncolor', mode);
  return mode;
}
// 手动切换配色: v = 'dark' | 'light' | null(回到自动)
function znetcontrolSetMode(v) {
  znetcontrolSetOverride(v);
  return znetcontrolApplyTheme();
}
]], json)
end

-- 一段可直接内嵌的完整 JS（检测 + 应用）
function M.js_bundle()
	return M.js_detect .. "\n" .. M.js_apply()
end


-- ============ 2.3.13：规则下发状态（缺陷③） ============
-- 目的：让用户能区分"规则已下发但设备无流量命中"与"规则根本没下发"。
-- 数据由 /admin/control/znetcontrol/api/rule_status 提供（控制器解析 nft 链得出）。

-- 取 LuCI 内部 URL；不可用时退回相对路径（页面都在 .../znetcontrol/ 下）
function M.api_url(path)
	local ok, d = pcall(require, "luci.dispatcher")
	if ok and type(d) == "table" and type(d.build_url) == "function" then
		local ok2, u = pcall(d.build_url, path)
		if ok2 and type(u) == "string" and u ~= "" then
			return u
		end
	end
	return (path:gsub("^admin/control/znetcontrol/", ""))
end

function M.rule_status_html()
	return [[<div class="cbi-section" id="znc-rule-status-section">
<h3>规则下发状态</h3>
<style>
.znc-rs-table{width:100%;border-collapse:collapse;margin-bottom:8px;}
.znc-rs-table th,.znc-rs-table td{padding:8px 10px;border-bottom:1px solid rgba(128,128,128,.25);text-align:left;font-size:13px;vertical-align:top;}
.znc-rs-table th{font-weight:600;background:rgba(128,128,128,.10);}
.znc-rs-badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:12px;font-weight:600;white-space:nowrap;}
.znc-rs-badge.ok{background:rgba(40,167,69,.18);color:#155724;}
.znc-rs-badge.warn{background:rgba(255,193,7,.20);color:#856404;}
.znc-rs-badge.bad{background:rgba(220,53,69,.18);color:#721c24;}
.znc-rs-badge.off{background:rgba(128,128,128,.18);color:#555;}
.znc-rs-note{font-size:11px;opacity:.75;margin-top:3px;}
.znc-rs-foot{font-size:12px;opacity:.7;margin-top:6px;}
.znc-rs-empty{text-align:center;padding:20px;}
</style>
<table class="znc-rs-table">
<thead><tr><th>规则</th><th>目标</th><th>启用</th><th>时间判定</th><th>nft 状态</th><th>命中包数</th><th>命中字节</th><th>结论</th></tr></thead>
<tbody id="znc-rs-body"><tr><td colspan="8" class="znc-rs-empty">正在加载规则状态...</td></tr></tbody>
</table>
<div class="znc-rs-foot"><button type="button" class="cbi-button cbi-button-action" onclick="zncRefreshRuleStatus()">刷新状态</button> <span id="znc-rs-time"></span></div>
</div>]]
end

function M.rule_status_js(url)
	url = url or "api/rule_status"
	local js = [[
(function(){
  function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
  function fmtBytes(b){ b=Number(b)||0; if(b<1024) return b+' B'; var u=['KB','MB','GB','TB']; var i=-1; do{ b=b/1024; i++; }while(b>=1024 && i<u.length-1); return b.toFixed(1)+' '+u[i]; }
  function badge(t,c){ return '<span class="znc-rs-badge '+(c||'off')+'">'+esc(t)+'</span>'; }
  function td(v){ return '<td>'+v+'</td>'; }
  function row(cells, cls){
    var h='<tr>';
    for(var i=0;i<cells.length;i++){
      var c=(cls&&cls[i])||'';
      h+=td(c===''?esc(cells[i]):badge(cells[i],c));
    }
    return h+'</tr>';
  }
  function render(rows){
    var body=document.getElementById('znc-rs-body');
    if(!body) return;
    if(!rows||!rows.length){ body.innerHTML='<tr><td colspan="8">暂无规则</td></tr>'; return; }
    var h='';
    for(var i=0;i<rows.length;i++){
      var r=rows[i];
      var tc='off';
      if(r.time_state==='in_time') tc='ok';
      else if(r.time_state!=='disabled') tc='warn';
      var nf=r.nft_present?('已下发 handle '+(r.nft_handle||'?')):'未下发';
      var nfc=r.nft_present?'ok':'bad';
      var st=r.status||'';
      var sc='off';
      if(st.indexOf('已下发并已命中')>=0) sc='ok';
      else if(st.indexOf('无流量命中')>=0) sc='warn';
      else if(st.indexOf('未下发')>=0) sc='bad';
      var pk=(r.packets===null||r.packets===undefined)?'-':String(r.packets);
      var by=(r.bytes===null||r.bytes===undefined)?'-':fmtBytes(r.bytes);
      var en=r.enable?'已启用':'未启用';
      var enc=r.enable?'ok':'off';
      var tt=r.time_text||'-';
      h+=row([r.name,r.target,en,tt,nf,pk,by,st],['','',enc,tc,nfc,'','',sc]);
    }
    body.innerHTML=h;
    var t=document.getElementById('znc-rs-time');
    if(t) t.textContent='更新时间：'+new Date().toLocaleString();
  }
  function refresh(){
    var body=document.getElementById('znc-rs-body');
    fetch('__ZNC_URL__').then(function(r){return r.json();}).then(render).catch(function(e){
      if(body) body.innerHTML='<tr><td colspan="8">加载失败：'+esc(e.message)+'</td></tr>';
    });
  }
  window.zncRefreshRuleStatus=refresh;
  window.zncRenderRuleStatus=render;
  if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded',refresh); } else { refresh(); }
})();
]]
	return (js:gsub("__ZNC_URL__", function() return url end))
end

return M
