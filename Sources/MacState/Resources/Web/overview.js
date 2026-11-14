"use strict";
const expandedMetrics = new Set();
const overviewSections = [
  {id:"cpu",title:"处理器",icon:"cpu",tone:"cpu"},
  {id:"memory",title:"内存",icon:"memory-stick",tone:"memory"},
  {id:"gpu",title:"图形处理器",icon:"monitor",tone:"gpu"},
  {id:"power",title:"温度与能耗",icon:"zap",tone:"power"},
  {id:"network",title:"网络",icon:"network",tone:"memory"},
  {id:"storage",title:"存储",icon:"hard-drive",tone:"memory"},
  {id:"system",title:"系统",icon:"activity",tone:"cpu"}
];
function metricSection(id) {
  if(["upload","download"].includes(id))return "network";
  if(id.startsWith("disk"))return "storage";
  if(id.startsWith("cpu") || id.startsWith("load"))return "cpu";
  if(id.startsWith("memory") || ["swap","pageins","pageouts"].includes(id))return "memory";
  if(id.startsWith("gpu"))return "gpu";
  if(id.startsWith("battery") || id.toLowerCase().includes("power") || id==="fan")return "power";
  return "system";
}
function metricSymbol(metric) {
  const section=overviewSections.find(section=>section.id===metricSection(metric.id));
  if(metric.unit==="°C")return {icon:"thermometer",tone:"power"};
  if(metric.unit==="RPM")return {icon:"fan",tone:"power"};
  if(metric.unit==="W")return {icon:"zap",tone:"power"};
  if(metric.id.startsWith("battery"))return {icon:"battery",tone:"power"};
  return section;
}
function coloredIcon(icon,tone) {return `<span class="metric-icon tone-${tone}" aria-hidden="true"><span class="glyph i-${icon}"></span></span>`;}
function compactHero(metric) {
  const symbol=metricSymbol(metric);
  const companion=({cpu:["cpuTemp","温度"],memory:["memoryUsed","已用"],gpu:["gpuTemp","温度"],download:["upload","上传"]})[metric.id];
  const extra=companion?snapshot.metrics.find(item=>item.id===companion[0]):null;
  const subtitle=extra?`${companion[1]} ${inlineValue(extra.value,extra.unit)}`:metric.value==null?"暂不可用":metric.title;
  const label=({cpu:"CPU",memory:"内存",gpu:"GPU",download:"下载"})[metric.id] || metric.title;
  return `<button class="summary-tile tone-${symbol.tone}" data-focus="${escapeHTML(metric.id)}" aria-label="查看 ${escapeHTML(metric.title)} 详情">
    <span class="summary-label">${coloredIcon(symbol.icon,symbol.tone)}${escapeHTML(label)}<span class="glyph i-arrow-up-right"></span></span>
    <strong class="summary-value">${valueHTML(metric.value,metric.unit)}</strong><span class="summary-subtitle">${escapeHTML(subtitle)}</span><span class="summary-chart">${chart(metric.id,metric.unit)}</span></button>`;
}
function renderCompactHeroes(metrics) {
  const container=document.getElementById("hero-metrics");
  const existing=new Map([...container.children].map(tile=>[tile.dataset.focus,tile]));
  for(const [index,metric] of metrics.entries()) {
    const template=document.createElement("template");
    template.innerHTML=compactHero(metric);
    const next=template.content.firstElementChild;
    let tile=existing.get(metric.id);
    if(tile) {
      existing.delete(metric.id);
      // Preserve the glass boundary, native-glass annotation, focus and hover.
      // Only text/chart content changes at sampling time.
      if(tile.className!==next.className)tile.className=next.className;
      if(tile.getAttribute("aria-label")!==next.getAttribute("aria-label"))tile.setAttribute("aria-label",next.getAttribute("aria-label"));
      for(const selector of [".summary-label",".summary-value",".summary-subtitle",".summary-chart"]) {
        const current=tile.querySelector(selector),replacement=next.querySelector(selector);
        if(current.innerHTML!==replacement.innerHTML)current.innerHTML=replacement.innerHTML;
      }
    } else tile=next;
    if(container.children[index]!==tile)container.insertBefore(tile,container.children[index] ?? null);
  }
  for(const tile of existing.values())tile.remove();
}
function compactMetric(metric) {
  const symbol=metricSymbol(metric),open=expandedMetrics.has(metric.id)||focusedMetric===metric.id;
  const unavailable=metric.value==null;
  return `<details id="metric-${escapeHTML(metric.id)}" data-metric-detail="${escapeHTML(metric.id)}" class="metric-row tone-${symbol.tone}${focusedMetric===metric.id?" focused":""}${unavailable?" is-unavailable":""}" ${open?"open":""}>
    <summary>${coloredIcon(symbol.icon,symbol.tone)}<span class="row-name" title="${escapeHTML(metric.title)}">${escapeHTML(metric.title)}${metric.kind==="estimated"?'<span class="estimate-mark" title="模型估算">估</span>':""}</span><span class="row-chart" aria-hidden="true">${chart(metric.id,metric.unit)}</span><strong class="row-value">${valueHTML(metric.value,metric.unit)}</strong><span class="glyph i-chevron-down row-chevron" aria-hidden="true"></span></summary>
    <div class="row-detail"><p>${escapeHTML(metric.detail || (unavailable?"设备未公开此数据，或正在等待采样。":""))}</p><div><span>${escapeHTML(metric.source)}</span><span>峰值 <strong>${escapeHTML(inlineValue(peak(metric.id),metric.unit))}</strong></span></div>${chart(metric.id,metric.unit)}</div></details>`;
}
function compactSection(section,metrics) {
  return `<section data-metric-section="${section.id}" class="metric-section tone-${section.tone}" aria-label="${section.title}"><div class="metric-section-title">${coloredIcon(section.icon,section.tone)}<h3>${section.title}</h3><span>${metrics.length} 项</span></div>${metrics.map(compactMetric).join("")}</section>`;
}
function renderCompactMetrics(metrics) {
  if(!metrics.length)return '<div class="empty">这一分类没有可见指标，可到设置中开启。</div>';
  const lanes=[[],[]];
  for(const section of overviewSections) {
    const rows=metrics.filter(metric=>metricSection(metric.id)===section.id);if(!rows.length)continue;
    const lane=["cpu","memory","system"].includes(section.id)?0:1;
    lanes[lane].push(compactSection(section,rows));
  }
  return lanes.map((lane,index)=>lane.length?`<div class="overview-lane" data-overview-lane="${index}">${lane.join("")}</div>`:"").join("");
}
function syncOverviewChildren(parent,nextChildren,key,update,offset=0) {
  const existing=new Map([...parent.children].filter(node=>node.hasAttribute(key)).map(node=>[node.getAttribute(key),node]));
  for(const [index,next] of [...nextChildren].entries()) {
    const id=next.getAttribute(key),current=existing.get(id) || next;
    existing.delete(id);
    if(current!==next)update(current,next);
    if(parent.children[index+offset]!==current)parent.insertBefore(current,parent.children[index+offset] ?? null);
  }
  for(const node of existing.values())node.remove();
}
function updateOverviewHTML(current,next) {
  if(current.innerHTML!==next.innerHTML)current.innerHTML=next.innerHTML;
}
function updateCompactMetrics(metrics) {
  const container=document.getElementById("metric-grid"),template=document.createElement("template");
  template.innerHTML=renderCompactMetrics(metrics);
  if(!metrics.length) {
    if(!container.querySelector(":scope > .empty"))container.replaceChildren(template.content);
    return;
  }
  for(const child of [...container.children])if(!child.hasAttribute("data-overview-lane"))child.remove();
  syncOverviewChildren(container,template.content.children,"data-overview-lane",(lane,nextLane)=>{
    syncOverviewChildren(lane,nextLane.children,"data-metric-section",(section,nextSection)=>{
      updateOverviewHTML(section.firstElementChild,nextSection.firstElementChild);
      syncOverviewChildren(section,[...nextSection.children].slice(1),"data-metric-detail",(row,nextRow)=>{
        // Keep the hovered details AND summary attached. Replacing either one
        // resets WebKit's hover/focus paint even if the HTML looks identical.
        if(row.className!==nextRow.className)row.className=nextRow.className;
        if(row.open!==nextRow.open)row.open=nextRow.open;
        const summary=row.firstElementChild,nextSummary=nextRow.firstElementChild;
        for(const [index,part] of [...summary.children].entries()) {
          const nextPart=nextSummary.children[index];
          if(part.className!==nextPart.className)part.className=nextPart.className;
          if(part.title!==nextPart.title)part.title=nextPart.title;
          updateOverviewHTML(part,nextPart);
        }
        updateOverviewHTML(row.lastElementChild,nextRow.lastElementChild);
      },1);
    });
  });
}
document.addEventListener("toggle",event=>{
  const id=event.target.dataset?.metricDetail;if(!id || !event.target.isConnected)return;
  if(event.target.open)expandedMetrics.add(id);else expandedMetrics.delete(id);
  if(!event.target.open && focusedMetric===id)focusedMetric=null;
},true);
