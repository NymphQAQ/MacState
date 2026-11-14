let screenshotState=null,shotRecording=null;
const shotModes={region:'区域截屏',window:'窗口截屏',screen:'全屏截屏',long:'长截屏',edited:'标注副本'};
const shotKeyCodes={KeyA:0,KeyS:1,KeyD:2,KeyF:3,KeyH:4,KeyG:5,KeyZ:6,KeyX:7,KeyC:8,KeyV:9,KeyB:11,KeyQ:12,KeyW:13,KeyE:14,KeyR:15,KeyY:16,KeyT:17,Digit1:18,Digit2:19,Digit3:20,Digit4:21,Digit6:22,Digit5:23,Equal:24,Digit9:25,Digit7:26,Minus:27,Digit8:28,Digit0:29,BracketRight:30,KeyO:31,KeyU:32,BracketLeft:33,KeyI:34,KeyP:35,Enter:36,KeyL:37,KeyJ:38,Quote:39,KeyK:40,Semicolon:41,Backslash:42,Comma:43,Slash:44,KeyN:45,KeyM:46,Period:47,Tab:48,Space:49,Backquote:50,Backspace:51,F1:122,F2:120,F3:99,F4:118,F5:96,F6:97,F7:98,F8:100,F9:101,F10:109,F11:103,F12:111,ArrowLeft:123,ArrowRight:124,ArrowDown:125,ArrowUp:126};
function renderScreenshots(){if(!screenshotState)post('getScreenshotState');}
function stopScreenshotShortcutRecording(){
  if(!shotRecording)return;shotRecording=null;post('suspendScreenshotShortcuts',{suspended:false});
  document.querySelectorAll('[data-shot-shortcut]').forEach(input=>{input.placeholder='点击录制快捷键';});
}
function shotFeedback(text){$('shot-settings-feedback').textContent=text;}
function renderShotState(){
  if(!screenshotState)return;
  const state=screenshotState,c=state.settings;
  $('shot-permission').hidden=state.permission;
  $('shot-status').textContent=state.message || '截屏不会隐藏任何现有窗口。区域或窗口选择按 Esc 取消。';
  shotFeedback(state.message || '');
  $('shot-shortcut-error').textContent=state.hotkeyError;
  $('shot-cancel').disabled=!state.canCancel;
  document.querySelectorAll('[data-shot-capture]').forEach(button=>button.disabled=state.busy);
  const selectedDisplay=$('shot-display').value || '1';
  $('shot-display').innerHTML='<option value="0">所有显示器（分别保存）</option>'+state.displays.map((name,i)=>`<option value="${i+1}">${escapeHTML(name)}</option>`).join('');
  $('shot-display').value=[...$('shot-display').options].some(o=>o.value===selectedDisplay)?selectedDisplay:'1';
  const active=document.activeElement;
  for(const key of ['destination','format','prefix','delay'])if(active!==$('shot-'+key))$('shot-'+key).value=c[key];
  for(const key of ['pointer','shadow','preview'])$('shot-'+key).checked=c[key];
  $('shot-directory').textContent=c.directory;
  if(!shotRecording)$('shot-shortcuts').innerHTML=['region','window','screen'].map(mode=>{const item=c.shortcuts[mode];return `<label>${shotModes[mode]}<input type="text" readonly data-shot-shortcut="${mode}" value="${escapeHTML(item.enabled?item.label:'未设置')}" aria-label="${shotModes[mode]}快捷键"><button class="text-button" data-shot-shortcut-clear="${mode}">停用</button></label>`;}).join('');
  $('shot-history-count').textContent=`${state.records.length} / 100 张`;
  $('shot-history').innerHTML=state.records.map(record=>`<article class="metric-card shot-history-card"><button type="button" class="shot-thumbnail" data-shot-edit="${record.id}" ${state.busy?'disabled':''} aria-label="编辑 ${escapeHTML(shotModes[record.mode] || '截图')}"><img src="${record.thumbnail}" alt="${escapeHTML(shotModes[record.mode] || '截图')}" loading="lazy"></button><strong>${escapeHTML(shotModes[record.mode] || '截图')} ${record.width}×${record.height}</strong><small class="muted">${escapeHTML(new Date(record.date*1000).toLocaleString())}</small><div class="shot-card-actions" role="group" aria-label="截图操作">
    <button type="button" class="button shot-card-action" data-shot-edit="${record.id}" ${state.busy?'disabled':''} title="编辑" aria-label="编辑"><span class="glyph i-pencil" aria-hidden="true"></span></button>
    <button type="button" class="button shot-card-action" data-shot-copy="${record.id}" ${state.busy?'disabled':''} title="拷贝" aria-label="拷贝"><span class="glyph i-copy" aria-hidden="true"></span></button>
    <button type="button" class="button shot-card-action" data-shot-reveal="${record.id}" title="在 Finder 中显示" aria-label="在 Finder 中显示"><span class="glyph i-folder-open" aria-hidden="true"></span></button>
    <button type="button" class="button shot-card-action danger" data-shot-trash="${record.id}" ${state.busy?'disabled':''} title="移到废纸篓" aria-label="移到废纸篓"><span class="glyph i-trash-2" aria-hidden="true"></span></button>
  </div></article>`).join('') || '<p class="muted">还没有截图。点击上方按钮，或使用自定义快捷键。</p>';
}
function saveShotSettings(){
  if(!screenshotState)return;
  const c=structuredClone(screenshotState.settings);
  for(const key of ['destination','format','prefix'])c[key]=$('shot-'+key).value;
  c.delay=Math.max(0,Math.min(30,Math.round(Number($('shot-delay').value)||0)));
  for(const key of ['pointer','shadow','preview'])c[key]=$('shot-'+key).checked;
  shotFeedback('保存中…');post('saveScreenshotSettings',{settings:c});
}
function installScreenshots(){
  document.querySelectorAll('[data-shot-capture]').forEach(button=>button.onclick=()=>post('captureScreenshot',{mode:button.dataset.shotCapture,display:Number($('shot-display').value)||0}));
  $('shot-cancel').onclick=()=>post('cancelScreenshot');
  $('shot-settings-toggle').onclick=()=>{window.openSettings();selectSettingsCategory('screenshot');};
  $('shot-permission-open').onclick=()=>post('openScreenshotPermission');$('shot-permission-check').onclick=()=>post('getScreenshotState');
  $('shot-choose-directory').onclick=()=>post('screenshotDirectory');$('shot-shortcuts-reset').onclick=()=>{stopScreenshotShortcutRecording();post('resetScreenshotShortcuts');};
  for(const key of ['destination','format','prefix','delay','pointer','shadow','preview'])$('shot-'+key).onchange=saveShotSettings;
  $('shot-shortcuts').addEventListener('focusin',event=>{const input=event.target.closest('[data-shot-shortcut]');if(!input)return;shotRecording=input.dataset.shotShortcut;input.value='按下组合键…';post('suspendScreenshotShortcuts',{suspended:true});});
  $('shot-shortcuts').addEventListener('focusout',()=>setTimeout(()=>{if(!document.activeElement?.matches('[data-shot-shortcut]'))stopScreenshotShortcutRecording();},0));
  $('shot-shortcuts').onclick=event=>{const clear=event.target.closest('[data-shot-shortcut-clear]');if(clear && screenshotState){stopScreenshotShortcutRecording();const c=structuredClone(screenshotState.settings);c.shortcuts[clear.dataset.shotShortcutClear].enabled=false;post('saveScreenshotSettings',{settings:c});}};
  $('shot-shortcuts').onkeydown=event=>{
    if(!shotRecording)return;event.preventDefault();event.stopPropagation();
    if(event.key==='Escape'){event.target.blur();stopScreenshotShortcutRecording();return;}
    if(/^(Control|Alt|Shift|Meta)$/.test(event.key))return;
    const code=shotKeyCodes[event.code],modifiers=(event.metaKey?256:0)+(event.shiftKey?512:0)+(event.altKey?2048:0)+(event.ctrlKey?4096:0);
    if(code==null || !(event.metaKey || event.altKey || event.ctrlKey)){$('shot-shortcut-error').textContent='请选择包含 ⌘ / ⌃ / ⌥ 的组合键。';return;}
    const label=(event.ctrlKey?'⌃':'')+(event.altKey?'⌥':'')+(event.shiftKey?'⇧':'')+(event.metaKey?'⌘':'')+(event.code.startsWith('Key')?event.code.slice(3):event.code.startsWith('Digit')?event.code.slice(5):event.code);
    const c=structuredClone(screenshotState.settings),mode=shotRecording;c.shortcuts[mode]={keyCode:code,modifiers,label,enabled:true};shotRecording=null;event.target.blur();post('saveScreenshotSettings',{settings:c});
  };
  $('shot-history').onclick=event=>{const edit=event.target.closest('[data-shot-edit]');if(edit){post('editScreenshotRecord',{id:edit.dataset.shotEdit});return;}for(const [key,action] of [['shotCopy','copyScreenshotRecord'],['shotReveal','revealScreenshot'],['shotTrash','trashScreenshot']]){const element=event.target.closest('[data-'+key.replace(/[A-Z]/g,m=>'-'+m.toLowerCase())+']');if(element){post(action,{id:element.dataset[key]});return;}}};
  window.receiveScreenshotState=state=>{screenshotState=state;renderShotState();};
}
