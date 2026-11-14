let storageInsights=null;
const storageAppIconCache=new Map();
function storageAppIcon(app){
  const source=storageAppIconCache.get(app.path);
  return `<span class="storage-app-icon" data-app-icon="${escapeHTML(app.path)}">${source?`<img src="${source}" alt="" width="56" height="56">`:'<span aria-hidden="true">▦</span>'}</span>`;
}
function requestStorageAppIcons(apps){
  if(!storageInsights || !diskScan)return;
  const paths=apps.filter(a=>!storageAppIconCache.has(a.path)).map(a=>a.path);
  for(let i=0;i<paths.length;i+=100)post('diskAppIcons',{requestID:diskScan.requestID,queryID:storageInsights.queryID,paths:paths.slice(i,i+100)});
}
window.receiveDiskAppIcons=result=>{
  if(result.requestID!==diskScan?.requestID || result.queryID!==storageInsights?.queryID)return;
  for(const item of result.icons){
    if(!item.icon?.startsWith('data:image/png;base64,') || item.icon.length>131072)continue;
    storageAppIconCache.set(item.path,item.icon);
  }
  while(storageAppIconCache.size>384)storageAppIconCache.delete(storageAppIconCache.keys().next().value);
  document.querySelectorAll('[data-app-icon]').forEach(element=>{const source=storageAppIconCache.get(element.dataset.appIcon);if(source && !element.querySelector('img'))element.innerHTML=`<img src="${source}" alt="" width="56" height="56">`;});
};
const insightNames={cleanup:'清理',apps:'应用空间分析',orphans:'App 疑似残留',cache:'缓存分析'};
const insightSections={body:'App 本体',cache:'缓存',support:'Application Support',containers:'Containers',groups:'Group Containers',logs:'Logs',preferences:'配置',developer:'开发工具缓存'};
const insightRisks={safe:'安全清理 可再生成',review:'建议确认',high:'高风险'};
const insightColors={safe:'#32d74b',review:'#ffb340',high:'#ff7b72'};
const insightCaches={browser:'浏览器缓存',application:'应用缓存',system:'系统缓存',developer:'开发工具缓存'};
let insightOperation='';
function closeStorageInsights(){
  if(storageInsights)post('cancelDiskStorageQuery');
  storageInsights=null;$('disk-insights-view').hidden=true;$('disk-cleanup-preview').hidden=true;
}
function openStorageInsights(mode){
  if(!diskScan)return;
  closeDiskWorkbench();closeDiskMap();closeStorageFiles();closeStorageInsights();$('disk-directory-view').hidden=true;
  storageInsights={mode,queryID:'',report:null,selected:new Set(),limit:100,preview:false};
  $('disk-insights-view').hidden=false;$('disk-insights-search').value='';$('disk-insights-feedback').hidden=true;
  configureInsightMode(mode);requestStorageInsights();
}
function configureInsightMode(mode){
  storageInsights.mode=mode;storageInsights.limit=100;storageInsights.preview=false;$('disk-cleanup-preview').hidden=true;
  $('disk-insights-title').textContent=insightNames[mode];
  document.querySelectorAll('[data-insight-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.insightMode===mode)));
  const filters=mode==='cache'?insightCaches:mode==='apps'?{}:insightRisks;
  $('disk-insights-filter').innerHTML='<option value="">全部</option>'+Object.entries(filters).map(([key,label])=>`<option value="${key}">${label}</option>`).join('');
  $('disk-insights-filter').hidden=['apps','cache','orphans'].includes(mode);renderStorageInsights();
}
function requestStorageInsights(){
  if(!storageInsights || !diskScan)return;
  storageInsights.queryID=crypto.randomUUID();storageInsights.report=null;storageInsights.selected.clear();storageInsights.preview=false;
  $('disk-cleanup-preview').hidden=true;$('disk-insights-list').textContent='';$('disk-insights-totals').textContent='';
  $('disk-insights-status').textContent='正在读取索引与应用归属信息，不重新扫描磁盘…';$('disk-insights-refresh').disabled=true;
  updateInsightSelection();post('diskInsights',{requestID:diskScan.requestID,queryID:storageInsights.queryID});
}
function insightDistinct(items){
  const sorted=[...items].sort((a,b)=>a.entry.path.length-b.entry.path.length),result=[];
  for(const item of sorted)if(!result.some(root=>item.entry.path===root.entry.path || item.entry.path.startsWith(root.entry.path+'/')))result.push(item);
  return result;
}
function insightSum(items){return insightDistinct(items).reduce((sum,item)=>sum+item.entry.bytes,0);}
function insightTotal(label,bytes,detail,color='#5aa9ff'){
  return `<div class="metric-card insight-total" style="--risk-color:${color}"><span>${label}</span><strong>${diskBytes(bytes)}</strong><span class="muted">${detail}</span></div>`;
}
function insightFilterCard(key,label,bytes,detail,color='#5aa9ff'){
  return `<button type="button" class="metric-card insight-total insight-filter-card" style="--risk-color:${color}" data-insight-filter="${escapeHTML(key)}" aria-pressed="${$('disk-insights-filter').value===key}"><span>${escapeHTML(label)}</span><strong>${diskBytes(bytes)}</strong><span class="muted">${escapeHTML(detail)}</span></button>`;
}
function insightItemRow(item,index,part=false){
  const e=item.entry,selectable=item.removable && !part;
  return `<div class="insight-row" data-file-path="${escapeHTML(e.path)}" style="--risk-color:${insightColors[item.risk]}">${selectable?`<input type="checkbox" data-insight-select="${index}" aria-label="选择 ${escapeHTML(e.name)}" ${storageInsights.selected.has(e.path)?'checked':''}>`:''}<div class="insight-info"><strong>${escapeHTML(e.name)} ${part?'':`<span class="insight-risk">${insightRisks[item.risk]}</span>`}</strong><small class="muted">${insightSections[item.section] || item.section} ${escapeHTML(item.owner)}${item.shared?' 共享，不计入独占合计':''}${e.skipped || e.pending?' 统计不完整':''}</small><small class="insight-path muted" title="${escapeHTML(e.path)}">${escapeHTML(e.path)}</small><small class="muted">${escapeHTML(item.reason)}</small></div><strong class="insight-size">${diskBytes(e.bytes)}</strong><div class="insight-actions"><button class="text-button" data-insight-reveal="${escapeHTML(e.path)}">Finder</button>${!item.removable && !part?'<span class="muted">仅分析</span>':''}</div></div>`;
}
function renderStorageInsights(){
  if(!storageInsights)return;
  const {mode,report}=storageInsights;$('disk-insights-footer').hidden=mode==='apps';
  $('disk-insights-totals').classList.toggle('cache-card-row',mode==='cache');
  if(!report){updateInsightSelection();return;}
  const query=$('disk-insights-search').value.trim().toLocaleLowerCase(),filter=$('disk-insights-filter').value;
  let items=report.items;
  if(mode==='cleanup')items=items.filter(i=>i.removable);
  if(mode==='orphans')items=items.filter(i=>i.orphan);
  if(mode==='cache')items=items.filter(i=>i.section==='cache' || i.section==='developer');
  const totals=$('disk-insights-totals');
  if(mode==='apps'){
    const allParts=report.apps.flatMap(a=>a.parts);
    totals.innerHTML=insightTotal('已归属占用',insightSum(allParts.filter(i=>!i.shared)),`${report.apps.length} 个 App 包，非完整卸载大小`)+insightTotal('共享目录',insightSum(allParts.filter(i=>i.shared)),'单独统计，不重复计入应用合计')+insightTotal('App 本体',insightSum(allParts.filter(i=>i.section==='body')),'包含所选卷中的应用包');
    const apps=report.apps.filter(a=>!query || `${a.name} ${a.bundleID} ${a.path}`.toLocaleLowerCase().includes(query));
    $('disk-insights-list').innerHTML=apps.slice(0,storageInsights.limit).map(a=>`<details class="insight-app"><summary class="insight-row" data-file-path="${escapeHTML(a.path)}"><button type="button" class="text-button storage-app-expand" data-file-expand aria-label="展开应用明细" aria-expanded="false"><span aria-hidden="true">›</span></button>${storageAppIcon(a)}<div class="insight-info"><strong>${escapeHTML(a.name)}</strong><small class="muted">${escapeHTML(a.bundleID || '缺少 Bundle ID')} 展开查看目录明细</small><small class="insight-path muted" title="${escapeHTML(a.path)}">${escapeHTML(a.path)}</small></div><div class="insight-size"><strong>${diskBytes(a.bytes)}</strong>${a.sharedBytes?`<small class="muted"> + 共享 ${diskBytes(a.sharedBytes)}</small>`:''}</div><button class="text-button" data-insight-reveal="${escapeHTML(a.path)}">Finder</button></summary><div class="insight-parts">${['body','cache','support','containers','groups','logs','preferences'].map(section=>{
      const parts=a.parts.filter(p=>p.section===section);return parts.length?parts.map(p=>insightItemRow(p,-1,true)).join(''):`<p class="muted">${insightSections[section]}：未匹配到已索引目录</p>`;
    }).join('')}</div></details>`).join('') || '<div class="empty">没有匹配的应用</div>';
    appendInsightMore(apps.length);updateInsightSelection();requestStorageAppIcons(apps.slice(0,storageInsights.limit));return;
  }
  if(mode==='cache'){
    totals.innerHTML=Object.entries(insightCaches).map(([key,name])=>{const selected=items.filter(i=>i.category===key);return insightFilterCard(key,name,insightSum(selected),`${selected.length} 项${key==='system'?' 含受保护项目':''}`);}).join('');
  }else{
    totals.innerHTML=Object.entries(insightRisks).map(([key,name])=>{const selected=items.filter(i=>i.risk===key && (mode==='orphans' || i.removable));return mode==='orphans'?insightFilterCard(key,name,insightSum(selected),`${selected.length} 项 占用估算`,insightColors[key]):insightTotal(name,insightSum(selected),`${selected.length} 项可选 占用估算`,insightColors[key]);}).join('');
  }
  items=items.filter(i=>(!filter || (mode==='cache'?i.category:i.risk)===filter) && (!query || `${i.entry.path} ${i.owner}`.toLocaleLowerCase().includes(query)));
  storageInsights.visible=items;
  $('disk-insights-list').innerHTML=items.slice(0,storageInsights.limit).map((item,index)=>insightItemRow(item,index)).join('') || '<div class="empty">没有匹配项目。未识别的目录不会自动视为可清理或残留。</div>';
  appendInsightMore(items.length);updateInsightSelection();
}
function appendInsightMore(count){if(count>storageInsights.limit)$('disk-insights-list').insertAdjacentHTML('beforeend',`<button id="disk-insights-more" class="button">继续显示（剩余 ${count-storageInsights.limit} 项）</button>`);}
function updateInsightSelection(){
  if(!storageInsights)return;
  const selected=(storageInsights.report?.items || []).filter(i=>storageInsights.selected.has(i.entry.path));
  const all=(storageInsights.report?.items || []).filter(i=>i.removable);
  $('disk-cleanup-selected').textContent=`可清理占用约 ${diskBytes(insightSum(all))} 已选 ${selected.length} 项 预计可清理占用 ${diskBytes(insightSum(selected))}（非立即释放）`;
  $('disk-cleanup-open').disabled=!selected.length || !!insightOperation;$('disk-cleanup-clear').disabled=!selected.length || !!insightOperation;
}
function previewInsightCleanup(){
  if(!storageInsights?.report || insightOperation)return;
  const items=insightDistinct(storageInsights.report.items.filter(i=>storageInsights.selected.has(i.entry.path)));
  if(!items.length)return;
  storageInsights.preview=true;$('disk-cleanup-preview').hidden=false;
  $('disk-cleanup-summary').textContent=`${items.length} 项，索引占用约 ${diskBytes(insightSum(items))}。整个目录及其内容将移入废纸篓；APFS 共享块、硬链接与索引时效影响实际释放。请先退出相关应用。`;
  $('disk-cleanup-paths').innerHTML=items.map(i=>`<p><span style="color:${insightColors[i.risk]}">${insightRisks[i.risk]}</span> ${diskBytes(i.entry.bytes)}<br>${escapeHTML(i.entry.path)}</p>`).join('');
  const high=items.some(i=>i.risk==='high');$('disk-cleanup-risk-label').hidden=!high;$('disk-cleanup-risk').checked=false;
  $('disk-cleanup-confirm').disabled=high;$('disk-cleanup-preview').scrollTop=0;
}
function installStorageInsights(){
  document.querySelectorAll('[data-insight-open]').forEach(b=>b.onclick=()=>openStorageInsights(b.dataset.insightOpen));
  $('disk-insights-tabs').onclick=e=>{const b=e.target.closest('[data-insight-mode]');if(b && storageInsights)configureInsightMode(b.dataset.insightMode);};
  $('disk-insights-back').onclick=()=>{closeStorageInsights();$('disk-directory-view').hidden=false;};
  $('disk-insights-refresh').onclick=requestStorageInsights;
  $('disk-insights-search').oninput=()=>{if(storageInsights){storageInsights.limit=100;renderStorageInsights();}};
  $('disk-insights-filter').onchange=()=>{if(storageInsights){storageInsights.limit=100;renderStorageInsights();}};
  $('disk-insights-totals').onclick=e=>{
    const card=e.target.closest('[data-insight-filter]');if(!card || !storageInsights)return;
    const filter=$('disk-insights-filter');filter.value=filter.value===card.dataset.insightFilter?'':card.dataset.insightFilter;
    storageInsights.limit=100;renderStorageInsights();$('disk-insights-list').scrollTop=0;
  };
  $('disk-insights-list').onclick=e=>{
    const reveal=e.target.closest('[data-insight-reveal]');
    if(reveal && diskScan){e.preventDefault();post('revealDiskEntry',{requestID:diskScan.requestID,path:reveal.dataset.insightReveal});return;}
    if(e.target.closest('#disk-insights-more') && storageInsights){storageInsights.limit+=100;renderStorageInsights();}
  };
  $('disk-insights-list').onchange=e=>{
    const box=e.target.closest('[data-insight-select]');if(!box || !storageInsights)return;
    const item=storageInsights.visible?.[Number(box.dataset.insightSelect)];if(!item)return;
    if(box.checked && storageInsights.selected.size>=100){box.checked=false;$('disk-insights-feedback').hidden=false;$('disk-insights-feedback').textContent='每批最多选择 100 项，请分批预览处理。';return;}
    if(box.checked)storageInsights.selected.add(item.entry.path);else storageInsights.selected.delete(item.entry.path);
    storageInsights.preview=false;$('disk-cleanup-preview').hidden=true;updateInsightSelection();
  };
  $('disk-cleanup-clear').onclick=()=>{if(storageInsights){storageInsights.selected.clear();storageInsights.preview=false;$('disk-cleanup-preview').hidden=true;renderStorageInsights();}};
  $('disk-cleanup-open').onclick=previewInsightCleanup;
  $('disk-cleanup-cancel').onclick=()=>{if(storageInsights)storageInsights.preview=false;$('disk-cleanup-preview').hidden=true;};
  $('disk-cleanup-risk').onchange=()=>$('disk-cleanup-confirm').disabled=!$('disk-cleanup-risk').checked;
  $('disk-cleanup-confirm').onclick=()=>{
    if(!diskScan || !storageInsights?.report || !storageInsights.preview || insightOperation)return;
    const items=insightDistinct(storageInsights.report.items.filter(i=>storageInsights.selected.has(i.entry.path)));
    if(items.some(i=>i.risk==='high') && !$('disk-cleanup-risk').checked)return;
    insightOperation=crypto.randomUUID();$('disk-cleanup-confirm').disabled=true;updateInsightSelection();
    post('trashDiskCleanup',{requestID:diskScan.requestID,queryID:storageInsights.queryID,operationID:insightOperation,paths:items.map(i=>i.entry.path)});
  };
  window.receiveDiskInsights=report=>{
    if(!diskScan || !storageInsights || report.requestID!==diskScan.requestID || report.queryID!==storageInsights.queryID)return;
    $('disk-insights-refresh').disabled=false;storageInsights.report=report;
    $('disk-insights-status').textContent=report.error || `${report.scope} ${new Date(report.updated*1000).toLocaleTimeString()} 的快照；手动刷新更新分析`;
    if(report.error){$('disk-insights-list').textContent='';return;}renderStorageInsights();
  };
  const previous=window.receiveDiskFileAction;
  window.receiveDiskFileAction=result=>{
    if(!insightOperation || result.operationID!==insightOperation){previous?.(result);return;}
    insightOperation='';
    if(!diskScan || !storageInsights || result.requestID!==diskScan.requestID)return;
    $('disk-insights-feedback').hidden=false;$('disk-insights-feedback').textContent=result.message;
    $('disk-cleanup-preview').hidden=true;storageInsights.preview=false;requestStorageInsights();
  };
}
