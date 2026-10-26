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
		table.insert(out, string.format("  --znc-%s: %s;", name, M.tok[name][idx]))
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
// 最简可靠方案: 只量"页面实际渲染出来的背景色", 不猜主题变量。
// 判据优先级: 手动覆盖 > 主题显式声明 > 实测内容区背景 > 实测文字色 > 系统偏好 > light
function znetcontrolParseColor(c) {
  if (!c || c.indexOf('rgb') !== 0) return null;
  var m = c.match(/[0-9.]+/g);
  if (!m || m.length < 3) return null;
  var a = m.length > 3 ? parseFloat(m[3]) : 1;
  if (a <= 0.5) return null;              // 透明色不算, 继续往上找
  return [parseFloat(m[0]), parseFloat(m[1]), parseFloat(m[2])];
}
function znetcontrolLum(c) {
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
// 从内容容器往上找第一个"不透明"的背景, 这就是用户眼睛看到的底色
function znetcontrolContentBg() {
  var el = document.querySelector('.cbi-map') || document.body || document.documentElement;
  while (el && el.nodeType === 1) {
    var c = znetcontrolParseColor(getComputedStyle(el).backgroundColor);
    if (c) return c;
    el = el.parentElement;
  }
  return null;
}
function znetcontrolDetectMode() {
  // 0) 手动覆盖: URL 加 ?znc=dark 或 ?znc=light (调试/强制用)
  try {
    var q = (window.location.search || '') + (window.location.hash || '');
    var mm = q.match(/[?&]znc=(dark|light)/);
    if (mm) return mm[1];
  } catch (e) {}
  // 1) 主题显式声明
  var dm = document.documentElement.getAttribute('data-mode');
  if (dm === 'dark' || dm === 'light') return dm;
  // 2) 实测内容区实际背景色 (最可靠: 看到什么就是什么)
  var bg = znetcontrolContentBg();
  if (bg) return znetcontrolLum(bg) < 128 ? 'dark' : 'light';
  // 3) 实测页面文字色: 文字亮 => 暗色主题
  try {
    var tc = znetcontrolParseColor(getComputedStyle(document.body).color);
    if (tc) return znetcontrolLum(tc) < 128 ? 'light' : 'dark';
  } catch (e) {}
  // 4) 系统偏好
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
  // 5) 默认
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
]], json)
end

-- 一段可直接内嵌的完整 JS（检测 + 应用）
function M.js_bundle()
	return M.js_detect .. "\n" .. M.js_apply()
end

return M
