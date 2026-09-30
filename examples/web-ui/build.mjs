import {build} from 'esbuild';
import {compile} from 'svelte/compiler';
import {readFile, mkdir, copyFile} from 'node:fs/promises';
await mkdir('dist', {recursive:true});
await build({entryPoints:['main.jsx'], bundle:true, format:'esm', outfile:'dist/app.js', minify:true,
  define:{'process.env.NODE_ENV':'"production"'},
  plugins:[{name:'svelte',setup(build){build.onLoad({filter:/\.svelte$/},async ({path})=>{
    const result=compile(await readFile(path,'utf8'),{filename:path,generate:'client',css:'injected'});
    return {contents:result.js.code,loader:'js'};
  });}}]});
await copyFile('index.html','dist/index.html');
