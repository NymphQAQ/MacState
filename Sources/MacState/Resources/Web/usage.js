"use strict";
let usageData = null, usageSelectedID = null, usageCursorTime = null, usageDeleteID = null, usageChartGeometry = null;
const usageModes = {battery:"电池供电",charging:"正在充电",plugged:"已连接电源",desktop:"外接电源 无电池",unknown:"电源状态未知"};
const usageColors = ["#64AAFF","#30D158","#FFB340","#FF827A","#5AC8FA","#66D4CF","#E2C466","#EB9E75"];

function usageDuration(seconds) {
  if (seconds == null || !Number.isFinite(seconds)) return "—";
  const n = Math.max(0, Math.floor(seconds)), hours = Math.floor(n / 3600), minutes = Math.floor(n % 3600 / 60);
  return hours ? `${hours}h${String(minutes).padStart(2,"0")}m` : minutes ? `${minutes}m${String(n % 60).padStart(2,"0")}s` : `${n}s`;
}
function usageDate(time, includeDate = true) {
  return new Date(time * 1000).toLocaleString("zh-CN", {month:includeDate?"2-digit":undefined,day:includeDate?"2-digit":undefined,hour:"2-digit",minute:"2-digit",hour12:false});
}
function usageAverage(total, duration) { return duration > 0 ? total / duration : null; }
function usageNumber(value, decimals = 1, unit = "") { return value == null || !Number.isFinite(value) ? "—" : `${value.toFixed(decimals)}${unit}`; }
function usageIcon(id) {
  const icon = usageData?.icons?.[id];
  return typeof icon === "string" && icon.startsWith("data:image/png;base64,") && icon.length < 65536 ? icon : null;
}
function usageColor(id) {
  let hash = 0; for (const character of id) hash = (Math.imul(hash,31) + character.charCodeAt(0)) >>> 0;
  return usageColors[hash % usageColors.length];
}
function usageNavigation(next) { post("usageHistory",{visible:next==="usage",sessionID:usageSelectedID}); }
window.receiveUsage = data => {
  usageData = data;
  if (usageSelectedID && !data.sessions.some(s=>s.id===usageSelectedID)) usageSelectedID = null;
  if (view === "usage") renderUsage();
};

function renderUsage() {
  const sessions = usageData?.sessions ?? [], selected = usageData?.selected;
  const active = sessions.find(s=>s.active);
  $("usage-history").innerHTML = `<option value="">${active ? `${escapeHTML(usageDate(active.startedAt))} 当前记录` : "当前记录"}</option>` + sessions.filter(s=>!s.active).map(s=>`<option value="${escapeHTML(s.id)}">${escapeHTML(usageDate(s.startedAt))} ${escapeHTML(usageModes[s.mode] ?? "未知")} ${escapeHTML(usageDuration(s.activeDuration))}</option>`).join("");
  $("usage-history").value = usageSelectedID ?? "";
  for (const id of ["usage-delete","usage-export"]) $(id).disabled = !native || !selected;
  $("usage-current").hidden = !usageSelectedID;
  if (!selected) {
    resetUsageProcesses(null);
    $("usage-chart").innerHTML = '<div class="usage-empty">从新版启动后开始记录，电量曲线和前台应用时间会在这里累积。</div>';
    $("usage-apps").innerHTML = '<div class="usage-empty">正在累积前台应用使用时间…</div>';
    $("usage-average-power").textContent = "—"; $("usage-duration").textContent = "0s"; $("usage-runtime").textContent = "—";
    $("usage-cursor").hidden = true; $("usage-app-count").textContent = "";
    $("usage-period").textContent = "正在开始记录…"; $("usage-mode").textContent = "等待采样";
    $("usage-mode").classList.remove("is-live");
    $("usage-inspector").textContent = "等待第一条采样";
    $("usage-power-note").textContent = "等待有效功率读数";
    $("usage-runtime-note").textContent = "电池供电时根据耗电速度估算";
    return;
  }
  const live = sessions.some(s=>s.id===selected.id && s.active);
  $("usage-mode").textContent = usageModes[selected.mode] ?? "未知";
  $("usage-mode").classList.toggle("is-live",live);
  const batteryRange = selected.startBattery == null || selected.endBattery == null ? "" : ` ${Math.round(selected.startBattery)}% → ${Math.round(selected.endBattery)}%`;
  $("usage-period").textContent = `${usageDate(selected.startedAt)} — ${live?"现在":usageDate(selected.updatedAt)}${batteryRange}`;
  $("usage-chart-title").textContent = selected.hasBattery ? "电量与使用过程" : "功耗与使用过程";
  $("usage-curve-label").textContent = selected.hasBattery ? "电量" : "整机功耗";
  const power = usageData.averagePower;
  $("usage-average-power").innerHTML = power == null ? "—" : `${usageNumber(power,2)}<small>W</small>`;
  $("usage-power-note").textContent = selected.powerDuration > 0 ? selected.powerSource : "等待有效功率读数";
  $("usage-duration").textContent = usageDuration(selected.activeDuration);
  $("usage-runtime").textContent = usageDuration(usageData.theoreticalRuntime);
  $("usage-runtime-note").textContent = usageData.theoreticalRuntime != null ? "根据已观测的放电速度估算" : selected.mode === "battery" ? "需 ≥5 分钟放电且电量下降 ≥2%" : selected.hasBattery ? "电池供电时估算" : "此设备没有电池";
  renderUsageChart(selected);
  renderUsageApps();
}

function renderUsageChart(session) {
  const points = session.points ?? [], field = session.hasBattery ? "battery" : "power";
  const valid = points.filter(p=>p[field]!=null && Number.isFinite(p[field]));
  if (!valid.length) {
    $("usage-chart").innerHTML = `<div class="usage-empty">${session.hasBattery?"等待电量读数":"此设备没有电池，也未提供可用的整机功率读数"}<br>前台应用时间仍会继续记录。</div>`;
    $("usage-cursor").hidden = true; $("usage-inspector").textContent = "尚无可用曲线数据";
    return;
  }
  const start = session.startedAt, end = Math.max(start + 1,session.updatedAt), span = end - start;
  const maximum = session.hasBattery ? 100 : Math.max(1,...valid.map(p=>p[field])) * 1.15;
  const compact = matchMedia("(max-height:500px)").matches;
  const width = Math.max(320,$("usage-chart").clientWidth), height = compact ? 115 : innerWidth <= 680 ? 180 : 200;
  const left = 38, right = width - 12, top = compact ? 8 : 13, bottom = height - (compact ? 55 : 67);
  const axisY = bottom + (compact ? 17 : 22), timelineY = bottom + (compact ? 30 : 36), iconY = bottom + (compact ? 41 : 50), iconSize = compact ? 13 : 16;
  usageChartGeometry = {width,left,right,span,start};
  const x = t => left + Math.max(0,Math.min(1,(t-start)/span)) * (right-left);
  const y = v => bottom - Math.max(0,Math.min(1,v/maximum)) * (bottom-top);
  let paths = [], current = [];
  for (const point of points) {
    if (point.gap || point[field] == null) { if(current.length) paths.push(current); current=[]; }
    if (point[field] != null) current.push(`${x(point.timestamp).toFixed(1)},${y(point[field]).toFixed(1)}`);
  }
  if(current.length) paths.push(current);
  let svg = "";
  for (let i=0;i<=4;i++) {
    const value = maximum*i/4, row = y(value);
    svg += `<line class="usage-grid" x1="${left}" x2="${right}" y1="${row}" y2="${row}"/><text class="usage-axis" x="${left-7}" y="${row+3.5}" text-anchor="end">${session.hasBattery?Math.round(value)+"%":usageNumber(value,maximum<10?1:0)+"W"}</text>`;
  }
  const ticks = span < 5 ? 2 : 4;
  for (let i=0;i<=ticks;i++) {
    const time = span*i/ticks, column = x(start+time);
    svg += `<line class="usage-grid" x1="${column}" x2="${column}" y1="${top}" y2="${bottom}"/><text class="usage-axis" x="${column}" y="${axisY}" text-anchor="${i===0?"start":i===ticks?"end":"middle"}">${usageDuration(time)}</text>`;
  }
  svg += paths.map(path=>`<polygon class="usage-area" points="${path[0].split(",")[0]},${bottom} ${path.join(" ")} ${path.at(-1).split(",")[0]},${bottom}"/><polyline class="usage-line" points="${path.join(" ")}"/>`).join("");
  const last = valid.at(-1);
  svg += `<circle class="usage-last-point" cx="${x(last.timestamp)}" cy="${y(last[field])}" r="3"/><line class="usage-cursor-line" id="usage-cursor-line" x1="${x(last.timestamp)}" x2="${x(last.timestamp)}" y1="${top}" y2="${bottom}"/>`;
  svg += `<rect class="usage-timeline-track" x="${left}" y="${timelineY}" width="${right-left}" height="6" rx="3"/>`;
  let iconEnd = -100;
  for (const segment of session.segments ?? []) {
    const left = x(segment.start), right = x(segment.end), app = session.applications[segment.appID];
    const title = `${app?.name ?? "应用"} ${usageDate(segment.start,false)} ${usageDuration(segment.end-segment.start)}`;
    svg += `<rect class="usage-timeline-segment" x="${left}" y="${timelineY}" width="${Math.max(.8,right-left)}" height="6" rx="2" fill="${usageColor(segment.appID)}"><title>${escapeHTML(title)}</title></rect>`;
    const icon = usageIcon(segment.appID);
    if (icon && left >= iconEnd && right-left >= 4) {
      svg += `<image href="${escapeHTML(icon)}" x="${Math.min(left,width-iconSize)}" y="${iconY}" width="${iconSize}" height="${iconSize}"><title>${escapeHTML(title)}</title></image>`;
      iconEnd = left + iconSize + 6;
    }
  }
  $("usage-chart").innerHTML = `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="${escapeHTML(session.hasBattery?"电池电量与前台应用时间线":"整机功耗与前台应用时间线")}">${svg}</svg>`;
  const cursor = $("usage-cursor"); cursor.hidden = points.length < 2; cursor.max = Math.max(0,points.length-1);
  const index = usageCursorTime == null ? points.length-1 : points.reduce((best,p,i)=>Math.abs(p.timestamp-usageCursorTime)<Math.abs(points[best].timestamp-usageCursorTime)?i:best,0);
  cursor.value = index;
  inspectUsagePoint(index);
}

function inspectUsagePoint(index) {
  const session = usageData?.selected, point = session?.points?.[index]; if(!point)return;
  const app = session.applications[point.appID];
  $("usage-inspector").textContent = `${usageDate(point.timestamp,false)} ${point.battery==null?"":usageNumber(point.battery,0,"%")+" "}${usageNumber(point.power,2,"W")} CPU ${usageNumber(point.temperature,1,"°C")}${app?" "+app.name:""}${point.gap?" 恢复采集":""}`;
  const line = $("usage-cursor-line");
  if(line && usageChartGeometry) {
    const {left,right,span,start}=usageChartGeometry, column = left+Math.max(0,Math.min(1,(point.timestamp-start)/span))*(right-left);
    line.setAttribute("x1",column); line.setAttribute("x2",column);
  }
}

function renderUsageApps() {
  const session = usageData?.selected; if(!session)return;
  const sameSession = usageProcessSession === session.id;
  const focusedApp = sameSession ? document.activeElement?.closest('[data-usage-app]')?.dataset.usageApp : null;
  if (sameSession) document.querySelectorAll('#usage-apps details[open]').forEach(details=>{
    const scroll = details.querySelector('.usage-process-scroll');
    if (scroll) usageProcessScroll.set(details.dataset.usageApp,scroll.scrollTop);
  });
  resetUsageProcesses(session.id);
  const query = $("usage-search").value.trim().toLowerCase(), sort = $("usage-sort").value;
  const apps = Object.values(session.applications).filter(app=>app.name.toLowerCase().includes(query));
  function sortValue(app) { return sort === "power" ? usageAverage(app.attributed?.combinedEnergy,app.attributed?.combinedDuration) : sort === "energy" ? app.attributed?.combinedEnergy : sort === "temperature" ? app.maximumTemperature : app.duration; }
  apps.sort((a,b)=>sort==="name" ? a.name.localeCompare(b.name,"zh-CN") : (sortValue(b)??-Infinity)-(sortValue(a)??-Infinity) || b.duration-a.duration);
  const model = session.applicationPowerVersion === 5 ? "CPU 能量 + GPU 归属" : session.applicationPowerVersion === 4 ? "旧算法 power（CPU）" : session.applicationPowerVersion === 3 ? "旧算法 评分分摊" : session.applicationPowerVersion === 2 ? "旧算法 CPU + GPU" : "旧记录";
  $("usage-app-count").textContent = `${apps.filter(app=>!["macstate:system","macstate:other-processes"].includes(app.id)).length} 个应用 ${model}`;
  $("usage-apps").innerHTML = apps.map(app=>{
    const icon = usageIcon(app.id), a = app.attributed, power = usageAverage(a?.combinedEnergy,a?.combinedDuration), temp = usageAverage(app.temperatureTotal,app.temperatureDuration);
    const coverage = a?.observedDuration > 0 ? Math.min(100,a.combinedDuration/a.observedDuration*100) : 0;
    const count = [4,5].includes(session.applicationPowerVersion) ? a?.measuredProcessCount : a?.scoredProcessCount;
    const processCoverage = count == null ? `${a?.processCount ?? 0} 个进程` : `${[4,5].includes(session.applicationPowerVersion)?"已读取":"评分覆盖"} ${count}/${a.processCount} 个进程${count<a.processCount?"（部分数据）":""}`;
    const note = ![2,3,4,5].includes(session.applicationPowerVersion) ? "旧记录：未采集应用功耗" : `已监测 ${usageDuration(a?.observedDuration)} 有效读数 ${coverage.toFixed(0)}% ${processCoverage}`;
    const energy = a?.combinedDuration > 0 ? usageNumber(a.combinedEnergy/3600,3,"Wh") : "—";
    const share = session.activeDuration > 0 ? app.duration/session.activeDuration*100 : 0;
    const backgroundGroup = ["macstate:system","macstate:other-processes"].includes(app.id);
    const scope = session.applicationPowerVersion===5 ? "GPU 部分按实际执行时间归属估算，不含共享外设等整机开销；仅统计完整有效区间。" : session.applicationPowerVersion===4 ? "未包含完整 GPU 能耗，仅统计已读取进程。" : "";
    const expanded = usageExpandedApps.has(app.id);
    return `<details class="usage-app" data-usage-app="${escapeHTML(app.id)}" ${expanded?'open':''}><summary class="usage-app-summary" aria-label="展开或收起 ${escapeHTML(app.name)} 的进程明细"><div class="usage-app-icon">${icon?`<img src="${escapeHTML(icon)}" alt="">`:'<span class="glyph i-monitor" aria-hidden="true"></span>'}</div><div><div class="usage-app-name" title="${escapeHTML(app.name)}">${escapeHTML(app.name)}</div><div class="usage-app-values"><span class="usage-total-power" title="${escapeHTML(model)}的平均功耗，含后台运行；按有效监测时长加权。${escapeHTML(scope)}${escapeHTML(note)}"><span class="glyph i-zap" aria-hidden="true"></span>≈ ${usageNumber(power,2,"W")}</span><span title="有效功耗读数期间累计耗能">${energy}</span></div><div class="usage-app-values usage-coverage"><span>${escapeHTML(note)}</span><span title="前台时整机 CPU 温度，温度不单独归属于应用">CPU ${usageNumber(temp,1,"°C")} MAX ${usageNumber(app.maximumTemperature,1,"°C")}</span></div></div><div class="usage-app-time">${backgroundGroup?"后台":usageDuration(app.duration)}<small>${backgroundGroup?(app.id==="macstate:system"?"旧未归属份额":"未归入应用的进程"):app.duration>0?share.toFixed(1)+"% 前台时间":"仅后台运行"}</small><span class="usage-process-prompt">进程明细 <span class="glyph i-chevron-down" aria-hidden="true"></span></span></div></summary><div class="usage-processes">${expanded?usageProcessMarkup(app,session):''}</div></details>`;
  }).join("") || `<div class="usage-empty">${query?"没有匹配的应用":"正在累积前台应用使用时间…"}</div>`;
  document.querySelectorAll('#usage-apps details[open]').forEach(details=>{
    const scroll=details.querySelector('.usage-process-scroll');
    if(scroll)scroll.scrollTop=usageProcessScroll.get(details.dataset.usageApp)??0;
  });
  if(focusedApp) [...document.querySelectorAll('#usage-apps details')].find(d=>d.dataset.usageApp===focusedApp)?.querySelector('summary')?.focus({preventScroll:true});
}

function installUsagePage() {
  installUsageProcessDisclosure();
  $("usage-history").onchange = () => { usageSelectedID=$("usage-history").value || null; usageCursorTime=null; usageNavigation("usage"); };
  $("usage-current").onclick = () => { usageSelectedID=null; usageCursorTime=null; usageNavigation("usage"); };
  $("usage-new").onclick = () => { usageSelectedID=null; usageCursorTime=null; post("newUsage"); };
  $("usage-export").onclick = () => post("exportUsage");
  $("usage-delete").onclick = () => {
    const session=usageData?.selected; if(!session)return;
    usageDeleteID=session.id; $("usage-delete-description").textContent=`${usageDate(session.startedAt)} ${usageModes[session.mode]} 已使用 ${usageDuration(session.activeDuration)}`;
    $("usage-delete-dialog").showModal();
  };
  $("usage-delete-cancel").onclick = () => $("usage-delete-dialog").close();
  $("usage-delete-confirm").onclick = () => { $("usage-delete-dialog").close(); if(usageDeleteID)post("deleteUsage",{sessionID:usageDeleteID}); usageDeleteID=null; usageCursorTime=null; };
  $("usage-search").oninput = renderUsageApps; $("usage-sort").onchange = renderUsageApps;
  $("usage-cursor").oninput = () => { const index=Number($("usage-cursor").value); usageCursorTime=usageData?.selected?.points[index]?.timestamp; inspectUsagePoint(index); };
  $("usage-chart").addEventListener("pointermove",event=>{
    const svg=$("usage-chart").querySelector("svg"), session=usageData?.selected; if(!svg || !session?.points.length || !usageChartGeometry)return;
    const {width,left,right}=usageChartGeometry, rect=svg.getBoundingClientRect(), column=(event.clientX-rect.left)/rect.width*width;
    const time=session.startedAt+Math.max(0,Math.min(1,(column-left)/(right-left)))*(session.updatedAt-session.startedAt);
    const index=session.points.reduce((best,p,i)=>Math.abs(p.timestamp-time)<Math.abs(session.points[best].timestamp-time)?i:best,0);
    usageCursorTime=session.points[index].timestamp; $("usage-cursor").value=index; inspectUsagePoint(index);
  });
  window.addEventListener("resize",()=>{if(view==="usage" && usageData?.selected)renderUsageChart(usageData.selected);});
  if(!native) $("usage-new").disabled=true;
}
