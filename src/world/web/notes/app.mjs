import {validateDocument,encodeDocument,makeNote,seedDocument,linksIn,visibleNotes,toggleTask,moveNote} from './model.mjs';

const $=id=>document.getElementById(id);
const reduced=matchMedia('(prefers-reduced-motion: reduce)');
let notebook=null, current=null, filter='all', mode='split', revision=0, saved=0, sent=0;
let saveTimer=0, previewTimer=0, closing=false, lastError='', drag=null, opened=false;
const send=(name,value)=>window.ataxiaUiSend(name,value);
const note=()=>notebook?.notes.find(n=>n.id===current);
const title=n=>n.title.trim()||'Untitled note';
const resolve=name=>notebook.notes.find(n=>title(n).toLocaleLowerCase()===name.toLocaleLowerCase());
function element(tag,text,className) {
  const node=document.createElement(tag);
  if(text!==undefined)node.textContent=text;
  if(className)node.className=className;
  return node;
}
function action(text,fn,className) {
  const node=element('button',text,className); node.dataset.action='noop';
  node.addEventListener('click',event=>{event.stopPropagation();fn();}); return node;
}
function animate(node,frames,options={}) {
  if(!reduced.matches)node.animate(frames,{duration:170,easing:'ease-out',...options});
}
function status(message,error=false) {
  $('save-state').textContent=message; $('save-state').classList.toggle('error',error);
  $('retry-save').hidden=!error||!notebook;
}
function dirty() {
  revision++; closing=false; status('Unsaved');
  clearTimeout(saveTimer); saveTimer=setTimeout(flush,350);
}
function flush() {
  clearTimeout(saveTimer);saveTimer=0;
  if(!notebook||revision<=saved)return;
  if(sent>saved)return; // At most one document in flight; the ack sends the latest edit.
  try {
    const data=encodeDocument(notebook);
    sent=revision;status('Saving…');send('notebook-save',`${revision}\n${data}`);
  } catch(error) {status(error.message,true);closing=false;}
}
function close() {
  if(!notebook||revision<=saved){send('notebook-hide',null);return;}
  closing=true;flush();
}
function changed() {
  note().updated=Date.now(); dirty(); updateContext();
}
function updateContext() {
  const n=note();
  $('context').textContent=n?`${n.body.trim()?n.body.trim().split(/\s+/).length:0} words · ${n.body.length} characters${n.archived?' · Archived':''}`:
    `${visibleNotes(notebook.notes,$('find').value,filter).length} notes · Drag Move to rearrange · [[Title]] links notes`;
}
function inline(parent,text) {
  const pattern=/\[\[([^\]\n]+)\]\]|\*\*([^*\n]+)\*\*|`([^`\n]+)`/g;
  let start=0;
  for(const match of text.matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(start,match.index)));
    if(match[1]) {
      const name=match[1].trim(),target=resolve(name);
      parent.append(action(name,()=>openLink(name),`wiki-link${target?'':' missing'}`));
    } else parent.append(element(match[2]?'strong':'code',match[2]||match[3]));
    start=match.index+match[0].length;
  }
  parent.append(document.createTextNode(text.slice(start)));
}
function renderReading() {
  clearTimeout(previewTimer);previewTimer=0;
  const n=note();if(!n)return;
  const fragment=document.createDocumentFragment(),lines=n.body.split('\n');
  let paragraph=[];
  const finish=()=>{if(paragraph.length){const p=element('p');inline(p,paragraph.join('\n'));fragment.append(p);paragraph=[];}};
  for(let i=0;i<lines.length;i++) {
    const line=lines[i];
    if(line.startsWith('```')) {
      finish();const code=[];while(++i<lines.length&&!lines[i].startsWith('```'))code.push(lines[i]);
      const pre=element('pre');pre.append(element('code',code.join('\n')));fragment.append(pre);continue;
    }
    const heading=/^(#{1,3})\s+(.+)$/.exec(line),task=/^- \[([ xX])\] (.*)$/.exec(line),list=/^(?:([-*]) |(\d+\.) )(.*)$/.exec(line);
    if(!line.trim()){finish();continue;}
    if(heading){finish();const h=element(`h${heading[1].length}`);inline(h,heading[2]);fragment.append(h);}
    else if(task) {
      finish();const index=i,checked=task[1]!==' ',row=element('div',undefined,`task${checked?' done':''}`);
      const toggle=action(checked?'[x]':'[ ]',()=>{n.body=toggleTask(n.body,index);$('body').value=n.body;changed();renderReading();$('reading').querySelector(`[data-line="${index}"]`)?.focus();},'task-toggle');
      toggle.dataset.line=String(i);toggle.setAttribute('role','checkbox');toggle.setAttribute('aria-checked',String(checked));toggle.setAttribute('aria-label',task[2]);
      const text=element('span',undefined,'task-text');inline(text,task[2]);row.append(toggle,text);fragment.append(row);
    } else if(list) {
      finish();const row=element('div',undefined,'list-line'),text=element('span');inline(text,list[3]);row.append(element('span',list[2]||'·'),text);fragment.append(row);
    } else if(line.startsWith('> ')){finish();const quote=element('blockquote');inline(quote,line.slice(2));fragment.append(quote);}
    else paragraph.push(line);
  }
  finish();$('reading').replaceChildren(fragment);renderBacklinks();
}
function renderBacklinks() {
  const n=note();if(!n)return;
  const incoming=notebook.notes.filter(other=>other!==n&&!other.archived&&linksIn(other.body).some(link=>link.toLocaleLowerCase()===title(n).toLocaleLowerCase()));
  $('backlinks').replaceChildren(...(incoming.length?incoming.map(other=>action(title(other),()=>openNote(other.id))):[element('span','No incoming links yet','muted')]));
}
function renderBoard(positions) {
  const nodes=visibleNotes(notebook.notes,$('find').value,filter).map(n=>{
    const card=element('article',undefined,`card${n.pinned?' pinned':''}`);card.dataset.id=n.id;
    const header=element('div',undefined,'card-header'),move=action('Move',()=>{},'card-move');
    move.title='Drag to rearrange; use arrow keys while focused';move.setAttribute('aria-label',`Move ${title(n)}`);
    move.addEventListener('pointerdown',event=>startDrag(event,card));
    move.addEventListener('keydown',event=>{
      const step={ArrowLeft:-1,ArrowUp:-1,ArrowRight:1,ArrowDown:1}[event.key];
      if(!step)return;event.preventDefault();
      const cards=visibleNotes(notebook.notes,$('find').value,filter),other=cards[cards.indexOf(n)+step];
      if(other){reorder(n.id,other.id);$('board').querySelector(`[data-id="${CSS.escape(n.id)}"] .card-move`)?.focus();}
    });
    header.append(action(title(n),()=>openNote(n.id),'card-title'),move);
    const info=element('div',undefined,'card-info');
    if(n.pinned)info.append(element('span','Pinned','pin-mark'));
    const tasks=[...n.body.matchAll(/^- \[([ xX])\] /gm)];
    if(tasks.length)info.append(element('span',`${tasks.filter(t=>t[1]!==' ').length}/${tasks.length} done`));
    if(!tasks.length&&!n.pinned)info.append(element('span',`${n.body.trim()?n.body.trim().split(/\s+/).length:0} words`));
    const preview=element('div',n.body.replace(/^#{1,3} /gm,'').replace(/\[\[([^\]]+)\]\]/g,'$1').replace(/\*\*|```[^\n]*/g,''),'card-preview');
    const tags=element('div',undefined,'card-tags');
    for(const tag of n.tags)tags.append(action(`#${tag}`,()=>{$('find').value=`#${tag}`;showBoard();}));
    if(!n.tags.length)tags.append(element('span','No tags','muted'));
    card.append(header,info,preview,tags);
    card.addEventListener('click',event=>{if(!event.target.closest('button'))openNote(n.id);});
    return card;
  });
  $('board').replaceChildren(...nodes);$('empty').hidden=!!nodes.length;
  $('count').textContent=String(notebook.notes.filter(n=>!n.archived).length);
  $('clear-filter').hidden=!$('find').value;
  for(const [id,value] of [['all-notes','all'],['pinned-notes','pinned'],['archived-notes','archive']])$(id).classList.toggle('selected',filter===value);
  if(positions)for(const node of nodes){const before=positions.get(node.dataset.id),after=node.getBoundingClientRect();if(before)animate(node,[{transform:`translate(${before.x-after.x}px,${before.y-after.y}px)`},{transform:'translate(0,0)'}]);}
  updateContext();
}
function showBoard() {
  current=null;clearTimeout(previewTimer);$('editor').hidden=true;$('board').hidden=false;renderBoard();
}
function setMode(value) {
  mode=value;$('pages').classList.toggle('split',mode==='split');$('write-pane').hidden=mode==='read';$('read-pane').hidden=mode==='write';
  for(const value of ['write','split','read'])$(`${value}-mode`).classList.toggle('selected',mode===value);
  if(mode!=='write')renderReading();
}
function openNote(id) {
  current=id;const n=note();if(!n)return showBoard();
  $('board').hidden=true;$('empty').hidden=true;$('editor').hidden=false;
  $('title').value=n.title;$('body').value=n.body;$('tags').value=n.tags.map(t=>`#${t}`).join(' ');
  $('pin-note').textContent=n.pinned?'Unpin':'Pin';$('archive-note').textContent=n.archived?'Restore':'Archive';
  setMode(mode);renderBacklinks();updateContext();
  animate($('pages'),[{opacity:.4,transform:'translateX(6px)'},{opacity:1,transform:'translateX(0)'}]);
}
function newNote(name='') {
  if(notebook.notes.length>=200){status('Notebook is full (200 notes).',true);return;}
  const n=makeNote(name);notebook.notes.unshift(n);dirty();openNote(n.id);$('title').focus();
}
function openLink(name) {const target=resolve(name);if(target)openNote(target.id);else newNote(name.slice(0,120));}
function reorder(source,target) {
  const positions=new Map([...$('board').children].map(node=>[node.dataset.id,node.getBoundingClientRect()]));
  if(moveNote(notebook.notes,source,target)){dirty();renderBoard(positions);}
}
function startDrag(event,card) {
  if(event.button!==0)return;event.preventDefault();
  const rect=card.getBoundingClientRect(),handle=event.currentTarget;
  drag={id:card.dataset.id,card,handle,pointer:event.pointerId,startX:event.clientX,startY:event.clientY,dx:event.clientX-rect.x,dy:event.clientY-rect.y,target:null,copy:null};
  handle.setPointerCapture(event.pointerId);
  const move=event=>{
    if(!drag)return;
    if(!drag.copy&&Math.hypot(event.clientX-drag.startX,event.clientY-drag.startY)>5){
      drag.copy=card.cloneNode(true);drag.copy.classList.add('drag-copy');drag.copy.style.width=`${rect.width}px`;drag.copy.style.height=`${rect.height}px`;
      drag.copy.setAttribute('aria-hidden','true');document.body.append(drag.copy);card.classList.add('dragging');
    }
    if(!drag.copy)return;
    drag.copy.style.left=`${event.clientX-drag.dx}px`;drag.copy.style.top=`${event.clientY-drag.dy}px`;
    const target=document.elementFromPoint(event.clientX,event.clientY)?.closest('#board .card');
    drag.target?.classList.remove('drop-target');drag.target=target&&target!==card?target:null;drag.target?.classList.add('drop-target');
  };
  const finish=event=>{
    if(!drag)return;const state=drag;drag=null;state.copy?.remove();card.classList.remove('dragging');state.target?.classList.remove('drop-target');
    handle.removeEventListener('pointermove',move);handle.removeEventListener('pointerup',finish);handle.removeEventListener('pointercancel',finish);handle.removeEventListener('lostpointercapture',finish);
    if(handle.hasPointerCapture(state.pointer))handle.releasePointerCapture(state.pointer);
    if(event.type==='pointerup'&&state.target)reorder(state.id,state.target.dataset.id);
  };
  handle.addEventListener('pointermove',move);handle.addEventListener('pointerup',finish);handle.addEventListener('pointercancel',finish);handle.addEventListener('lostpointercapture',finish);
}

$('topbar').addEventListener('pointerdown',event=>{if(event.button===0&&!event.target.closest('button'))send('notebook-move',null);});
$('new-note').onclick=()=>newNote();$('empty-new').onclick=()=>newNote();$('back').onclick=showBoard;
$('close-notebook').onclick=close;$('retry-save').onclick=()=>{sent=saved;flush();};
for(const value of ['write','split','read'])$(`${value}-mode`).onclick=()=>setMode(value);
for(const [id,value] of [['all-notes','all'],['pinned-notes','pinned'],['archived-notes','archive']])$(id).onclick=()=>{filter=value;showBoard();};
$('find').oninput=showBoard;$('clear-filter').onclick=()=>{$('find').value='';showBoard();$('find').focus();};
$('title').oninput=()=>{note().title=$('title').value;changed();renderBacklinks();};
$('tags').oninput=()=>{note().tags=[...new Set($('tags').value.split(/[\s,]+/).map(t=>t.replace(/^#+/,'').slice(0,40)).filter(Boolean))].slice(0,20);changed();};
$('body').oninput=()=>{note().body=$('body').value;changed();clearTimeout(previewTimer);if(mode!=='write')previewTimer=setTimeout(renderReading,100);};
$('pin-note').onclick=()=>{note().pinned=!note().pinned;changed();$('pin-note').textContent=note().pinned?'Unpin':'Pin';};
$('archive-note').onclick=()=>{note().archived=!note().archived;changed();showBoard();};
document.addEventListener('keydown',event=>{
  if(!notebook||event.isComposing)return;
  if(event.ctrlKey&&!event.altKey&&!event.shiftKey){
    if(event.key.toLowerCase()==='n'){event.preventDefault();newNote();}
    else if(event.key.toLowerCase()==='f'){event.preventDefault();$('find').focus();$('find').select();}
    else if(event.key.toLowerCase()==='s'){event.preventDefault();flush();}
    else if(event.key==='Enter'&&current){event.preventDefault();setMode(mode==='read'?'split':'read');}
  } else if(event.key==='Escape'&&!drag){showBoard();document.activeElement.blur();}
});
document.addEventListener('visibilitychange',()=>{if(document.hidden&&revision>saved)flush();});
window.addEventListener('ui-state',event=>{
  const state=event.detail;
  if(!opened&&typeof state['notebook-document']==='string'){
    opened=true;
    try {
      const initial=state['notebook-document'];notebook=initial?validateDocument(JSON.parse(initial)):seedDocument();
      for(const node of document.querySelectorAll('[disabled]'))node.disabled=false;
      showBoard();status('Saved locally');if(!initial)dirty();
      [...$('board').children].forEach((card,index)=>animate(card,[{opacity:0,transform:'translateY(8px)'},{opacity:1,transform:'translateY(0)'}],{delay:Math.min(index,5)*25}));
    } catch(error){status(error.message,true);$('close-notebook').disabled=false;}
  }
  if(typeof state['saved-revision']==='number'&&state['saved-revision']>saved){
    saved=state['saved-revision'];
    if(saved>=revision){status('Saved locally');if(closing){closing=false;send('notebook-hide',null);}}
    else if(sent===saved)flush();
  }
  if(typeof state['notebook-error']==='string'&&state['notebook-error']!==lastError){lastError=state['notebook-error'];if(lastError){status(lastError,true);sent=saved;closing=false;$('close-notebook').disabled=false;}}
  if(state['notebook-path'])$('save-state').title=state['notebook-path'];
});
send('notebook-ready',null);
