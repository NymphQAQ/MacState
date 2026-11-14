let diskMap = null, diskMapFrame = 0;
const diskMapKinds = {folder:'文件夹',image:'图片',audio:'音频',video:'视频',text:'文本',document:'文档',archive:'压缩包',application:'应用',link:'符号链接',other:'其他文件',development:'开发文件',model:'模型文件',metadata:'目录元数据'};
const diskMapColors = {folder:'#5aa9ff',image:'#32d74b',audio:'#ff7b72',video:'#ffb340',text:'#69d2c5',document:'#8bc8ed',archive:'#d4ad72',application:'#a9d9af',link:'#aab8c6',other:'#909b96',development:'#69d2c5',model:'#d4ad72',metadata:'#64736c'};
function diskMapName(node) { return diskMap?.mode==='types' ? diskMapKinds[node.kind] || node.name : node.name; }

function closeDiskMap() {
  if(diskMap)post('cancelDiskSpaceMap');
  diskMap=null;cancelAnimationFrame(diskMapFrame);
  $('disk-map-view').hidden=true;
}
function requestDiskMap(path) {
  if(!diskMap || !diskScan)return;
  diskMap.path=path;diskMap.mapID=crypto.randomUUID();diskMap.loading=true;
  $('disk-map-summary').textContent='正在读取本地索引…';
  $('disk-map-canvas').setAttribute('aria-busy','true');
  $('disk-map-view').classList.add('map-loading');
  $('disk-map-refresh').disabled=true;
  document.querySelectorAll('[data-map-mode]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.mapMode===diskMap.mode)));
  post('diskSpaceMap',{requestID:diskScan.requestID,mapID:diskMap.mapID,path,mode:diskMap.mode});
}

// Squarified strips keep large regions close to squares. Areas are proportional
// to bytes; tiny/zero regions remain available through the adjacent project list.
function diskMapLayout(nodes,width,height) {
  const total=nodes.reduce((sum,node)=>sum+node.bytes,0);
  if(!total || width<=0 || height<=0)return [];
  const remaining=nodes.map((node,index)=>({index,area:node.bytes/total*width*height})).filter(item=>item.area>0).sort((a,b)=>b.area-a.area);
  let rect={x:0,y:0,w:width,h:height},offset=0;
  const output=[];
  const worst=(row,side)=>{
    const sum=row.reduce((s,item)=>s+item.area,0),max=Math.max(...row.map(item=>item.area)),min=Math.min(...row.map(item=>item.area));
    return Math.max(side*side*max/(sum*sum),sum*sum/(side*side*min));
  };
  while(offset<remaining.length && rect.w>0 && rect.h>0) {
    const side=Math.min(rect.w,rect.h),row=[remaining[offset++]];
    while(offset<remaining.length && worst([...row,remaining[offset]],side)<=worst(row,side))row.push(remaining[offset++]);
    const sum=row.reduce((s,item)=>s+item.area,0);
    let cursor=rect.w>=rect.h?rect.y:rect.x;
    if(rect.w>=rect.h) {
      const strip=Math.min(rect.w,sum/rect.h);
      for(const item of row){const h=item.area/strip;output.push({index:item.index,x:rect.x,y:cursor,w:strip,h});cursor+=h;}
      rect={...rect,x:rect.x+strip,w:Math.max(0,rect.w-strip)};
    } else {
      const strip=Math.min(rect.h,sum/rect.w);
      for(const item of row){const w=item.area/strip;output.push({index:item.index,x:cursor,y:rect.y,w,h:strip});cursor+=w;}
      rect={...rect,y:rect.y+strip,h:Math.max(0,rect.h-strip)};
    }
  }
  return output;
}
function drawDiskMap() {
  if(!diskMap?.page || $('disk-map-view').hidden)return;
  const canvas=$('disk-map-canvas'),{width,height}=canvas.getBoundingClientRect(),page=diskMap.page;
  if(width<=0 || height<=0)return;
  const fragment=document.createDocumentFragment();
  for(const rect of diskMapLayout(page.nodes,width,height)) {
    if(rect.w<4 || rect.h<4)continue;
    const node=page.nodes[rect.index],name=diskMapName(node),button=document.createElement('button');
    button.className='disk-map-tile';button.dataset.mapNode=rect.index;
    button.style.cssText=`left:${rect.x}px;top:${rect.y}px;width:${rect.w}px;height:${rect.h}px;--tile-color:${diskMapColors[node.kind] || diskMapColors.other}`;
    button.title=`${name} ${diskBytes(node.bytes)}${node.path?'\n'+node.path:''}`;
    button.setAttribute('aria-label',`${name}，实际占用 ${diskBytes(node.bytes)}${node.browsable?'，双击或在详情中进入文件夹':''}`);
    button.setAttribute('aria-pressed',String(diskMap.selected===rect.index));
    if(rect.w>56 && rect.h>34){const label=document.createElement('strong');label.textContent=name;button.append(label);if(rect.h>54){const size=document.createElement('span');size.textContent=diskBytes(node.bytes);button.append(size);}}
    fragment.append(button);
  }
  if(!fragment.childNodes.length){const empty=document.createElement('div');empty.className='empty';empty.textContent='此目录没有已计入实际占用的项目';fragment.append(empty);}
  canvas.replaceChildren(fragment);
}
function selectDiskMapNode(index) {
  if(!diskMap?.page)return;
  const node=diskMap.page.nodes[index];if(!node)return;
  diskMap.selected=index;
  document.querySelectorAll('[data-map-node]').forEach(button=>button.setAttribute('aria-pressed',String(Number(button.dataset.mapNode)===index)));
  const percent=diskMap.page.bytes?node.bytes/diskMap.page.bytes*100:0;
  $('disk-map-selection').innerHTML=`<strong>${escapeHTML(diskMapName(node))}</strong><div class="disk-map-selected-size">${diskBytes(node.bytes)}</div><p class="muted">${percent.toFixed(2)}% ${node.files.toLocaleString()} 个文件</p>${node.path?`<p class="disk-map-selected-path muted">${escapeHTML(node.path)}</p>`:'<p class="muted">汇总区域，不对应单个文件</p>'}<div class="disk-map-selected-actions">${node.browsable?'<button class="button" id="disk-map-enter">进入文件夹</button>':''}${!node.synthetic && node.path?'<button class="button" id="disk-map-reveal">Finder 定位</button>':''}</div>`;
  if($('disk-map-enter'))$('disk-map-enter').onclick=()=>requestDiskMap(node.path);
  if($('disk-map-reveal'))$('disk-map-reveal').onclick=()=>post('revealDiskEntry',{requestID:diskScan.requestID,path:node.path});
}
function installDiskSpaceMap() {
  $('disk-map-open').onclick=()=>{
    if(!diskScan)return;
    if(typeof closeStorageFiles==='function')closeStorageFiles();
    if(typeof closeStorageInsights==='function')closeStorageInsights();
  if(typeof closeDiskWorkbench==='function')closeDiskWorkbench();
    $('disk-directory-view').hidden=true;$('disk-largest-view').hidden=true;$('disk-map-view').hidden=false;
    diskMap={mode:'folders',page:null,selected:-1,breadcrumbs:[]};
    $('disk-map-canvas').innerHTML='<div class="empty">正在读取本地索引…</div>';
    $('disk-map-legend').textContent='';$('disk-map-crumbs').textContent='';$('disk-map-up').disabled=true;
    $('disk-map-note').textContent='';$('disk-map-selection').innerHTML='<p class="muted">选择方块查看占用详情</p>';
    requestDiskMap(!diskDirectory?.filtered?diskDirectory?.path || diskScan.rootPath || '':diskScan.rootPath || '');
  };
  $('disk-map-back').onclick=()=>{closeDiskMap();$('disk-directory-view').hidden=false;$('disk-map-open').focus();};
  $('disk-map-refresh').onclick=()=>{if(diskMap)requestDiskMap(diskMap.path);};
  $('disk-map-up').onclick=()=>{const crumbs=diskMap?.breadcrumbs;if(crumbs?.length>1)requestDiskMap(crumbs[crumbs.length-2].path);};
  $('disk-map-crumbs').onclick=event=>{const button=event.target.closest('[data-map-path]');if(button)requestDiskMap(button.dataset.mapPath);};
  $('disk-map-current-reveal').onclick=()=>{if(diskMap && diskScan)post('revealDiskEntry',{requestID:diskScan.requestID,path:diskMap.path});};
  document.querySelectorAll('[data-map-mode]').forEach(button=>button.onclick=()=>{if(diskMap){diskMap.mode=button.dataset.mapMode;requestDiskMap(diskMap.path);}});
  for(const id of ['disk-map-canvas','disk-map-legend'])$(id).onclick=event=>{const button=event.target.closest('[data-map-node]');if(button)selectDiskMapNode(Number(button.dataset.mapNode));};
  $('disk-map-canvas').ondblclick=event=>{const button=event.target.closest('[data-map-node]'),node=button?diskMap?.page?.nodes[Number(button.dataset.mapNode)]:null;if(node?.browsable)requestDiskMap(node.path);};
  new ResizeObserver(()=>{cancelAnimationFrame(diskMapFrame);diskMapFrame=requestAnimationFrame(drawDiskMap);}).observe($('disk-map-canvas'));
  window.receiveDiskSpaceMap=page=>{
    if(!diskMap || !diskScan || page.requestID!==diskScan.requestID || page.mapID!==diskMap.mapID)return;
    diskMap.loading=false;$('disk-map-view').classList.remove('map-loading');$('disk-map-refresh').disabled=false;$('disk-map-canvas').setAttribute('aria-busy','false');
    if(page.error){diskMap.page=null;$('disk-map-summary').textContent=page.error;$('disk-map-canvas').innerHTML='<div class="empty">暂时无法显示地图，可返回上一级或刷新重试</div>';$('disk-map-legend').textContent='';$('disk-map-selection').textContent='';return;}
    diskMap.page=page;diskMap.path=page.path;diskMap.selected=-1;diskMap.breadcrumbs=page.breadcrumbs;
    $('disk-map-summary').textContent=`${diskBytes(page.bytes)} ${page.files.toLocaleString()} 个文件 ${page.mode==='types'?'当前目录全部后代按类型汇总':'当前目录直接子项'} ${new Date(page.updated*1000).toLocaleTimeString()} 的索引快照`;
    $('disk-map-crumbs').innerHTML=page.breadcrumbs.map(crumb=>`<button class="text-button" data-map-path="${escapeHTML(crumb.path)}">${escapeHTML(crumb.name)}</button>`).join('<span aria-hidden="true">›</span>');
    $('disk-map-up').disabled=page.breadcrumbs.length<=1;
    $('disk-map-note').textContent=[page.omitted?`较小的 ${page.omitted.toLocaleString()} 项已汇总至“其他项目及目录元数据”；完整明细可返回目录分析查看。`:'',page.skipped?`${page.skipped.toLocaleString()} 项受限或已跳过，未完整计入。`:'','按实际分配空间统计，硬链接沿用索引去重；快照及 APFS 共享块可能造成与存储卷已用空间不同。文件变化后可刷新地图。'].filter(Boolean).join(' ');
    $('disk-map-selection').innerHTML='<p class="muted">选择方块查看占用详情</p>';
    $('disk-map-legend').innerHTML=page.nodes.map((node,index)=>`<button class="disk-map-legend-row" data-map-node="${index}" aria-pressed="false"><span class="disk-map-swatch" style="background:${diskMapColors[node.kind] || diskMapColors.other}"></span><span>${escapeHTML(diskMapName(node))}</span><strong>${diskBytes(node.bytes)}</strong></button>`).join('');
    drawDiskMap();
  };
}
