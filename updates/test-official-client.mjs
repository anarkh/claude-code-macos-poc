// Test-only local TLS material and archived public signature fixtures. No external requests.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import dns from 'node:dns';
import {once} from 'node:events';
import {createHash} from 'node:crypto';
import {mkdtemp,realpath,chmod,readFile,readdir,writeFile,rm,mkdir,symlink} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {runOfficialRequest,OfficialFailure,OFFICIAL_REQUEST_SCHEMA} from './official-client.mjs';
import {inspectNativeArchive} from './official-integrity.mjs';
import {gzipSync} from 'node:zlib';
const KEY=Buffer.from("-----BEGIN PRIVATE KEY-----\nMIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDF3tgdgZkwECYS\nWY+egxU0djz3U/9p7nmSfDNqkucy6oQi7BwDxWQwrNUIoyDTEZFw3TtvjDWTB2vg\nMXTLObtzWH1T9Sq1EE5+MKXzNZAAYPCeoMgiaUgnjJ32DrY9INaPlD9jjHiZ9gU4\nQBotgEGPgRZMq766m7OM0AkIDePjyPQ6VEqksL13zzlX1/jh9EzYNRtPw6HClrRe\nrfO070L8hplcanI9wTJ8mcXKK6Kdj2+avgW9SPZ7yHPEyb7/v3k670are5fRuA/f\n5IhxE5vj7WGbHXfGsXX+kjMnC4HShUqCxuRUTkecvZY4D3OtjRrosnTGPT9aXDUu\nUG0kCJ5jAgMBAAECggEAITYeIBW4mJCdU0clC/4EeSG/aeP3YthcH3IpTyIJHEqw\nkwv+R8PB5UmdGC4JPGQefUskxrxJ4bvFJ4QljlbKV7nqj0T/PhTWl+eicwfye53J\nxVZHQT9alQjNGpetjuUMHl1LpnHVbEIW7jIUMr7sQiHwlD3fbYLkyCXC3k82iOzO\nGkxbPyh3tpE2Z+Xvf5/22ox9YPvEJ2w5DViqBjNNNpbqyfNTG95iIuCrYIhb2H6Y\n+MNEDqbU+ti/en9EuX1EMkreJvckxcmAANTMNjf7DA6Mzk2U4L7ckMa46sKEQdOu\n4GH4+IjETh1Vzy09pwCu3YVefLrbhES7lmODAcV2QQKBgQDwSWKubHh+EUag3r18\nLSU7nmkPcTdmHIfQLB9gTqiq5WUzscJjzWeoji08RlaykQfbPrZ6YG8m1jT4z5Qa\neNaxtcNuzAbBaawICi4MB+j+CFc6PZ9/zHFAczGryu2crC4+AKh1tWtkYFxmWqqw\nW3bw6Z6bYshY4/9DkZOve5pWVQKBgQDSz1+zaRleJJqKHHhWOTJWbUqm1Nb1Ykd6\nyDUJdxgnx1k4N9OBVPJBGtsrdxWgh4n3PKb9cpEdni6EAVcsbA2C1FIAC6T4vD3K\n5ivZbnfaRdvzrg2ggtI9AAlbM0NXLZo+fx7F4a9jiomu7Afumi18hEkA/xLG1PAH\n4aU/3Lyp1wKBgF9WjrvsN+a1ThO4LPCfLP25va+t2TA/s7dqOkzJCO09tWjMZ/eX\nYUCkoNgghHe3Sam4+UgXCSMcrMnn+riCJ5U9LDzC4Q9OsT5DY7/MR6q7fniSSL25\nTVooGpYyHxMh0fsx4aVKhUC/ZwoJgV4V/FxcJV071YhHdlnF4hYncbY9AoGANFJ4\nBEWPoEgheyn5zBzCG6Vgo+urtpe/+f96+nButGDMCiIBAtackgAiabVSztcVLSIG\nqF0pG1rJXMYgZswixlgASjaZqYq/I37hX0QFx00TfHW0uCQAHlfF+rbMffS5lc1j\nS+Xp7CDUb2/xwAzQQVlr7S1h8aukL7CXnTQiN10CgYAVlBP4rMLD8lAfWgsMU6+9\naQqJxQrBHJA4f2ONCiYOrpKdtpj+CHHGHSnd6NsBIP43ICOxYF6O6QGcV/uUvHlZ\nK7d4HuRp/1qTR9DEPWwLtZiO2fprRHVOL3BXyB6MMOVXgJ1gYxjFYB8acJ92daHc\nYvhO/ZYWnX9pp2ZanBJNNQ==\n-----END PRIVATE KEY-----\n");
const CERT=Buffer.from("-----BEGIN CERTIFICATE-----\nMIIDKTCCAhGgAwIBAgIJAKPdB7aF3hBoMA0GCSqGSIb3DQEBCwUAMB0xGzAZBgNV\nBAMMEnJlZ2lzdHJ5Lm5wbWpzLm9yZzAeFw0yNjEwMTMwNDIzMDBaFw0zNjEwMTAw\nNDIzMDBaMB0xGzAZBgNVBAMMEnJlZ2lzdHJ5Lm5wbWpzLm9yZzCCASIwDQYJKoZI\nhvcNAQEBBQADggEPADCCAQoCggEBAMXe2B2BmTAQJhJZj56DFTR2PPdT/2nueZJ8\nM2qS5zLqhCLsHAPFZDCs1QijINMRkXDdO2+MNZMHa+AxdMs5u3NYfVP1KrUQTn4w\npfM1kABg8J6gyCJpSCeMnfYOtj0g1o+UP2OMeJn2BThAGi2AQY+BFkyrvrqbs4zQ\nCQgN4+PI9DpUSqSwvXfPOVfX+OH0TNg1G0/DocKWtF6t87TvQvyGmVxqcj3BMnyZ\nxcorop2Pb5q+Bb1I9nvIc8TJvv+/eTrvRqt7l9G4D9/kiHETm+PtYZsdd8axdf6S\nMycLgdKFSoLG5FROR5y9ljgPc62NGuiydMY9P1pcNS5QbSQInmMCAwEAAaNsMGow\nMgYDVR0RBCswKYIScmVnaXN0cnkubnBtanMub3JnghNkb3dubG9hZHMuY2xhdWRl\nLmFpMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgKkMBMGA1UdJQQMMAoG\nCCsGAQUFBwMBMA0GCSqGSIb3DQEBCwUAA4IBAQAfXM9/q6n0z57O0JkcPw4sY9op\n1pgS5GGPRz4wSVk36y4RaxnbWRfQqP+6hyWmcmSjiob4vwsu/IZDHo47OWIDASce\nHx2jsV+Tnrv1wVbD/yHxe1fnpLG5v43aUb3DEZKpd06yCMbRI8Y9pJti/i0y2c4d\n9zNYEuK1kAuaaTq/y1aOz3kps0jtL7JGUDT5KSGEoDt+0LTlAzZ7dqDPq1mPnxTI\n6jK2+a7ssGzN/DUM5O80X2MdAEO7MADPKo4bL5mZoULkY4gnZAfFm9Xi1OQtvMSX\nBJQrxTq4OQ45rJiVf5PiPNs8k2xCp1NsVr9LfrTvVQc7ZFfUcrYVDYbVvQul\n-----END CERTIFICATE-----\n");
const MANIFEST=Buffer.from("{\n  \"version\": \"2.1.296\",\n  \"manifestSignatureEnforcement\": \"flag\",\n  \"commit\": \"fdb6c17a97b6e0e3cf15e3566663fca58e7c43a9\",\n  \"buildDate\": \"2026-10-09T14:46:35Z\",\n  \"platforms\": {\n    \"darwin-arm64\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"c9b5341637becbd423ddffc5b254afb645682a3868cb708bbc6cc0e7bb419937\",\n      \"size\": 240664432\n    },\n    \"darwin-x64\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"a6bf4f30be241053a923f3820ad23c5991d2f5ac2935b3a8dd64da218d9cc603\",\n      \"size\": 249194752\n    },\n    \"linux-arm64\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"f1f6e96e0d8342b9dbf41d7e88255397a6a52ce3d8736ad6a4c6b59c9b62fefa\",\n      \"size\": 256434168\n    },\n    \"linux-x64\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"24972e3bc859fab2b46ed4c1e51f7d6130f06d3bd550811a114640de3370d0de\",\n      \"size\": 257068216\n    },\n    \"linux-arm64-musl\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"b0bbc936a82930933d7d5645081050d5f827a946cf6abc6575383b777a0feec0\",\n      \"size\": 248788800\n    },\n    \"linux-x64-musl\": {\n      \"binary\": \"claude\",\n      \"checksum\": \"94a1ccc6ffc9b0889c6b2b80e202885c8a575766775377398daa4db5fd89417f\",\n      \"size\": 250818648\n    },\n    \"win32-x64\": {\n      \"binary\": \"claude.exe\",\n      \"checksum\": \"76de74f7694a5bdc03378a5f837c9e132827bf004c98c276bc4e9094ff06769a\",\n      \"size\": 260489376\n    },\n    \"win32-arm64\": {\n      \"binary\": \"claude.exe\",\n      \"checksum\": \"a652a17f5a324d2d9ad9995cc047145f8176b9a4b4f28bbd3aa0708a22679e3b\",\n      \"size\": 248013984\n    }\n  },\n  \"sdkCompat\": {\n    \"testedWrapperVersions\": [\n      \"0.3.261\",\n      \"0.3.263\",\n      \"0.3.265\",\n      \"0.3.266\",\n      \"0.3.267\",\n      \"0.3.268\",\n      \"0.3.269\",\n      \"0.3.270\",\n      \"0.3.271\",\n      \"0.3.272\",\n      \"0.3.273\",\n      \"0.3.274\",\n      \"0.3.275\",\n      \"0.3.276\",\n      \"0.3.277\",\n      \"0.3.278\",\n      \"0.3.280\",\n      \"0.3.281\",\n      \"0.3.282\",\n      \"0.3.285\"\n    ],\n    \"harnessSchema\": 1\n  }\n}\n");
const SIGNATURE=Buffer.from("-----BEGIN PGP SIGNATURE-----\n\niQIzBAABCgAdFiEEMd3eJN36tnn0LXvSuqkp/xp+ys4FAmrI/sAACgkQuqkp/xp+\nys7LLA//YLPv3iOSWj/coYvkEmh11sw22gqZUmypGX9IFW8VzpJTsBK7wgVk/AyT\nKG08uZ4tnenf7F84hpJTjnRtLX+CKlUGa6beJx9oCV0wpQJa3ZzRsDaJjsbQ9Acs\nUUmm5vNaHbJPN1YUUeGB1RB4yLz4gP+qYGs3pzCcPYre1Q778dzShoZeivCmg69F\nKBgkhVXCiA3YR9+FUZk1M5wZqzajbZj4D8mtmIVCm9NaN6gWRbHeI3Aw996GurAX\nR34TKgHlDny4ehSIZf6dV4Msh7jITGfyKyk6ZnaFaijeMjRNMCMbex2guoO2KoIu\nYS6J6OoCfPYNY9I2lVfsxnUlviANwfQgZhXNimbLKiD5RJgkIX/7X4R/yVDtcTN1\nQddLxJXZ1CRWyzJE9TOOyyPGUIJI3E3Y0ivU7npFm1BkxP+a0APAOwP9Ve0rH6jj\nl06tMKXLW935Y1sLTvAE+J40gJxA9kkQk9/JOOhL4wSRneXOfNOweFLPQ666M7O+\nHkAogwUZ9rSRtOhjkFII6A2zUXUlcPWluZmxkNaGcUcIUOvGLcU7Z5MIRQR6c8yZ\nFFdeyHaNdg7/8lVWikLcwBMmEWS2n8aqyQrqH3W8f2kmauWtRX74DBLenJMt1ZtP\nPh2rrHTgtnskQVC+qz59wdjmIa1jUAg/mzJDDhgS/pzIO+z5Nfw=\n=xvxr\n-----END PGP SIGNATURE-----\n");
const SECRET = 'private-test-sentinel-never-render';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const sri = bytes => 'sha512-' + createHash('sha512').update(bytes).digest('base64');
const SDK = '@anthropic-ai/claude-agent-sdk', NATIVE = SDK + '-linux-arm64', V = '0.3.296';
const tarball = name => `https://registry.npmjs.org/${name}/-/${name.slice(name.indexOf('/') + 1)}-${V}.tgz`;
const SDK_BYTES = Buffer.from('not executed SDK archive fixture');
const NATIVE_BYTES = Buffer.from('not executed native archive fixture');
const rawMetadata = (name, mutate) => { const value = {name,version:V,dist:{tarball:tarball(name),integrity:sri(name === SDK ? SDK_BYTES : NATIVE_BYTES),unpackedSize:name === SDK ? 1000 : 256434765,fileCount:name === SDK ? 19 : 4}};
  if(name === SDK){value.claudeCodeVersion='2.1.296';value.engines={node:'>=18.0.0'};value.optionalDependencies={[NATIVE]:V};}
  else {value.os=['linux'];value.cpu=['arm64'];} mutate?.(value);return Buffer.from(JSON.stringify(value));};
async function listen(server){server.listen(0,'127.0.0.1');await once(server,'listening');return server.address().port;}
async function fixture(t,{mode='good', mutateSDK, mutateNative, signature=SIGNATURE, stable='2.1.287', proxyMode='good'}={}){
  const sockets=new Set(),observed={connects:[],requests:[]};
  const capture=s=>{sockets.add(s);s.on('error',()=>{});s.once('close',()=>sockets.delete(s));}; // Deliberately destroyed fixture sockets.
  let heldResolve;const held=new Promise(resolve=>{heldResolve=resolve;});
  const sdkRaw=rawMetadata(SDK,mutateSDK),nativeRaw=rawMetadata(NATIVE,mutateNative);
  const origin=https.createServer({key:KEY,cert:CERT},(req,res)=>{
    observed.requests.push({host:req.headers.host,url:req.url});
    const routes = new Map([[`/${SDK}/latest`,sdkRaw],[`/${SDK}/${V}`,sdkRaw],[`/${NATIVE}/${V}`,nativeRaw],
      ['/claude-code-releases/2.1.296/manifest.json',MANIFEST],['/claude-code-releases/2.1.296/manifest.json.sig',signature],
      ['/claude-code-releases/stable',Buffer.from(stable)],
      [`/${SDK}/-/claude-agent-sdk-${V}.tgz`,SDK_BYTES],[`/${NATIVE}/-/claude-agent-sdk-linux-arm64-${V}.tgz`,NATIVE_BYTES]]);
    const bytes=routes.get(req.url);if(!bytes){res.writeHead(404);res.end(SECRET);return;}
    if(mode==='redirect' && req.url.endsWith('/latest')){res.writeHead(302,{location:'https://forbidden.invalid/'+SECRET});res.end(SECRET);return;}
    if(mode==='large-metadata' && req.url.endsWith('/latest')){res.writeHead(200,{'content-length':65537});res.end(SECRET);return;}
    if(req.url.endsWith('.tgz')){
      if(mode==='hold'){res.writeHead(200,{'content-length':bytes.length});res.write(bytes.subarray(0,1));heldResolve();return;}
      if(mode==='oversize'){res.writeHead(200,{'content-length':160*1024**2+1});res.end(SECRET);return;}
      if(mode==='hash'){res.writeHead(200);res.end(Buffer.from('tampered-'+SECRET));return;}
    }
    res.writeHead(200,{'content-length':bytes.length,'content-type':'application/octet-stream',connection:'close'});res.end(bytes);
  });origin.on('connection',capture);origin.on('tlsClientError',()=>{});const originPort=await listen(origin);
  const proxy=http.createServer((_req,res)=>{res.writeHead(405);res.end();});proxy.on('connection',socket=>{capture(socket);socket.on('end',()=>socket.destroy());});
  proxy.on('connect',(req,socket,head)=>{
    observed.connects.push(req.url);
    if(proxyMode==='reject'){socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');return;}
    if(proxyMode==='hang'){socket.resume();heldResolve();return;}
    const upstream=net.connect({host:'127.0.0.1',port:originPort});capture(upstream);socket.once('close',()=>upstream.destroy());upstream.once('close',()=>socket.resume());
    upstream.once('connect',()=>{socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)upstream.write(head);socket.pipe(upstream);upstream.pipe(socket);});
  });const proxyPort=await listen(proxy);
  t.after(async()=>{for(const s of sockets)s.destroy();await Promise.all([new Promise(resolve=>proxy.close(resolve)),new Promise(resolve=>origin.close(resolve))]);});
  return {observed,sockets,held,network:{schema:'app-network-policy/v1',proxyURL:`http://127.0.0.1:${proxyPort}`,dnsPolicy:'proxy-only'},
    options:{testOnly:true,transportDependencies:{testOnly:true,ca:CERT,timeoutMs:1000}}};
}
const check=f=>({schema:OFFICIAL_REQUEST_SCHEMA,operation:'check',currentSDK:'0.3.295',currentCLI:'2.1.295',network:f.network});
async function scratch(t){const root=await realpath(await mkdtemp(path.join(os.tmpdir(),'official-client-test-')));await chmod(root,0o700);t.after(()=>rm(root,{recursive:true,force:true}));return root;}
async function rejectsSafe(promise,code){await assert.rejects(promise,e=>e instanceof OfficialFailure && (!code||e.code===code)&&e.message===e.code&&!e.stack.includes(SECRET));}
async function noDNS(action){const original=dns.lookup;dns.lookup=()=>{throw new Error('Target DNS is forbidden');};try{return await action();}finally{dns.lookup=original;}}
const download=(f,release,dir)=>({schema:OFFICIAL_REQUEST_SCHEMA,operation:'download',network:f.network,release,artifactDirectory:dir});

test('latest SDK chooses its declared paired CLI, stable is informational, all traffic uses CONNECT without DNS',async t=>{
  const f=await fixture(t),events=[];const out=await noDNS(()=>runOfficialRequest(check(f),e=>events.push(e),f.options));
  assert.equal(out.type,'checked');assert.equal(out.updateAvailable,true);assert.equal(out.release.sdkVersion,V);assert.equal(out.release.cliVersion,'2.1.296');assert.equal(out.release.officialStableCLI,'2.1.287');assert.equal(out.release.nodeMinimum,'18.0.0');
  assert.equal(out.release.artifacts.cli.sha256,'f1f6e96e0d8342b9dbf41d7e88255397a6a52ce3d8736ad6a4c6b59c9b62fefa');
  assert.deepEqual(f.observed.connects,['registry.npmjs.org:443','registry.npmjs.org:443','registry.npmjs.org:443','downloads.claude.ai:443','downloads.claude.ai:443','downloads.claude.ai:443']);
  assert.deepEqual(events.map(e=>e.phase),['metadata','metadata']);assert.equal(events.at(-1).fraction,1);
  const same=await runOfficialRequest({...check(f),currentSDK:V,currentCLI:'2.1.296'},()=>{},f.options);assert.equal(same.updateAvailable,false);
});

test('stable channel malformed response is explicit unavailable, does not change paired release',async t=>{
  const f=await fixture(t,{stable:'bad-'+SECRET});const out=await runOfficialRequest(check(f),()=>{},f.options);
  assert.equal(out.release.officialStableCLI,null);assert.equal(out.release.stableChannelStatus,'unavailable');assert.equal(out.release.cliVersion,'2.1.296');assert.equal(JSON.stringify(out).includes(SECRET),false);
});

test('SDK pairing, new runtime dependencies, node engine and native platform incompatibilities fail closed',async t=>{
  for(const mutateSDK of [m=>{m.optionalDependencies[NATIVE]='0.3.295';},m=>{m.claudeCodeVersion='latest';},m=>{m.engines.node='>=18 || >=20';},m=>{m.dependencies={unexpected:'1.0.0'};}]){
    const f=await fixture(t,{mutateSDK});await rejectsSafe(runOfficialRequest(check(f),()=>{},f.options),'OFFICIAL_INCOMPATIBLE_RELEASE');assert.equal(f.observed.requests.length,2);
  }
  const f=await fixture(t,{mutateNative:m=>{m.cpu=['x64'];}});await rejectsSafe(runOfficialRequest(check(f),()=>{},f.options),'OFFICIAL_INCOMPATIBLE_RELEASE');
});

test('tampered signature, redirect and oversized metadata are rejected before archives or any fallback',async t=>{
  const tamper=await fixture(t,{signature:Buffer.from(SIGNATURE.toString().replace('iQIz','jQIz'))});await rejectsSafe(runOfficialRequest(check(tamper),()=>{},tamper.options),'OFFICIAL_SIGNATURE_INVALID');
  for(const [mode,code] of [['redirect','OFFICIAL_REDIRECT_REFUSED'],['large-metadata','OFFICIAL_METADATA_TOO_LARGE']]){
    const f=await fixture(t,{mode});await rejectsSafe(noDNS(()=>runOfficialRequest(check(f),()=>{},f.options)),code);assert.equal(f.observed.connects.length,1);
  }
});

test('stdin-like request fields cannot add URLs, credentials, custom CA or transport overrides',async t=>{
  const f=await fixture(t);
  for(const extra of [{feedURL:'https://evil.invalid'},{testOnly:true},{transportDependencies:f.options.transportDependencies},{authorization:SECRET}])await rejectsSafe(runOfficialRequest({...check(f),...extra},()=>{},f.options),'OFFICIAL_INVALID_REQUEST');
  await rejectsSafe(runOfficialRequest({...check(f),network:{...f.network,proxyURL:'http://localhost:7897'}},()=>{},f.options),'OFFICIAL_NETWORK_POLICY_INVALID');
  assert.deepEqual(f.observed.connects,[]);
});

test('production rejects fixture TLS and proxy rejection remains bounded without direct fallback',async t=>{
  const f=await fixture(t);await rejectsSafe(noDNS(()=>runOfficialRequest(check(f))),'OFFICIAL_NETWORK_FAILED');assert.equal(f.observed.requests.length,0);
  const reject=await fixture(t,{proxyMode:'reject'});await rejectsSafe(noDNS(()=>runOfficialRequest(check(reject),()=>{},reject.options)),'OFFICIAL_NETWORK_FAILED');assert.equal(reject.observed.connects.length,1);
});

test('release objects round-trip with sorted keys, changed proofs fail before directory creation',async t=>{
  const f=await fixture(t,{mode:'hash'}),root=await scratch(t);const out=await runOfficialRequest(check(f),()=>{},f.options);
  const release=JSON.parse(JSON.stringify(out.release,(_key,value)=>value&&typeof value==='object'&&!Array.isArray(value)?Object.fromEntries(Object.keys(value).sort().map(k=>[k,value[k]])):value));
  release.metadataSHA256.manifest='0'.repeat(64);
  await rejectsSafe(runOfficialRequest(download(f,release,root+'/artifacts'),()=>{},f.options),'OFFICIAL_RELEASE_CHANGED');assert.deepEqual(await readdir(root),[]);
  release.metadataSHA256.manifest=out.release.metadataSHA256.manifest;
  await rejectsSafe(runOfficialRequest(download(f,release,root+'/artifacts'),()=>{},f.options),'OFFICIAL_DOWNLOAD_HASH');
  assert.deepEqual(await readdir(root),[]);
});

test('archive integrity and size failures clean only owned files while preserving unrelated scratch',async t=>{
  for(const [mode,code] of [['hash','OFFICIAL_DOWNLOAD_HASH'],['oversize','OFFICIAL_DOWNLOAD_SIZE']]){
    const f=await fixture(t,{mode}),root=await scratch(t);const checked=await runOfficialRequest(check(f),()=>{},f.options);await writeFile(root+'/keep.txt',SECRET);
    await rejectsSafe(runOfficialRequest(download(f,checked.release,root+'/artifacts'),()=>{},f.options),code);assert.deepEqual(await readdir(root),['keep.txt']);assert.equal(await readFile(root+'/keep.txt','utf8'),SECRET);
  }
});

test('cancellation during body and CONNECT closes transport and deletes owned partial artifacts',async t=>{
  const f=await fixture(t,{mode:'hold'}),root=await scratch(t),events=[];const checked=await runOfficialRequest(check(f),()=>{},f.options),abort=new AbortController();
  const pending=noDNS(()=>runOfficialRequest(download(f,checked.release,root+'/artifacts'),e=>events.push(e),{...f.options,signal:abort.signal}));await f.held;abort.abort();await rejectsSafe(pending,'OFFICIAL_CANCELLED');
  assert.deepEqual(await readdir(root),[]);assert.equal(events.some(e=>e.fraction===1),false);
  const hung=await fixture(t,{proxyMode:'hang'}),a=new AbortController();const wait=runOfficialRequest(check(hung),()=>{},{...hung.options,signal:a.signal});await hung.held;a.abort();await rejectsSafe(wait,'OFFICIAL_CANCELLED');
});

test('staging rejects symlink, existing destination and public parent without contacting provider',async t=>{
  const f=await fixture(t),root=await scratch(t),checked=await runOfficialRequest(check(f),()=>{},f.options);const requests=f.observed.requests.length;
  await mkdir(root+'/public',{mode:0o755});await mkdir(root+'/existing',{mode:0o700});await symlink(root+'/existing',root+'/linked');
  for(const dest of [root+'/existing',root+'/public/artifacts',root+'/linked/artifacts',root+'/child/../artifacts','relative'])await rejectsSafe(runOfficialRequest(download(f,checked.release,dest),()=>{},f.options),'OFFICIAL_STAGING_INVALID');
  assert.equal(f.observed.requests.length,requests);
});

function tarEntry(name,bytes,type='0'){
  const header=Buffer.alloc(512);header.write(name,0,100,'ascii');for(const [offset,width,value]of [[100,8,0o644],[108,8,0],[116,8,0],[124,12,bytes.length],[136,12,0]])header.write(value.toString(8).padStart(width-1,'0')+'\0',offset,width,'ascii');
  header.fill(32,148,156);header.write(type,156);header.write('ustar\0',257);header.write('00',263);let checksum=0;for(const byte of header)checksum+=byte;header.write(checksum.toString(8).padStart(6,'0')+'\0 ',148,8,'ascii');
  return Buffer.concat([header,bytes,Buffer.alloc((512-bytes.length%512)%512)]);
}
function nativeTar({cli=Buffer.from('ELF-not-executed'),extra,link=false}={}){
  const pkg=Buffer.from(JSON.stringify({name:NATIVE,version:V,os:['linux'],cpu:['arm64']}));
  const entries=[tarEntry('package/claude',cli,link?'2':'0'),tarEntry('package/package.json',pkg),tarEntry('package/LICENSE.md',Buffer.from('license')),tarEntry('package/README.md',Buffer.from('readme'))];if(extra)entries.push(tarEntry(extra,Buffer.from(SECRET)));
  return gzipSync(Buffer.concat([...entries,Buffer.alloc(1024)]));
}
test('native tar verifier hashes binary bytes and rejects symlinks, traversal, extras and hash differences',async t=>{
  const root=await scratch(t),cli=Buffer.from('ELF-not-executed');await writeFile(root+'/native.tgz',nativeTar({cli}));
  assert.equal((await inspectNativeArchive(root+'/native.tgz',{version:V,cliSHA256:sha(cli),cliBytes:cli.length})).binaryMatchesSignedManifest,true);
  for(const options of [{link:true},{extra:'../escape'},{extra:'package/unexpected'}]){await writeFile(root+'/native.tgz',nativeTar(options));await assert.rejects(inspectNativeArchive(root+'/native.tgz',{version:V,cliSHA256:sha(cli),cliBytes:cli.length}),{code:'OFFICIAL_ARTIFACT_INVALID'});}
  await writeFile(root+'/native.tgz',nativeTar());await assert.rejects(inspectNativeArchive(root+'/native.tgz',{version:V,cliSHA256:'0'.repeat(64),cliBytes:cli.length}),{code:'OFFICIAL_ARTIFACT_INVALID'});
});

 test('stream deadline closes a stalled archive and removes partial files',async t=>{
  const f=await fixture(t,{mode:'hold'}),root=await scratch(t),checked=await runOfficialRequest(check(f),()=>{},f.options);
  const started=Date.now();
  await rejectsSafe(runOfficialRequest(download(f,checked.release,root+'/artifacts'),()=>{},{testOnly:true,transportDependencies:{testOnly:true,ca:CERT,timeoutMs:100}}),'OFFICIAL_NETWORK_FAILED');
  assert.ok(Date.now()-started<1500);assert.deepEqual(await readdir(root),[]);
 });
 test('registry artifact URLs and identities are fixed and malformed SRI is rejected',async t=>{
  for(const mutateSDK of [m=>{m.name='untrusted-package';},m=>{m.dist.tarball='https://untrusted.invalid/'+SECRET;},m=>{m.dist.integrity='sha256-'+SECRET;}]){
    const f=await fixture(t,{mutateSDK});await rejectsSafe(runOfficialRequest(check(f),()=>{},f.options),'OFFICIAL_METADATA_INVALID');assert.equal(f.observed.requests.length,1);
  }
 });
