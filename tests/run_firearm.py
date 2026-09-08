"""Run firearm tests against Godot; Photon required for --network."""
from pathlib import Path
import subprocess,sys,time,uuid
root=Path(__file__).resolve().parents[1]
logs=root/'tests/results';logs.mkdir(exist_ok=True)
binary=sys.argv[1]; base=[binary,'--headless','--path',str(root)]
failed=False
def report(path,code,marker):
    content=path.read_text()
    errors=[s for s in content.splitlines() if 'ERROR:' in s and s!="ERROR: Capture not registered: 'fusion'."]
    good=code==0 and marker in content and not errors and ' FAIL' not in content
    print(path.name,'PASS' if good else 'FAIL',flush=True)
    if not good: print(content,flush=True)
    return good
for name,args,marker in [('firearm-unit',['--script','res://tests/firearm_unit.gd'],'[FIREARM RESULT] failures=0'),('firearm-editor',['--editor','--','--firearm-editor-test'],'[FIREARM EDITOR RESULT] failures=0')]:
    path=logs/(name+'.log')
    with path.open('w') as output: result=subprocess.run(base+args,stdout=output,stderr=subprocess.STDOUT,timeout=60)
    failed=not report(path,result.returncode,marker) or failed
if '--network' in sys.argv:
    for script,marker in [('firearm_peer','[FIREARM PEER] PASS'),('firearm_auto_peer','[AUTO PEER] PASS')]:
        children=[];room='DGD_FIRE_'+uuid.uuid4().hex[:10]
        try:
            for role in ['host','client']:
                path=logs/(script+'-'+role+'.log'); output=path.open('w')
                proc=subprocess.Popen(base+['--script',f'res://tests/{script}.gd','--','--autojoin',f'--room={room}'],stdout=output,stderr=subprocess.STDOUT)
                children.append((proc,output,path))
                if role=='host':time.sleep(2)
            for proc,output,path in children:
                code=proc.wait(timeout=40);output.close()
                failed=not report(path,code,marker) or failed
        finally:
            for proc,output,_ in children:
                if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
                output.close()
sys.exit(1 if failed else 0)
