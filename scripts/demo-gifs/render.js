const {chromium}=require('playwright');const scenes=require('./scenes.js');const fs=require('fs');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:800,height:450}});
await p.goto('file://'+__dirname+'/stage.html');await p.evaluate(()=>document.fonts.ready);
const only=process.argv[2];const fps=15;
for(const [name,s] of Object.entries(scenes)){ if(only&&only!==name)continue;
 const dir=`${__dirname}/frames/${name}`;fs.rmSync(dir,{recursive:true,force:true});fs.mkdirSync(dir,{recursive:true});
 await p.evaluate(s=>setScene(s),s);
 const n=Math.round(s.total*fps);
 for(let i=0;i<n;i++){await p.evaluate(t=>render(t),i/fps);await p.screenshot({path:`${dir}/${String(i).padStart(4,'0')}.png`});}
 console.log(name,n);}
await b.close();})();
