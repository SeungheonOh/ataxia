export const MAX_BYTES=768*1024;
export function validateDocument(value) {
  if(!value || value.version!==1 || !Array.isArray(value.notes) || value.notes.length>200) throw Error('This is not a supported notebook. The saved file has not been changed.');
  const ids=new Set();
  for(const note of value.notes) {
    if(!note || typeof note.id!=='string' || !note.id || ids.has(note.id) || typeof note.title!=='string' || note.title.length>120 || typeof note.body!=='string' || note.body.length>64000 || !Array.isArray(note.tags) || note.tags.length>20 || note.tags.some(t=>typeof t!=='string'||t.length>40) || typeof note.pinned!=='boolean' || typeof note.archived!=='boolean' || !Number.isFinite(note.updated)) throw Error('A note is invalid. The saved file has not been changed.');
    ids.add(note.id);
  }
  encodeDocument(value);
  return value;
}
export function encodeDocument(value) {
  const text=JSON.stringify(value);
  if(new TextEncoder().encode(text).length>MAX_BYTES) throw Error('Notebook is full (768 KiB). Your current edits remain open.');
  return text;
}
export function makeNote(title='',body='',tags=[]) {return {id:crypto.randomUUID(),title,body,tags,pinned:false,archived:false,updated:Date.now()};}
export function seedDocument() {
  const notes=[
    makeNote('Start here','A notebook for ideas that are still taking shape.\n\n- [ ] Open a card and start writing\n- [ ] Tick a box in the reading view\n- [ ] Follow [[Loose threads]]\n- [ ] Drag Move to rearrange the cards\n\nUse **bold**, `code`, # headings, and [[links]] to other notes.\n\nNothing leaves this computer.',['guide']),
    makeNote('Loose threads','## Questions worth keeping\n\nWhat would make this workspace feel more like a desk?\n\nWhat should a note remember besides its words?\n\nFollow a thread into [[Small experiments]].',['ideas']),
    makeNote('Next steps','- [x] Give these thoughts a home\n- [ ] Try a few small experiments\n- [ ] Keep the useful parts\n\nSee [[Small experiments]] and [[Things worth keeping]].',['todo']),
    makeNote('Small experiments','## Make something tangible\n\n1. Pick the smallest version of an idea.\n2. Make it work.\n3. Write down what surprised you.\n\n```\nidea → experiment → observation\n```\n\nCollect the results in [[Things worth keeping]].',['ideas','work']),
    makeNote('Reading room','## In the margins\n\nA place for excerpts, references, and observations.\n\n> Leave room for a second reading.\n\nLink an observation to [[Loose threads]] instead of filing it away.',['reading']),
    makeNote('Things worth keeping','Useful shortcuts. A sentence you want to return to. The result of an experiment.\n\nAdd them here as you find them.',['collection'])
  ];
  notes[0].pinned=true; return {version:1,notes};
}
export function linksIn(body) {return [...body.matchAll(/\[\[([^\]\n]+)\]\]/g)].map(m=>m[1].trim());}
export function visibleNotes(notes,query,filter) {
  const words=query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  return notes.filter(n=>(filter==='archive'?n.archived:!n.archived)&&(filter!=='pinned'||n.pinned)&&words.every(w=>w.startsWith('#')?n.tags.some(t=>t.toLocaleLowerCase().includes(w.slice(1))):`${n.title}\n${n.body}\n${n.tags.join(' ')}`.toLocaleLowerCase().includes(w)));
}
export function toggleTask(body,line) {
  const lines=body.split('\n');
  if(!/^- \[[ xX]\] /.test(lines[line]||''))return body;
  lines[line]=lines[line].replace(/^- \[([ xX])\]/,(_,checked)=>`- [${checked===' '?'x':' '}]`);
  return lines.join('\n');
}
export function moveNote(notes,source,target) {
  const from=notes.findIndex(n=>n.id===source),to=notes.findIndex(n=>n.id===target);
  if(from<0||to<0||from===to)return false;
  notes.splice(to,0,notes.splice(from,1)[0]);return true;
}
