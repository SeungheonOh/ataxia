// All work is driven by host state or DOM input. No polling or animation loop.
const models = Object.create(null);
const element = id => id ? document.getElementById(id) : document.body;
const outgoing=[];
let sending=false;
function pumpInput(){if(!sending&&outgoing.length){sending=true;ataxia.postMessage(...outgoing[0]);}}
const send = (name,value=null) => {
  if(typeof value==='string' && value.length>2048) {
    outgoing.push(['__start:'+name,'']);
    for(let i=0;i<value.length;){let end=Math.min(i+1024,value.length);const last=value.charCodeAt(end-1);if(end<value.length&&last>=0xd800&&last<=0xdbff)end--;outgoing.push(['__part:'+name,value.slice(i,end)]);i=end;}
    outgoing.push(['__end:'+name,'']);
  } else outgoing.push([name,value]);
  pumpInput();
};
window.ataxiaUiSend=send;
const strings=new Map();
let pasteRequest=null,pasteSequence=0;

function applyModel(id,data) {
  for (const node of document.querySelectorAll('[data-value]')) {
    if(node.dataset.value===id && node.value!==String(data)) node.value=String(data);
  }
  for (const node of document.querySelectorAll('[data-disabled]')) {
    if(node.dataset.disabled===id) node.disabled=Boolean(data);
  }
  for (const node of document.querySelectorAll('[data-property]')) {
    if(node.dataset.property===id) node.textContent=data;
  }
  const node=element(id);
  if(node && !node.dataset.html && !node.matches('input:not([type=button]),textarea,select')) {
    if(node.matches('input[type=button]')) node.value=data;
    else if(!node.children.length) node.textContent=data;
  }
}
addEventListener('ataxia-message', ({detail:{name,value}}) => {
  if(name!=='ui' && name!=='shell') return;
  let htmlChanged=false;
  for(let [op,id,key,data] of value) {
    if(op==='input-ack'){if(sending&&outgoing[0]?.[0]===id){outgoing.shift();sending=false;pumpInput();}continue;}
    const token=id+':'+key;
    if(op==='string-start'){strings.set(token,{key:data,parts:[]});continue;}
    if(op==='string-part'){strings.get(token)?.parts.push(data);continue;}
    if(op==='string-end'){
      const complete=strings.get(token);strings.delete(token);if(!complete)continue;
      op=key;key=complete.key;data=complete.parts.join('');
    }
    if(op==='paste') {
      const request=pasteRequest;pasteRequest=null;
      if(request && id===request.id && request.node===document.activeElement) {
        if(request.node.matches('input,textarea')) {
          request.node.setRangeText(data,request.start,request.end,'end');
          request.node.dispatchEvent(new Event('input',{bubbles:true}));
        } else document.execCommand('insertText',false,data);
      }
      continue;
    }
    const node=element(id);
    if(op==='model'||op==='text') {
      models[id]=data;
      for(const target of document.querySelectorAll('[data-html]')) if(target.dataset.html===id) {
        const scroll=target.closest('#conversation');
        const atEnd=scroll && scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<32;
        target.innerHTML=data;htmlChanged=true;
        if(atEnd) scroll.scrollTop=scroll.scrollHeight;
      }
      applyModel(id,data);
    } else if(node) {
      if(op==='style') node.style.setProperty(key,String(data).replaceAll('dp','px'));
      else if(op==='class') node.classList.toggle(key,Boolean(data));
      else if(op==='attribute') {if(data===false||data===null)node.removeAttribute(key);else node.setAttribute(key,data);}
    }
  }
  if(htmlChanged)for(const [id,data] of Object.entries(models))applyModel(id,data);
  dispatchEvent(new CustomEvent('ui-state',{detail:models}));
});
document.addEventListener('click',event=>{
  const action=event.target.closest('button,input[type=button]');
  if(action && !action.disabled)send(action.dataset.action||action.id,action.dataset.argument??null);
});
document.addEventListener('input',event=>{
  const node=event.target;
  if(node.dataset.value) {models[node.dataset.value]=node.value;send('model:'+node.dataset.value,node.value);}
  if(node.dataset.edited)send(node.dataset.edited,node.value);
});
document.addEventListener('change',event=>{
  for(let node=event.target;node && node!==document.body;node=node.parentElement)if(node.id)send(node.id+':change',event.target.value);
});
for(const [event,name] of [['focusin','focus'],['focusout','blur']]) {
  document.addEventListener(event,e=>{if(event==='focusout'&&pasteRequest?.node===e.target)pasteRequest=null;if(e.target.id)send(e.target.id+':'+name,null);});
}
document.addEventListener('animationend',event=>{if(event.target.id)send(event.target.id+':animationend',event.animationName);});
document.addEventListener('keydown',event=>{
  if((event.ctrlKey && event.key.toLowerCase()==='v')||(event.shiftKey&&event.key==='Insert')) {
    const node=document.activeElement;
    if(node?.matches('input:not([type=button]),textarea,[contenteditable=true]')) {
      event.preventDefault();
      pasteRequest={id:String(++pasteSequence),node,start:node.selectionStart,end:node.selectionEnd};
      send('clipboard:paste',pasteRequest.id);
    }
  }
});
for(const kind of ['copy','cut'])document.addEventListener(kind,event=>{
  const node=document.activeElement;
  const field=node?.matches('input,textarea');
  const text=field?node.value.slice(node.selectionStart,node.selectionEnd):String(getSelection());
  if(text){event.preventDefault();send('clipboard:copy',text);
    if(kind==='cut' && field && !node.readOnly){node.setRangeText('',node.selectionStart,node.selectionEnd,'end');node.dispatchEvent(new Event('input',{bubbles:true}));}}
});
send('shell-ready',true);
send('ui-ready',true);
