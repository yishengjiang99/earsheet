// Shared chrome: status bar + home indicator.
document.querySelectorAll('[data-status]').forEach(el=>{
  el.className='status '+(el.dataset.status||'');
  el.innerHTML=`<span>9:41</span><span class="icons"><span class="bars"><i style="height:4px"></i><i style="height:6px"></i><i style="height:9px"></i><i style="height:12px"></i></span>
  <svg width="17" height="12" viewBox="0 0 17 12"><path d="M8.5 11.5l2.6-3.1a4 4 0 00-5.2 0zM3.6 6.3a7.4 7.4 0 019.8 0l1.4-1.6a9.6 9.6 0 00-12.6 0zM.6 2.9a12 12 0 0115.8 0L17.7 1.4A14 14 0 00-.7 1.4z" fill="currentColor"/></svg>
  <span class="batt">92</span></span>`;
});
document.querySelectorAll('[data-home]').forEach(el=>el.className='home');
const X='<svg viewBox="0 0 12 12"><path d="M1 1l10 10M11 1L1 11" stroke="#1C1C1C" stroke-width="1.8" stroke-linecap="round"/></svg>';
document.querySelectorAll('.close').forEach(el=>el.innerHTML=X);
const LOCK='<svg class="lock" viewBox="0 0 12 12"><rect x="2" y="5.2" width="8" height="6" rx="1.4" fill="currentColor"/><path d="M3.8 5.4V3.8a2.2 2.2 0 014.4 0v1.6" stroke="currentColor" stroke-width="1.4" fill="none"/></svg>';
document.querySelectorAll('[data-lock]').forEach(el=>el.insertAdjacentHTML('afterbegin',LOCK));
