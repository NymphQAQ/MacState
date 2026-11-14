let diskScan = null, diskDirectory = null, storageVolumeSignature = "";
let diskIndexes = new Map();
let diskKind = "", diskSortKey = "", diskSortDescending = false;
function diskSortPayload() { return {sortKey:diskSortKey,sortDescending:diskSortDescending}; }
function renderDiskSort() {
  document.querySelectorAll("[data-disk-sort]").forEach(button=>{
    const active=button.dataset.diskSort===diskSortKey;
    button.setAttribute("aria-pressed",String(active));
    button.querySelector(".disk-sort-arrow").textContent=active?(diskSortDescending?"↓":"↑"):"";
  });
}

function setDiskKind(kind) {
  diskKind=kind;
  document.querySelectorAll("[data-disk-kind]").forEach(button=>button.setAttribute("aria-pressed",String(button.dataset.diskKind===kind)));
}
function showDiskLargest(show) {
  if(typeof closeStorageFiles==='function')closeStorageFiles();
  if(typeof closeStorageInsights==='function')closeStorageInsights();
  if(typeof closeDiskWorkbench==='function')closeDiskWorkbench();
  if(typeof closeDiskMap==='function')closeDiskMap();
  $("disk-directory-view").hidden=show;
  $("disk-largest-view").hidden=!show;
}
let diskAccess = "unknown", diskRequestedPath = null, diskProgressTime = 0;

function renderDiskCacheStatus() {
  const status=diskScan?diskIndexes.get(diskScan.volumePath):null;
  const manual=$("disk-sync"),pause=$("disk-sync-pause");
  const unavailable=!native || diskAccess!=='granted' || !status?.ready || status.merging;
  manual.disabled=unavailable || status.manualSynchronization;
  manual.textContent=status?.manualSynchronization?'手动同步中…':'手动同步';
  manual.title=status?.synchronizationPaused?'同步一次，完成后保持暂停':'立即同步文件变化';
  pause.disabled=unavailable;
  pause.textContent=status?.manualSynchronization?'停止本次同步':status?.synchronizationPaused?'恢复自动同步':'暂停同步';
}
function renderDiskAccess() {
  const granted=diskAccess==='granted';
  $("disk-access").hidden=granted || Boolean(diskScan);
  if(!granted){
    $("disk-access-title").textContent=diskAccess==='checking'?'正在检查权限…':diskAccess==='missing'?'受保护目录访问被拒绝':'无法确认磁盘访问权限';
    $("disk-access-note").textContent=diskAccess==='unknown'?'未能完成受保护目录的访问检查，可能是检测目录不存在或其他系统错误，不代表你没有授权。请点击“重新检查权限”；应用不会自动申请或修改权限。':'请自行在系统设置 → 隐私与安全 → 完全磁盘访问权限中允许当前版本的 MacState，再点击“重新检查权限”。应用不会自动申请或修改权限；修改授权后可能需要重启应用。';
  }
  $("disk-access-check").disabled=diskAccess==='checking';
  document.querySelectorAll('[data-analyze-volume]').forEach(button=>button.disabled=!native || !granted || !diskIndexes.get(button.dataset.analyzeVolume)?.ready);
  if(diskScan)$("disk-rescan").disabled=diskScan.state==='scanning' || !granted;
  renderDiskCacheStatus();
}

function formatVolumeCapacity(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let index = 0;
  while (bytes >= 1000 && index < units.length - 1) {
    bytes /= 1000;
    index++;
  }
  return `${bytes.toFixed(index === 0 ? 0 : 2)} ${units[index]}`;
}

function renderStorageVolumes(volumes) {
  const signature = JSON.stringify(volumes);
  if(storageVolumeSignature === signature) return;
  storageVolumeSignature = signature;
  const grid = $("volume-grid"), existing = new Map([...grid.querySelectorAll('[data-volume-path]')].map(card=>[card.dataset.volumePath,card]));
  if(!volumes.length) { grid.innerHTML='<div class="empty">没有可见的本地存储卷</div>'; return; }
  grid.querySelector(':scope > .empty')?.remove();
  for(const [index,volume] of volumes.entries()) {
    let card = existing.get(volume.path);
    existing.delete(volume.path);
    if(!card) {
      card = document.createElement('article');card.className='metric-card';card.dataset.volumePath=volume.path;
      card.innerHTML='<div class="card-title"><span>本地存储卷</span><button class="button volume-analyze"><span class="glyph i-hard-drive" aria-hidden="true"></span>文件分析</button></div><div class="network-name"></div><div class="metric-detail volume-path"></div><div class="metric-value"></div><progress class="core-progress" aria-label="磁盘占用"></progress><div class="kv"><span class="muted">容量</span><strong></strong></div><div class="kv"><span class="muted">可用</span><strong></strong></div><div class="kv"><span class="muted">已用</span><strong></strong></div><div class="volume-index" role="status"><strong class="volume-index-label"></strong><span class="volume-index-detail muted"></span><progress class="volume-index-progress" aria-label="文件索引进度"></progress><span class="volume-index-path muted"></span><div class="volume-index-actions"><button class="button volume-rebuild">重建索引</button></div></div>';
    }
    const button = card.querySelector('button');
    button.dataset.analyzeVolume=volume.path;button.setAttribute('aria-label',`分析 ${volume.name} 的磁盘空间`);button.disabled=!native || diskAccess!=='granted' || !diskIndexes.get(volume.path)?.ready;
    card.querySelector('.network-name').textContent=volume.name;
    card.querySelector('.volume-path').textContent=volume.path;
    const available=volume.availableForImportantUsage ?? volume.available;
    const used=Math.max(0,volume.total-available),value=card.querySelector('.metric-value'),html=valueHTML(volume.total?used/volume.total*100:0,'%');
    if(value.innerHTML!==html)value.innerHTML=html;
    const progress=card.querySelector('progress');progress.max=volume.total;progress.value=used;
    card.querySelectorAll('.kv strong').forEach((node,i)=>node.textContent=formatVolumeCapacity([volume.total,available,used][i]));
    renderVolumeIndex(card);
    if(grid.children[index]!==card)grid.insertBefore(card,grid.children[index] ?? null);
  }
  for(const card of existing.values())card.remove();
}

function renderVolumeIndex(card) {
  const status=diskIndexes.get(card.dataset.volumePath),button=card.querySelector('[data-analyze-volume]');
  button.disabled=!native || diskAccess!=='granted' || !status?.ready;
  const state=status?.state ?? (diskAccess==='granted'?'waiting':'blocked');
  card.dataset.indexState=state;
  const rebuild=card.querySelector('.volume-rebuild');
  if(rebuild){rebuild.dataset.rebuildVolume=card.dataset.volumePath;rebuild.disabled=!native || diskAccess!=='granted' || ['indexing','preparing'].includes(state) || status?.merging;}
  const usable=Boolean(status?.ready) && diskAccess==='granted';
  card.dataset.indexReady=String(usable);
  const labels={waiting:'等待建立文件索引',blocked:'需要磁盘访问权限',preparing:'正在准备文件索引 暂不可分析',indexing:'正在建立文件索引 暂不可分析',updating:'正在同步文件索引',verifying:'正在核对文件索引',ready:'文件索引已就绪',failed:'文件索引暂不可用'};
  const label=card.querySelector('.volume-index-label');
  label.textContent=usable?'索引已就绪 可以分析':labels[state] || state;
  const detail=card.querySelector('.volume-index-detail');
  detail.textContent=status?`${status.files.toLocaleString()} 个文件 ${status.directories.toLocaleString()} 个目录 ${diskBytes(status.bytes)}`:'只读取文件属性，不读取文件内容';
  if(state==='indexing')detail.textContent+=` 已用 ${Math.floor(status.elapsed)} 秒${status.readConcurrency?` ${status.readConcurrency} 路并行`:''}`;
  if(status?.completedAt)detail.title=`索引建立于 ${new Date(status.completedAt*1000).toLocaleString()} 用时 ${Math.floor(status.buildElapsed || 0)} 秒`;
  else detail.removeAttribute('title');
  const progress=card.querySelector('.volume-index-progress');
  progress.hidden=usable || !['indexing','preparing'].includes(state);
  progress.removeAttribute('value');
  const path=card.querySelector('.volume-index-path');
  if(usable) {
    const pending=status.pendingChanges || 0;
    const activity=state==='verifying'?'后台正在核对变化，可正常分析':state==='updating'?`后台同步中${pending?` ${pending.toLocaleString()} 个目录待更新`:''}，可正常分析`:`文件变化自动同步${status.updated?` 更新于 ${new Date(status.updated*1000).toLocaleTimeString()}`:''}`;
    path.textContent=status.manualSynchronization?'正在手动同步，可正常分析'
      :status.synchronizationPaused?'自动同步已暂停，可使用已有索引':activity;
  } else path.textContent=status?.message || (state==='indexing'?status.currentPath:state==='waiting'?'建立完成后即可搜索和分析文件':'');
  path.title=path.textContent;
  // Keep access warnings separate from normal background activity.
  let note=card.querySelector('.volume-index-note');
  if(!note){note=document.createElement('span');note.className='volume-index-note muted';card.querySelector('.volume-index-actions').before(note);}
  note.textContent=usable?(status.message || ''):'';
  note.hidden=!note.textContent;note.title=note.textContent;

}

function diskBytes(bytes) { return inlineValue(bytes ?? 0,'B'); }
let diskSearchTimer;
function diskSearch(offset=0) {
  if(!diskScan)return;
  diskRequestedPath=null;
  post('searchDiskIndex',{requestID:diskScan.requestID,text:$("disk-search").value,kind:diskKind,offset,...diskSortPayload()});
}
function diskBrowse(path,offset=0) {
  if(!diskScan)return;
  recordDirectoryNavigation(path);
  $("disk-search").value='';setDiskKind('');clearTimeout(diskSearchTimer);
  diskRequestedPath=path;
  post('diskDirectory',{requestID:diskScan.requestID,path,offset,...diskSortPayload()});
}
function openDiskAnalysis(volumePath) {
  if(diskAccess!=='granted' || !diskIndexes.get(volumePath)?.ready){renderDiskAccess();return;}
  const volume=snapshot?.volumes.find(item=>item.path===volumePath);
  if(!volume)return;
  diskScan={requestID:crypto.randomUUID(),volumePath,volumeName:volume.name,state:'loading',files:0,directories:0,bytes:0,skipped:0,elapsed:0};diskDirectory=null;diskRequestedPath=null;directoryNavigationEntries=[];directoryNavigationPosition=-1;directoryNavigationRequest=diskScan.requestID;diskProgressTime=performance.now();
  $("disk-search").value='';setDiskKind('');
  $("volume-grid").hidden=true;$("storage-notice").hidden=true;$("disk-analysis").hidden=false;
  $("disk-volume-name").textContent=volume.name;
  $("disk-breadcrumbs").textContent='正在读取文件索引';
  $("disk-entries").innerHTML='<div class="empty">正在读取本地索引…</div>';
  $("disk-largest").innerHTML='<div class="empty">发现大文件后会在这里实时显示</div>';
  $("disk-directory-summary").textContent='目录与文件';$("disk-page-controls").hidden=true;
  diskSortKey='';diskSortDescending=false;renderDiskSort();
  showDiskLargest(false);resetStorageWorkspace();renderDiskAccess();renderDiskProgress();
  post('startDiskAnalysis',{requestID:diskScan.requestID,volumePath});
}
function renderDiskProgress() {
  if(!diskScan)return;
  const labels={loading:'正在读取索引',scanning:'正在扫描',completed:'索引分析',cancelled:'已停止 部分结果',failed:'索引不可用'};
  $("disk-state").textContent=labels[diskScan.state] || diskScan.state;
  $("disk-state").dataset.state=diskScan.state;
  $("disk-scanned-size").textContent=diskBytes(diskScan.bytes);
  const elapsed=(diskScan.elapsed ?? 0)+(diskScan.state==='scanning'?(performance.now()-diskProgressTime)/1000:0);
  $("disk-scanned-count").textContent=`${diskScan.files ?? 0} 个文件 ${diskScan.directories ?? 0} 个目录 ${diskScan.state==='completed'?'来自本地索引':`${Math.floor(elapsed)} 秒`}`;
  $("disk-current-path").textContent=diskScan.state==='scanning' ? diskScan.currentPath || '正在开始…' : diskScan.rootPath || diskScan.volumePath;
  $("disk-current-path").title=$("disk-current-path").textContent;
  const excluded=diskScan.excluded ?? 0,other=Math.max(0,(diskScan.skipped ?? 0)-excluded);
  $("disk-scan-note").textContent=[diskScan.message,excluded?`${excluded} 项手机/云端映射、占位文件或其他挂载卷已跳过。`:'',other?`${other} 项无法访问或超出目录深度范围，未完整计入。`:''].filter(Boolean).join(' ');
  $("disk-scan-note").title=$("disk-scan-note").textContent;
  $("disk-cancel").hidden=diskScan.state!=='scanning';$("disk-rescan").disabled=diskScan.state==='scanning' || diskAccess!=='granted';
}
function diskEntrySize(entry) {
  const pending=entry.pending && diskScan?.state==='scanning';
  return `${pending?'≥ ':''}${diskBytes(entry.bytes)}${pending?'<small>统计中</small>':entry.note?`<small>${escapeHTML(entry.note)}</small>`:entry.skipped?'<small>部分未计入</small>':entry.pending?'<small>未扫描完成</small>':''}`;
}
function diskEntryMetadata(entry) {
  const kinds={folder:'文件夹',image:'图像',audio:'音频',video:'视频',text:'文本',archive:'压缩包',document:'文档',application:'应用',link:'符号链接',other:'其他'};
  const date=entry.modified?'修改 '+new Date(entry.modified*1000).toLocaleString():'';
  return [kinds[entry.kind] || '',entry.fileExtension?'.'+entry.fileExtension:'',!entry.directory && entry.logicalBytes!=null?'文件大小 '+diskBytes(entry.logicalBytes):'',date].filter(Boolean).join(' ');
}
function diskEntryHTML(entry,largest=false) {
  const percent=diskDirectory?.bytes ? Math.min(100,entry.bytes/diskDirectory.bytes*100) : 0;
  const label=`选择 ${entry.directory?'文件夹':'文件'} ${entry.name}`;
  return `<div class="disk-entry" role="listitem" data-entry-path="${escapeHTML(entry.path)}" data-file-path="${escapeHTML(entry.path)}"><button class="disk-entry-main"  aria-label="${escapeHTML(label)}"><span class="glyph ${entry.directory?'i-hard-drive':'i-list'}" aria-hidden="true"></span><span class="disk-entry-text"><span class="disk-entry-name" title="${escapeHTML(entry.path)}${entry.created?' 创建 '+escapeHTML(new Date(entry.created*1000).toLocaleString()):''}">${escapeHTML(entry.name)}</span><span class="disk-entry-metadata muted">${escapeHTML(diskEntryMetadata(entry))}</span>${largest?`<span class="muted disk-entry-path" title="${escapeHTML(entry.path)}">${escapeHTML(entry.path)}</span>`:`<progress max="100" value="${percent}" aria-label="${escapeHTML(entry.name)} 占用比例"></progress>`}</span><span class="disk-entry-size">${diskEntrySize(entry)}</span></button>${entry.browsable?`<button class="text-button" data-disk-directory="${escapeHTML(entry.path)}" title="在索引中浏览文件夹">浏览</button>`:''}<button class="text-button disk-reveal" data-disk-reveal="${escapeHTML(entry.path)}" aria-label="在访达中显示 ${escapeHTML(entry.name)}" title="在访达中显示"><span class="glyph i-arrow-up-right" aria-hidden="true"></span></button></div>`;
}
function renderDiskEntries(container,entries,largest=false) {
  const old=new Map([...container.querySelectorAll(':scope > [data-entry-path]')].map(row=>[row.dataset.entryPath,row]));
  container.querySelector(':scope > .empty')?.remove();
  const interacting=container.matches(':hover') || container.contains(document.activeElement);
  entries.forEach((entry,index)=>{
    let row=old.get(entry.path);old.delete(entry.path);
    if(row && (Boolean(row.querySelector('.disk-entry-path'))!==largest)){row.remove();row=null;}
    if(!row){const template=document.createElement('template');template.innerHTML=diskEntryHTML(entry,largest);row=template.content.firstElementChild;}
    else {
      const size=row.querySelector('.disk-entry-size'),html=diskEntrySize(entry);
      if(size.innerHTML!==html)size.innerHTML=html;
      row.querySelector('.disk-entry-metadata').textContent=diskEntryMetadata(entry);
      const progress=row.querySelector('progress');if(progress)progress.value=diskDirectory?.bytes?Math.min(100,entry.bytes/diskDirectory.bytes*100):0;
    }
    if(!row.parentElement)container.append(row);
    if(!interacting && container.children[index]!==row)container.insertBefore(row,container.children[index] ?? null);
  });
  old.forEach(row=>row.remove());
  if(!entries.length)container.innerHTML=`<div class="empty">${diskScan?.state==='scanning'?'正在扫描，已发现的项目会自动显示':'没有可显示的本地文件'}</div>`;
}
function installDiskAnalysis() {
  $("disk-access-settings").disabled=!native;
  $("disk-access-settings").onclick=()=>post('openDiskAccessSettings');
  window.receiveDiskAccess=status=>{diskAccess=status;renderDiskAccess();document.querySelectorAll('[data-volume-path]').forEach(renderVolumeIndex);};
  window.receiveDiskIndexes=statuses=>{
    diskIndexes=new Map(statuses.map(status=>[status.volumePath,status]));
    if(diskScan && diskIndexes.get(diskScan.volumePath)?.state==='indexing')$("disk-back").click();
    document.querySelectorAll('[data-volume-path]').forEach(renderVolumeIndex);
    renderDiskCacheStatus();
  };
  $("disk-access-check").onclick=()=>{diskAccess='checking';renderDiskAccess();post('checkDiskAccess');};
  renderDiskAccess();
  $("disk-search").oninput=()=>{clearTimeout(diskSearchTimer);diskSearchTimer=setTimeout(()=>diskSearch(),80);};
  $("disk-kind-filters").onclick=event=>{const button=event.target.closest('[data-disk-kind]');if(!button)return;setDiskKind(button.dataset.diskKind);clearTimeout(diskSearchTimer);diskSearch();};
  $("disk-sort-controls").onclick=event=>{
    const button=event.target.closest('[data-disk-sort]');if(!button || !diskScan)return;
    const key=button.dataset.diskSort;
    diskSortDescending=key===diskSortKey?!diskSortDescending:['size','modified'].includes(key);
    diskSortKey=key;renderDiskSort();clearTimeout(diskSearchTimer);
    if($("disk-search").value.trim() || diskKind)diskSearch();else diskBrowse(diskDirectory?.path || diskScan.rootPath || diskScan.volumePath);
  };
  $("disk-largest-open").onclick=()=>{showDiskLargest(true);$("disk-largest-back").focus();};
  $("disk-largest-back").onclick=()=>{showDiskLargest(false);$("disk-largest-open").focus();};
  setInterval(()=>{if(view==='storage' && diskScan?.state==='scanning')renderDiskProgress();},500);
  $("volume-grid").addEventListener('click',event=>{
    const rebuild=event.target.closest('[data-rebuild-volume]');
    if(rebuild && !rebuild.disabled){post('rebuildDiskIndex',{volumePath:rebuild.dataset.rebuildVolume});return;}
    const button=event.target.closest('[data-analyze-volume]');if(button && !button.disabled)openDiskAnalysis(button.dataset.analyzeVolume);
  });
  $("disk-analysis").addEventListener('click',event=>{
    const folder=event.target.closest('[data-disk-directory]'),reveal=event.target.closest('[data-disk-reveal]');
    if(folder)diskBrowse(folder.dataset.diskDirectory);
    if(reveal && diskScan)post('revealDiskEntry',{requestID:diskScan.requestID,path:reveal.dataset.diskReveal});
  });
  $("disk-back").onclick=()=>{
    clearTimeout(diskSearchTimer);
    if(typeof closeDiskMap==='function')closeDiskMap();
    if(typeof closeStorageFiles==='function')closeStorageFiles();
  if(typeof closeStorageInsights==='function')closeStorageInsights();
  if(typeof closeDiskWorkbench==='function')closeDiskWorkbench();
    if(diskScan)post('cancelDiskAnalysis',{requestID:diskScan.requestID});
    diskScan=null;diskDirectory=null;$("disk-analysis").hidden=true;$("volume-grid").hidden=false;$("storage-notice").hidden=false;renderDiskAccess();
  };
  $("disk-cancel").onclick=()=>{if(diskScan)post('cancelDiskAnalysis',{requestID:diskScan.requestID});};
  $("disk-sync").onclick=()=>{if(diskScan)post('syncDiskIndexCache',{volumePath:diskScan.volumePath});};
  $("disk-sync-pause").onclick=()=>{
    if(!diskScan)return;
    const status=diskIndexes.get(diskScan.volumePath);
    if(status?.ready)post('setDiskSynchronizationPaused',{
      volumePath:diskScan.volumePath,paused:!status.synchronizationPaused || Boolean(status.manualSynchronization)
    });
  };
  $("disk-rescan").onclick=()=>{if(diskScan){const volumePath=diskScan.volumePath;$("disk-back").click();post('rebuildDiskIndex',{volumePath});}};
  $("disk-page-prev").onclick=()=>{if(diskDirectory){if(diskDirectory.filtered)diskSearch(diskDirectory.offset-100);else diskBrowse(diskDirectory.path,diskDirectory.offset-100);}};
  $("disk-page-next").onclick=()=>{if(diskDirectory){if(diskDirectory.filtered)diskSearch(diskDirectory.offset+100);else diskBrowse(diskDirectory.path,diskDirectory.offset+100);}};
  window.receiveDiskAnalysis=update=>{
    if(!diskScan || update.requestID!==diskScan.requestID)return;
    diskScan={...diskScan,...update};diskProgressTime=performance.now();renderDiskProgress();

  };
  window.receiveDiskDirectory=directory=>{
    if(directory.filtered && directory.searchText!==undefined && (directory.searchText!==$("disk-search").value.trim().slice(0,256) || directory.searchKind!==diskKind))return;
    if(!diskScan || directory.requestID!==diskScan.requestID)return;
    if(directory.sortKey!==undefined && (directory.sortKey!==diskSortKey || directory.sortDescending!==diskSortDescending))return;
    if(diskRequestedPath && directory.path!==diskRequestedPath)return;
    diskRequestedPath=null;
    const changed=diskDirectory?.path!==directory.path || diskDirectory?.offset!==directory.offset || diskDirectory?.sortKey!==directory.sortKey || diskDirectory?.sortDescending!==directory.sortDescending;
    diskDirectory=directory;
    if(!directory.filtered && directoryNavigationPosition<0)recordDirectoryNavigation(directory.path);
    $("disk-breadcrumbs").hidden=Boolean(directory.filtered) || directory.breadcrumbs.length<=1;
    const crumbs=directory.breadcrumbs.map(crumb=>`<button class="text-button" data-disk-directory="${escapeHTML(crumb.path)}">${escapeHTML(crumb.name)}</button>`).join('<span aria-hidden="true">›</span>');
    if($("disk-breadcrumbs").innerHTML!==crumbs)$("disk-breadcrumbs").innerHTML=crumbs;
    $("disk-directory-summary").textContent=`${directory.pending?'已发现 ':''}${diskBytes(directory.bytes)} ${directory.files} 个文件${directory.pending?(diskScan.state==='scanning'?' 统计中，点击目录优先扫描':' 未扫描完成'):''}${directory.skipped?` ${directory.skipped} 项未完整计入`:''}`;
    if(changed)$("disk-entries").textContent='';
    if(directory.filtered)$("disk-directory-summary").textContent=`整个卷的索引结果 ${directory.countIsExact===false?'至少 ':''}${directory.entryCount} 项${diskSortKey?'':' 按索引顺序'}`;
    renderDiskEntries($("disk-entries"),directory.entries,Boolean(directory.filtered));
    $("disk-page-controls").hidden=directory.entryCount<=100;
    $("disk-page-label").textContent=`${directory.entryCount?directory.offset+1:0}–${Math.min(directory.offset+100,directory.entryCount)} / ${directory.countIsExact===false?'至少 ':''}${directory.entryCount} 项`;
    $("disk-page-prev").disabled=directory.offset===0;$("disk-page-next").disabled=directory.offset+100>=directory.entryCount;
    if(changed)$("disk-entries").scrollTop=0;
  };
  window.diskAnalysisFailed=error=>{if(diskScan && error.requestID===diskScan.requestID)window.receiveDiskAnalysis({...diskScan,state:'failed',message:error.message,largest:[]});};
}
