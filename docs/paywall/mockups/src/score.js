// Draws a simple engraved staff (treble clef, 4/4, beamed eighths) into every <svg data-staff>.
// data-notes: comma list of staff steps (0 = bottom line E4, 1 = F4 space, ...). '|' = barline.
function drawStaff(svg){
  const W=+svg.getAttribute('width'), H=+svg.getAttribute('height');
  const gap=+(svg.dataset.gap||10), top=(H-4*gap)/2, ink='#1C1C1C';
  const hl=(svg.dataset.hl||'').split(',').filter(Boolean).map(Number);
  const fade=svg.dataset.fade? +svg.dataset.fade : null;
  let s='';
  for(let i=0;i<5;i++) s+=`<line x1="4" x2="${W-4}" y1="${top+i*gap}" y2="${top+i*gap}" stroke="${ink}" stroke-width="1.1" opacity=".75"/>`;
  s+=`<text x="6" y="${top+3*gap+gap*0.05}" font-family="Noto Music" font-size="${gap*4.1}" fill="${ink}">𝄞</text>`;
  if(svg.dataset.time!=='no'){
    s+=`<text x="${gap*3.6}" y="${top+gap*1.85}" font-family="Libre Caslon Text,serif" font-weight="700" font-size="${gap*2.1}" fill="${ink}">4</text>`;
    s+=`<text x="${gap*3.6}" y="${top+gap*3.85}" font-family="Libre Caslon Text,serif" font-weight="700" font-size="${gap*2.1}" fill="${ink}">4</text>`;
  }
  const toks=svg.dataset.notes.split(',');
  const x0=svg.dataset.time==='no'? gap*4.2 : gap*6.4; const dx=(W-x0-gap)/toks.length;
  const pts=[]; let idx=0;
  toks.forEach((t,i)=>{
    const x=x0+i*dx+dx*0.35;
    if(t==='|'){ s+=`<line x1="${x}" x2="${x}" y1="${top}" y2="${top+4*gap}" stroke="${ink}" stroke-width="1.2"/>`; pts.push(null); return;}
    const st=+t, y=top+4*gap-st*gap/2; const n=idx++;
    pts.push({x,y,st,n});
  });
  // beam in pairs
  const notes=pts.filter(Boolean);
  for(let i=0;i<notes.length;i++){
    const p=notes[i]; const col=hl.includes(p.n)?'#0C6B6B':ink;
    const op=(fade!==null && p.n>=fade)? .28:1;
    // ledger lines
    for(let l=-2;l>=p.st;l-=2){const ly=top+4*gap-l*gap/2;s+=`<line x1="${p.x-gap*.95}" x2="${p.x+gap*.95}" y1="${ly}" y2="${ly}" stroke="${ink}" stroke-width="1.1" opacity="${op}"/>`}
    for(let l=10;l<=p.st;l+=2){const ly=top+4*gap-l*gap/2;s+=`<line x1="${p.x-gap*.95}" x2="${p.x+gap*.95}" y1="${ly}" y2="${ly}" stroke="${ink}" stroke-width="1.1" opacity="${op}"/>`}
    s+=`<ellipse cx="${p.x}" cy="${p.y}" rx="${gap*.62}" ry="${gap*.44}" transform="rotate(-20 ${p.x} ${p.y})" fill="${col}" opacity="${op}"/>`;
  }
  for(let i=0;i+1<notes.length;i+=2){
    const a=notes[i],b=notes[i+1]; const up=(a.st+b.st)/2<4; const sx=up? gap*.56:-gap*.56;
    const op=(fade!==null && a.n>=fade)? .28:1;
    const ya=up? Math.min(a.y,b.y)-gap*3.2 : Math.max(a.y,b.y)+gap*3.2;
    s+=`<line x1="${a.x+sx}" x2="${a.x+sx}" y1="${a.y}" y2="${ya}" stroke="${ink}" stroke-width="1.3" opacity="${op}"/>`;
    s+=`<line x1="${b.x+sx}" x2="${b.x+sx}" y1="${b.y}" y2="${ya}" stroke="${ink}" stroke-width="1.3" opacity="${op}"/>`;
    s+=`<line x1="${a.x+sx-.6}" x2="${b.x+sx+.6}" y1="${ya}" y2="${ya}" stroke="${ink}" stroke-width="${gap*.48}" opacity="${op}"/>`;
  }
  svg.innerHTML=s;
}
document.querySelectorAll('svg[data-staff]').forEach(drawStaff);
