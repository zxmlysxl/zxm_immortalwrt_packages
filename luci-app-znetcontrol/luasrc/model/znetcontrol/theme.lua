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
	log_bg          = { "#ffffff",                 "#1e2126" },
	log_text        = { "#1a202c",                 "#e8e8e8" },
	log_info        = { "#2563eb",                 "#9cdcfe" },
	log_info_bg     = { "rgba(37,99,235,0.05)",      "rgba(156,220,254,0.08)" },
	log_ts          = { "#1e40af",                 "#569cd6" },
	log_ok          = { "#155724",                 "#6a9955" },
	log_warn        = { "#856404",                 "#ffcc00" },
	log_err         = { "#a62121",                 "#ce9178" },
	log_stat        = { "#0f766e",                 "#4ec9b0" },
	log_border      = { "rgba(0,0,0,0.10)",       "rgba(255,255,255,0.18)" },
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
function M.root(mode)
	local idx = (mode == 'dark') and 2 or 1
	local out = { ":root {" }
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
function znetcontrolDetectMode() {
  // ① 主题自行声明（预留扩展点）
  var html = document.documentElement;
  var dm = html.getAttribute('data-mode');
  if (dm === 'dark' || dm === 'light') return dm;
  // ② 实测主题 CSS 变量出明暗（kucat 暗色 --primary-rgbbody=33,45,60）
  try {
    var rgb = getComputedStyle(html).getPropertyValue('--primary-rgbbody');
    if (rgb) {
      var parts = rgb.trim().split(',');
      if (parts.length >= 3) {
        var lum = 0.2126 * parseInt(parts[0], 10)
                + 0.7152 * parseInt(parts[1], 10)
                + 0.0722 * parseInt(parts[2], 10);
        if (!isNaN(lum)) return lum < 120 ? 'dark' : 'light';
      }
    }
  } catch (e) {}
  // ②.5 实测 body 背景明暗（最通用判据：任何主题改了 body 背景都能识别）
  try {
    if (document.body) {
      var bg = getComputedStyle(document.body).backgroundColor;
      if (bg && bg.indexOf('rgb') === 0) {
        var m = bg.match(/\d+/g);
        if (m && m.length >= 3) {
          var lum2 = 0.2126 * parseInt(m[0], 10)
                   + 0.7152 * parseInt(m[1], 10)
                   + 0.0722 * parseInt(m[2], 10);
          if (!isNaN(lum2)) return lum2 < 128 ? 'dark' : 'light';
        }
      }
    }
  } catch (e) {}
  // ③ 系统偏好兜底
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
  // ④ 默认
  return 'light';
}
]]

-- 应用函数 JS：检测 + 注入暗色变量块
function M.js_apply()
	local json = json_escape(M.root("dark"))
	return string.format([[
function znetcontrolApplyTheme() {
  var mode = znetcontrolDetectMode();
  var existing = document.getElementById('znetcontrol-theme-style');
  if (existing) existing.remove();
  if (mode === 'dark') {
    var s = document.createElement('style');
    s.id = 'znetcontrol-theme-style';
    s.textContent = %s;
    document.head.appendChild(s);
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
