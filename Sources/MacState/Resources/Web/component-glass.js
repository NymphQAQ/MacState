/* Geometry only: native AppKit owns the optical material; H5 owns content. */
(() => {
  const selector = [
    'button:not(.disk-map-tile):not(.disk-map-legend-row):not(.disk-type-card)', '.segmented',
    '.summary-tile', '.metric-card', '.metric-section', '.core-grid', '.notice',
    '.settings-section', '.menu-column', '.menu-style-grid fieldset', '.menu-preview',
    '.table-wrap', '.order-chip', '.usage-chart-card', '.usage-app-card',
    '.usage-summary > article', '.usage-app-summary', '.usage-process-scroll', '.usage-mode',
    'select', 'input[type="search"]', 'input[type="text"]', 'input[type="number"]'
  ].join(',');
  let tracking = false, enabled = false, scheduled = false, lastPayload = '';
  const observed = new Set();
  const resize = new ResizeObserver(schedule);
  const mutation = new MutationObserver(schedule);

  function schedule() {
    if (!tracking || scheduled) return;
    scheduled = true;
    // WebKit suspends animation frames while a panel is ordered out. A bounded
    // timer keeps the first layout ready when that panel is shown again.
    let frame, timer;
    const flush = () => {
      if (!scheduled) return;
      scheduled = false;
      cancelAnimationFrame(frame); clearTimeout(timer);
      if (tracking) collect();
    };
    frame = requestAnimationFrame(flush);
    timer = setTimeout(flush,80);
  }
  function intersection(a, b) {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    return {x, y, width: Math.max(0, Math.min(a.x+a.width, b.x+b.width)-x), height: Math.max(0, Math.min(a.y+a.height, b.y+b.height)-y)};
  }
  function identity(element) {
    const path = [];
    for (let node = element; node && node !== document.body; node = node.parentElement) {
      if (node.id) { path.unshift('#'+node.id); break; }
      path.unshift(node.tagName+':'+Array.prototype.indexOf.call(node.parentElement.children, node));
    }
    return path.join('/');
  }
  function geometry(element, id, rect = element.getBoundingClientRect()) {
    if (rect.width < 10 || rect.height < 10 || !element.getClientRects().length) return null;
    let clip = intersection(rect, {x:0,y:0,width:innerWidth,height:innerHeight});
    // Fixed footer paints above scrolling page content, not above the sidebar.
    if (element.closest('main')) {
      const footer = document.querySelector('footer')?.getBoundingClientRect();
      if (footer) clip = intersection(clip, {x:0,y:0,width:innerWidth,height:footer.top});
    }
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      if (/(hidden|clip|scroll|auto)/.test(style.overflowX+' '+style.overflowY)) {
        const bounds = parent.getBoundingClientRect();
        // Only clip the axes this ancestor actually clips.
        const area = {
          x: /(hidden|clip|scroll|auto)/.test(style.overflowX) ? bounds.left : 0,
          y: /(hidden|clip|scroll|auto)/.test(style.overflowY) ? bounds.top : 0,
          width: /(hidden|clip|scroll|auto)/.test(style.overflowX) ? bounds.width : innerWidth,
          height: /(hidden|clip|scroll|auto)/.test(style.overflowY) ? bounds.height : innerHeight
        };
        clip = intersection(clip, area);
      }
    }
    if (clip.width < 1 || clip.height < 1 || getComputedStyle(element).visibility === 'hidden') return null;
    const radiusText = getComputedStyle(element).borderTopLeftRadius;
    let radius = parseFloat(radiusText) || 0;
    if (radiusText.includes('%')) radius = Math.min(rect.width, rect.height)*radius/100;
    const round = n => Math.round(n*2)/2;
    return {id, x:round(rect.x),y:round(rect.y),width:round(rect.width),height:round(rect.height),
      clipX:round(clip.x),clipY:round(clip.y),clipWidth:round(clip.width),clipHeight:round(clip.height),radius:round(radius)};
  }
  function collect() {
    // Economical mode only tracks the drag handle. H5 tinted cards share the
    // window blur; avoid measuring every card and control on every sample.
    const elements = new Set(enabled ? document.querySelectorAll(selector) : []);
    for (const element of observed) if (!elements.has(element)) { resize.unobserve(element); observed.delete(element); }
    const components = [];
    for (const element of elements) {
      if (element.closest('th')) continue;
      if (!observed.has(element)) { observed.add(element); resize.observe(element); }
      const item = geometry(element, identity(element));
      if (!item) { delete element.dataset.nativeGlass; continue; }
      element.dataset.nativeGlass = 'true';
      if (components.length < 256) components.push(item);
      else delete element.dataset.nativeGlass;
    }
    const header = document.querySelector('header');
    let dragRegion = null;
    if (header) {
      const rect = header.getBoundingClientRect();
      const actions = header.querySelector('.header-actions')?.getBoundingClientRect();
      dragRegion = geometry(header, 'window-drag', {x:rect.x,y:rect.y,width:Math.max(0,(actions?.left ?? rect.right)-rect.left-10),height:rect.height});
    }
    const sidebar=document.querySelector('.sidebar'),nav=sidebar?.querySelector('nav'),bottom=sidebar?.querySelector('.sidebar-bottom');
    let sidebarDragRegion=null;
    if(sidebar && nav && bottom) {
      const bounds=sidebar.getBoundingClientRect(),top=nav.getBoundingClientRect().bottom+4,end=bottom.getBoundingClientRect().top-4;
      sidebarDragRegion=geometry(sidebar,'sidebar-drag',{x:bounds.x,y:top,width:bounds.width,height:Math.max(0,end-top)});
    }
    const layout = {components,dragRegion,sidebarDragRegion};
    const payload = JSON.stringify(layout);
    if (payload !== lastPayload) {
      lastPayload = payload;
      window.webkit?.messageHandlers.macstate.postMessage({action:'glassLayout',layout});
    }
  }
  window.setComponentGlassEnabled = value => {
    tracking = Boolean(window.webkit?.messageHandlers.macstate);
    enabled = Boolean(value && tracking);
    document.body.classList.toggle('native-component-glass',enabled);
    document.body.classList.toggle('economical-glass',!enabled);
    if (!enabled) document.querySelectorAll('[data-native-glass]').forEach(element=>delete element.dataset.nativeGlass);
    lastPayload='';
    if (tracking) {
      mutation.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class','style','hidden','open']});
      resize.observe(document.documentElement);
      schedule();
    } else {
      mutation.disconnect(); resize.disconnect(); observed.clear(); lastPayload='';
    }
  };
  addEventListener('resize',schedule);
  addEventListener('scroll',schedule,true);
})();
