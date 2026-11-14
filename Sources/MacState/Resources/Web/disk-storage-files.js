let storageFiles = null;
const storageTypeNames={video:'视频',image:'图片',audio:'音频',document:'文档',archive:'压缩包',application:'应用',development:'开发文件',model:'模型文件',other:'其他文件'};
const storageTypeColors={video:'#ffb340',image:'#32d74b',audio:'#ff7b72',document:'#8bc8ed',archive:'#d4ad72',application:'#a9d9af',development:'#69d2c5',model:'#e4bc80',other:'#909b96'};
const storageOperations=new Map();
function closeStorageFiles() {
  if(storageFiles)post('cancelDiskStorageQuery');
  storageFiles=null;$('disk-types-view').hidden=true;$('disk-largest-view').hidden=true;
}
function openStorageFiles(mode,category='') {
  if(!diskScan)return;
  closeDiskWorkbench();closeStorageInsights();closeDiskMap();closeStorageFiles();
  $('disk-directory-view').hidden=true;
  storageFiles={mode,queryID:'',page:null,loading:false};
  $('disk-types-view').hidden=mode!=='types';$('disk-largest-view').hidden=mode!=='large';
  if(mode==='types') {
    $('disk-types-grid').textContent='';requestStorageTypes();
  } else {
    $('disk-large-kind').value=category;$('disk-large-min').value=category?'0':'100';$('disk-large-max').value='';
    $('disk-large-basis').value=category?'physical':'logical';$('disk-large-order').value='desc';
    $('disk-large-after').value='';$('disk-large-before').value='';$('disk-files-feedback').hidden=true;
    $('disk-largest').textContent='';requestLargeFiles();
  }
}
function requestStorageTypes() {
  if(!diskScan || storageFiles?.mode!=='types')return;
  storageFiles.queryID=crypto.randomUUID();storageFiles.loading=true;
  $('disk-types-summary').textContent='正在汇总本地索引中的文件类型…';$('disk-types-refresh').disabled=true;
  $('disk-types-grid').setAttribute('aria-busy','true');
  post('diskFileTypes',{requestID:diskScan.requestID,queryID:storageFiles.queryID});
}
function storageDate(value,end=false) {
  if(!value)return 0;
  const [year,month,day]=value.split('-').map(Number);
  return new Date(year,month-1,day+(end?1:0)).getTime()/1000;
}
function requestLargeFiles(offset=0) {
  if(!diskScan || storageFiles?.mode!=='large')return;
  const minimum=Number($('disk-large-min').value || 0),maximum=Number($('disk-large-max').value || 0);
  const modifiedAfter=storageDate($('disk-large-after').value),modifiedBefore=storageDate($('disk-large-before').value,true);
  storageFiles.queryID=crypto.randomUUID();
  if(!Number.isFinite(minimum) || !Number.isFinite(maximum) || minimum<0 || maximum<0 || minimum>1e9 || maximum>1e9 || (maximum && minimum>maximum) || !Number.isFinite(modifiedAfter) || !Number.isFinite(modifiedBefore) || (modifiedBefore && modifiedAfter>=modifiedBefore)) {
    post('cancelDiskStorageQuery');storageFiles.page=null;storageFiles.loading=false;
    $('disk-largest').textContent='';$('disk-largest').classList.remove('files-loading');$('disk-large-refresh').disabled=false;
    $('disk-large-prev').disabled=true;$('disk-large-next').disabled=true;$('disk-large-page-label').textContent='';
    $('disk-large-summary').textContent='请检查大小与日期范围：最小值不能大于最大值，开始日期不能晚于结束日期。';return;
  }
  storageFiles.loading=true;storageFiles.physical=$('disk-large-basis').value==='physical';
  $('disk-large-summary').textContent='正在读取文件排行…';$('disk-large-refresh').disabled=true;
  $('disk-largest').classList.add('files-loading');$('disk-largest').setAttribute('aria-busy','true');
  $('disk-large-prev').disabled=true;$('disk-large-next').disabled=true;
  post('diskLargeFiles',{requestID:diskScan.requestID,queryID:storageFiles.queryID,category:$('disk-large-kind').value,
    minimum:Math.round(minimum*1048576),maximum:Math.round(maximum*1048576),modifiedAfter,modifiedBefore,
    physical:storageFiles.physical,descending:$('disk-large-order').value==='desc',offset});
}
function storageFeedback(message,success=true) {
  $('disk-files-feedback').hidden=false;$('disk-files-feedback').textContent=message;
  $('disk-files-feedback').dataset.success=String(success);
}
function renderLargeFiles(page) {
  const physical=storageFiles.physical;
  $('disk-largest').innerHTML=page.entries.map((row,index)=>{
    const entry=row.entry,rank=page.offset+index+1,date=entry.modified?new Date(entry.modified*1000).toLocaleString():'未知';
    return `<div class="disk-large-row" data-large-index="${index}" data-file-path="${escapeHTML(entry.path)}" role="listitem"><span class="disk-large-rank muted">${rank}</span><div class="disk-large-file"><strong title="${escapeHTML(entry.name)}">${escapeHTML(entry.name)}</strong><span class="muted">${storageTypeNames[row.category] || '其他文件'} 修改 ${escapeHTML(date)}</span><span class="muted disk-large-path" title="${escapeHTML(entry.path)}">${escapeHTML(entry.path)}</span></div><div class="disk-large-sizes"><strong>${diskBytes(physical?entry.bytes:entry.logicalBytes)}</strong><span class="muted">${physical?'文件大小':'实际占用'} ${diskBytes(physical?entry.logicalBytes:entry.bytes)}</span></div><div class="disk-large-actions"><button class="text-button" data-file-action="reveal">Finder</button></div></div>`;
  }).join('') || '<div class="empty">没有符合筛选条件的文件</div>';
  $('disk-large-summary').textContent=`整个存储卷 按${physical?'实际占用':'文件大小'}${$('disk-large-order').value==='desc'?'从大到小':'从小到大'}排列 每页 100 项${page.hasMore?'，还有更多结果':''}`;
  $('disk-large-page-label').textContent=`${page.entries.length?page.offset+1:0}–${page.offset+page.entries.length}${page.hasMore?' 还有更多':''}`;
  $('disk-large-prev').disabled=page.offset===0;$('disk-large-next').disabled=!page.hasMore;$('disk-largest').scrollTop=0;
}
function installStorageFiles() {
  for(const [key,name] of Object.entries(storageTypeNames)){const option=document.createElement('option');option.value=key;option.textContent=name;$('disk-large-kind').append(option);}
  $('disk-types-open').onclick=()=>openStorageFiles('types');$('disk-largest-open').onclick=()=>openStorageFiles('large');
  const back=()=>{const mode=storageFiles?.mode;closeStorageFiles();$('disk-directory-view').hidden=false;$(mode==='types'?'disk-types-open':'disk-largest-open').focus();};
  $('disk-types-back').onclick=back;$('disk-largest-back').onclick=back;
  $('disk-types-refresh').onclick=requestStorageTypes;$('disk-large-refresh').onclick=()=>requestLargeFiles(storageFiles?.page?.offset || 0);
  $('disk-large-filters').onchange=()=>requestLargeFiles();
  $('disk-large-prev').onclick=()=>requestLargeFiles(Math.max(0,(storageFiles?.page?.offset || 0)-100));
  $('disk-large-next').onclick=()=>requestLargeFiles((storageFiles?.page?.offset || 0)+100);
  $('disk-types-grid').onclick=event=>{
    const card=event.target.closest('[data-storage-type]');
    if(card){openStorageFiles('large',card.dataset.storageType);renderStorageWorkspace('large');}
  };
  $('disk-largest').onclick=event=>{
    if(!storageFiles?.page || storageFiles.loading || !diskScan)return;
    const button=event.target.closest('[data-file-action]'),element=button?.closest('[data-large-index]');if(!element)return;
    const entry=storageFiles.page.entries[Number(element.dataset.largeIndex)]?.entry;if(!entry)return;
    const kind=button.dataset.fileAction;
    if(kind==='reveal'){post('revealDiskEntry',{requestID:diskScan.requestID,path:entry.path});return;}
    if(kind==='trash' && [...storageOperations.values()].some(op=>op.kind==='trash')){storageFeedback('请先完成当前废纸篓确认。',false);return;}
    const operationID=crypto.randomUUID();storageOperations.set(operationID,{kind,path:entry.path});
    post(kind==='copy'?'copyDiskEntry':'trashDiskEntry',{requestID:diskScan.requestID,operationID,path:entry.path});
    storageFeedback(kind==='copy'?'正在复制路径…':'请在确认窗口中核对文件路径。');
  };
  window.receiveDiskFileTypes=result=>{
    if(!diskScan || storageFiles?.mode!=='types' || result.requestID!==diskScan.requestID || result.queryID!==storageFiles.queryID)return;
    storageFiles.loading=false;$('disk-types-refresh').disabled=false;$('disk-types-grid').setAttribute('aria-busy','false');
    if(result.error){$('disk-types-summary').textContent=result.error;$('disk-types-grid').textContent='';return;}
    const bytes=result.categories.reduce((sum,item)=>sum+item.bytes,0),files=result.categories.reduce((sum,item)=>sum+item.files,0);
    $('disk-types-summary').textContent=`${files.toLocaleString()} 个文件 文件实际占用 ${diskBytes(bytes)} 目录元数据 ${diskBytes(result.directoryBytes)}${result.skipped?` ${result.skipped.toLocaleString()} 项未完整计入`:''} ${new Date(result.updated*1000).toLocaleTimeString()} 的索引快照`;
    $('disk-types-grid').innerHTML=result.categories.map(item=>`<button class="metric-card disk-type-card" data-storage-type="${item.key}" style="--type-color:${storageTypeColors[item.key] || storageTypeColors.other}"><span class="disk-type-heading"><i aria-hidden="true"></i><strong>${storageTypeNames[item.key] || item.key}</strong><span aria-hidden="true">↗</span></span><span class="disk-type-size">${diskBytes(item.bytes)}</span><span class="muted">${item.files.toLocaleString()} 个文件 文件大小 ${diskBytes(item.logicalBytes)}</span><progress max="100" value="${bytes?item.bytes/bytes*100:0}" aria-label="${storageTypeNames[item.key]} 实际占用比例"></progress><span class="muted">${bytes?(item.bytes/bytes*100).toFixed(1):'0.0'}% 的文件占用</span></button>`).join('');
  };
  window.receiveDiskLargeFiles=page=>{
    if(!diskScan || storageFiles?.mode!=='large' || page.requestID!==diskScan.requestID || page.queryID!==storageFiles.queryID)return;
    storageFiles.loading=false;$('disk-large-refresh').disabled=false;$('disk-largest').classList.remove('files-loading');$('disk-largest').setAttribute('aria-busy','false');
    if(page.error){storageFiles.page=null;$('disk-large-summary').textContent=page.error;$('disk-largest').textContent='';$('disk-large-page-label').textContent='';return;}
    storageFiles.page=page;renderLargeFiles(page);
  };
  window.receiveDiskFileAction=result=>{
    const operation=storageOperations.get(result.operationID);if(!operation)return;
    storageOperations.delete(result.operationID);
    if(!diskScan || result.requestID!==diskScan.requestID || storageFiles?.mode!=='large')return;
    storageFeedback(result.message,result.success || result.message==='已取消。');
    if(result.success && operation.kind==='trash')requestLargeFiles(storageFiles.page?.offset || 0);
  };
}
