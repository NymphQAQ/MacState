// Side buttons browse directory history only, within the current volume session.
let directoryNavigationEntries=[],directoryNavigationPosition=-1,directoryNavigationRequest='',directoryNavigationReplaying=false;
function isDirectoryNavigationPage(){
  return view==='storage' && !!diskScan && !$('disk-analysis').hidden && !$('disk-directory-view').hidden && !diskWorkbench && !storageInsights && !diskMap && !storageFiles;
}
function recordDirectoryNavigation(path){
  if(!diskScan || !path)return;
  if(directoryNavigationRequest!==diskScan.requestID){directoryNavigationEntries=[];directoryNavigationPosition=-1;directoryNavigationRequest=diskScan.requestID;}
  if(directoryNavigationReplaying || directoryNavigationEntries[directoryNavigationPosition]===path)return;
  directoryNavigationEntries.splice(directoryNavigationPosition+1);
  directoryNavigationEntries.push(path);
  if(directoryNavigationEntries.length>100)directoryNavigationEntries.shift();
  directoryNavigationPosition=directoryNavigationEntries.length-1;
}
window.navigateHistory=direction=>{
  if(!isDirectoryNavigationPage() || directoryNavigationReplaying || document.querySelector('dialog[open]'))return;
  if(directoryNavigationRequest!==diskScan.requestID)return;
  const next=directoryNavigationPosition+(direction<0?-1:1);
  if(next<0 || next>=directoryNavigationEntries.length)return;
  directoryNavigationReplaying=true;directoryNavigationPosition=next;
  try{diskBrowse(directoryNavigationEntries[next]);}
  finally{directoryNavigationReplaying=false;}
};
