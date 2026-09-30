import test from 'node:test';
import assert from 'node:assert/strict';
import {MAX_BYTES,seedDocument,validateDocument,makeNote,encodeDocument,linksIn,visibleNotes,toggleTask,moveNote} from '../src/world/web/notes/model.mjs';

test('Unicode notes survive the persisted format; invalid files are rejected',()=>{
  const value=seedDocument();value.notes[0].body='λ🙂 <script>text</script>';
  assert.deepEqual(validateDocument(JSON.parse(encodeDocument(value))),value);
  assert.throws(()=>validateDocument({version:2,notes:[]}));
  assert.throws(()=>validateDocument({version:1,notes:[value.notes[0],value.notes[0]]}));
  assert.throws(()=>validateDocument({version:1,notes:[{...value.notes[0],body:12}]}));
  assert.throws(()=>encodeDocument({body:'🙂'.repeat(MAX_BYTES/4)}));
});
test('Search combines words and tags while archive stays separate',()=>{
  const a=makeNote('Desk ideas','a quiet workspace',['work']),b=makeNote('Desk','quiet',['home']);
  a.pinned=true;b.archived=true;
  assert.deepEqual(visibleNotes([a,b],'DESK #wor','all'),[a]);
  assert.deepEqual(visibleNotes([a,b],'quiet','archive'),[b]);
  assert.deepEqual(visibleNotes([a,b],'#home','pinned'),[]);
});
test('Checklist toggles preserve the other text and handle line indices',()=>{
  const original='Heading\n- [ ] First\n\n- [x] Second\nλ🙂';
  assert.equal(toggleTask(toggleTask(original,1),1),original);
  assert.equal(toggleTask(original,3),'Heading\n- [ ] First\n\n- [ ] Second\nλ🙂');
  assert.equal(toggleTask(original,40),original);
  assert.deepEqual(linksIn('[[One]]\n[[Two words]] [[One]]'),['One','Two words','One']);
});
test('Reordering persists a stable complete order, even with hidden notes',()=>{
  const notes=['a','b','c','d'].map(id=>({...makeNote(id),id}));
  assert.equal(moveNote(notes,'a','c'),true);assert.deepEqual(notes.map(n=>n.id),['b','c','a','d']);
  assert.equal(moveNote(notes,'d','b'),true);assert.deepEqual(notes.map(n=>n.id),['d','b','c','a']);
  assert.equal(moveNote(notes,'missing','a'),false);
});
