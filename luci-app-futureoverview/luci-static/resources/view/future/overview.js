'require view';
'require rpc';
'require uci';
'require dom';
'require ui';
'require fs';
'require network';

var callBoard    = rpc.declare({ object: 'system', method: 'board' });
var callSysInfo  = rpc.declare({ object: 'system', method: 'info' });
var callCPUUsage = rpc.declare({ object: 'luci', method: 'getCPUUsage' });
var callTempInfo = rpc.declare({ object: 'luci', method: 'getTempInfo' });
var callMounts   = rpc.declare({ object: 'luci', method: 'getMountPoints', expect: { result: [] } });
var callOnline   = rpc.declare({ object: 'luci', method: 'getOnlineUsers' });
var callDHCP     = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} } });
var callEthPorts = rpc.declare({ object: 'luci', method: 'getBuiltinEthernetPorts', expect: { result: [] } });
var callNetDev   = rpc.declare({ object: 'network.device', method: 'status', params: [ 'name' ], expect: { '': {} } });
var callLuciVer  = rpc.declare({ object: 'luci', method: 'getVersion' });
var callNetAll   = rpc.declare({ object: 'luci-rpc', method: 'getNetwork', expect: { '': {} } });

var D = {};

/* ================= 农历 ================= */
var LUNAR=[0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,
0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,
0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252];
var LMN=['正','二','三','四','五','六','七','八','九','十','冬','腊'];
var LD1=['初','十','廿','三'], LD2=['日','一','二','三','四','五','六','七','八','九','十'];
var SX=['鼠','牛','虎','兔','龙','蛇','马','羊','猴','鸡','狗','猪'];
var GZ=['甲','乙','丙','丁','戊','己','庚','辛','壬','癸'];
var GZ2=['子','丑','寅','卯','辰','巳','午','未','申','酉','戌','亥'];
function lyDays(y){var i,s=348;for(i=0x8000;i>0x8;i>>=1)s+=(LUNAR[y-1900]&i)?1:0;return s+lyLeapDays(y);}
function lyLeap(y){return LUNAR[y-1900]&0xf;}
function lyLeapDays(y){return lyLeap(y)?((LUNAR[y-1900]&0x10000)?30:29):0;}
function lyMonth(y,m){return (LUNAR[y-1900]&(0x10000>>m))?30:29;}
function s2l(y,m,d){
  var off=Math.floor((Date.UTC(y,m-1,d)-Date.UTC(1900,0,31))/86400000), i, dy;
  for(i=1900;i<2100;i++){ dy=lyDays(i); if(off<dy) break; off-=dy; }
  var leap=lyLeap(i), lm=1, isLeap=false, dm, g=0;
  while(g++<16){
    if(leap>0&&lm===leap+1){ dm=lyLeapDays(i); isLeap=true; }
    else { dm=lyMonth(i,lm); isLeap=false; }
    if(off<dm) break;
    off-=dm; lm++;
    if(lm>12){ lm=1; i++; leap=lyLeap(i); }
  }
  var ld=off+1;
  if(lm<1||lm>12||ld<1||ld>30) return '--';
  var ds;
  if(ld===10) ds='初十'; else if(ld===20) ds='二十'; else if(ld===30) ds='三十';
  else ds=LD1[Math.floor(ld/10)]+LD2[ld%10];
  var mn=isLeap?LMN[lm-2]:LMN[lm-1];
  return (isLeap?'闰':'')+mn+'月'+ds;
}

/* ================= 工具 ================= */
function p2(n){ return (n<10?'0':'')+n; }
function fmtBytes(b){
  if(b==null) return '?';
  if(b>=1073741824) return (b/1073741824).toFixed(2)+' GB';
  if(b>=1048576) return (b/1048576).toFixed(1)+' MB';
  if(b>=1024) return (b/1024).toFixed(1)+' KB';
  return b+' B';
}
function fmtUp(s){
  if(s==null) return '?';
  s=Math.max(0,parseInt(s)||0);
  var d=Math.floor(s/86400), h=Math.floor(s%86400/3600), m=Math.floor(s%3600/60), sec=s%60, x=[];
  if(d) x.push(d+' 天');
  if(d||h) x.push(h+' 小时');
  x.push(m+' 分');
  x.push(sec+' 秒');
  return x.join(' ');
}
function fmtSpeed(s){
  if(s==null || s==='') return '';
  var n=parseInt(s,10);
  if(!isFinite(n)) return String(s);
  if(n>=1000) return (n/1000)+' Gb/s';
  return n+' Mb/s';
}
function fmtNum(n){
  if(n==null) return '-';
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}
/* 剩余时间精确到秒：不足一天显示 HH:MM:SS */
function fmtLeft(sec_){
  if(sec_==null||sec_<0) return '永久';
  sec_=Math.max(0,parseInt(sec_,10)||0);
  var dd=Math.floor(sec_/86400),
      t=p2(Math.floor(sec_%86400/3600))+':'+p2(Math.floor(sec_%3600/60))+':'+p2(sec_%60);
  return dd ? (dd+' 天 '+t) : t;
}
function esc(s){ return String(s==null||s===''?'-':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function sec(title, right, body, cls){
  return '<div class="fov card sec'+(cls?' '+cls:'')+'">'+
    '<div class="fov shead"><i></i>'+esc(title)+
    (right?'<span class="fov rt">'+right+'</span>':'')+'</div>'+body+'</div>';
}
function rows(a){
  var s='<div class="fov rows">';
  for(var i=0;i<a.length;i++){
    var raw=(a[i][3]===true);
    s+='<div class="fov row"><span class="fov k">'+a[i][0]+'</span>'+
       '<span class="fov v '+(a[i][2]||'')+'">'+(raw?a[i][1]:esc(a[i][1]))+'</span></div>';
  }
  return s+'</div>';
}
function gauge(pct, color, unit, meta){
  var C=389.6, n=parseFloat(pct);
  if(!isFinite(n)) n=0;
  var p=Math.max(0,Math.min(100,n));
  return '<div class="fov gauge"><svg width="132" height="132">'+
    '<circle class="fov gbg" cx="66" cy="66" r="62"></circle>'+
    '<circle class="fov gfg" cx="66" cy="66" r="62" stroke="'+color+
    '" stroke-dasharray="'+C.toFixed(1)+'" stroke-dashoffset="'+(C-(C*p/100)).toFixed(1)+'"></circle></svg>'+
    '<div class="fov gval"><div class="fov gnum" style="color:'+color+'">'+Math.round(p)+
    '<span class="fov gunit">'+unit+'</span></div></div></div>'+
    '<div class="fov gmeta">'+meta+'</div>';
}
function gaugeCard(label, pct, color, unit, meta){
  return '<div class="fov card sec mid"><div class="fov gtitle">'+label+'</div>'+
         gauge(pct,color,unit,meta)+'</div>';
}


/* ================= 数据整理 ================= */
/* getDHCPLeases 返回 { 接口名: [租约,...] }，拍平 */
function flatLeases(raw){
  var out=[], k;
  if(!raw) return out;
  if(Array.isArray(raw)) return raw.slice();
  for(k in raw){
    if(!Object.prototype.hasOwnProperty.call(raw,k)) continue;
    var arr=raw[k];
    if(!Array.isArray(arr)) continue;
    for(var i=0;i<arr.length;i++){
      if(!arr[i]||typeof arr[i]!=='object') continue;
      var e={}; for(var j in arr[i]) e[j]=arr[i][j];
      if(!e.ifname) e.ifname=k;
      out.push(e);
    }
  }
  return out;
}

/* ---- 网口：直读 sysfs 与 /proc/net/dev，不依赖 RPC 返回结构 ---- */
/* 在线判定只用 OpenWrt/LuCI 自身能力，不依赖任何第三方插件：
   /proc/net/arp          当前仍在局域网应答的设备
   /proc/net/nf_conntrack 有活动连接的设备（补充 ARP 漏掉的空闲设备）
   /tmp/dhcp.leases       动态租约（名字、IP、最后续租时间）            */

/* 新增区块的数据源，全部走 L.resolveDefault 兜底：RPC 不存在时返回空，不报错 */
var callSvcRestart = rpc.declare({ object:'service', method:'restart',
                                    params:[ 'name', 'instance' ], expect:{} });

function readSys(p){ return L.resolveDefault(fs.read(p), '').then(function(v){ return (v||'').trim(); }); }
function safe(fn, def){ try{ var v=fn(); return (v==null)?def:v; }catch(e){ return def; } }

/* 网口：照搬官方 29_ports.js 取法
   getBuiltinEthernetPorts 返回对象数组，接口名在 .device
   速率/双工/链路 用 network.instantiateDevice
   流量用 netdev._devstate('stats')                            */
function fetchPorts(portList){
  var names=[];
  for(var i=0;i<(portList||[]).length;i++){
    var p=portList[i], d=(p&&typeof p==='object')?(p.device||p.ifname||p.name):p;
    if(typeof d==='string'&&d) names.push(d);
  }
  if(!names.length) return Promise.resolve([]);
  return Promise.all(names.map(function(name){
    var dev=safe(function(){ return network.instantiateDevice(name); }, null);
    var stats=safe(function(){ return dev&&dev._devstate?dev._devstate('stats'):null; }, null)||{};
    var spd=safe(function(){ return dev.getSpeed(); }, null);
    var dup=safe(function(){ return dev.getDuplex(); }, null);
    var car=safe(function(){ return dev.getCarrier(); }, false);
    return {
      name:name, up:!!car, status: car?'已连接':'未连接',
      speed:spd, duplex:dup,
      rx_bytes:stats.rx_bytes, tx_bytes:stats.tx_bytes,
      rx_packets:stats.rx_packets, tx_packets:stats.tx_packets,
      rx_errors:stats.rx_errors, tx_errors:stats.tx_errors,
      rx_dropped:stats.rx_dropped, tx_dropped:stats.tx_dropped,
      collisions:stats.collisions
    };
  }));
}

/* ---- WAN：照搬官方 30_network.js 取法
   network.getWANNetworks() 返回带方法的 netifd 对象，不是纯数据 ---- */
function toArr(v){ if(v==null) return []; return Array.isArray(v)?v:[v]; }
function wanInfo(ifc, is6){
  if(!ifc) return null;
  var dev   = safe(function(){ return ifc.getL3Device(); }, null);
  var proto = safe(function(){ return ifc.getProtocol(); }, '');
  var addrs = toArr(safe(function(){ return is6?ifc.getIP6Addrs():ifc.getIPAddrs(); }, []));
  var dns   = toArr(safe(function(){ return is6?ifc.getDNS6Addrs():ifc.getDNSAddrs(); }, []));
  var gw    = safe(function(){ return is6?ifc.getGateway6Addr():ifc.getGatewayAddr(); }, '');
  var exp   = safe(function(){ return ifc.getExpiry(); }, null);
  var upt   = safe(function(){ return ifc.getUptime(); }, null);
  var pd    = toArr(safe(function(){ return ifc.getIP6Prefixes?ifc.getIP6Prefixes():[]; }, []));
  var name  = safe(function(){ return ifc.getName?ifc.getName():((dev&&dev.device)||''); }, '');
  return {
    ifname:name, proto:proto, addr:addrs.length?addrs[0]:'-',
    gw:gw||'-', pd:pd.length?pd[0]:'-', dns:dns, up:!!dev,
    exp:(exp!=null&&exp>-1)?fmtLeft(exp):'-', upt:fmtUp(upt||0)
  };
}
/* 在线设备：照搬官方 network.getHostHints().hosts 结构
   { mac: { name, ipaddrs, ip6addrs, ipv4, ipv6, dev } }   */
/* conntrack 表可能很大，条目过多时不读，避免每 5 秒拉几百 KB */
function parseConnIps(txt){
  var s={}, lines=String(txt||'').split('\n');
  for(var i=0;i<lines.length;i++){
    var re=/\b(?:src|dst)=(\d+\.\d+\.\d+\.\d+)\b/g, m;
    while((m=re.exec(lines[i]))!==null){
      var ip=m[1];
      if(/^(10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(ip)) s[ip]=1;
    }
  }
  return s;
}
function fetchConnIps(){
  return readSys('/proc/sys/net/netfilter/nf_conntrack_count').then(function(cnt){
    var n=parseInt(cnt,10);
    if(!isFinite(n) || n>8000) return {};
    return L.resolveDefault(fs.read('/proc/net/nf_conntrack'), '').then(function(v){
      return parseConnIps(v);
    });
  });
}
/* /tmp/dhcp.leases 里有绝对到期时间，可倒推出最后续租时刻。
   dhcp_option 写在 /etc/config/dhcp 的 dhcp 区段里，直接读原文最稳。 */
function leaseDuration(){
  try{
    var txt=D.dhcpRaw||'';
    var m=/^\s*(?:option\s+)?dhcp_option\s+['"]?([^'\n]+)/m.exec(txt);
    if(m){
      var opts=String(m[1]).split(',');
      for(var j=0;j<opts.length;j++){
        var parts=String(opts[j]).split(',');
        if(String(parts[0]).trim()==='3' && parts[1]){
          var n=parseInt(parts[1],10);
          if(isFinite(n)&&n>0) return n;
        }
      }
    }
    return 43200;
  }catch(e){}
  return 43200;
}
function parseLeaseFile(txt){
  var out={}, lines=String(txt||'').split('\n');
  for(var i=0;i<lines.length;i++){
    var f=lines[i].trim().split(/\s+/);
    if(f.length<3) continue;
    var exp=parseInt(f[0],10);
    if(!isFinite(exp)||exp<=0) continue;
    var mac=String(f[1]||'').toLowerCase();
    if(!mac) continue;
    out[mac]={ ip:f[2]||'', hostname:(f[3]&&f[3]!=='*')?f[3]:'', expiry:exp };
  }
  return out;
}
function readLeaseFile(){
  return L.resolveDefault(fs.read('/tmp/dhcp.leases'), '').then(function(v){
    var raw=parseLeaseFile(v), out={}, dur=leaseDuration()*1000;
    for(var mac in raw){
      if(!Object.prototype.hasOwnProperty.call(raw,mac)) continue;
      var r=raw[mac];
      out[mac]={ ip:r.ip, hostname:r.hostname, last_activity:(r.expiry*1000)-dur };
    }
    return out;
  });
}

/* ---- 在线设备检测 ----
   在线 = ARP 有应答  或  该 IP 在 conntrack 里有活动连接
   hostHints 只是「曾连接过」的缓存，不能直接当在线列表。 */
function readArp(){
  return readSys('/proc/net/arp').then(function(txt){
    var out={}, lines=String(txt||'').split('\n');
    for(var i=1;i<lines.length;i++){
      var f=lines[i].trim().split(/\s+/);
      if(f.length<6) continue;
      if(f[2]!=='0x2') continue;              /* 0x2 = 有效(complete)条目 */
      var mac=String(f[3]).toLowerCase();
      if(!mac || mac==='00:00:00:00:00:00') continue;
      out[mac]={ ip:f[0], dev:f[5] };
    }
    return out;
  });
}
/* ---- 静态 DHCP ---- */
function macSet(list){
  var m={};
  for(var i=0;i<(list||[]).length;i++){
    var o=list[i]||{};
    var x=String(o.macaddr||o.mac||o.duid||'').toLowerCase();
    if(x) m[x]=true;
  }
  return m;
}
/* 读 /etc/config/dhcp 里已有的静态租约 MAC */
/* 已配置静态租约的 MAC 集合：
   1) interface 区段的 list 里挂的 host 列表
   2) dhcp 的 host option 区段
   两个都读，否则漏掉用 list 方式添加的静态租约。 */
/* 已配置静态租约的 MAC 集合。
   直接读 /etc/config/dhcp 原文最稳：dnsmasq 认的静态租约以 'ip mac'
   形式写在 config host 区段，list 或 scalar 都兼容。 */
/* 静态 MAC 集合：解析 /etc/config/dhcp 原文。
   兼容三类区段：
     - config host（LuCI 保存的标准区段）
     - config server / config option（老式把 mac/ip 挂全局 option 的写法）
   每个区段内同时认：
     - option mac 'AA:BB:CC:DD:EE:01'          （新写法，独立选项）
     - option host '192.168.x.x AA:BB:CC:DD:EE:01'（dnsmasq 标量写法）
     - list host '192.168.x.x AA:BB:CC:DD:EE:01'   （list 写法）
   MAC 格式支持冒号/连字符/无分隔，大小写不敏感。 */
function parseStaticMacsFromText(txt){
  var set={}, L2=String(txt||'').split('\n'), inMac=false;
  /* 区段内出现即认为该值可承载静态租约：host / server / option / tag */
  for(var i=0;i<L2.length;i++){
    var l=L2[i];
    if(l.charAt(0)==='#') continue;
    var mCfg=/^\s*config\s+(\S+)\s*(\S+)?$/.exec(l);
    if(mCfg){
      var t=String(mCfg[1]).toLowerCase();
      inMac=(t==='host'||t==='server'||t==='option'||t==='tag');
      continue;
    }
    if(!inMac) continue;
    /* 选项行：option X ... / list X ... / X ...（裸写）*/
    var mOpt=/^\s*(?:option|list)\s+([\w]+)\s+(.*)$/.exec(l)
          || /^\s*([a-z_]+)\s+(\S.*)$/.exec(l);
    if(!mOpt) continue;
    var val=(mOpt[2]||'').replace(/^\s*['"]|['"]\s*$/g,'');
    /* 提取所有 MAC（不论在 ip+mac 串里、还是独立 mac 值里）。
       用 match(全局正则) 一次性取出所有匹配，避免 exec+lastIndex 死循环。 */
    var all=val.match(/(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/g);
    if(all){
      for(var q=0;q<all.length;q++) set[all[q].toLowerCase()]=true;
    }
  }
  return set;
}
function readDhcpFile(){
  return L.resolveDefault(fs.read('/etc/config/dhcp'), '').then(function(v){
    D.dhcpRaw=v;                       /* 原文存 D 供 leaseDuration 等复用 */
    return parseStaticMacsFromText(v);
  });
}
/* 本机所有接口 IP（路由器自身）。用于把"路由器自己"从可设为静态的列表剔除。
   读 /etc/config/network 里所有 interface 区段的 ipaddr / list ipaddr。 */
function parseOwnIpsFromText(txt){
  /* 收集 /etc/config/network 里所有 interface 区段的 IPv4 地址：
     option ipaddr 'a b' / list ipaddr '...' / 裸 ipaddr '...' */
  var set={}, L2=String(txt||'').split('\n'), inIface=false;
  for(var i=0;i<L2.length;i++){
    var l=L2[i];
    if(l.charAt(0)==='#') continue;
    var mCfg=/^\s*config\s+(\S+)\s*(\S+)?$/.exec(l);
    if(mCfg){ inIface=(String(mCfg[1]).toLowerCase()==='interface'); continue; }
    if(!inIface) continue;
    /* 去掉前缀 option / list 后，只要行内含 IPv4 即提取全部 */
    var body=l.replace(/^\s*(?:option|list)\s+\w+\s+/, '');  /* 去掉 option xxx / list xxx */
    var reIp=/\b\d{1,3}(?:\.\d{1,3}){3}\b/g, mm;
    while((mm=reIp.exec(body))!==null){
      var ip=mm[0];
      var parts=ip.split('.');
      if(parts.every(function(x){return x<=255;})) set[ip]=true;
    }
  }
  return set;
}
function readOwnIps(){
  return L.resolveDefault(fs.read('/etc/config/network'), '').then(function(v){
    D.ownIps=parseOwnIpsFromText(v);
    return D.ownIps;
  });
}
/* 不再需要：setStaticLease 直接 uci.add('dhcp','host')，无需猜测区段名。 */
function guessDhcpSection(dev){ return true; }
function dhcpPageUrl(){
  /* 直接固定 CGI 入口（菜单点 DHCP 实际跳的就是它）。
     L.resource() 返回的是 /luci-static/resources/... 静态资源路径，
     当 URL 跳转会 404，所以不用它。 */
  return '/cgi-bin/luci/admin/network/dhcp';
}
/* 写入静态租约 -> 保存 -> 重启 dnsmasq -> 跳转 DHCP 页面。
   直接新增 config host 区段（uci.add），挂 host 选项 'ip mac'，
   这是 dnsmasq/LuCI DHCP 页面认的标准写法。 */
function setStaticLease(mac, ip, name, dev, btn){
  function back(){
    if(btn){ btn.disabled=false; btn.textContent='设为静态'; }
  }
  try{
    /* LuCI DHCP 页（view/network/dhcp.js）用 form.DynamicList 'mac' +
       form.Value 'ip'/'name'/'leasetime'，独立选项，不读 host 标量。
       按它的字段写，页面里才会直接带出 IP/MAC，不用再手填。 */
    var sid=uci.add('dhcp','host');
    uci.set('dhcp',sid,'mac',mac);
    if(ip) uci.set('dhcp',sid,'ip',ip);
    if(name && name!=='-' && name!=='(未知)'){
      uci.set('dhcp',sid,'name',name);
      uci.set('dhcp',sid,'dns','1');   /* 与 LuCI 写 name 时联动 dns 一致 */
    }
  }catch(e){
    back();
    if(window.alert) window.alert('写入失败：'+(e.message||e));
    return;
  }
  uci.save().then(function(){
    return L.resolveDefault(callSvcRestart('dnsmasq','dnsmasq'), null);
  }).then(function(){
    window.location.href = dhcpPageUrl();
  }).catch(function(e){
    back();
    if(window.alert) window.alert('保存失败：'+((e&&e.message)||e));
  });
}
/* 事件委托：重绘后按钮元素会换掉，所以绑在容器上而不是按钮上 */
function bindSetStatic(){
  var box=document.getElementById('fov-users');
  if(!box || !box.addEventListener || box.getAttribute('data-sb')) return;
  box.setAttribute('data-sb','1');
  box.addEventListener('click', function(ev){
    var t=ev.target;
    while(t && t!==box){
      if(t.getAttribute && String(t.className||'').indexOf('btn-setstatic')>=0) break;
      t=t.parentNode;
    }
    if(!t || t===box || !t.getAttribute) return;
    var mac=t.getAttribute('data-mac'), ip=t.getAttribute('data-ip');
    if(!mac||!ip) return;
    if(window.confirm && !window.confirm('将 '+mac+' 固定为 '+ip+' ？\n\n'+
        '将写入 /etc/config/dhcp 静态租约，并重启 dnsmasq 使其生效。')) return;
    t.disabled=true; t.textContent='保存中…';
    setStaticLease(mac, ip, t.getAttribute('data-name'), t.getAttribute('data-dev'), t);
  });
}

/* IP 升序：IPv4 数值比较在前，无 IP / IPv6 的排最后，最后按 MAC 兜底 */
function ipKey(ip){
  var m=/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(String(ip||''));
  if(!m) return null;
  return (parseInt(m[1],10)*16777216)+(parseInt(m[2],10)*65536)+
         (parseInt(m[3],10)*256)+parseInt(m[4],10);
}
function cmpByIp(a,b){
  var ka=ipKey(a.ip), kb=ipKey(b.ip);
  if(ka==null && kb==null) return a.mac.localeCompare(b.mac);
  if(ka==null) return 1;
  if(kb==null) return -1;
  if(ka!==kb) return ka-kb;
  return a.mac.localeCompare(b.mac);
}
function computeOnline(hosts, leases, arp, conn, leaseInfo, staticMacs){
  var byMac={}, bx={};
  function put(t, mac, name, ip, dev, last){
    mac=String(mac||'').toLowerCase();
    if(!mac || mac==='00:00:00:00:00:00') return;
    var d=t[mac];
    if(!d) d=t[mac]={ mac:mac, name:'', ip:'', dev:'', last_online:0 };
    if(name) d.name=d.name||name;
    if(ip) d.ip=d.ip||ip;
    if(dev) d.dev=d.dev||dev;
    if(last) d.last_online=d.last_online||last;
  }
  for(var mac in hosts){
    if(!Object.prototype.hasOwnProperty.call(hosts,mac)) continue;
    var h=hosts[mac]||{};
    var ip4=toArr(h.ipaddrs||h.ipv4), ip6=toArr(h.ip6addrs||h.ipv6);
    put(byMac, mac, h.name||'', ip4[0]||ip6[0]||'', h.dev||'', 0);
  }
  for(var i=0;i<(leases||[]).length;i++){
    var l=leases[i]||{};
    put(byMac, l.mac||l.duid, l.hostname||'', l.ipaddr||l.ip6addr||'', l.ifname||'', 0);
  }
  for(var am in arp){
    if(!Object.prototype.hasOwnProperty.call(arp,am)) continue;
    var a=arp[am];
    put(byMac, am, '', a.ip, a.dev, 0);
  }
  /* 租约文件里出现、但 hostHints 尚未收录的设备也要纳入 */
  for(var lk in leaseInfo){
    if(!Object.prototype.hasOwnProperty.call(leaseInfo,lk)) continue;
    var lf=leaseInfo[lk];
    put(byMac, lk, lf.hostname||'', lf.ip||'', '', lf.last_activity||0);
  }
  var out=[];
  for(var k in byMac){
    if(!Object.prototype.hasOwnProperty.call(byMac,k)) continue;
    var d=byMac[k];
    var li=leaseInfo[k];
    if(li){
      if(li.ip && !d.ip) d.ip=li.ip;
      if(li.hostname && !d.name) d.name=li.hostname;
      if(li.last_activity) d.last_online=li.last_activity;
    }
    /* ARP 无应答且无活动连接 -> 视为离线 */
    if(!arp[k] && !(d.ip && conn[d.ip])) continue;
    /* 没有租约估算值、但 conntrack 在线或已配静态租约 => 视为此刻在线 */
    if(!d.last_online && (conn[d.ip] || (staticMacs && staticMacs[d.mac])))
      d.last_online=Date.now()-5*60*1000;
    out.push(d);
  }
  return out.sort(cmpByIp);
}

/* 时区显示：一律以 UTC 偏移为主，区域名仅在直观时补充
   Etc/GMT-8 是 POSIX 写法，符号与偏移相反（= UTC+8）        */
function utcOffsetStr(min){
  var h=Math.floor(Math.abs(min)/60), m=Math.abs(min)%60;
  return 'UTC'+(min<0?'-':'+')+h+(m?(':'+p2(m)):'');
}
function friendlyTZ(tz, realOffsetMin){
  var off=utcOffsetStr(realOffsetMin);
  if(!tz) return off;
  var m=/^Etc\/GMT([+-])(\d{1,2})$/.exec(tz);
  if(m) return off;
  if(/^(Asia\/Shanghai|Asia\/Chongqing|Asia\/Hong_Kong|Asia\/Macau)$/.test(tz))
    return off+' '+tz;
  return off;
}

function pickWan(wans){
  var list=Array.isArray(wans)?wans:[], up=list.filter(function(x){
    return safe(function(){ return x.getProtocol(); },'')!=='none' && x.getL3Device();
  });
  return (up.length?up:list)[0]||null;
}

/* ================= 渲染 ================= */
function buildHTML(){
  var d=D, h='';

  var KB=1024;
  var mem=d.sysinfo.memory||{};
  var memTotal=(mem.total||0);
  var memFree= mem.available!=null?mem.available:((mem.free||0)+(mem.buffered||0));
  var memUsed= memTotal>0?memTotal-memFree:0;
  var memPct = memTotal>0?memUsed/memTotal*100:0;
  var rt=d.sysinfo.root||{};
  var stoPct=(rt.total>0)?rt.used/rt.total*100:0;
  var cpu=parseFloat(d.cpuusage&&d.cpuusage.cpuusage);
  if(!isFinite(cpu)) cpu=0;
  var temp=(d.tempinfo&&d.tempinfo.tempinfo!=null)?parseFloat(d.tempinfo.tempinfo):null;
  if(temp!=null&&!isFinite(temp)) temp=null;

  h+='<div class="fov g4">';
  h+=gaugeCard('CPU 使用率', cpu, 'var(--accent)', '%', '负载 1/5/15: '+(d.loadTxt||'--'));
  h+=gaugeCard('内存使用率', memPct, 'var(--accent2)', '%', fmtBytes(memUsed)+' / '+fmtBytes(memTotal));
  h+=gaugeCard('磁盘使用率', stoPct, 'var(--ok)', '%',
      rt.total?(fmtBytes(rt.used*KB)+' / '+fmtBytes(rt.total*KB)):'无数据');
  h+=gaugeCard('CPU 温度', temp!=null?temp:0, 'var(--warn)', '°C',
      temp!=null?'SoC / Package':'无温度传感器');
  h+='</div>';

  /* ---- 系统信息 ---- */
  var b=d.board||{}, rel=(b.release&&L.isObject(b.release))?b.release:{};
  var a=[];
  a.push(['型号', b.model||'?']);
  a.push(['架构', (d.cpuinfo&&d.cpuinfo.cpuinfo)||b.system||'?']);
  a.push(['固件版本', d.fwdesc||'?']);
  a.push(['LuCI 版本', d.luciVer||'?']);
  if(temp!=null) a.push(['温度', temp+' °C']);
  a.push(['运行时间', fmtUp(d.sysinfo&&d.sysinfo.uptime), 'hl']);
  a.push(['时区', d.tz||'?']);
  var sSys=sec('系统信息','system · board', rows(a),'');

  /* ---- 内存 ---- */
  var sMem=sec('内存','system.info', rows([
    ['总内存', fmtBytes(mem.total)],
    ['可用', fmtBytes(memFree), 'hl'],
    ['已使用', fmtBytes(memUsed)],
    ['已缓冲', fmtBytes(mem.buffered)],
    ['已缓存', fmtBytes(mem.cached)],
    ['Swap 剩余', (d.sysinfo.swap&&d.sysinfo.swap.total>0)?
        (fmtBytes(d.sysinfo.swap.free)+' / '+fmtBytes(d.sysinfo.swap.total)):'未启用']
  ]),'');

  /* ---- 网络 ---- */
  var w4=d.wan4, w6=d.wan6;
  var nb;
  if(w4){
    nb=rows([
      ['协议', w4.proto], ['设备', w4.ifname],
      ['地址', w4.addr, 'hl'], ['网关', w4.gw],
      ['DNS 服务器', (w4.dns||[]).slice(0,2).join(' / ')],
      ['租约剩余', w4.exp], ['已连接', w4.upt,'hl'],
      ['状态', w4.up?'<span class="fov tag ok">● 已连接</span>':'<span class="fov tag no">● 未连接</span>','',true]
    ]);
  } else {
    nb='<div style="color:var(--txt-dim);font-size:12px;padding:10px">未检测到 WAN 接口</div>';
  }
  var nb6;
  if(w6){
    nb6=rows([
      ['协议', w6.proto], ['设备', w6.ifname],
      ['地址', w6.addr,'hl'], ['网关', w6.gw],
      ['分发前缀', w6.pd],
      ['DNS 服务器', (w6.dns||[]).slice(0,2).join(' / ')],
      ['剩余有效期', w6.exp], ['已连接', w6.upt],
      ['状态', w6.up?'<span class="fov tag ok">● 已连接</span>':'<span class="fov tag wn">● 无 IPv6</span>','',true]
    ]);
  } else {
    nb6='<div style="color:var(--txt-dim);font-size:12px;padding:10px">无 IPv6</div>';
  }
  var sNet=sec('网络','luci-rpc.getNetwork',
      '<div class="fov v4blk"><div class="fov btitle">IPv4 上游</div>'+nb+'</div>'+
      '<div class="fov v4blk"><div class="fov btitle">IPv6 上游</div>'+nb6+'</div>','');

  /* ---- 网口状态 ---- */
  var ps='<div class="fov ports">', pts=d.ports||[];
  if(!pts.length) ps+='<div style="color:var(--txt-dim);font-size:12px">无网口信息</div>';
  for(var j=0;j<pts.length;j++){
    var p=pts[j], col=p.up?'var(--ok)':'var(--txt-dim)';
    ps+='<div class="fov port"><div class="fov ptop">'+
      '<span class="fov pdot" style="background:'+col+';box-shadow:0 0 7px '+col+'"></span>'+
      '<span class="fov pname">'+esc(p.name)+'</span>'+
      '<span class="fov pstat"><span class="fov tag '+(p.up?'ok':'wn')+'">'+esc(p.status)+'</span></span></div>'+
      ((p.speed||p.duplex)?'<div class="fov pspeed">'+esc([p.speed?fmtSpeed(p.speed):'',p.duplex?String(p.duplex).toUpperCase():''].filter(Boolean).join(' · '))+'</div>':'')+
      '<div class="fov pmetrics">'+
      '<div class="fov pm"><span>接收</span><b>'+fmtBytes(p.rx_bytes)+'</b></div>'+
      '<div class="fov pm"><span>发送</span><b>'+fmtBytes(p.tx_bytes)+'</b></div>'+
      '<div class="fov pm"><span>收包</span><b>'+fmtNum(p.rx_packets)+'</b></div>'+
      '<div class="fov pm"><span>发包</span><b>'+fmtNum(p.tx_packets)+'</b></div>'+
      '<div class="fov pm"><span>收错/丢</span><b>'+fmtNum(p.rx_errors)+' / '+fmtNum(p.rx_dropped)+'</b></div>'+
      '<div class="fov pm"><span>发错/丢</span><b>'+fmtNum(p.tx_errors)+' / '+fmtNum(p.tx_dropped)+'</b></div>'+
      '</div></div>';
  }
  ps+='</div>';
  var sPrt=sec('网口状态','luci.getBuiltinEthernetPorts', ps,'');

  /* ---- 在线用户：ARP + 连接跟踪，折叠显示设备明细 ---- */
  var sOnl=sec('在线用户','ARP / 连接跟踪 实时检测 · 轮询 5s',
      '<div class="fov ustat">'+
      '<div class="fov ucell"><div class="fov unum" id="fov-ucnt">0</div>'+
      '<div class="fov ulab">在线设备</div></div>'+
      '<div class="fov ucell"><div class="fov unum" id="fov-ct">0</div>'+
      '<div class="fov ulab">活动连接</div></div>'+
      '</div>'+
      '<div class="fov ucoll">'+
      '<div class="fov uhead" id="fov-uhead"><span class="fov ucaret">&#9656;</span>'+
      '<span>设备明细</span><span class="fov ucnt" id="fov-ucnt2">0</span></div>'+
      '<div class="fov ulist" id="fov-users" style="display:none"></div>'+
      '</div>','');

  /* ---- 存储 ---- */
  var SKIP=['/rom','/tmp','/dev','/overlay','/'];
  var t='<table><tr><th>设备 (挂载点)</th><th>类型</th><th class="fov num">已用</th><th class="fov num">大小</th><th class="fov num">用量</th></tr>';
  function addRow(label,usedB,sizeB,type){
    if(sizeB==null||sizeB<=0) return false;
    t+='<tr><td>'+esc(label)+'</td><td>'+esc(type||'-')+'</td><td class="fov num">'+
       fmtBytes(usedB)+'</td><td class="fov num">'+fmtBytes(sizeB)+
       '</td><td class="fov num">'+Math.round(usedB/sizeB*100)+'%</td></tr>';
    return true;
  }
  var any=false;
  if(rt.total>0) any=addRow('磁盘空间 (/', rt.used*KB, rt.total*KB, 'root')||any;
  if(d.sysinfo.tmp&&d.sysinfo.tmp.total>0)
    any=addRow('临时空间 (/tmp)', d.sysinfo.tmp.used*KB, d.sysinfo.tmp.total*KB, 'tmpfs')||any;
  var ms=Array.isArray(d.mounts)?d.mounts:[];
  for(var i=0;i<ms.length;i++){
    var m=ms[i], mp=m.mount||m.mountpoint||'';
    if(SKIP.indexOf(mp)>=0) continue;
    any=addRow((m.device||'?')+' ('+mp+')', (m.size||0)-(m.free||0), m.size||0, m.type)||any;
  }
  if(!any) t+='<tr><td colspan="5">无存储信息</td></tr>';
  var sSto=sec('存储','luci.getMountPoints', '<div class="fov tblwrap">'+t+'</table></div>','');

  /* ---- DHCP 租约 ---- */
  var lv=d.leases||[], dh='<table><tr><th>接口</th><th>主机名</th><th>IPv4</th><th>MAC</th><th>剩余</th></tr>';
  if(!lv.length) dh+='<tr><td colspan="5">无活动租约</td></tr>';
  for(var k2=0;k2<lv.length;k2++){
    var l=lv[k2];
    dh+='<tr><td>'+esc(l.ifname)+'</td><td>'+esc(l.hostname||'(未知)')+'</td><td>'+
        esc(l.ipaddr||l.ip6addr)+'</td><td>'+esc(l.macaddr||l.mac||l.duid)+
        '</td><td>'+fmtLeft(l.expires)+'</td></tr>';
  }
  var sDhc=sec('DHCP 租约','luci-rpc.getDHCPLeases', dh+'</table>','');

  h+='<div class="fov g2row">'+sSys+sMem+'</div>';
  h+='<div class="fov g2row">'+sNet+'<div class="fov gcol">'+sPrt+sSto+'</div></div>';
  h+='<div class="fov gfull">'+sOnl+'</div>';
  h+='<div class="fov gfull">'+sDhc+'</div>';
  return h;
}


/* ================= 在线设备明细 ================= */
function renderUsers(){
  var el=document.getElementById('fov-users');
  if(!el) return;
  var hs=D.hosts||[];
  var c2=document.getElementById('fov-ucnt2');
  if(c2) c2.textContent=hs.length;
  if(!hs.length){
    el.innerHTML='<div style="color:var(--txt-dim);font-size:12px;padding:8px">未检测到在线设备</div>';
    return;
  }
  var t='<table><tr><th>设备名</th><th>MAC</th><th>IP</th><th>接口</th>'+
        '<th>最后上线</th><th>静态分配</th></tr>';
  for(var i=0;i<hs.length;i++){
    var h=hs[i];
    var last=h.last_online ? new Date(h.last_online).toLocaleString() : '-';
    var mkey=String(h.mac||'').toLowerCase();
    var isStatic=!!(D.staticMac && D.staticMac[mkey]);
    var cell;
    var isSelf=!!(D.ownIps && h.ip && D.ownIps[h.ip]);
    if(!isStatic && !isSelf && h.ip){
      cell='<button class="fov btn-setstatic" data-mac="'+esc(mkey)+'"'+
            ' data-ip="'+esc(h.ip)+'" data-name="'+esc(h.name||'')+'"'+
            ' data-dev="'+esc(h.dev||'')+'"'+
            ' title="写入 /etc/config/dhcp 静态租约并重启 dnsmasq">设为静态</button>';
    } else if(isSelf){
      cell='<span class="fov dimtxt" title="这是路由器自身的接口">路由器自身</span>';
    } else if(isStatic){
      cell='<span class="fov dimtxt">已静态</span>';
    } else {
      cell='<span class="fov dimtxt">-</span>';
    }
    t+='<tr><td>'+esc(h.name||'(未知)')+'</td><td>'+esc(h.mac)+'</td>'+
       '<td class="hl">'+(h.ip?esc(h.ip):'-')+'</td><td>'+esc(h.dev||'-')+
       '</td><td>'+esc(last)+'</td><td>'+cell+'</td></tr>';
  }
  el.innerHTML=t+'</table>';
}

/* ---- 主题适配 ----
   不针对任何单一主题：运行时读取「主题自己已经渲染出来的颜色」，
   反推出一套配套配色（面板/文字/描边/强调色）。
   页面根容器背景保持透明，主题的底色与壁纸直接透出来。
   因此 kucat / bootstrap / openwrt-2020 / material 等任意主题都能跟随。 */
function parseColor(css){
  if(!css) return null;
  var m=/rgba?\(([^)]+)\)/.exec(css);
  if(!m) return null;
  var p=m[1].split(/[,\s\/]+/);
  var r=parseFloat(p[0]), g=parseFloat(p[1]), b=parseFloat(p[2]), a=1;
  if(p.length>3){
    a=(String(p[3]).indexOf('%')>=0)?parseFloat(p[3])/100:parseFloat(p[3]);
  }
  if(!isFinite(r)||!isFinite(g)||!isFinite(b)) return null;
  if(!isFinite(a)) a=1;
  return { r:r, g:g, b:b, a:a };
}
function colorLum(c){ return (0.299*c.r+0.587*c.g+0.114*c.b)/255; }
function rgba(c,a){
  var v=(a==null)?c.a:a;
  return 'rgba('+Math.round(c.r)+','+Math.round(c.g)+','+Math.round(c.b)+','+(Math.round(v*1000)/1000)+')';
}
function cssOf(el,prop){
  try{ return window.getComputedStyle(el).getPropertyValue(prop); }catch(e){ return ''; }
}
/* 找主题自己的面板/卡片底色 */
function themeSurface(){
  var sels=['.cbi-section','.cbi-map','table.cbi-section','.table','.card','.tr','#maincontent','.main-right'];
  for(var i=0;i<sels.length;i++){
    var el=document.querySelector(sels[i]);
    if(!el) continue;
    var c=parseColor(cssOf(el,'background-color'));
    if(c && c.a>0.04) return c;
  }
  return null;
}
/* 主题强调色：取主题里链接/主色实际渲染色 */
function themeAccent(){
  var cands=document.querySelectorAll('.main a, .main-left a, .navbar a, a');
  for(var i=0;i<cands.length&&i<40;i++){
    var c=parseColor(cssOf(cands[i],'color'));
    if(c && c.a>0.5 && colorLum(c)>0.05 && colorLum(c)<0.95) return c;
  }
  return null;
}
function computePalette(){
  var fg=parseColor(cssOf(document.body,'color'))||{ r:32,g:40,b:56,a:1 };
  var bg=parseColor(cssOf(document.body,'background-color'));
  var surface=themeSurface();

  /* 明暗判定：底色不透明看底色，否则看文字色（深色主题通常浅色文字） */
  var dark;
  if(bg && bg.a>0.5) dark = colorLum(bg) < 0.5;
  else dark = colorLum(fg) > 0.55;

  var acc=themeAccent();
  if(acc && dark && colorLum(acc)<0.22) acc=null;   /* 暗底上太暗的强调色看不清 */
  if(acc && !dark && colorLum(acc)>0.78) acc=null;  /* 亮底上太浅的强调色看不清 */
  if(!acc) acc = dark ? { r:34,g:228,b:255,a:1 } : { r:13,g:127,b:168,a:1 };
  var acc2 = dark ? { r:160,g:107,b:255,a:1 } : { r:107,g:63,b:212,a:1 };

  var panel, panel2;
  if(surface){
    panel  = rgba(surface, Math.min(surface.a, 0.94));
    panel2 = rgba(surface, Math.min(surface.a, 0.55));
  } else {
    panel  = dark ? 'rgba(16,20,30,.66)'   : 'rgba(255,255,255,.82)';
    panel2 = dark ? 'rgba(255,255,255,.055)' : 'rgba(255,255,255,.55)';
  }
  return {
    'bg':      (bg && bg.a>0.5) ? rgba(bg,1) : 'transparent',
    'panel':   panel,
    'panel2':  panel2,
    'line':    rgba(fg,0.16),
    'line2':   rgba(fg,0.08),
    'txt':     rgba(fg,1),
    'txt-dim': rgba(fg,0.60),
    'accent':  rgba(acc,1),
    'accent2': rgba(acc2,1),
    'ok':      dark ? '#2bff88' : '#0a9d5c',
    'warn':    dark ? '#ffc53d' : '#c98500',
    'bad':     dark ? '#ff4d6a' : '#d63a52',
    'glow':    rgba(acc, dark?0.30:0.18),
    'grid':    rgba(acc, dark?0.05:0.06),
    'shadow':  dark ? '0 12px 44px rgba(0,0,0,.55),inset 0 1px 0 rgba(255,255,255,.05)'
                    : '0 10px 34px rgba(30,50,90,.10),inset 0 1px 0 rgba(255,255,255,.7)'
  };
}
function applyTheme(el){
  if(!el||!el.style||!el.style.setProperty) return;
  var p=computePalette();
  for(var k in p){
    if(!Object.prototype.hasOwnProperty.call(p,k)) continue;
    try{ el.style.setProperty('--'+k, p[k]); }catch(e){}
  }
  el.__fovPal=JSON.stringify(p);
}
function watchTheme(el){
  applyTheme(el);
  try{
    var mo=new MutationObserver(function(){ applyTheme(el); });
    mo.observe(document.documentElement,{attributes:true,attributeFilter:['data-theme','class','style']});
    if(document.body) mo.observe(document.body,{attributes:true,attributeFilter:['data-theme','class','style']});
  }catch(e){}
  window.setInterval(function(){
    var p=null; try{ p=computePalette(); }catch(e){}
    if(p && JSON.stringify(p)!==el.__fovPal) applyTheme(el);
  }, 2000);
}

/* CSS 链接：优先 L.resource，失败回退到绝对路径；
   追加版本号避免升级后浏览器仍用旧缓存。 */
var CSS_VER='20261021i';
function cssHref(){
  var base='';
  try{ if(L && typeof L.resource==='function') base=L.resource('future/overview.css'); }catch(e){}
  if(!base || base.indexOf('overview.css')<0) base='/luci-static/resources/future/overview.css';
  if(base.indexOf('?')<0) base+='?v='+CSS_VER;
  return base;
}

/* ================= 时钟 ================= */
function tick(){
  var d=new Date();
  var w=['星期日','星期一','星期二','星期三','星期四','星期五','星期六'][d.getDay()];
  var c=document.getElementById('fov-clk');
  if(c) c.textContent=p2(d.getHours())+':'+p2(d.getMinutes())+':'+p2(d.getSeconds());
  var dt=document.getElementById('fov-dat');
  if(dt) dt.textContent=d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())+' '+w;
  var ln=document.getElementById('fov-lun');
  if(ln) ln.textContent=s2l(d.getFullYear(),d.getMonth()+1,d.getDate());
}

function bindUserToggle(){
  var uhead=document.getElementById('fov-uhead');
  var ubody=document.getElementById('fov-users');
  if(!uhead||!ubody||uhead.getAttribute('data-bound')) return;
  uhead.setAttribute('data-bound','1');
  uhead.style.cursor='pointer';
  uhead.addEventListener('click', function(){
    var open=(ubody.style.display!=='none');
    ubody.style.display=open?'none':'';
    var car=uhead.querySelector('.ucaret');
    if(car) car.textContent=open?'\u25B8':'\u25BE';
  });
}

/* 整块重绘，保留在线用户折叠状态 */
function repaint(){
  console.log('[FOV] repaint');
  var host=document.getElementById('fov-body');
  if(!host) return;
  var old=document.getElementById('fov-users');
  var wasOpen=!!(old && old.style.display!=='none');
  host.innerHTML=buildHTML();
  var u=document.getElementById('fov-users');
  if(u) u.style.display=wasOpen?'':'none';
  var h=document.getElementById('fov-uhead');
  if(h){
    var c=h.querySelector('.ucaret');
    if(c) c.textContent=wasOpen?'\u25BE':'\u25B8';
    bindUserToggle();
  }
  var uc=document.getElementById('fov-ucnt'); if(uc) uc.textContent=D.onlineCount||0;
  var ct=document.getElementById('fov-ct');   if(ct) ct.textContent=D.conntrack||0;
  bindSetStatic();
  renderUsers();
}

/* 复用 load()：下标与首次渲染完全一致（0..14），避免再次错位 */
function refreshLive(){
  console.log('[FOV] poll tick', new Date().toLocaleTimeString());
  return fetchAll().then(function(res){
    var d=res.d;
    D.board=d[0]||{}; D.sysinfo=d[1]||{}; D.cpuusage=d[2]||{}; D.tempinfo=d[3]||{};
    D.mounts=(d[4]&&d[4].result)?d[4].result:(Array.isArray(d[4])?d[4]:[]);
    D.leases=flatLeases(d[6]);
    D.cpuinfo={}; D.ports=res.stats||[];
    var lv=d[8];
    if(lv&&lv.branch) D.luciVer=lv.branch+' '+lv.revision;
    if((d[9]||'').trim()) D.fwdesc=d[9].trim();
    D.tz=friendlyTZ((d[10]||'').trim().replace(/^:/,''), -new Date().getTimezoneOffset())||D.tz;
    D.wan4=wanInfo(pickWan(d[11]), false);
    D.wan6=wanInfo(pickWan(d[12]), true);
    D.conntrack=parseInt(d[13])||0;

    /* 在线设备：ARP 应答 或 有活动连接 */
    D.staticMac=d[19]||{};
    D.ownIps=d[20]||{};
    D.hosts=computeOnline(d[14]&&d[14].hosts, D.leases, d[15]||{}, d[16]||{}, d[17]||{}, D.staticMac);
    D.onlineCount=D.hosts.length;
    D.dhcpCfg=d[18]||null;
    D.leaseMacs=macSet(D.leases);

    var ld=D.sysinfo.load;
    D.loadTxt=Array.isArray(ld)
      ? (ld[0]/65535).toFixed(2)+' / '+(ld[1]/65535).toFixed(2)+' / '+(ld[2]/65535).toFixed(2) : '--';

    repaint();
    return D;
  }).catch(function(){
    /* RPC 失败：保留上次数据重绘，避免定时器卡死 */
    try{ repaint(); }catch(e){}
    return D;
  });
}

/* ================= 视图 ================= */
/* 统一取数入口：load() 与 refreshLive() 共用，保证下标同源 */
function fetchAll(){
  var base=Promise.all([
    L.resolveDefault(callBoard(), {}),
    L.resolveDefault(callSysInfo(), {}),
    L.resolveDefault(callCPUUsage(), {}),
    L.resolveDefault(callTempInfo(), {}),
    L.resolveDefault(callMounts(), {}),
    L.resolveDefault(callOnline(), {}),
    L.resolveDefault(callDHCP(), {}),
    L.resolveDefault(callEthPorts(), {}),
    L.resolveDefault(callLuciVer(), {}),
    L.resolveDefault(fs.read('/etc/compile_info'), ''),
    L.resolveDefault(fs.read('/etc/TZ'), ''),
    L.resolveDefault(network.getWANNetworks(), []),
    L.resolveDefault(network.getWAN6Networks(), []),
    readSys('/proc/sys/net/netfilter/nf_conntrack_count'),
    L.resolveDefault(network.getHostHints(), null),
    readArp(),
    fetchConnIps(),
    readLeaseFile(),
    L.resolveDefault(uci.load('dhcp'), null),
    readDhcpFile(),
    readOwnIps()
  ]);
  return base.then(function(d){
    var names=(d[7]&&d[7].result)?d[7].result:(Array.isArray(d[7])?d[7]:[]);
    return fetchPorts(names).then(function(stats){
      return { d:d, names:names, stats:stats };
    });
  });

}

return view.extend({

  load: function(){ return fetchAll(); },

  render: function(res){
    var d=res.d;
    D.board=d[0]||{}; D.sysinfo=d[1]||{}; D.cpuusage=d[2]||{}; D.tempinfo=d[3]||{};
    D.mounts=(d[4]&&d[4].result)?d[4].result:(Array.isArray(d[4])?d[4]:[]);
    var o=d[5]||{};
    D.onlineCount=(o.onlineusers!=null)?parseInt(o.onlineusers)||0:0;
    D.leases=flatLeases(d[6]);
    D.cpuinfo={}; D.ports=res.stats||[];
    var lv=d[8];
    D.luciVer=(lv&&lv.branch)?(lv.branch+' '+lv.revision):'?';
    D.fwdesc=(d[9]||'').trim();
    D.tz=friendlyTZ((d[10]||'').trim().replace(/^:/,''), -new Date().getTimezoneOffset())
      || (uci.get('system','@system[0]','zonename')||'')
      || (function(){ try{ return Intl.DateTimeFormat().resolvedOptions().timeZone||''; }catch(e){ return ''; } })()
      || '未知';
    D.wan4=wanInfo(pickWan(d[11]), false);
    D.wan6=wanInfo(pickWan(d[12]), true);
    D.conntrack=parseInt(d[13])||0;
    D.staticMac=d[19]||{};
    D.ownIps=d[20]||{};
    D.hosts=computeOnline(d[14]&&d[14].hosts, D.leases, d[15]||{}, d[16]||{}, d[17]||{}, D.staticMac);
    D.onlineCount=D.hosts.length;
    D.dhcpCfg=d[18]||null;
    D.leaseMacs=macSet(D.leases);

    var ld=D.sysinfo.load;
    D.loadTxt=Array.isArray(ld)
      ? (ld[0]/65535).toFixed(2)+' / '+(ld[1]/65535).toFixed(2)+' / '+(ld[2]/65535).toFixed(2) : '--';

    var root=E('div', { 'class':'fov fovroot',
      'style':'margin:-1em -1em 0 -1em;padding:14px;background:transparent;' }, [
      E('link', { 'rel':'stylesheet', 'href': cssHref() }),
      E('div', { 'class':'fov card hdr' }, [
        E('div', { 'class':'fov logo' }, [ 'IW' ]),
        E('div', {}, [
          E('div', { 'class':'fov hname' }, [ D.board.hostname||'ImmortalWrt' ]),
          E('div', { 'class':'fov hsub' }, [
            ((D.board.release&&D.board.release.target)||'').toUpperCase()+' · '+(D.board.kernel||'')
          ])
        ]),
        E('div', { 'class':'fov sp' }),
        E('select', { 'id':'fov-poll', 'class':'fov sel' }, [
          E('option', { 'value':'5' },  [ '5s' ]),
          E('option', { 'value':'10' }, [ '10s' ]),
          E('option', { 'value':'15' }, [ '15s' ]),
          E('option', { 'value':'0' },  [ 'off' ])
        ]),
        E('span', { 'class':'fov pill' }, [ E('span', { 'class':'fov dot' }), 'ONLINE' ]),
        E('div', { 'class':'fov ctime' }, [
          E('div', { 'class':'fov clock', 'id':'fov-clk' }, [ '--:--:--' ]),
          E('div', { 'class':'fov cdate', 'id':'fov-dat' }, [ '----/--/--' ]),
          E('div', { 'class':'fov lunar', 'id':'fov-lun' }, [ '农历 --' ])
        ])
      ]),
      (function(){
        var dd=document.createElement('div');
        dd.id='fov-body';
        dd.innerHTML=buildHTML();
        return dd;
      })()
    ]);

    window.setInterval(tick,1000);
    window.setTimeout(function(){ tick(); renderUsers(); bindSetStatic(); },0);

    watchTheme(root);
    bindUserToggle();

    /* ---- 轮询间隔下拉框：5s/10s/15s/关闭（render 返回前挂载，DOM attach 后绑定） ---- */
    (function(){
      var POLL_KEY='fov_poll_interval';
      function startPoll(v){
        v=String(v||'10');
        if(window.__fovPollTimer){ clearInterval(window.__fovPollTimer); window.__fovPollTimer=null; }
        if(v==='0') return;
        var ms=parseInt(v,10)*1000;
        window.__fovPollTimer=setInterval(function(){
          console.log('[FOV] timer fired, refreshLive @'+new Date().toLocaleTimeString());
          refreshLive();
        }, ms);
      }
      function bind(){
        var sel=document.getElementById('fov-poll');
        if(!sel) return;
        var bound=document.__fovPollBound;
        if(bound){
          /* 已绑定过，只重置定时器（DOM 被重绘/复用场景） */
          startPoll(sel.value);
          return;
        }
        var saved='';
        try{ saved=localStorage.getItem(POLL_KEY)||''; }catch(e){}
        var cur=String(saved||'10');
        sel.value=cur;
        sel.addEventListener('change',function(){
          var v=sel.value;
          try{ localStorage.setItem(POLL_KEY, v); }catch(e){}
          startPoll(v);
        });
        startPoll(cur);
        document.__fovPollBound=true;
        console.log('[FOV] poll sel bound, interval='+(cur==='0'?'off':cur+'s'));
      }
      /* render() 在 LuCI attach 之前执行，#fov-poll 此时不在 document。
         三重兜底：requestAnimationFrame + 200ms + 1s，确保挂载成功后绑上。 */
      requestAnimationFrame(function(){ bind(); });
      setTimeout(function(){ bind(); },200);
      setTimeout(function(){ bind(); },1000);
    })();

    return root;
  },

  handleSaveApply:null, handleSave:null, handleReset:null
});
