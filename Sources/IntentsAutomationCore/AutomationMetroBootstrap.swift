#if os(macOS)
import Foundation

/// Product-owned orchestration of installed Metro APIs. It preserves the app's
/// existing config/entrypoint; worker/watch settings only bound child ownership.
enum AutomationMetroBootstrap {
    static let source = #"""
    'use strict';
    const fs = require('node:fs');
    const path = require('node:path');
    const crypto = require('node:crypto');
    const token = process.env.INTENTS_JS_TOKEN;
    const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    const root = spec.root;
    const expected = new URL(spec.bundleURL);
    const pending = new Map();
    const delivered = [];
    const cache = new Map();
    const splitURLs = new Set();
    let sequence = 0;
    function key(raw) {
      const u = new URL(raw, expected.origin);
      return u.pathname + '?' + [...u.searchParams].sort((a,b)=>a[0].localeCompare(b[0])).map(v=>encodeURIComponent(v[0])+'='+encodeURIComponent(v[1])).join('&');
    }
    function admitted(raw) {
      const u=new URL(raw,expected.origin);
      if(key(raw)===key(expected.href))return true;
      return [...splitURLs].some(v=>key(v)===key(raw));
    }
    function capture(req,res,next,done) {
      const requestKey=key(req.url);
      const chunks=[];let count=0;
      req.headers['accept-encoding']='identity';
      const write=res.write.bind(res),end=res.end.bind(res);
      res.write=(chunk,...args)=>{if(chunk){const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);count+=b.length;if(count>33554432){res.destroy();return false;}chunks.push(b);}return write(chunk,...args);};
      res.end=(chunk,...args)=>{if(chunk){const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);count+=b.length;chunks.push(b);}if(res.statusCode===200&&count>0&&count<=33554432){const bytes=Buffer.concat(chunks);cache.set(requestKey,bytes);for(const match of bytes.toString('utf8').matchAll(/(?:https?:\/\/[^"'\\\s]+|\/[^"'\\\s]+)\.bundle\?[^"'\\\s]+/g)){const u=new URL(match[0],expected.origin);if(u.protocol==='http:'&&u.hostname==='127.0.0.1'&&u.port===expected.port&&u.searchParams.get('modulesOnly')==='true'&&u.searchParams.get('runModule')==='false'&&!decodeURIComponent(u.pathname).split('/').includes('..'))splitURLs.add(u.href);}done(bytes);}return end(chunk,...args);};
      next();
    }
    function middleware(req, res, next) {
      const url = new URL(req.url, expected.origin);
      const authorized = req.headers['x-intents-probe'] === token;
      if (url.pathname === '/__intents/pending') {
        if (!authorized) { res.statusCode=403; return res.end(); }
        res.setHeader('Content-Type','application/json');
        return res.end(JSON.stringify({pending:[...pending.values()].filter(v=>!v.released).map(v=>({id:v.id,port:v.port,url:v.url})),delivered,inFlight:pending.size,splitURLs:[...splitURLs]}));
      }
      if (url.pathname === '/__intents/release') {
        if (!authorized) { res.statusCode=403; return res.end(); }
        const item = pending.get(Number(url.searchParams.get('id')));
        if (!item || item.released || !admitted(item.url)) { res.statusCode=409; return res.end(); }
        item.released=true;clearTimeout(item.timer);
        const done=(bytes)=>{pending.delete(item.id);delivered.push({id:item.id,port:item.port,url:item.url,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});};
        const cached=cache.get(key(item.url));
        if(cached){item.res.statusCode=200;item.res.setHeader('Content-Type','application/javascript');item.res.end(cached);done(cached);}
        else capture(item.req,item.res,item.next,done);
        res.end('released'); return;
      }
      if (url.pathname.endsWith('.bundle')) {
        if (!admitted(req.url)) { res.statusCode=409; return res.end('Native JavaScript URL differs from the approved profile'); }
        if (authorized) {
          const cached=cache.get(key(req.url));
          if (cached) { res.setHeader('Content-Type','application/javascript'); return res.end(cached); }
          return capture(req,res,next,()=>{});
        }
        if (!cache.has(key(expected.href)) || pending.size>=16 || delivered.length>=32) { res.statusCode=503; return res.end(); }
        const item={id:++sequence,port:req.socket.remotePort,url:req.url,req,res,next,released:false};
        item.timer=setTimeout(()=>{pending.delete(item.id);res.statusCode=403;res.end('Native consumer ownership was not verified');},15000);
        req.once('close',()=>{if(res.writableEnded){pending.delete(item.id);clearTimeout(item.timer);}});
        pending.set(item.id,item);return;
      }
      next();
    }
    async function main() {
      const expoConfig=require(path.join(root,spec.expoConfigModule));
      const metro=require(path.join(root,spec.metroModule));
      let config=expoConfig.getDefaultConfig(path.join(root,spec.app));
      if(spec.metroConfig){ const file=path.join(root,spec.metroConfig);const existing=require(file);if(typeof existing==='function'||!existing||typeof existing!=='object')throw new Error('Unsupported dynamic Metro config export');const {loadConfig}=require(path.join(root,spec.metroConfigModule));config=await loadConfig({cwd:path.join(root,spec.app),config:file},config); }
      config.maxWorkers=1;
      config.resolver={...config.resolver,useWatchman:false};
      config.server={...config.server,port:Number(expected.port)};
      config.cacheStores=[];
      await metro.runServer(config,{host:'127.0.0.1',watch:false,waitForBundler:true,unstable_extraMiddleware:[middleware]});
    }
    main().catch(e=>{console.error(e.stack||String(e));process.exitCode=1;});
    """#
    static func write(recipe: AutomationMetroAutomaticRecipe, manifest: AutomationSourceManifest, frozenRoot: URL, profile: AutomationServedJavaScriptProfile, session: URL) throws -> (URL, URL) {
        let script = session.appendingPathComponent("intents-owned-metro-bootstrap.js"), config = session.appendingPathComponent("metro-session.json")
        try AutomationDurableFile(url: script, maximumBytes: 65_536).write(Data(source.utf8))
        let packagePath = recipe.appRelativePath.isEmpty ? "package.json" : recipe.appRelativePath + "/package.json"
        guard let package = manifest.files.first(where: { $0.inputPath == recipe.sourceRoot + "/" + packagePath }), package.relativePath.hasSuffix(packagePath) else { throw AutomationContractError.invalidIdentity }
        let prefix = String(package.relativePath.dropLast(packagePath.count))
        let primary = prefix.isEmpty ? frozenRoot : frozenRoot.appendingPathComponent(prefix)
        guard let configModule = recipe.metroConfigModuleRelativePath else { throw AutomationContractError.invalidIdentity }
        let object: [String: String] = ["root": primary.path, "app": recipe.appRelativePath, "bundleURL": profile.bundleURL,
            "expoConfigModule": recipe.expoConfigModuleRelativePath, "metroModule": recipe.metroModuleRelativePath,
            "metroConfigModule": configModule,
            "metroConfig": recipe.metroConfigRelativePath ?? ""]
        try AutomationDurableFile(url: config, maximumBytes: 65_536).write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return (script, config)
    }
}
#endif
