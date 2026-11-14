"use strict";
// Disclosure state is scoped to the selected record, never shared with another
// session. Only expanded apps render their process rows.
let usageProcessSession = null;
const usageExpandedApps = new Set(), usageProcessPages = new Map(), usageProcessScroll = new Map();
const usageProcessPageSize = 100;

function usageProcessPowerNumber(watts) {
  if (watts == null || !Number.isFinite(watts)) return '—';
  if (watts > 0 && watts < 0.00001) return '<0.01mW';
  return watts > 0 && watts < 1 ? usageNumber(watts*1000,2,'mW') : usageNumber(watts,2,'W');
}

function resetUsageProcesses(sessionID) {
  if (sessionID === usageProcessSession) return;
  usageProcessSession = sessionID;
  usageExpandedApps.clear(); usageProcessPages.clear(); usageProcessScroll.clear();
}

function orderedUsageProcesses(records) {
  const byID = new Map(records.map(p=>[p.id,p])), children = new Map(), roots = [];
  for (const process of records) {
    if (process.parentID && process.parentID !== process.id && byID.has(process.parentID)) {
      if (!children.has(process.parentID)) children.set(process.parentID,[]);
      children.get(process.parentID).push(process);
    } else roots.push(process);
  }
  const compare = (a,b) => Number(b.isMain)-Number(a.isMain) || (usageAverage(b.energy,b.powerDuration)??-1)-(usageAverage(a.energy,a.powerDuration)??-1) || a.pid-b.pid || a.firstSeen-b.firstSeen;
  roots.sort(compare); for (const values of children.values()) values.sort(compare);
  const result = [], visited = new Set();
  // Iterative traversal also handles deep ancestry and malformed cycles.
  function visit(root) {
    const stack = [{process:root,depth:0}];
    while (stack.length) {
      const entry = stack.pop(); if (visited.has(entry.process.id)) continue;
      visited.add(entry.process.id); result.push(entry);
      const nested = children.get(entry.process.id) ?? [];
      for (let i=nested.length-1;i>=0;i--) stack.push({process:nested[i],depth:entry.depth+1});
    }
  }
  for (const root of roots) visit(root);
  for (const process of [...records].sort(compare)) visit(process);
  return result;
}

function usageProcessMarkup(app, session) {
  if (app.processes == null) return '<p class="usage-process-note">此记录未保存进程明细。启用新版后开始记录，旧数据无法补齐。</p>';
  const rows = orderedUsageProcesses(Object.values(app.processes));
  if (!rows.length) return '<p class="usage-process-note">尚未采集到归属此应用的进程，等待下一次采样。</p>';
  const lastPage = Math.max(0,Math.ceil(rows.length/usageProcessPageSize)-1);
  const page = Math.max(0,Math.min(lastPage,usageProcessPages.get(app.id)??0));
  usageProcessPages.set(app.id,page);
  const live = usageData?.sessions.some(s=>s.id===session.id && s.active);
  const current = rows.filter(({process:p})=>Math.abs(p.lastSeen-session.updatedAt)<0.01).length;
  const body = rows.slice(page*usageProcessPageSize,(page+1)*usageProcessPageSize).map(({process:p,depth})=>{
    const present = Math.abs(p.lastSeen-session.updatedAt)<0.01;
    const state = present ? live ? '本次采样存在' : '记录结束时存在' : '已退出或不再归属';
    const coverage = p.observedDuration>0 ? Math.min(100,p.powerDuration/p.observedDuration*100) : 0;
    const power = usageAverage(p.energy,p.powerDuration);
    const role = p.isMain ? '主进程' : '辅助进程';
    return `<tr data-process-id="${escapeHTML(p.id)}"><td><div class="usage-process-name depth-${Math.min(4,depth)}" title="${escapeHTML(p.path || p.name)}"><span class="usage-process-dot ${p.isMain?'is-main':''}" aria-hidden="true"></span><span>${escapeHTML(p.name)}</span></div><div class="usage-process-meta">PID ${p.pid} PPID ${p.parent} ${role} ${state}${present&&p.lastPower==null?' 本次功耗缺失':''}</div></td><td class="usage-process-power" title="${escapeHTML(p.status)}；平均值按本进程的有效采样时长计算。">≈ ${escapeHTML(usageProcessPowerNumber(power))}</td><td>${p.powerDuration>0?usageNumber(p.energy/3600,4,'Wh'):'—'}</td><td title="首次记录 ${escapeHTML(usageDate(p.firstSeen))}；最后出现 ${escapeHTML(usageDate(p.lastSeen))}"><strong>${coverage.toFixed(0)}%</strong><small>${usageDuration(p.powerDuration)} / ${usageDuration(p.observedDuration)}</small></td></tr>`;
  }).join('');
  return `<div class="usage-process-heading"><span>主进程及辅助进程 累计 ${rows.length} 个${live?` 本次 ${current} 个`:''}</span>${lastPage>0?`<div class="usage-process-pages"><button type="button" class="text-button" data-process-page="${page-1}" ${page===0?'disabled':''} aria-label="上一页进程">上一页</button><span>${page+1}/${lastPage+1}</span><button type="button" class="text-button" data-process-page="${page+1}" ${page===lastPage?'disabled':''} aria-label="下一页进程">下一页</button></div>`:''}</div><div class="usage-process-scroll"><table class="usage-process-table"><thead><tr><th>进程 / PID</th><th>平均估算</th><th>累计耗能</th><th>有效读数</th></tr></thead><tbody>${body}</tbody></table></div><p class="usage-process-note">各进程按自己的有效时段平均，平均功耗不能直接相加。缺失区间不补零；已退出进程保留。明细从启用新版后开始积累。</p>`;
}

function installUsageProcessDisclosure() {
  const container = $('usage-apps');
  container.addEventListener('toggle',event=>{
    const details = event.target;
    if (!details.matches('details[data-usage-app]')) return;
    const id = details.dataset.usageApp;
    if (details.open) {
      const alreadyExpanded = usageExpandedApps.has(id);
      usageExpandedApps.add(id);
      const app = usageData?.selected?.applications[id];
      if (app && !alreadyExpanded) details.querySelector('.usage-processes').innerHTML = usageProcessMarkup(app,usageData.selected);
    } else usageExpandedApps.delete(id);
  },true);
  container.addEventListener('click',event=>{
    const button=event.target.closest('[data-process-page]'); if(!button)return;
    const details=button.closest('[data-usage-app]'), id=details.dataset.usageApp;
    usageProcessPages.set(id,Number(button.dataset.processPage)); usageProcessScroll.set(id,0);
    details.querySelector('.usage-processes').innerHTML=usageProcessMarkup(usageData.selected.applications[id],usageData.selected);
  });
}
