<script>
  import {onMount} from 'svelte';
  let count = $state(0);
  onMount(()=>globalThis.ataxia?.postMessage('svelte-ready',true));
</script>
<h2>Svelte</h2>
<p><button id="svelte-count" onclick={()=>{count++;globalThis.ataxia?.postMessage('svelte-count',count)}}>Count {count}</button></p>
<p>Both use the browser DOM.</p>
