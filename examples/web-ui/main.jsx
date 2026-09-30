import React,{useEffect,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {mount} from 'svelte';
import Counter from './Counter.svelte';
const send=(name,value)=>globalThis.ataxia?.postMessage(name,value);
function App(){
  const [count,setCount]=useState(0),[text,setText]=useState('');
  useEffect(()=>{send('react-ready',true);const receive=e=>{if(e.detail.name==='text')setText(e.detail.value)};
    addEventListener('ataxia-message',receive);return()=>removeEventListener('ataxia-message',receive)},[]);
  return <><h2>React</h2><p><button id="react-count" onClick={e=>{setCount(count+1);send('react-count',count+1);send('react-modifiers',e.ctrlKey)}}>Count {count}</button></p>
  <p><input id="editor" aria-label="Text" placeholder="Type here" value={text} onChange={e=>{setText(e.target.value);send('text',e.target.value)}}/></p>
  <button id="animate" onClick={()=>{document.body.classList.remove('animate');requestAnimationFrame(()=>document.body.classList.add('animate'))}}>Animate</button></>;
}
createRoot(document.getElementById('react')).render(<App/>);
mount(Counter,{target:document.getElementById('svelte')});
send('features',{grid:CSS.supports('display','grid'),webAnimations:!!Element.prototype.animate,canvas:!!document.createElement('canvas').getContext('2d')});
