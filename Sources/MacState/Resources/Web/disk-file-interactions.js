const diskFileSelection=new Set();
let diskFileSelectionRequest='',diskFileAnchor='';
function visibleFileRows(){return [...document.querySelectorAll('#disk-analysis [data-file-path]')].filter(row=>row.getClientRects().length);}
function fileInteraction(kind,paths=null,event=null){
  if(!diskScan)return;
  paths=paths || [...diskFileSelection];if(!paths.length)return;
  post('diskFileInteraction',{requestID:diskScan.requestID,kind,paths,x:event?.clientX || 0,y:event?.clientY || 0});
}
function fileSelectionSync(){
  if(diskFileSelectionRequest!==diskScan?.requestID){diskFileSelection.clear();diskFileSelectionRequest=diskScan?.requestID || '';}
  const rows=visibleFileRows(),paths=new Set(rows.map(row=>row.dataset.filePath));
  for(const path of diskFileSelection)if(!paths.has(path))diskFileSelection.delete(path);
  for(const row of rows){
    row.tabIndex=0;row.setAttribute('role','option');
    let box=row.querySelector(':scope > [data-file-select]');
    if(!box){
      box=row.querySelector(':scope > [data-insight-select]');
      if(!box){box=document.createElement('input');box.type='checkbox';row.prepend(box);}
      box.dataset.fileSelect='';box.setAttribute('aria-label','选择 '+row.dataset.filePath.split('/').at(-1));
    }
    if(!row.querySelector(':scope > [data-file-trash]')){
      const button=document.createElement('button');button.className='text-button file-trash-icon';button.dataset.fileTrash='';button.title='移到废纸篓';button.setAttribute('aria-label','移到废纸篓');
      button.innerHTML='<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 10v7M14 10v7"/></svg>';row.append(button);
    }
    const selected=diskFileSelection.has(row.dataset.filePath);box.checked=selected;row.classList.toggle('file-selected',selected);row.setAttribute('aria-selected',String(selected));
  }
  if($('file-selection-bar').hidden!==!rows.length)$('file-selection-bar').hidden=!rows.length;
  const count=`已选 ${diskFileSelection.size} / ${paths.size} 项`;if($('file-selection-count').textContent!==count)$('file-selection-count').textContent=count;
  $('file-copy-selected').disabled=!diskFileSelection.size;$('file-trash-selected').disabled=!diskFileSelection.size;
}
function selectFileRow(row,event,toggle=false){
  const path=row.dataset.filePath;
  if(event.shiftKey && diskFileAnchor){
    const paths=visibleFileRows().map(r=>r.dataset.filePath),a=paths.indexOf(diskFileAnchor),b=paths.indexOf(path);
    if(a>=0 && b>=0)for(const item of paths.slice(Math.min(a,b),Math.max(a,b)+1))diskFileSelection.add(item);
  }else if(toggle || event.metaKey || event.ctrlKey){if(diskFileSelection.has(path))diskFileSelection.delete(path);else diskFileSelection.add(path);diskFileAnchor=path;}
  else{diskFileSelection.clear();diskFileSelection.add(path);diskFileAnchor=path;}
  row.focus({preventScroll:true});fileSelectionSync();
  syncFileCleanupSelection();
}
function syncFileCleanupSelection(){
  if(storageInsights?.report){
    storageInsights.selected=new Set((storageInsights.visible || []).filter(item=>item.removable && diskFileSelection.has(item.entry.path)).slice(0,100).map(item=>item.entry.path));
    storageInsights.preview=false;$('disk-cleanup-preview').hidden=true;updateInsightSelection();
  }
}
function fileRowIndexedEntry(path){
  const candidates=[...(diskDirectory?.entries || []),...(diskWorkbench?.report?.rows || []).map(row=>row.entry),...(storageFiles?.page?.entries || []).map(row=>row.entry),...(storageInsights?.report?.items || []).map(item=>item.entry),...(storageInsights?.report?.apps || []).flatMap(app=>app.parts.map(part=>part.entry))];
  return candidates.find(entry=>entry?.path===path);
}
function openFileRow(row){
  const path=row.dataset.filePath,entry=fileRowIndexedEntry(path);
  if(entry?.directory){
    if(!entry.browsable){$('file-interaction-feedback').textContent='此目录当前无法在索引中浏览，请检查权限状态或等待索引更新。';return;}
    storageSection('directory');diskBrowse(path);return;
  }
  fileInteraction('open',[path]);
}
function installDiskFileInteractions(){
  const root=$('disk-analysis');
  root.addEventListener('click',event=>{
    const row=event.target.closest('[data-file-path]');if(!row)return;
    if(event.target.closest('[data-file-expand]')){event.preventDefault();event.stopImmediatePropagation();const details=row.closest('details');if(details){details.open=!details.open;event.target.closest('[data-file-expand]').setAttribute('aria-expanded',String(details.open));}return;}
    if(event.target.closest('[data-file-trash]')){
      event.preventDefault();event.stopImmediatePropagation();
      if(diskWorkbench?.mode==='duplicates'){
        const original=row.querySelector('[data-wb-action=trash]');
        if(original){original.click();return;}
        $('file-interaction-feedback').textContent='请先校验重复内容；保留副本不可删除。';return;
      }
      fileInteraction('trash',[row.dataset.filePath]);return;
    }
    if(event.target.closest('[data-file-select]')){event.preventDefault();event.stopImmediatePropagation();selectFileRow(row,event,true);queueMicrotask(fileSelectionSync);return;}
    if(event.target.closest('button:not(.disk-entry-main),a,input,select,textarea'))return;
    event.preventDefault();event.stopImmediatePropagation();selectFileRow(row,event);
  },true);
  root.addEventListener('dblclick',event=>{
    const row=event.target.closest('[data-file-path]');if(!row || event.button!==0 || event.target.closest('input,button:not(.disk-entry-main),a'))return;
    event.preventDefault();event.stopImmediatePropagation();openFileRow(row);
  },true);
  root.addEventListener('contextmenu',event=>{
    const row=event.target.closest('[data-file-path]');if(!row || event.target.closest('input:not([type=checkbox]),textarea'))return;
    event.preventDefault();event.stopImmediatePropagation();if(!diskFileSelection.has(row.dataset.filePath))selectFileRow(row,event);
    fileInteraction('menu',null,event);
  },true);
  root.addEventListener('keydown',event=>{
    if(event.target.closest('input,textarea,select,[contenteditable=true]'))return;
    if(event.key===' ' && diskFileSelection.size){event.preventDefault();event.stopImmediatePropagation();fileInteraction('preview');}
    else if((event.metaKey || event.ctrlKey) && event.key.toLowerCase()==='a' && visibleFileRows().length){event.preventDefault();$('file-select-all').click();}
    else if((event.metaKey || event.ctrlKey) && event.key.toLowerCase()==='c' && diskFileSelection.size){event.preventDefault();fileInteraction('copy');}
    else if(event.key==='Escape'){diskFileSelection.clear();fileSelectionSync();syncFileCleanupSelection();}
  },true);
  $('file-select-all').onclick=()=>{for(const row of visibleFileRows())diskFileSelection.add(row.dataset.filePath);fileSelectionSync();syncFileCleanupSelection();};
  $('file-clear-selection').onclick=()=>{diskFileSelection.clear();fileSelectionSync();syncFileCleanupSelection();};
  $('disk-cleanup-clear').addEventListener('click',()=>{diskFileSelection.clear();fileSelectionSync();});
  $('file-copy-selected').onclick=()=>fileInteraction('copy');
  $('file-trash-selected').onclick=()=>{
    if(diskWorkbench?.mode==='duplicates'){
      const rows=visibleFileRows().filter(row=>diskFileSelection.has(row.dataset.filePath) && row.querySelector('[data-wb-action=trash]'));
      if(!rows.length){$('file-interaction-feedback').textContent='请先校验内容，保留项及未校验文件不会处理。';return;}
      fileInteraction('trash',rows.map(row=>row.dataset.filePath));return;
    }
    fileInteraction('trash');
  };
  new MutationObserver(()=>fileSelectionSync()).observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden']});
  window.receiveDiskInteractionResult=result=>$('file-interaction-feedback').textContent=result.message;
  const previous=window.receiveDiskFileAction;
  window.receiveDiskFileAction=result=>{
    if(!result.operationID.startsWith('interaction-')){previous?.(result);return;}
    if(result.requestID!==diskScan?.requestID)return;
    $('file-interaction-feedback').textContent=result.message;
    if(result.success){diskFileSelection.clear();
      if(storageFiles?.mode==='large')requestLargeFiles(storageFiles.page?.offset || 0);
      else if(diskWorkbench)requestDiskWorkbench(diskWorkbench.report?.offset || 0);
      else if(storageInsights)requestStorageInsights();
      else diskBrowse(diskDirectory?.path || diskScan.rootPath || diskScan.volumePath);
      fileSelectionSync();
    }
  };
  window.receiveDiskOpenApplications=apps=>{
    $('file-open-applications').innerHTML=apps.map(app=>`<div class="file-open-app"><strong>${escapeHTML(app.name)}</strong><span class="muted">${escapeHTML(app.path || '未安装')}</span>${app.custom?`<button class="text-button" data-remove-open-app="${escapeHTML(app.path)}">移除</button>`:''}</div>`).join('');
  };
  $('file-add-application').onclick=()=>post('addDiskOpenApplication');
  $('file-open-applications').onclick=event=>{const button=event.target.closest('[data-remove-open-app]');if(button)post('removeDiskOpenApplication',{path:button.dataset.removeOpenApp});};
  fileSelectionSync();post('getDiskOpenApplications');
}
