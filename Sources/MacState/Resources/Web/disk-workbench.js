let diskWorkbench=null,workbenchSearchTimer=null,workbenchProgressTimer=null,storageAnalysisSuspended=false;
const workbenchOperations=new Map();
let developerFolderNames=[];
function developerCategoryOptions(){
  const select=$('wb-category'),selected=select.value;
  select.innerHTML='<option value="">全部</option>'+developerFolderNames.map(name=>`<option value="${escapeHTML(name)}">${escapeHTML(name)}</option>`).join('');
  select.value=developerFolderNames.includes(selected)?selected:'';
}
function isWorkbenchCardMode(){return ['developer','browser','chat','system'].includes(diskWorkbench?.mode);}
const workbenchCardBack={developer:'返回开发者',browser:'返回浏览器',chat:'返回聊天软件',system:'返回系统数据'};
function updateWorkbenchCardLayout(){
  const cards=isWorkbenchCardMode(),home=cards && !diskWorkbench.cardList;
  $('disk-workbench-view').classList.toggle('workbench-card-home',home);
  $('wb-stats').hidden=cards && !home;
  $('wb-list').hidden=home;
  $('disk-workbench-view').querySelector('.wb-filters').hidden=home;
  const growth=diskWorkbench?.mode==='growth',report=diskWorkbench?.report;
  $('disk-workbench-view').querySelector('.wb-pagination').hidden=home || (growth && !report?.offset && !report?.hasMore);
  $('wb-note').hidden=home;
  $('wb-status').hidden=home && !diskWorkbench.loading && !diskWorkbench.report?.error;
  if(cards){$('wb-title').textContent=home?workbenchTitles[diskWorkbench.mode]:($('wb-category').value || '全部'+workbenchTitles[diskWorkbench.mode]);$('wb-back').textContent=home?'返回文件':workbenchCardBack[diskWorkbench.mode];}
}
function openWorkbenchCardList(name){
  if(!isWorkbenchCardMode())return;
  diskWorkbench.cardScroll=$('wb-stats').scrollTop;
  diskWorkbench.cardList=true;$('wb-category').value=name;$('wb-search').value='';
  updateWorkbenchCardLayout();requestDiskWorkbench();
}
function backToWorkbenchCards(){
  clearTimeout(workbenchSearchTimer);workbenchSearchTimer=null;
  if(diskWorkbench.loading){post('cancelDiskWorkbench');diskWorkbench.queryID='';diskWorkbench.loading=false;stopWorkbenchProgress();$('wb-refresh').disabled=false;$('wb-stop').disabled=true;}
  diskWorkbench.cardList=false;$('wb-category').value='';$('wb-search').value='';
  updateWorkbenchCardLayout();renderWorkbenchCards();$('wb-stats').scrollTop=diskWorkbench.cardScroll || 0;
}
function renderWorkbenchCards(){
  if(!isWorkbenchCardMode())return;
  const container=$('wb-stats'),scroll=container.scrollTop,selected=$('wb-category').value;
  const developer=diskWorkbench.mode==='developer',stats=diskWorkbench.stats || [],total=stats[0]?.key==='total'?stats[0]:null;
  let cards;
  if(developer){cards=[{key:'',title:'合计占用',bytes:total?.bytes,count:total?.count},...developerFolderNames.map(name=>{const stat=stats.slice(1).find(s=>s.key===name);return {key:name,title:name,bytes:stat?.bytes,count:stat?.count};})];}
  else if(stats.length){cards=stats.map(s=>({...s,key:s.key==='total'?'':s.key}));}
  else{cards=(wbFilters[diskWorkbench.mode] || []).map(name=>({key:name,title:name}));}
  cards.sort((a,b)=>(b.bytes ?? -1)-(a.bytes ?? -1) || a.title.localeCompare(b.title));
  container.innerHTML=cards.map(s=>`<button type="button" class="metric-card insight-total workbench-category-card" data-workbench-category="${escapeHTML(s.key)}" aria-pressed="${selected===s.key}" title="点击查看${escapeHTML(s.title)}，按占用从大到小排列"><span>${escapeHTML(s.title)}</span><strong>${s.bytes==null?'—':diskBytes(s.bytes)}</strong><span class="muted">${s.count==null?'等待统计':`${s.count.toLocaleString()} ${developer?'个目录':'项'}`}${s.key?'':' 不重复计算'}</span></button>`).join('')+(developer?'<button type="button" class="metric-card insight-total workbench-category-card developer-add" data-developer-add aria-label="添加文件夹名称"><strong>＋</strong><span>添加文件夹名称</span></button>':'');
  container.scrollTop=scroll;
}
window.receiveDeveloperFolders=names=>{developerFolderNames=Array.isArray(names)?names:[];if(diskWorkbench?.mode==='developer'){developerCategoryOptions();renderWorkbenchCards();}};
window.receiveDeveloperFolderAdded=result=>{
  $('developer-folder-save').disabled=false;
  if(result.error){$('developer-folder-error').textContent=result.error;return;}
  $('developer-folder-dialog').close();
  if(diskWorkbench?.mode==='developer')openWorkbenchCardList(result.name);
};
const storageSections={files:[['directory','目录'],['map','空间地图'],['types','文件类型'],['large','大文件'],['duplicates','重复文件'],['media','图片与视频']],apps:[['apps','应用空间'],['cache','缓存'],['orphans','疑似残留'],['developer','开发者'],['browser','浏览器'],['chat','聊天软件'],['system','系统数据'],['backups','设备备份'],['cloud','iCloud'],['snapshots','Time Machine'],['permissions','权限']],cleanup:[['cleanup','清理预览']],history:[['history','扫描历史'],['growth','最近空间增长']]};
const storageGroupNames={files:'文件',apps:'应用与专项',cleanup:'清理',history:'历史'};
const workbenchTitles={developer:'开发者空间',duplicates:'重复文件',media:'图片与视频',browser:'浏览器空间',chat:'聊天软件空间',system:'macOS 系统数据',backups:'iPhone / iPad 备份',cloud:'iCloud 空间识别',snapshots:'Time Machine 本地快照',history:'存储使用记录',growth:'最近空间增长',permissions:'受限与无权限目录'};
const wbFilters={duplicates:[['image','图片'],['video','视频'],['document','文档'],['archive','压缩包'],['other','普通其他文件']],media:[['large-video','大型视频 ≥1 GiB'],['4k','4K 视频（按需识别）'],['raw','RAW 图片'],['screenshot','截图（名称识别）'],['recording','屏幕录制（名称识别）'],['gif','GIF'],['video','全部视频'],['image','其他图片']],browser:['Safari','Chrome','Edge','Firefox','Arc'],chat:['微信','Telegram','Discord','Slack','LINE','QQ','企业微信'],system:['Caches','Logs','Application Support','Containers','Swap','Developer Data','其他系统数据'],cloud:[['downloaded','已下载 iCloud'],['placeholder','云端占位文件']],growth:[['directory','文件夹增长'],['application','应用增长']]};
function renderStorageWorkspace(section='directory'){
  $('storage-section-tabs').querySelectorAll('[data-storage-section]').forEach(button=>{
    if(button.dataset.storageSection===section)button.setAttribute('aria-current','page');
    else button.removeAttribute('aria-current');
  });
}
function resetStorageWorkspace(){$('storage-export-panel').hidden=true;$('storage-navigation').scrollTop=0;renderStorageWorkspace();}
function stopWorkbenchProgress(){clearInterval(workbenchProgressTimer);workbenchProgressTimer=null;$('wb-progress-wrap').hidden=true;}
function updateWorkbenchProgress(message,completed=null,total=null){
  if(!diskWorkbench?.loading)return;
  if(message)diskWorkbench.progressMessage=message;
  const bar=$('wb-progress');$('wb-progress-wrap').hidden=false;
  if(Number.isFinite(completed) && Number.isFinite(total) && total>0){bar.max=total;bar.value=completed;diskWorkbench.progressCount=`${completed}/${total} 个文件`;}
  else{bar.removeAttribute('value');diskWorkbench.progressCount='';}
  const seconds=Math.floor((performance.now()-diskWorkbench.startedAt)/1000);
  $('wb-progress-detail').textContent=[diskWorkbench.progressMessage,diskWorkbench.progressCount,`已用 ${seconds} 秒`].filter(Boolean).join(' ');
}
function suspendStorageAnalysis(){
  if(!diskScan)return;storageAnalysisSuspended=true;post('pauseStorageAnalysis');stopWorkbenchProgress();
  if(diskWorkbench){diskWorkbench.queryID='';diskWorkbench.loading=false;}
  if(storageFiles){storageFiles.queryID='';storageFiles.loading=false;}
  if(storageInsights)storageInsights.queryID='';
  if(diskMap){diskMap.mapID='';diskMap.loading=false;}
}
function resumeStorageAnalysis(){
  if(!storageAnalysisSuspended || !diskScan)return;storageAnalysisSuspended=false;
  if(diskWorkbench)requestDiskWorkbench(diskWorkbench.report?.offset || 0);
  else if(diskMap)requestDiskMap(diskMap.path);
  else if(storageFiles?.mode==='large')requestLargeFiles(storageFiles.page?.offset || 0);
  else if(storageFiles)requestStorageTypes();
  else if(storageInsights)requestStorageInsights();
  else diskBrowse(diskDirectory?.path || diskScan.rootPath || diskScan.volumePath);
}
function closeDiskWorkbench(){
  stopWorkbenchProgress();
  clearTimeout(workbenchSearchTimer);workbenchSearchTimer=null;
  if(diskWorkbench)post('cancelDiskWorkbench');diskWorkbench=null;$('disk-workbench-view').hidden=true;
}
function storageSection(section){
  if(!diskScan)return;
  renderStorageWorkspace(section);
  if(section==='directory'){
    closeDiskWorkbench();closeDiskMap();closeStorageFiles();closeStorageInsights();$('disk-directory-view').hidden=false;
  }else if(section==='map')$('disk-map-open').click();
  else if(['types','large'].includes(section))openStorageFiles(section);
  else if(['apps','cache','orphans','cleanup'].includes(section)){
    if(storageInsights && !diskWorkbench)configureInsightMode(section);else openStorageInsights(section);
  }else openDiskWorkbench(section);
}
function openDiskWorkbench(mode,period=null){
  if(!diskScan)return;
  closeDiskWorkbench();closeDiskMap();closeStorageFiles();closeStorageInsights();$('disk-directory-view').hidden=true;$('disk-workbench-view').hidden=false;
  diskWorkbench={mode,queryID:'',report:null,stats:[],loading:false,detail:false,cardList:false,cardScroll:0};
  const growth=mode==='growth';
  $('disk-workbench-view').classList.toggle('workbench-growth',growth);
  $('wb-title').textContent=workbenchTitles[mode];$('wb-search').value='';$('wb-since').value='';$('wb-until').value='';$('wb-feedback').hidden=true;
  $('wb-growth-hours').value='24';$('wb-growth-direction').value='increase';
  $('wb-growth-hours').hidden=!growth;$('wb-growth-direction').hidden=!growth;
  $('wb-refresh').textContent=growth?'记录当前占用':'刷新';
  $('wb-category').innerHTML='<option value="">全部</option>'+(wbFilters[mode] || []).map(pair=>{const [key,name]=Array.isArray(pair)?pair:[pair,pair];return `<option value="${key}">${name}</option>`;}).join('');
  if(growth){
    $('wb-category').innerHTML='<option value="directory">文件夹</option><option value="application">应用</option><option value="">全部类别</option>';
  }
  if(mode==='developer')developerCategoryOptions();
  $('wb-category').hidden=isWorkbenchCardMode() || !(wbFilters[mode]?.length);$('wb-since-label').hidden=mode!=='history';$('wb-until-label').hidden=mode!=='history';
  $('wb-enrich').hidden=!['duplicates','media'].includes(mode);$('wb-enrich').textContent=mode==='duplicates'?'校验本页内容':'识别本页属性';
  $('wb-back').textContent='返回文件';$('wb-list').textContent='';$('wb-stats').textContent='';$('wb-chart').hidden=true;
  $('wb-stats').classList.toggle('workbench-cards',isWorkbenchCardMode());if(isWorkbenchCardMode())renderWorkbenchCards();
  if(period){$('wb-since').value=wbLocalDate(period.since);$('wb-until').value=wbLocalDate(period.until);}
  updateWorkbenchCardLayout();requestDiskWorkbench();
}
function wbLocalDate(time){const d=new Date(time*1000);return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}
function wbTimestamp(value){return value?new Date(value).getTime()/1000:0;}
function requestDiskWorkbench(offset=0,enrich=false,detailTimestamp=0,captureGrowthSample=false){
  if(!diskScan || !diskWorkbench)return;
  const since=detailTimestamp || wbTimestamp($('wb-since').value),until=detailTimestamp || wbTimestamp($('wb-until').value);
  if(!Number.isFinite(since) || !Number.isFinite(until) || (until && since>until)){$('wb-status').textContent='请检查开始和结束时间。';return;}
  diskWorkbench.queryID=crypto.randomUUID();diskWorkbench.loading=true;diskWorkbench.detail=!!detailTimestamp;updateWorkbenchCardLayout();
  stopWorkbenchProgress();diskWorkbench.startedAt=performance.now();diskWorkbench.progressMessage='等待分析任务开始…';diskWorkbench.progressCount='';updateWorkbenchProgress();workbenchProgressTimer=setInterval(()=>{if(diskWorkbench?.loading){const seconds=Math.floor((performance.now()-diskWorkbench.startedAt)/1000);$('wb-progress-detail').textContent=[diskWorkbench.progressMessage,diskWorkbench.progressCount,`已用 ${seconds} 秒`].filter(Boolean).join(' ');}},1000);
  if(offset===0 && !isWorkbenchCardMode())diskWorkbench.stats=[];
  $('wb-status').textContent=enrich?'正在按需读取本页文件，请保持应用运行；可以停止。':'正在读取索引与已保存记录…';
  $('wb-list').classList.add('wb-muted-row');$('wb-list').setAttribute('aria-busy','true');$('wb-refresh').disabled=true;$('wb-enrich').disabled=true;$('wb-prev').disabled=true;$('wb-next').disabled=true;$('wb-stop').disabled=false;
  post('diskWorkbench',{requestID:diskScan.requestID,queryID:diskWorkbench.queryID,mode:diskWorkbench.mode,
    category:$('wb-category').value,text:$('wb-search').value.trim(),offset,enrich,since,until,
    growthHours:Number($('wb-growth-hours').value),growthDecreasing:$('wb-growth-direction').value==='decrease',captureGrowthSample});
}
function wbGrowthDelta(value){
  return value==null?'—':`${value===0?'':value>0?'+':'−'}${formatVolumeCapacity(Math.abs(value))}`;
}
function renderGrowthSummary(summary){
  if(!summary){
    $('wb-status').textContent='尚无采样。点击「记录当前占用」建立第一份记录。';
    $('wb-stats').textContent='';
    return;
  }
  const time=value=>new Date(value*1000).toLocaleString();
  $('wb-status').textContent=summary.baseline==null
    ? `已记录 ${time(summary.latest)} 的占用。再记录一次即可对比。`
    : `采样区间 ${time(summary.baseline)} → ${time(summary.latest)}`;
  $('wb-stats').innerHTML=summary.baseline==null?'':[
    ['卷已用净变化',summary.volumeDelta],['索引占用净变化',summary.indexedDelta]
  ].map(([title,value])=>`<div class="metric-card insight-total"><span>${title}</span><strong class="wb-delta${value<0?' wb-delta-negative':''}">${wbGrowthDelta(value)}</strong></div>`).join('');
  $('wb-note').textContent=summary.unmatchedCount
    ? `${summary.unmatchedCount.toLocaleString()} 项只出现在一次采样中，无法计算净变化。`
    : '';
}

function renderGrowthTrend(points){
  const chart=$('wb-chart');
  chart.hidden=points.length<2;
  if(chart.hidden)return;

  const series=[
    {key:'volumeDelta',label:'卷已用',className:'wb-trend-volume'},
    {key:'indexedDelta',label:'索引占用',className:'wb-trend-indexed'}
  ].filter(series=>points.some(point=>Number.isFinite(point[series.key])));
  let min=0,max=0;
  for(const point of points){
    for(const item of series){
      const value=point[item.key];
      if(Number.isFinite(value)){min=Math.min(min,value);max=Math.max(max,value);}
    }
  }
  const start=points[0].timestamp,duration=points.at(-1).timestamp-start || 1;
  const left=8,right=1192,top=12,bottom=218;
  const x=point=>left+(point.timestamp-start)/duration*(right-left);
  const y=value=>min===max?(top+bottom)/2:bottom-(value-min)/(max-min)*(bottom-top);

  chart.innerHTML=`<div class="wb-trend-heading"><strong>占用变化趋势</strong><div class="wb-trend-legend">${series.map(item=>
    `<span class="${item.className}"><i aria-hidden="true"></i>${item.label} <b data-trend-value="${item.key}"></b></span>`).join('')}</div></div>
    <div class="wb-trend-plot">
      <div class="wb-trend-scale muted" aria-hidden="true"><span>${wbGrowthDelta(max)}</span><span>${wbGrowthDelta(min)}</span></div>
      <canvas width="1200" height="230" aria-hidden="true"></canvas>
    </div>
    <div class="wb-trend-footer">
      <output id="wb-trend-time" for="wb-trend-sample" aria-live="off"></output>
      <input id="wb-trend-sample" type="range" min="0" max="${points.length-1}" value="${points.length-1}" aria-label="查看采样点">
    </div>`;
  const canvas=chart.querySelector('canvas'),ctx=canvas.getContext('2d'),slider=$('wb-trend-sample');
  for(const item of series)item.valueNode=chart.querySelector(`[data-trend-value="${item.key}"]`);
  const show=index=>{
    const point=points[index], time=new Date(point.timestamp*1000).toLocaleString();
    const styles=getComputedStyle(chart);
    const color=name=>styles.getPropertyValue(name).trim();
    $('wb-trend-time').textContent=time;
    for(const item of series){
      item.valueNode.textContent=wbGrowthDelta(point[item.key]);
    }
    slider.setAttribute('aria-valuetext',[time,...series.map(item=>`${item.label} ${wbGrowthDelta(point[item.key])}`)].join('，'));
    ctx.clearRect(0,0,canvas.width,canvas.height);
    ctx.lineWidth=2;
    ctx.strokeStyle=color('--border');
    for(const line of new Set([top,bottom,y(0)])){
      ctx.beginPath();ctx.moveTo(left,line);ctx.lineTo(right,line);ctx.stroke();
    }
    ctx.strokeStyle=color('--muted');
    ctx.beginPath();ctx.moveTo(x(point),top);ctx.lineTo(x(point),bottom);ctx.stroke();
    for(const item of series){
      ctx.strokeStyle=ctx.fillStyle=color(`--${item.className}`);
      ctx.lineWidth=4;
      ctx.setLineDash(item.key==='indexedDelta'?[10,6]:[]);
      ctx.beginPath();
      let connected=false;
      for(const sample of points){
        const value=sample[item.key];
        if(!Number.isFinite(value)){connected=false;continue;}
        if(connected)ctx.lineTo(x(sample),y(value));else ctx.moveTo(x(sample),y(value));
        connected=true;
      }
      ctx.stroke();
      ctx.setLineDash([]);
      for(const sample of new Set([points[0],point,points.at(-1)])){
        const value=sample[item.key];
        if(!Number.isFinite(value))continue;
        ctx.beginPath();ctx.arc(x(sample),y(value),6,0,2*Math.PI);ctx.fill();
      }
    }
  };
  slider.oninput=()=>show(Number(slider.value));
  canvas.onclick=event=>{
    const bounds=canvas.getBoundingClientRect();
    const position=(event.clientX-bounds.left)/bounds.width*canvas.width;
    const nearest=points.reduce((best,point,index)=>Math.abs(x(point)-position)<Math.abs(x(points[best])-position)?index:best,0);
    slider.value=nearest;
    show(nearest);
  };
  show(points.length-1);
}

function renderWorkbench(report){
  const mode=diskWorkbench.mode,growth=mode==='growth';
  $('wb-status').textContent=report.error || `${report.rows.length} 项 ${new Date(report.updated*1000).toLocaleTimeString()} 的分析${mode==='duplicates'?' 分页为候选批次，可补充其他已校验页的匹配项':''}`;
  $('wb-note').textContent=report.note;
  if(report.stats.length || report.offset===0)diskWorkbench.stats=report.stats;
  if(growth && !report.error)renderGrowthSummary(report.growth);
  else if(isWorkbenchCardMode())renderWorkbenchCards();
  else $('wb-stats').innerHTML=diskWorkbench.stats.map(s=>mode==='snapshots'?`<div class="metric-card insight-total"><span>${escapeHTML(s.title)}</span><strong>${s.count}</strong><span class="muted">占用/可释放空间：未知</span></div>`:insightTotal(escapeHTML(s.title),s.bytes,`${s.count.toLocaleString()} 项`)).join('');
  const hashGroups=new Map();for(const row of report.rows)if(row.hash){if(!hashGroups.has(row.hash))hashGroups.set(row.hash,[]);hashGroups.get(row.hash).push(row);}
  const growthScale=report.growth?.largestChange || Math.max(1,...report.rows.map(row=>Math.abs(row.delta || 0)));
  $('wb-list').innerHTML=report.rows.map((row,index)=>{
    const peers=row.hash?hashGroups.get(row.hash):[],verified=peers?.length>1 && row.detail.includes('已验证重复'),keeper=verified && peers[0].path===row.path;
    const date=row.timestamp?` ${new Date(row.timestamp*1000).toLocaleString()}`:'';
    const delta=row.delta==null?'':`<span class="wb-delta">${row.delta>=0?'+':'−'}${diskBytes(Math.abs(row.delta))}</span>`;
    const actions=row.path?`<button class="text-button" data-wb-action="reveal">Finder</button><button class="text-button" data-wb-action="copy">复制路径</button>${row.entry?.directory && row.entry?.browsable || growth && row.category==='directory'?'<button class="text-button" data-wb-action="browse">浏览目录</button>':''}${mode==='duplicates' && verified && !keeper?'<button class="text-button" data-wb-action="trash">移到废纸篓</button>':''}`:'';
    if(growth){
      const change=wbGrowthDelta(row.delta);
      const title=$('wb-category').value?row.title:`${row.title} · ${row.category==='directory'?'文件夹':'应用'}`;
      return `<div class="insight-row wb-growth-row" data-wb-row="${index}">
        <div class="insight-info"><strong>${escapeHTML(title)}</strong><small class="insight-path muted" title="${escapeHTML(row.path)}">${escapeHTML(row.path)}</small>
          <progress class="wb-growth-bar${row.delta<0?' wb-growth-bar-negative':''}" max="${growthScale}" value="${Math.abs(row.delta)}" aria-hidden="true"></progress>
        </div>
        <div class="insight-size"><strong class="wb-delta${row.delta<0?' wb-delta-negative':''}">${change}</strong><small class="muted">${formatVolumeCapacity(row.previousBytes)} → ${formatVolumeCapacity(row.bytes)}</small></div>
        <div class="wb-actions">${actions}</div>
      </div>`;
    }
    return `<div class="insight-row" data-wb-row="${index}" ${row.entry?`data-file-path="${escapeHTML(row.path)}"`:''}><div class="insight-info"><strong>${escapeHTML(row.title)} ${keeper?'<span class="wb-keeper">保留此份</span>':''}</strong><small class="${verified?'wb-verified':'muted'}">${escapeHTML(row.category)}${date} ${escapeHTML(row.detail)}</small>${row.path?`<small class="insight-path muted" title="${escapeHTML(row.path)}">${escapeHTML(row.path)}</small>`:''}${verified?`<small class="wb-verified">重复组 ${escapeHTML(row.hash.slice(0,12))} ${peers.length} 个已校验路径</small>`:''}</div><div class="insight-size"><strong>${mode==='snapshots'?'大小未知':diskBytes(row.bytes)}</strong>${delta}</div><div class="wb-actions">${actions}${mode==='history' && !diskWorkbench.detail?'<button class="text-button" data-wb-action="history">查看记录</button>':''}</div></div>`;
  }).join('') || `<div class="empty">${report.error?'分析未完成':growth
    ? (report.growth?.baseline!=null?'没有符合筛选条件的已知变化':'等待两次采样')
    : mode==='media' && $('wb-category').value==='4k'?'本批视频未找到已确认 4K 文件，可继续下一批':'暂无匹配结果'}</div>`;
  if(growth)$('wb-list').scrollTop=0;
  $('wb-page').textContent=growth && report.rows.length
    ? `${report.offset+1}–${report.offset+report.rows.length} / ${report.growth.resultCount}`
    : `批次 ${Math.floor(report.offset/100)+1}${report.hasMore?' 还有更多':''}`;
  $('wb-prev').disabled=report.offset===0;$('wb-next').disabled=!report.hasMore;$('wb-enrich').disabled=!report.rows.length;
  $('wb-back').textContent=diskWorkbench.detail?'返回历史时间线':'返回文件';
  if(growth)renderGrowthTrend(report.error?[]:report.growth?.trend || []);else renderWorkbenchChart(report.points);
  updateWorkbenchCardLayout();
}
function renderWorkbenchChart(points){
  $('wb-chart').hidden=!points.length;if(!points.length)return;
  const width=900,height=105,left=10,right=890,top=8,bottom=78,min=Math.min(...points.map(p=>p.bytes)),max=Math.max(min+1,...points.map(p=>p.bytes));
  const start=points[0].timestamp,end=Math.max(start+1,points.at(-1).timestamp),x=t=>left+(t-start)/(end-start)*(right-left),y=b=>bottom-(b-min)/(max-min)*(bottom-top);
  const line=points.map(p=>`${x(p.timestamp).toFixed(2)},${y(p.bytes).toFixed(2)}`).join(' ');
  $('wb-chart').innerHTML=`<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="真实磁盘占用历史"><line x1="${left}" x2="${right}" y1="${bottom}" y2="${bottom}" stroke="currentColor" opacity=".2"/><polyline points="${line}" fill="none" stroke="#5aa9ff" stroke-width="2"/></svg><div class="wb-chart-caption"><span>${escapeHTML(new Date(start*1000).toLocaleString())}</span><span>${escapeHTML(new Date(end*1000).toLocaleString())} ${diskBytes(points.at(-1).bytes)}</span></div>`;
}
function wbFeedback(text){$('wb-feedback').hidden=false;$('wb-feedback').textContent=text;}
function installDiskWorkbench(){
  $('wb-stats').onclick=e=>{
    if(!isWorkbenchCardMode())return;
    if(e.target.closest('[data-developer-add]')){
      $('developer-folder-input').value='';$('developer-folder-error').textContent='';$('developer-folder-save').disabled=false;
      $('developer-folder-dialog').showModal();$('developer-folder-input').focus();return;
    }
    const card=e.target.closest('[data-workbench-category]');if(!card)return;
    openWorkbenchCardList(card.dataset.workbenchCategory);
  };
  $('developer-folder-cancel').onclick=()=>$('developer-folder-dialog').close();
  $('developer-folder-form').onsubmit=e=>{
    e.preventDefault();const name=$('developer-folder-input').value.trim();
    if(!name || name==='.' || name==='..' || /[\/\x00-\x1f\x7f]/.test(name)){$('developer-folder-error').textContent='请输入单个文件夹名称，不要填写路径。';return;}
    $('developer-folder-save').disabled=true;post('addDeveloperFolder',{name});
  };
  $('storage-section-tabs').innerHTML=Object.entries(storageSections).map(([group,sections])=>
    `<div class="storage-nav-group" data-storage-group="${group}" role="group" aria-label="${storageGroupNames[group]}">
      <div class="storage-nav-label" aria-hidden="true">${storageGroupNames[group]}</div>
      ${sections.map(([key,name])=>`<button type="button" class="text-button" data-storage-section="${key}">${name}</button>`).join('')}
    </div>`).join('');
  resetStorageWorkspace();
  $('storage-section-tabs').onclick=event=>{
    const button=event.target.closest('[data-storage-section]');
    if(!button)return;
    storageSection(button.dataset.storageSection);window.scrollTo(0,0);
  };
  for(const id of ['disk-types-back','disk-largest-back','disk-map-back','disk-insights-back'])$(id).addEventListener('click',()=>{
    renderStorageWorkspace();
    $('storage-section-tabs').querySelector('[data-storage-section="directory"]').focus();
  });
  $('wb-back').onclick=()=>{if(isWorkbenchCardMode() && diskWorkbench.cardList){backToWorkbenchCards();return;}if(diskWorkbench?.detail){requestDiskWorkbench();return;}storageSection('directory');};
  $('wb-refresh').onclick=()=>{
    if(diskWorkbench?.mode==='growth'){requestDiskWorkbench(0,false,0,true);return;}
    requestDiskWorkbench(isWorkbenchCardMode() && !diskWorkbench.cardList?0:diskWorkbench?.report?.offset || 0);
  };
  $('wb-enrich').onclick=()=>requestDiskWorkbench(diskWorkbench?.report?.offset || 0,true);
  $('wb-stop').onclick=()=>{if(!diskWorkbench)return;post('cancelDiskWorkbench');stopWorkbenchProgress();diskWorkbench.queryID='';diskWorkbench.loading=false;diskWorkbench.report=null;$('wb-status').textContent='已停止；属性与历史已保留，点击刷新后继续操作。';$('wb-list').setAttribute('aria-busy','false');$('wb-enrich').disabled=true;$('wb-prev').disabled=true;$('wb-next').disabled=true;$('wb-list').classList.remove('wb-muted-row');$('wb-refresh').disabled=false;$('wb-stop').disabled=true;};
  $('wb-search').oninput=()=>{clearTimeout(workbenchSearchTimer);workbenchSearchTimer=setTimeout(()=>requestDiskWorkbench(),250);};
  for(const id of ['wb-category','wb-growth-hours','wb-growth-direction','wb-since','wb-until'])$(id).onchange=()=>requestDiskWorkbench();
  $('wb-prev').onclick=()=>requestDiskWorkbench(Math.max(0,(diskWorkbench?.report?.offset || 0)-100));$('wb-next').onclick=()=>requestDiskWorkbench((diskWorkbench?.report?.offset || 0)+100);
  $('wb-list').onclick=e=>{
    const button=e.target.closest('[data-wb-action]'),element=button?.closest('[data-wb-row]');if(!element || !diskScan || !diskWorkbench?.report || diskWorkbench.loading)return;
    const row=diskWorkbench.report.rows[Number(element.dataset.wbRow)],kind=button.dataset.wbAction;if(!row)return;
    if(kind==='history'){requestDiskWorkbench(0,false,row.timestamp);return;}
    if(kind==='browse'){storageSection('directory');$('disk-search').value='';setDiskKind('');diskBrowse(row.path);return;}
    if(kind==='reveal'){post('revealWorkbenchEntry',{requestID:diskScan.requestID,path:row.path});return;}
    if(kind==='trash' && [...workbenchOperations.values()].some(op=>op.kind==='trash')){wbFeedback('请先完成当前废纸篓确认。');return;}
    const operationID=crypto.randomUUID();workbenchOperations.set(operationID,{kind});
    post(kind==='copy'?'copyWorkbenchEntry':'trashDiskDuplicate',{requestID:diskScan.requestID,operationID,path:row.path,hash:row.hash});
    wbFeedback(kind==='copy'?'正在复制路径…':'请在原生确认窗口核对文件；保留副本会在移动前重新校验。');
  };
  window.receiveDiskWorkbench=report=>{
    if(!diskScan || !diskWorkbench || report.requestID!==diskScan.requestID || report.queryID!==diskWorkbench.queryID)return;
    stopWorkbenchProgress();diskWorkbench.loading=false;diskWorkbench.report=report;$('wb-refresh').disabled=false;$('wb-stop').disabled=true;$('wb-list').classList.remove('wb-muted-row');$('wb-list').setAttribute('aria-busy','false');renderWorkbench(report);
  };
  window.receiveDiskWorkbenchProgress=progress=>{if(diskScan?.requestID===progress.requestID && diskWorkbench?.queryID===progress.queryID){$('wb-status').textContent=progress.message;updateWorkbenchProgress(progress.message,progress.completed,progress.total);}};
  const previous=window.receiveDiskFileAction;
  window.receiveDiskFileAction=result=>{const op=workbenchOperations.get(result.operationID);if(!op){previous?.(result);return;}workbenchOperations.delete(result.operationID);if(!diskWorkbench || diskScan?.requestID!==result.requestID)return;wbFeedback(result.message);if(result.success && op.kind==='trash')requestDiskWorkbench(diskWorkbench.report?.offset || 0);};
  $('storage-export-toggle').onclick=()=>$('storage-export-panel').hidden=!$('storage-export-panel').hidden;
  $('storage-export-cancel').onclick=()=>post('cancelStorageExport');
  $('storage-export-start').onclick=()=>{
    if(!diskScan)return;
    const source=$('storage-export-source').value,minimum=Number($('disk-large-min').value || 0),maximum=Number($('disk-large-max').value || 0);
    if(source==='large' && (!Number.isFinite(minimum) || !Number.isFinite(maximum) || minimum<0 || maximum<0 || (maximum && maximum<minimum))){$('storage-export-feedback').textContent='请先修正大文件大小筛选范围。';return;}
    $('storage-export-feedback').textContent='请选择保存位置；完整列表将在后台导出。';
    post('exportStorage',{requestID:diskScan.requestID,source:$('storage-export-source').value,format:$('storage-export-format').value,analysisMode:diskWorkbench?'workbench':storageInsights?'apps':diskMap?'map':storageFiles?.mode || 'directory',analysisPath:diskMap?.path || '',mapMode:diskMap?.mode || 'folders',analysisOffset:storageFiles?.page?.offset || 0,category:$('disk-large-kind').value,minimum:Math.round(minimum*1048576),maximum:Math.round(maximum*1048576),modifiedAfter:storageDate($('disk-large-after').value),modifiedBefore:storageDate($('disk-large-before').value,true),physical:$('disk-large-basis').value==='physical',descending:$('disk-large-order').value==='desc'});
  };
  window.receiveStorageExport=result=>$('storage-export-feedback').textContent=result.message;
  $('usage-storage-history').onclick=()=>{
    const selected=usageData?.selected,period=selected?{since:selected.startedAt,until:selected.updatedAt}:null;
    navigate('storage');const volume=[...diskIndexes.values()].find(v=>v.ready);
    if(!volume){$('storage-notice').textContent='请先检查磁盘访问状态并等待索引就绪，再查看存储变化。';return;}
    if(!diskScan || diskScan.volumePath!==volume.volumePath)openDiskAnalysis(volume.volumePath);
    if(!diskScan)return;renderStorageWorkspace('history');openDiskWorkbench('history',period);
  };
}
