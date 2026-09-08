from pathlib import Path
import subprocess,sys,time,uuid
root=Path(__file__).resolve().parents[1]
logs=root/'tests/results';logs.mkdir(exist_ok=True)
script=sys.argv[2] if len(sys.argv)>2 else 'ammo_peer'
room='DGD_AMMO_'+uuid.uuid4().hex[:10]
children=[];failed=False
try:
    for role in (['host','client','observer'] if script=='ammo_migration_peer' else ['host','client']):
        if role=='observer':
            deadline=time.monotonic()+18
            while '[AMMO MIGRATION START]' not in children[0][2].read_text():
                if time.monotonic()>deadline: raise RuntimeError('Host did not begin reload')
                time.sleep(0.2)
        path=logs/(script+'-'+role+'.log');output=path.open('w')
        proc=subprocess.Popen([sys.argv[1],'--headless','--path',str(root),'--script',f'res://tests/{script}.gd','--','--autojoin',f'--room={room}',f'--role={role}'],stdout=output,stderr=subprocess.STDOUT)
        children.append((proc,output,path))
        if role=='host':time.sleep(2)
    for proc,output,path in children:
        code=proc.wait(timeout=50);output.close();content=path.read_text()
        errors=[s for s in content.splitlines() if 'ERROR:' in s and s!="ERROR: Capture not registered: 'fusion'."]
        good=code==0 and '[AMMO RESULT] failures=0' in content and not errors and ' FAIL' not in content
        print(path.name,'PASS' if good else 'FAIL',flush=True)
        print('\n'.join(s for s in content.splitlines() if s.startswith('[AMMO') or 'ERROR:' in s),flush=True)
        failed=failed or not good
finally:
    for proc,output,_ in children:
        if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
        output.close()
sys.exit(1 if failed else 0)
