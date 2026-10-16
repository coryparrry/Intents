// Development host for exercising the actual stdio server and MCP app together.
// It uses the same tools and native runner as Codex; no fabricated run results.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
const root = new URL('../', import.meta.url);
const exportsPath = join(process.env.FOUNDATION_EVALS_PLUGIN_DATA || tmpdir(), 'preview-trace-exports');
const downloadName = value => { if (typeof value !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._ -]{0,180}\.(json|afevaltrace|afevalsuite)$/.test(value)) throw Error('Invalid export filename'); return value; };
const traceName = value => { if (typeof value !== 'string' || !/^[a-f0-9-]{36}\.afevaltrace$/i.test(value)) throw Error('Invalid trace filename'); return value; };
const child = spawn(process.execPath, [fileURLToPath(new URL('server/main.mjs', root))], { stdio: ['pipe', 'pipe', 'inherit'], env: process.env });
let sequence = 0;
const requests = new Map();
createInterface({ input: child.stdout }).on('line', line => {
  const response = JSON.parse(line); const pending = requests.get(response.id);
  if (!pending) return; requests.delete(response.id); clearTimeout(pending.timer); pending.resolve(response);
});
function rpc(message) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { requests.delete(id); reject(Error('Preview MCP request timed out')); }, 180000);
    requests.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ ...message, id }) + '\n');
  });
}
await rpc({ jsonrpc: '2.0', method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'local-preview', version: '1' } } });
child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
const host = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Foundation Evals local preview</title><style>html,body,iframe{margin:0;border:0;width:100%;height:100%;display:block}body{overflow:hidden}</style></head><body><iframe src="/app" title="Foundation Evals" sandbox="allow-scripts allow-same-origin allow-downloads"></iframe><script>
const frame=document.querySelector('iframe');
const options=new URLSearchParams(location.search);
let theme=options.get('theme')==='dark'?'dark':'light';
function hostContext(){return {theme,styles:{variables:theme==='dark'?{
 '--color-background-primary':'#212121','--color-background-secondary':'#181818','--color-background-tertiary':'#303030',
 '--color-text-primary':'#ededed','--color-text-secondary':'#a0a0a0','--color-border-primary':'#505050','--color-border-secondary':'#363636',
 '--color-background-inverse':'#ededed','--color-text-inverse':'#212121','--font-sans':'-apple-system, BlinkMacSystemFont, sans-serif'
}:{
 '--color-background-primary':'#ffffff','--color-background-secondary':'#f7f7f7','--color-background-tertiary':'#ebebeb',
 '--color-text-primary':'#252525','--color-text-secondary':'#707070','--color-border-primary':'#d4d4d4','--color-border-secondary':'#e8e8e8',
 '--color-background-inverse':'#252525','--color-text-inverse':'#ffffff','--font-sans':'-apple-system, BlinkMacSystemFont, sans-serif'
}}};}
if(options.has('themeControls')){
 const control=document.createElement('button');control.textContent='Switch preview theme';
 control.style.cssText='position:fixed;bottom:8px;right:8px;padding:6px 10px;border:1px solid #888;border-radius:6px;z-index:1';
 control.onclick=()=>{theme=theme==='dark'?'light':'dark';frame.contentWindow.postMessage({jsonrpc:'2.0',method:'ui/notifications/host-context-changed',params:hostContext()},location.origin);};
 document.body.append(control);
}
addEventListener('message',async event=>{
 if(event.source!==frame.contentWindow||event.origin!==location.origin||event.data?.jsonrpc!=='2.0')return;
 const message=event.data;if(message.id==null)return;
 let response;
 try {
  if(message.method==='ui/initialize'){
   response={result:{protocolVersion:'2026-01-26',hostInfo:{name:'Local MCP preview',version:'1'},hostCapabilities:{downloadFile:{},experimental:{'openai/resource':{}}},hostContext:hostContext()}};
   setTimeout(async()=>{const trace=new URLSearchParams(location.search).get('trace');const tool=trace?{name:'eval_open_trace',arguments:{file:{name:trace,resourceUri:'host-resource://preview/'+trace}}}:{name:'eval_open_workspace',arguments:{}};const r=await fetch('/rpc',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',method:'tools/call',params:tool})}).then(r=>r.json());frame.contentWindow.postMessage({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:r.result},location.origin);},20);
  }else if(message.method==='ui/download-file')response=await fetch('/export',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(message)}).then(r=>r.json());
  else if(message.method==='resources/read'&&message.params?.uri?.startsWith('host-resource://preview/'))response=await fetch('/import?name='+encodeURIComponent(message.params.uri.split('/').pop())).then(r=>r.json());
  else {const delay=Math.min(5000,Math.max(0,Number(options.get('delayMs'))||0));if(message.method==='tools/call'&&message.params?.name===options.get('delayTool'))await new Promise(resolve=>setTimeout(resolve,delay));response=await fetch('/rpc',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(message)}).then(r=>r.json());}
 }catch(error){response={error:{code:-32603,message:error.message}};}
 frame.contentWindow.postMessage({...response,jsonrpc:'2.0',id:message.id},location.origin);
});
</script></body></html>`;
const server = createServer(async (req, res) => {
  try {
    const address = server.address();
    const allowedHosts = new Set([`127.0.0.1:${address.port}`, `localhost:${address.port}`]);
    const requestHost = req.headers.host;
    if (!allowedHosts.has(requestHost)) { res.statusCode = 403; return res.end('Invalid preview host'); }
    if (req.method === 'POST') {
      if (req.headers.origin !== `http://${requestHost}`) { res.statusCode = 403; return res.end('Preview requests must be same-origin'); }
      if (req.headers['content-type']?.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
        res.statusCode = 415; return res.end('Preview requests require application/json');
      }
    }
    if (req.method === 'GET' && req.url === '/') { res.setHeader('Content-Type', 'text/html'); return res.end(host); }
    if (req.method === 'GET' && req.url === '/app') { res.setHeader('Content-Type', 'text/html'); return res.end(await readFile(new URL('ui/app.html', root))); }
    if (req.method === 'GET' && req.url.startsWith('/?')) { res.setHeader('Content-Type', 'text/html'); return res.end(host); }
    if (req.method === 'GET' && req.url.startsWith('/import?')) {
      const name = traceName(new URL(req.url, 'http://127.0.0.1').searchParams.get('name'));
      const text = await readFile(join(exportsPath, name), 'utf8');
      res.setHeader('Content-Type', 'application/json'); return res.end(JSON.stringify({ result: { contents: [{ uri: 'host-resource://preview/' + name, mimeType: 'application/json', text }] } }));
    }
    if (req.method === 'POST' && req.url === '/export') {
      let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 32 * 1024 * 1024) throw Error('Trace too large'); }
      const resource = JSON.parse(body).params?.contents?.[0]?.resource;
      const name = downloadName(decodeURIComponent(new URL(resource.uri).pathname.slice(1)));
      await mkdir(exportsPath, { recursive: true }); await writeFile(join(exportsPath, name), resource.text, { mode: 0o600 });
      res.setHeader('Content-Type', 'application/json'); return res.end(JSON.stringify({ result: { isError: false } }));
    }
    if (req.method === 'POST' && req.url === '/rpc') {
      let body = ''; for await (const chunk of req) { body += chunk; if (Buffer.byteLength(body) > 65 * 1024 * 1024) throw Error('Body too large'); }
      res.setHeader('Content-Type', 'application/json'); return res.end(JSON.stringify(await rpc(JSON.parse(body))));
    }
    res.statusCode = 404; res.end();
  } catch (error) {
    res.statusCode = 500;
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.end(JSON.stringify({ error: { code: -32603, message: error.message } }));
  }
});
const port = Number(process.env.FOUNDATION_EVALS_PREVIEW_PORT || 4317);
server.listen(port, '127.0.0.1', () => console.error(`Local MCP preview: http://127.0.0.1:${server.address().port}`));
function close() { server.close(); child.stdin.end(); child.kill('SIGTERM'); }
process.on('SIGTERM', close); process.on('SIGINT', close);
child.on('exit', () => { server.close(); for (const pending of requests.values()) { clearTimeout(pending.timer); pending.reject(Error('MCP server exited')); } });
