"use strict";
const $ = id => document.getElementById(id);
const escapeHTML = value => String(value ?? "").replace(/[&<>"\x27]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","\x27":"&#39;"}[c]));
const native = Boolean(window.webkit?.messageHandlers?.macstate);
const post = (action, extra = {}) => window.webkit?.messageHandlers?.macstate.postMessage({action, ...extra});
const menuLabels = {cpu:"CPU 占用",memory:"内存占用",gpu:"GPU 占用",network:"网络上传 / 下载",cpuTemp:"CPU 温度",gpuTemp:"GPU 温度",systemPower:"系统功耗",battery:"电池电量",disk:"磁盘占用",fan:"风扇转速"};
const defaultNameStyle = () => ({font:"system",size:9,color:"#FFFFFF",automaticColor:true,opacity:0.8});
const defaultValueStyle = () => ({font:"monospaced",size:11,color:"#FFFFFF",automaticColor:true,opacity:1});
let fontFamilies = [];
let lensStatus = "disabled";
let settings = {menuColumnSpacing:4,hideFanUnit:false,menuMetrics:["cpu","memory","network"],hiddenMetrics:[],interval:2,historySeconds:120,theme:"dark",glassOpacity:1,nativeGlassEnabled:false,launchAtLogin:false,compact:false,commandTabOpensMissionControl:false,menuNameStyle:defaultNameStyle(),menuValueStyle:defaultValueStyle()};
let snapshot = null, history = [], view = "overview", group = "all";
let sortKey = "cpu", descending = true, page = 0, paused = false, frozenProcesses = [];
let detailPID = null, saveTimer = null, hotkeyStatus = "disabled";
let focusedMetric = null;
let settingsCategory = "general";
const pageSize = 75;
const titles = {overview:"系统总览",processes:"进程活动",sensors:"硬件传感器",network:"网络接口",storage:"存储卷",usage:"电池与应用使用记录",misc:"快捷工具",screenshot:"截屏",settings:"设置"};
const monitoringViews = ["processes","sensors","network"];
const heroes = ["cpu","memory","gpu","download"];
function format(value, unit = "", precise = false) {
  if (value == null || !Number.isFinite(value)) return {value:"—", unit:"不可用"};
  if (unit === "s") return {value:value >= 86400 ? (value / 86400).toFixed(1) : (value / 3600).toFixed(1),unit:value >= 86400 ? "天" : "小时"};
  if (unit === "thermal") return {value:["正常","轻度","严重","危急"][value] ?? "未知",unit:""};
  if (unit === "level") return {value:({1:"正常",2:"升高",4:"危急"})[value] ?? "未知",unit:""};
  if (unit === "powerState") return {value:({0:"使用电池",1:"正在充电",2:"已连接电源"})[value] ?? "未知",unit:""};
  return {value:value.toFixed(["次","个","页","RPM","MHz","min"].includes(unit) ? 0 : precise || unit === "W" ? 2 : 1),unit};
}
// Bytes use binary units. Keep bandwidth suffix explicit.
function display(value, unit = "") {
  if (value != null && Number.isFinite(value) && (unit === "B" || unit === "B/s")) {
    let n = value, i = 0;
    while (Math.abs(n) >= 1024 && i < 4) { n /= 1024; i++; }
    return {value:n.toFixed(i > 1 ? 2 : i ? 1 : 0),unit:["B","KiB","MiB","GiB","TiB"][i] + (unit === "B/s" ? "/s" : "")};
  }
  return format(value, unit);
}
function valueHTML(value, unit) { const f = display(value, unit); return `${escapeHTML(f.value)}<small>${escapeHTML(f.unit)}</small>`; }
function inlineValue(value, unit) { const f = display(value, unit); return `${f.value} ${f.unit}`.trim(); }
function metricGroup(id) {
  if (id.startsWith("cpu") || id.startsWith("load")) return "cpu";
  if (id.startsWith("memory") || ["swap","pageins","pageouts"].includes(id)) return "memory";
  if (id.startsWith("gpu")) return "gpu";
  if (id.startsWith("battery") || id.toLowerCase().includes("power")) return "power";
  return "other";
}
function points(id) { return history.map(s => ({t:s.timestamp,v:s.metrics.find(m => m.id === id)?.value})); }
function chart(id, unit) {
  const series = points(id), valid = series.filter(p => p.v != null && Number.isFinite(p.v));
  if (valid.length < 2) return `<div class="chart-empty">${valid.length ? "积累趋势数据中" : "暂无可用历史"}</div>`;
  const minimum = Math.min(0,...valid.map(p => p.v)), maximum = unit === "%" ? Math.max(100,...valid.map(p => p.v)) : Math.max(1,...valid.map(p => p.v)) * 1.15;
  const end = history.at(-1).timestamp, start = end - settings.historySeconds;
  let paths = [], segment = [];
  for (const point of series) {
    if (point.v == null) { if(segment.length) paths.push(segment); segment = []; continue; }
    const x = Math.max(0,Math.min(300,(point.t-start)/settings.historySeconds*300));
    const y = 45 - (point.v-minimum)/(maximum-minimum)*40;
    segment.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  if(segment.length) paths.push(segment);
  const lines = paths.map(p => `<polyline class="line" points="${p.join(" ")}"/>`).join("");
  const areas = paths.map(p => `<polygon class="area" points="${p[0].split(",")[0]},48 ${p.join(" ")} ${p.at(-1).split(",")[0]},48"/>`).join("");
  return `<svg class="chart" viewBox="0 0 300 50" preserveAspectRatio="none" aria-label="${escapeHTML(id)} 最近 ${settings.historySeconds} 秒趋势">${areas}${lines}</svg>`;
}
function peak(id) { const valid = points(id).map(p=>p.v).filter(v=>v!=null); return valid.length ? Math.max(...valid) : null; }
function renderOverview() {
  if (!snapshot) return;
  $("chip").textContent = snapshot.device.chip;
  $("model").textContent = snapshot.device.model;
  $("device-meta").textContent = `${snapshot.device.cores} 核 CPU ${inlineValue(snapshot.metrics.find(m=>m.id==="memoryTotal")?.value,"B")}`;
  renderCompactHeroes(heroes.filter(id=>!settings.hiddenMetrics.includes(id)).map(id=>snapshot.metrics.find(m=>m.id===id)).filter(Boolean));
  const metrics = snapshot.metrics.filter(m => (!settings.hiddenMetrics.includes(m.id) || m.id===focusedMetric) && (group === "all" || metricGroup(m.id) === group));
  updateCompactMetrics(metrics.filter(metric=>!heroes.includes(metric.id) || metric.id===focusedMetric));
  $("core-grid").innerHTML = snapshot.cores.map((n,i)=>`<div class="core" title="核心 ${i} ${escapeHTML(inlineValue(n,"%"))}"><span class="core-index">${i}</span><progress class="core-progress" max="100" value="${n ?? 0}" aria-label="核心 ${i} 占用"></progress><span class="core-value">${n==null?"—":Math.round(n)+"%"}</span></div>`).join("");
  const unavailable = snapshot.metrics.filter(m=>m.value==null).length;
  $("availability").innerHTML = `<div class="status-line"><i class="live-dot"></i><span>${snapshot.metrics.length-unavailable} / ${snapshot.metrics.length} 项指标可用 ${snapshot.sensors.length} 个 SMC 传感器 ${snapshot.processes.filter(p=>p.cpu==null).length} 个进程尚无 CPU 数据</span></div>` + snapshot.issues.map(issue=>`<div>${escapeHTML(issue)}</div>`).join("") + `<div>未提供的数据保留“不可用”；原始传感器与全部进程可在“监控”中查看。</div>`;
}
function renderProcesses() {
  if (!snapshot) return;
  const query = $("process-search").value.trim().toLowerCase();
  const active = $("active-only").checked;
  const source = paused ? frozenProcesses : snapshot.processes;
  const rows = source.filter(p => (!query || `${p.name} ${p.pid} ${p.user} ${p.path}`.toLowerCase().includes(query)) && (!active || (p.cpu ?? 0) > .1 || (p.gpu ?? 0) > .1 || (p.readRate ?? 0)+(p.writeRate ?? 0)>0));
  rows.sort((a,b)=>{
    const av = a[sortKey], bv = b[sortKey];
    if(av==null && bv==null) return a.pid-b.pid;
    if(av==null) return 1; if(bv==null) return -1;
    const diff = typeof av === "string" ? av.localeCompare(bv,"zh-CN") : av-bv;
    return (descending ? -diff : diff) || a.pid-b.pid;
  });
  page = Math.min(page,Math.max(0,Math.ceil(rows.length/pageSize)-1));
  function cell(value,unit="") { return `<td${value==null ? ` class="unavailable"` : ""}>${escapeHTML(inlineValue(value,unit))}</td>`; }
  $("process-rows").innerHTML = rows.slice(page*pageSize,(page+1)*pageSize).map(p=>`<tr data-pid="${p.pid}" tabindex="0" aria-label="查看 ${escapeHTML(p.name)} 详情"><td class="process-name" title="${escapeHTML(p.path || p.status)}">${escapeHTML(p.name)}</td><td>${p.pid}</td>${cell(p.cpu)}${cell(p.gpu)}${cell(p.memory,"B")}<td class="process-power" title="${escapeHTML(p.powerStatus || 'CPU 内核能量 + GPU 执行时间归属；主值为当前采样区间，GPU 部分为估算')}">≈ ${usageNumber(p.power,2,"W")}<small>30s 平滑 ${usageNumber(p.smoothedPower,2,"W")}</small></td>${cell(p.readRate,"B/s")}${cell(p.writeRate,"B/s")}<td>${p.threads || "—"}</td><td>${escapeHTML(p.user)}</td></tr>`).join("") || `<tr><td colspan="10" class="empty">没有符合条件的进程</td></tr>`;
  const measured = source.filter(p=>p.power!=null);
  const total = measured.length ? measured.reduce((sum,p)=>sum+p.power,0) : null;
  $("process-power-summary").textContent = `CPU 能量 + GPU 归属 已读取 ${measured.length}/${source.length} 个进程 当前合计 ${usageNumber(total,2,"W")} GPU 部分为估算${paused?" 列表已暂停":""}`;
  if (!paused && snapshot?.processPower) {
    const power = snapshot.processPower;
    if (power.gpuUnattributedPower != null) $("process-power-summary").textContent += ` GPU 未计入合计 ${usageNumber(power.gpuUnattributedPower,2,"W")}`;
    $("process-power-summary").title = power.gpuStatus || "";
  }
  $("process-count").textContent = `${rows.length} / ${source.length} 个进程${paused ? " 已暂停" : ""}`;
  $("page-info").textContent = `第 ${page+1} / ${Math.max(1,Math.ceil(rows.length/pageSize))} 页 每页 ${pageSize} 个 点击进程查看详情`;
  $("prev-page").disabled = page===0; $("next-page").disabled = (page+1)*pageSize>=rows.length;
  document.querySelectorAll("[data-sort]").forEach(button=>{button.textContent = button.textContent.replace(/ [↑↓]$/,"") + (button.dataset.sort===sortKey ? descending ? " ↓" : " ↑" : "");});
  if ($("process-detail").open) renderDetail();
}
function renderDetail() {
  const p = (paused ? frozenProcesses : snapshot.processes).find(p=>p.pid===detailPID);
  if(!p) { $("detail-content").innerHTML = "<dt>状态</dt><dd>进程已退出</dd>"; return; }
  $("detail-title").textContent = p.name;
  const rows = [["PID / 父进程",`${p.pid} / ${p.parent}`],["用户",p.user],["路径",p.path || "未公开"],["CPU",inlineValue(p.cpu,"%")],["GPU 执行时间占比",inlineValue(p.gpu,"%")],["GPU 计数器","IOGPU AppUsage 累计 GPU 纳秒差值 / 采样时间；重叠执行可超过 100%"],["物理 footprint",inlineValue(p.memory,"B")],["驻留内存",inlineValue(p.resident,"B")],["线程",p.threads],["磁盘读取",inlineValue(p.readRate,"B/s")],["磁盘写入",inlineValue(p.writeRate,"B/s")],["唤醒次数",inlineValue(p.wakeups,"次/s")],["当前合计功耗",usageNumber(p.power,3,"W")],["30 秒平滑功耗",usageNumber(p.smoothedPower,3,"W")],["CPU 存活期记录能量",usageNumber(p.lifetimeEnergy == null ? null : p.lifetimeEnergy/3600,4,"Wh")],["计算方式","CPU 内核能量增量 + GPU 设备能量 × 进程 GPU 执行时间份额；除以对应采样秒数。应用合并主进程及辅助进程。"],["数据来源","proc_pid_rusage IOGPU AppUsage IOReport GPU Energy"],["数据范围","CPU 为内核归账，GPU 为执行时间归属估算；相同执行时长的不同 GPU 工作不一定耗能相同，不代表完整硬件实测。共享服务留在其进程，不按前台应用猜测。"],["功耗状态",p.powerStatus || "等待采样"],["缺失处理","CPU 缺失或 GPU 客户端变化、窗口错位时不显示完整合计；未归属能量不强制分摊。"],["读取状态",p.status]];
  $("detail-content").innerHTML = rows.map(([k,v])=>`<dt>${escapeHTML(k)}</dt><dd>${escapeHTML(v)}</dd>`).join("");
}
function renderSensors() {
  if(!snapshot) return;
  const query = $("sensor-search").value.toLowerCase();
  const rows = snapshot.sensors.filter(s=>`${s.key} ${s.unit}`.toLowerCase().includes(query));
  $("sensor-count").textContent = `${rows.length} 个传感器`;
  $("sensor-grid").innerHTML = rows.map(s=>`<article class="metric-card"><div class="card-title"><span>${escapeHTML(s.key)}</span><span>AppleSMC ${escapeHTML(s.type)}</span></div><div class="metric-value">${valueHTML(s.value,s.unit)}</div></article>`).join("") || `<div class="empty">${snapshot.sensors.length ? "没有匹配的传感器" : "此设备未提供可读取的 SMC 传感器"}</div>`;
}
function kv(label,value) { return `<div class="kv"><span class="muted">${escapeHTML(label)}</span><strong>${escapeHTML(value)}</strong></div>`; }
function renderNetwork() {
  if(!snapshot) return;
  $("network-grid").innerHTML = snapshot.networks.map(n=>`<article class="metric-card"><div class="card-title"><span>网络接口</span><span>${n.up ? "活动" : "未连接"}</span></div><div class="network-name">${escapeHTML(n.name)}</div><div class="metric-detail">${escapeHTML(n.address || "无 IPv4 地址")}</div>${kv("下载",inlineValue(n.download,"B/s"))}${kv("上传",inlineValue(n.upload,"B/s"))}${kv("累计接收",inlineValue(n.received,"B"))}${kv("累计发送",inlineValue(n.sent,"B"))}</article>`).join("") || `<div class="empty">没有可读取的网络接口</div>`;
}
function renderVolumes() {
  if(!snapshot) return;
  renderStorageVolumes(snapshot.volumes);
}
function renderSettings() {
  renderMenuStyle("name",settings.menuNameStyle);
  renderMenuStyle("value",settings.menuValueStyle);
  renderMenuPreview();
  renderColumns();
  $("menu-column-spacing").value=settings.menuColumnSpacing ?? 4;
  $("hide-fan-unit").checked=Boolean(settings.hideFanUnit);
  $("interval").value = settings.interval; $("history").value = settings.historySeconds; $("theme").value = settings.theme;
  $("glass-opacity").value = Math.round((1 - settings.glassOpacity) * 100);
  $("glass-opacity-value").textContent = Math.round((1 - settings.glassOpacity) * 100) + "%";
  $("native-glass-enabled").checked = Boolean(settings.nativeGlassEnabled);
  renderMisc();
  renderLensStatus();
  $("compact").checked = settings.compact; $("launch-login").checked = settings.launchAtLogin;
  $("panel-options").innerHTML = snapshot ? snapshot.metrics.map(m=>`<label><input type="checkbox" data-panel="${m.id}" ${settings.hiddenMetrics.includes(m.id)?"":"checked"}>${escapeHTML(m.title)}${m.value==null?" 不可用":""}</label>`).join("") : `<div class="muted">采样后可以配置指标</div>`;
}
function renderMisc() {
  renderBrightness();
  $("command-tab-mission-control").checked = Boolean(settings.commandTabOpensMissionControl);
  renderHotkeyStatus();
}
function renderHotkeyStatus() {
  const messages = {
    disabled:"快捷键映射已关闭。",
    active:"",
    permissionNeeded:"当前版本尚未获得系统的键盘控制授权。请在“隐私与安全 → 设备控制和数据访问”（旧版为“辅助功能”）中允许 MacState；若已经开启仍无效，请移除旧 MacState 条目，再添加当前应用并授权。授权生效后会自动重试，勾选会保留。",
    unavailable:"系统未能建立快捷键监听，正在自动重试。也可以点击“重新检测”。"
  };
  const needsPermission = hotkeyStatus === "permissionNeeded";
  $("command-tab-status").textContent = messages[hotkeyStatus] ?? messages.disabled;
  $("command-tab-status").hidden = hotkeyStatus === "active";
  $("command-tab-access-settings").hidden = !needsPermission;
  $("command-tab-permission-actions").hidden = !settings.commandTabOpensMissionControl || !(needsPermission || hotkeyStatus === "unavailable");
}
function columns() {
  if(!settings.menuColumns) settings.menuColumns=settings.menuMetrics.map(id=>({id,name:({cpu:"CPU",memory:"MEM",gpu:"GPU"})[id] || menuLabels[id],metrics:id==="network"?["upload","download"]:[id],spacing:6,layout:id==="network"?"network":"named"}));
  return settings.menuColumns;
}
function selectableMetrics() {
  const result=new Map(Object.entries(menuLabels).filter(([id])=>id!=="network"));
  result.set("upload","网络上传");result.set("download","网络下载");
  for(const metric of snapshot?.metrics || []) result.set(metric.id,metric.title);
  return result;
}
function renderColumns() {
  const options=selectableMetrics();
  $("menu-options").innerHTML=columns().map((column,index)=>`<fieldset class="menu-column" data-column="${index}"><legend>栏目 ${index+1}</legend>
    <div class="column-controls"><label>名称<input data-column-field="name" maxlength="64" value="${escapeHTML(column.name)}" aria-label="栏目 ${index+1} 名称"></label>
    <label>排列<select data-column-field="layout"><option value="named" ${column.layout!=="network"?"selected":""}>名称在上 参数在下</option><option value="network" ${column.layout==="network"?"selected":""}>网络上传在上 下载在下</option></select></label>
    <label>栏内参数间距（pt）<input data-column-field="spacing" type="number" min="0" max="40" step="1" value="${column.spacing}" aria-label="栏目 ${index+1} 参数间距"></label>
    <button data-column-action="left" ${index===0?"disabled":""} aria-label="栏目左移">←</button><button data-column-action="right" ${index===columns().length-1?"disabled":""} aria-label="栏目右移">→</button><button data-column-action="delete" ${columns().length===1?"disabled":""}>删除栏目</button></div>
    ${column.layout==="network"?'<p class="muted">上传与下载共用数值样式。切换排列后可以自定义名称和参数。</p>':`<div class="column-parameters">${column.metrics.map((id,position)=>`<div class="parameter-control"><select data-parameter="${position}" aria-label="栏目 ${index+1} 参数 ${position+1}">${[...new Map([...options,[id,options.get(id)||id]])].map(([key,title])=>`<option value="${escapeHTML(key)}" ${key===id?"selected":""}>${escapeHTML(title)}</option>`).join("")}</select><button data-parameter-move="${position}" ${position===0?"disabled":""} aria-label="参数左移">←</button><button data-parameter-delete="${position}" ${column.metrics.length===1?"disabled":""} aria-label="删除参数">×</button></div>`).join("")}<button data-column-action="add" ${column.metrics.length>=8?"disabled":""}>添加参数</button></div>`}
  </fieldset>`).join("");
  $("add-menu-column").disabled=columns().length>=20;
}
function renderMenuStyle(part, style) {
  const families = [...new Set(["system","monospaced",...fontFamilies,style.font])];
  const fontOptions = families.map(font=>`<option value="${escapeHTML(font)}" ${style.font===font?"selected":""}>${escapeHTML(font==="system"?"系统字体":font==="monospaced"?"系统等宽数字":font)}</option>`).join("");
  $(part+"-style").innerHTML = `<legend>${part==="name"?"名称样式":"数值样式"}</legend>
    <label class="setting-row">字体<select data-style-part="${part}" data-style-field="font" aria-label="${part==="name"?"名称":"数值"}字体">${fontOptions}</select></label>
    <label class="setting-row">字号（pt）<input type="number" min="6" max="18" step="0.5" value="${style.size}" data-style-part="${part}" data-style-field="size" aria-label="${part==="name"?"名称":"数值"}字号"></label>
    <label class="setting-row">自动适应菜单栏颜色<input type="checkbox" ${style.automaticColor?"checked":""} data-style-part="${part}" data-style-field="automaticColor"></label>
    <label class="setting-row">自定义颜色<input type="color" value="${escapeHTML(style.color)}" ${style.automaticColor?"disabled":""} data-style-part="${part}" data-style-field="color" aria-label="${part==="name"?"名称":"数值"}颜色"></label>
    <label class="setting-row">不透明度<span class="opacity-control"><input type="range" min="0" max="100" step="1" value="${Math.round(style.opacity*100)}" data-style-part="${part}" data-style-field="opacity" aria-label="${part==="name"?"名称":"数值"}不透明度"><output id="${part}-opacity-value">${Math.round(style.opacity*100)}%</output></span></label>`;
}
function renderMenuPreview() {
  if(native)post("menuPreview",{visible:view==="settings" && settingsCategory==="menu"});
  else $("menu-preview-wait").textContent="原生状态栏预览在 MacState 应用内显示。";
  for(const part of ["name","value"]) {const output=$(part+"-opacity-value");if(output)output.textContent=Math.round(settings[part==="name"?"menuNameStyle":"menuValueStyle"].opacity*100)+"%";}
}
window.receiveMenuPreview = image => {
  $("menu-preview").src=image;
  $("menu-preview").hidden=false;
  $("menu-preview-wait").hidden=true;
};
function applyAppearance() {
  document.body.classList.toggle("light",settings.theme==="light" || settings.theme==="system" && matchMedia("(prefers-color-scheme: light)").matches);
  document.body.classList.toggle("compact",settings.compact);
  settings.glassOpacity = Number.isFinite(settings.glassOpacity) ? Math.min(1,Math.max(0,settings.glassOpacity)) : 1;
  const opacity = settings.glassOpacity;
  const style = document.documentElement.style;
  style.setProperty("--glass-opacity",String(opacity));
  style.setProperty("--glass-surface-alpha",String(0.025 + opacity * 0.055));
  style.setProperty("--glass-control-alpha",String(0.06 + opacity * 0.10));
  style.setProperty("--glass-sidebar-alpha",String(0.02 + opacity * 0.04));
  style.setProperty("--glass-footer-alpha","0.7");
  $("glass-opacity-value").textContent = Math.round((1 - opacity) * 100) + "%";
  post("glassAppearance",{opacity,theme:settings.theme});
}
function saveSettings(immediate = false) {
  applyAppearance(); $("save-status").textContent = native ? "保存中…" : "预览设置已更新";
  renderMenuPreview();
  clearTimeout(saveTimer);
  if(immediate) {saveTimer=null;post("saveSettings",{settings});}
  else saveTimer = setTimeout(()=>post("saveSettings",{settings}),180);
}
function selectSettingsCategory(next) {
  const panel=$("settings-"+next);
  if(!panel?.classList.contains("settings-category"))return;
  stopScreenshotShortcutRecording();
  settingsCategory=next;
  $("save-status").hidden=next==="screenshot";
  document.querySelectorAll("#settings .settings-category").forEach(section=>section.hidden=section!==panel);
  document.querySelectorAll("#settings-tabs [role=tab]").forEach(tab=>{
    const selected=tab.dataset.settingsCategory===next;
    tab.classList.toggle("selected",selected);
    tab.setAttribute("aria-selected",String(selected));
    tab.tabIndex=selected?0:-1;
  });
  if(next==="screenshot")post("getScreenshotState");
  renderMenuPreview();window.scrollTo(0,0);
}
function navigate(next) {
  if(!Object.prototype.hasOwnProperty.call(titles,next))return;
  if(view==="storage" && next!=="storage")suspendStorageAnalysis();
  stopScreenshotShortcutRecording();
  if(next!=="overview") focusedMetric=null;
  view = next;
  if(next==="settings")selectSettingsCategory("general");
  const monitoring = monitoringViews.includes(next);
  const navigationPage = monitoring ? "processes" : next;
  document.querySelectorAll(".view").forEach(s=>s.hidden=s.id!==next);
  document.querySelectorAll(".sidebar [data-view]").forEach(b=>{
    b.classList.toggle("active",b.dataset.view===navigationPage);
    if(b.dataset.view===navigationPage)b.setAttribute("aria-current","page");
    else b.removeAttribute("aria-current");
  });
  $("monitor-tabs").hidden = !monitoring;
  document.querySelectorAll("#monitor-tabs [role=tab]").forEach(tab=>{
    const selected = tab.dataset.view===next;
    tab.classList.toggle("selected",selected);
    tab.setAttribute("aria-selected",String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  $("page-title").textContent = monitoring ? "监控" : titles[next];
  $("export").hidden = next === "usage";
  renderCurrent(); window.scrollTo(0,0); post("refresh");
  if(next==="screenshot")post("getScreenshotState");
  if(next==="misc")post("getDisplayBrightness");
  if(next!=="settings")post("menuPreview",{visible:false});
  usageNavigation(next);
  post("navigation",{page:next});
  if(next==="storage"){post("checkDiskAccess");resumeStorageAnalysis();}
}
window.restorePage = saved => navigate(monitoringViews.includes(saved)?"processes":Object.prototype.hasOwnProperty.call(titles,saved)?saved:"overview");
function renderCurrent() {
  ({overview:renderOverview,processes:renderProcesses,sensors:renderSensors,network:renderNetwork,storage:renderVolumes,usage:renderUsage,misc:renderMisc,screenshot:renderScreenshots,settings:renderSettings})[view]();
}
window.receiveSnapshot = data => {
  snapshot = data;
  if (!history.some(s=>s.timestamp===data.timestamp)) history.push({timestamp:data.timestamp,metrics:data.metrics});
  history = history.filter(s=>s.timestamp>=data.timestamp-settings.historySeconds).slice(-600);
  $("process-badge").textContent = data.processes.length;
  $("sampling").innerHTML = `<i class="live-dot"></i>每 ${settings.interval} 秒更新`;
  $("device-mini").textContent = data.device.model;
  const small=document.createElement("small"); small.textContent="本地采集 数据不上传"; $("device-mini").append(small);
  $("last-update").textContent = "更新于 " + new Date(data.timestamp*1000).toLocaleTimeString("zh-CN",{hour12:false});
  $("collection-time").textContent = `本次采集 ${data.collectionMS.toFixed(0)} ms`;
  if(view!=="settings" && view!=="usage") renderCurrent();
  else if(view==="settings") renderMenuPreview();
};
window.receiveHistory = samples => {
  history = samples.map(s=>({timestamp:s.timestamp,metrics:s.metrics}));
  if(view==="overview") renderOverview();
};
window.receiveSettings = data => {
  const editingGlass = document.activeElement === $("glass-opacity");
  settings={...data,nativeGlassEnabled:Boolean(data.nativeGlassEnabled),commandTabOpensMissionControl:Boolean(data.commandTabOpensMissionControl),glassOpacity:editingGlass?settings.glassOpacity:data.glassOpacity ?? 1}; applyAppearance(); renderLensStatus();
  if(view==="settings" && !document.activeElement.matches("[data-style-field],[data-column-field],[data-parameter],#menu-column-spacing,#glass-opacity,#command-tab-mission-control")) renderSettings();
  if(view==="misc") renderMisc();
  $("save-status").textContent="已保存到本机";
  if(view==="overview") renderOverview();
};
window.receiveHotkeyStatus = status => {hotkeyStatus=status;renderHotkeyStatus();};
window.receiveFonts = families => {fontFamilies=families;if(view==="settings")renderSettings();};
window.focusMetric = id => {
  focusedMetric=id;
  group="all"; document.querySelectorAll("[data-group]").forEach(b=>b.classList.toggle("selected",b.dataset.group==="all"));
  navigate("overview");
  const card=document.querySelector(`#metric-grid #metric-${CSS.escape(id)}`);
  if(card) card.scrollIntoView({behavior:matchMedia("(prefers-reduced-motion: reduce)").matches?"instant":"smooth",block:"center"});
};
window.openOverview = () => {
  focusedMetric=null; group="all"; expandedMetrics.clear();
  document.querySelectorAll("[data-group]").forEach(button=>button.classList.toggle("selected",button.dataset.group==="all"));
  document.querySelectorAll("dialog[open]").forEach(dialog=>dialog.close());
  navigate("overview");
};
window.openSettings = () => navigate("settings");
window.showError = message => { $("error").textContent=message; $("error").hidden=false; };
document.addEventListener("click",event=>{
  const nav=event.target.closest("[data-view]"); if(nav) navigate(nav.dataset.view);
  const category=event.target.closest("[data-settings-category]"); if(category)selectSettingsCategory(category.dataset.settingsCategory);
  const g=event.target.closest("[data-group]"); if(g){group=g.dataset.group;document.querySelectorAll("[data-group]").forEach(b=>b.classList.toggle("selected",b===g));renderOverview();}
  const focus=event.target.closest("[data-focus]"); if(focus) window.focusMetric(focus.dataset.focus);
  const sort=event.target.closest("[data-sort]"); if(sort){if(sortKey===sort.dataset.sort) descending=!descending; else {sortKey=sort.dataset.sort;descending=!['name','user','pid'].includes(sortKey);}page=0;renderProcesses();}
  const row=event.target.closest("[data-pid]"); if(row){detailPID=Number(row.dataset.pid);renderDetail();$("process-detail").showModal();}
  const fieldset=event.target.closest("[data-column]");
  if(fieldset){const index=Number(fieldset.dataset.column),column=columns()[index],button=event.target.closest("button");if(!button || button.disabled)return;
    const action=button.dataset.columnAction;
    if(action==="left" || action==="right"){const other=index+(action==="left"?-1:1);[settings.menuColumns[index],settings.menuColumns[other]]=[settings.menuColumns[other],settings.menuColumns[index]];}
    if(action==="delete" && columns().length>1)settings.menuColumns.splice(index,1);
    if(action==="add" && column.metrics.length<8){const id=[...selectableMetrics().keys()].find(id=>!column.metrics.includes(id));if(id)column.metrics.push(id);}
    if(button.dataset.parameterDelete!==undefined && column.metrics.length>1)column.metrics.splice(Number(button.dataset.parameterDelete),1);
    if(button.dataset.parameterMove!==undefined){const i=Number(button.dataset.parameterMove);if(i>0)[column.metrics[i-1],column.metrics[i]]=[column.metrics[i],column.metrics[i-1]];}
    renderColumns();saveSettings();
  }
});
document.addEventListener("keydown",event=>{
  if(event.isComposing || event.keyCode===229)return;
  const tab=event.target.closest("[role=tablist] [role=tab]");
  if(tab && ["ArrowLeft","ArrowRight","Home","End"].includes(event.key)){
    const tabs=[...tab.closest("[role=tablist]").querySelectorAll("[role=tab]")];
    const index=event.key==="Home"?0:event.key==="End"?tabs.length-1:(tabs.indexOf(tab)+(event.key==="ArrowRight"?1:-1)+tabs.length)%tabs.length;
    event.preventDefault();tabs[index].click();tabs[index].focus();return;
  }
  if(event.key==="Enter" || event.key===" "){const target=event.target.closest("[data-pid],[data-focus]");if(target){event.preventDefault();target.click();}}
});
$("add-menu-column").onclick=()=>{if(columns().length>=20)return;const id=typeof crypto.randomUUID==="function"?crypto.randomUUID():"column-"+Array.from(crypto.getRandomValues(new Uint32Array(4)),value=>value.toString(16)).join("-");settings.menuColumns.push({id,name:"CPU",metrics:["cpu","cpuTemp"],spacing:6,layout:"named"});renderColumns();saveSettings();};
$("menu-options").addEventListener("input",event=>{
  const fieldset=event.target.closest("[data-column]");if(!fieldset)return;
  const column=columns()[Number(fieldset.dataset.column)],field=event.target.dataset.columnField;
  if(field==="name")column.name=event.target.value;
  if(field==="spacing"){const n=Number(event.target.value);if(!Number.isFinite(n)||n<0||n>40)return;column.spacing=n;}
  if(field==="layout"){column.layout=event.target.value;if(column.layout==="network")column.metrics=["upload","download"];renderColumns();}
  if(event.target.dataset.parameter!==undefined){const index=Number(event.target.dataset.parameter),id=event.target.value;if(column.metrics.some((value,i)=>i!==index&&value===id)){event.target.value=column.metrics[index];return;}column.metrics[index]=id;}
  saveSettings();
});
$("menu-column-spacing").addEventListener("input",()=>{const value=Number($("menu-column-spacing").value);if(!Number.isFinite(value)||value<0||value>40)return;settings.menuColumnSpacing=value;saveSettings();});
$("hide-fan-unit").addEventListener("change",()=>{settings.hideFanUnit=$("hide-fan-unit").checked;saveSettings();});
// Keep the persisted material density compatible; the user-facing control is
// transparency adjusts native tint; enhanced glass adds system lensing.
$("glass-opacity").addEventListener("input",()=>{settings.glassOpacity=1-Number($("glass-opacity").value)/100;saveSettings();});
function renderLensStatus() {
  const state = settings.nativeGlassEnabled ? lensStatus : "disabled";
  const messages = {
    disabled:"低开销模式 一层系统磨砂背景，组件使用轻量透明层。无需录屏权限。",
    native:"原生玻璃增强已开启 由 macOS 合成玻璃效果，无需录屏权限。0% 时仍使用磨砂。",
    starting:"正在应用原生玻璃…无需录屏权限。",
    unavailable:"当前系统不支持原生玻璃增强，继续使用低开销磨砂。无需录屏权限。"
  };
  $("lens-status").textContent = messages[state] || messages.native;
}
window.receiveLensStatus = state => {lensStatus=state;renderLensStatus();};
$("native-glass-enabled").addEventListener("change",()=>{settings.nativeGlassEnabled=$("native-glass-enabled").checked;lensStatus=settings.nativeGlassEnabled?"starting":"disabled";renderLensStatus();saveSettings();});
let brightnessRows = [];
// Leading-edge updates make DDC react during the drag. Intermediate values
// are coalesced to one send per ~85ms; mouseup guarantees the final target.
const brightnessPending = new Map();
const brightnessSendIntervalMs = 85;
let brightnessDragging = null;
function brightnessModeText(mode) {
  return ({system:"系统背光",ddc:"DDC/CI",ddcUnverified:"DDC/CI 待读回",software:"软件调暗",unavailable:"不可用"})[mode] || "不可用";
}
function renderBrightness() {
  const container = $("brightness-displays");
  // Preserve the native WebKit drag while the pointer is actually held.
  // Keyboard-focus alone must not freeze future hardware status refreshes.
  if (brightnessDragging) return;
  container.innerHTML = brightnessRows.length ? brightnessRows.map(row => {
    const safeMode = ["system","ddc","ddcUnverified","software","unavailable"].includes(row.mode) ? row.mode : "unavailable";
    const value = Math.max(0,Math.min(100,Math.round(Number(row.percent) || 0)));
    return `<article class="brightness-display">
      <div><div class="brightness-title"><strong>${escapeHTML(row.name)}</strong><span class="brightness-mode mode-${safeMode}">${brightnessModeText(safeMode)}</span></div>
      <div class="brightness-subtitle">${escapeHTML(row.detail)}</div></div>
      <div class="brightness-controls"><input type="range" data-brightness-id="${escapeHTML(row.id)}" min="0" max="100" step="1" value="${value}" aria-label="${escapeHTML(row.name)}亮度" ${safeMode==="unavailable"?"disabled":""}>
      <output>${safeMode==="unavailable" || row.valueKnown===false?"—":value+"%"}</output></div>
    </article>`;
  }).join("") : `<div class="muted">没有检测到可调节的显示器，或正在读取显示器能力。</div>`;
}
window.receiveDisplayBrightness = rows => {
  brightnessRows=Array.isArray(rows)?rows.filter(row=>row && typeof row.id==="string"):[];
  renderBrightness();
  $("brightness-status").textContent = brightnessRows.some(row=>row.mode==="ddcUnverified")
    ? "DDC/CI 读取失败不代表不能硬件调节。此时滑块位置只是参考，首次拖动会发送硬件亮度命令；写入结果会显示在显示器信息中。"
    : brightnessRows.some(row=>row.mode==="software")
      ? "软件调暗只改变画面，不会调整物理背光。退出 MacState 会尝试恢复原始色彩表。"
      : "亮度命令发送到对应显示器；刷新可重新检测状态。";
};
function sendPendingBrightness(id, force=false) {
  const state=brightnessPending.get(id);
  if(!state || state.next===null)return;
  const remaining=brightnessSendIntervalMs-(performance.now()-state.lastSentAt);
  if(!force && remaining>0) {
    if(!state.timer)state.timer=setTimeout(()=>{
      state.timer=null;
      sendPendingBrightness(id);
    },remaining);
    return;
  }
  if(state.timer){clearTimeout(state.timer);state.timer=null;}
  const value=state.next;
  state.next=null;
  // Native input can fire just before change. Do not send the same value twice.
  if(value===state.lastSentValue)return;
  state.lastSentValue=value;
  state.lastSentAt=performance.now();
  post("setDisplayBrightness",{id,percent:value});
}
function queueBrightnessValue(input, final=false) {
  const id=input.dataset.brightnessId;
  const percent=Math.round(Number(input.value));
  if(!id || !Number.isFinite(percent))return;
  input.nextElementSibling.textContent=percent+"%";
  const visible=brightnessRows.find(row=>row.id===id);
  if(visible){visible.percent=percent;visible.valueKnown=true;}
  let state=brightnessPending.get(id);
  if(!state){
    state={lastSentAt:-Infinity,lastSentValue:null,next:null,timer:null};
    brightnessPending.set(id,state);
  }
  state.next=percent;
  sendPendingBrightness(id,final);
}
$("brightness-displays").addEventListener("pointerdown",event=>{
  if(event.target.matches("[data-brightness-id]")){
    brightnessDragging=event.target.dataset.brightnessId;
    const state=brightnessPending.get(brightnessDragging);
    // Each new deliberate drag may retry the same value after a DDC error.
    if(state)state.lastSentValue=null;
  }
});
for(const type of ["pointerup","pointercancel"]){
  document.addEventListener(type,()=>{
    if(!brightnessDragging)return;
    const id=brightnessDragging;
    const slider=[...$("brightness-displays").querySelectorAll("[data-brightness-id]")]
      .find(el=>el.dataset.brightnessId===id);
    if(slider)queueBrightnessValue(slider,true);
    brightnessDragging=null;
    // Do not replace a range input before its native change event fires.
    setTimeout(renderBrightness,80);
  });
}
$("brightness-displays").addEventListener("input",event=>{
  if(event.target.matches("[data-brightness-id]"))queueBrightnessValue(event.target);
});
$("brightness-displays").addEventListener("change",event=>{
  if(event.target.matches("[data-brightness-id]")){
    queueBrightnessValue(event.target,true);
    if(!brightnessDragging)setTimeout(renderBrightness,0);
  }
});
$("refresh-brightness").onclick=()=>{
  $("brightness-status").textContent="正在重新检测显示器…";
  post("retryDisplayBrightness");
};
$("command-tab-mission-control").addEventListener("change",()=>{settings.commandTabOpensMissionControl=$("command-tab-mission-control").checked;saveSettings(true);});
$("retry-command-tab").onclick=()=>post("retryMissionControlHotkey");
$("command-tab-access-settings").disabled=!native;
$("command-tab-access-settings").onclick=()=>post("openMissionControlAccessSettings");
for(const part of ["name","value"]) $(part+"-style").addEventListener("input",event=>{
  const field=event.target.dataset.styleField;if(!field)return;
  const style=settings[part==="name"?"menuNameStyle":"menuValueStyle"];
  if(field==="size") {const n=Number(event.target.value);if(!Number.isFinite(n)||n<6||n>18)return;style.size=n;}
  else if(field==="opacity") style.opacity=Number(event.target.value)/100;
  else if(field==="automaticColor") {style.automaticColor=event.target.checked;$(part+"-style").querySelector("input[type=color]").disabled=style.automaticColor;}
  else style[field]=event.target.value;
  saveSettings();
});
$("reset-menu-style").onclick=()=>{settings.menuNameStyle=defaultNameStyle();settings.menuValueStyle=defaultValueStyle();renderSettings();saveSettings();};
$("panel-options").addEventListener("change",event=>{const id=event.target.dataset.panel;if(!id)return;settings.hiddenMetrics=event.target.checked?settings.hiddenMetrics.filter(m=>m!==id):[...settings.hiddenMetrics,id];saveSettings();});
for(const [id,key] of [["interval","interval"],["history","historySeconds"],["theme","theme"],["compact","compact"],["launch-login","launchAtLogin"]]) $(id).addEventListener("change",()=>{settings[key]=$(id).type==="checkbox"?$(id).checked:key==="theme"?$(id).value:Number($(id).value);saveSettings();});
$("process-search").addEventListener("input",()=>{page=0;renderProcesses();});
$("active-only").addEventListener("change",()=>{page=0;renderProcesses();});
$("sensor-search").addEventListener("input",renderSensors);
$("prev-page").onclick=()=>{page--;renderProcesses();};$("next-page").onclick=()=>{page++;renderProcesses();};
$("pause-processes").onclick=()=>{paused=!paused;if(paused)frozenProcesses=snapshot?.processes ?? [];$("pause-processes").textContent=paused?"恢复列表":"暂停列表";renderProcesses();};
$("close-detail").onclick=()=>$("process-detail").close();
$("settings-button").onclick=window.openSettings;
$("close-panel").onclick=()=>post("closePanel");
$("fullscreen-panel").onclick=()=>post("toggleFullscreen");
window.receivePanelFullscreen=expanded=>{
  const button=$("fullscreen-panel");
  button.setAttribute("aria-label",expanded?"退出全屏":"全屏");
  button.title=expanded?"退出全屏":"全屏";
  button.setAttribute("aria-pressed",String(expanded));
};
$("open-mission-control").onclick=()=>post("openMissionControl");
$("show-all").onclick=()=>{settings.hiddenMetrics=[];renderSettings();saveSettings();};
$("available-only").onclick=()=>{settings.hiddenMetrics=snapshot?.metrics.filter(m=>m.value==null).map(m=>m.id) ?? [];renderSettings();saveSettings();};
$("export").onclick=()=>{if(view==="storage" && diskScan){$("storage-export-panel").hidden=!$("storage-export-panel").hidden;}else post("export");};$("quit").onclick=()=>post("quit");
$("reset-history").onclick=()=>{history=[];post("resetHistory");renderOverview();};
matchMedia("(prefers-color-scheme: light)").addEventListener("change",applyAppearance);
if(!native){$("preview-notice").hidden=false;$("export").disabled=true;$("launch-login").disabled=true;$("quit").disabled=true;$("close-panel").disabled=true;$("fullscreen-panel").disabled=true;$("open-mission-control").disabled=true;$("command-tab-mission-control").disabled=true;}
installUsagePage();installDiskAnalysis();installDiskSpaceMap();installStorageFiles();installStorageInsights();installDiskWorkbench();installDiskFileInteractions();installScreenshots();applyAppearance();post("ready");
