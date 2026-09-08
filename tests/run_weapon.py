"""Weapon runtime/editor and two-client Photon regression. Pass the Godot binary."""
from pathlib import Path
import subprocess
import sys
import time
import uuid
root = Path(__file__).resolve().parents[1]
logs = root / 'tests' / 'results'
logs.mkdir(exist_ok=True)
godot = sys.argv[1]
base = [godot, '--headless', '--path', str(root)]
def check(path, code, marker):
    content = path.read_text()
    errors = [s for s in content.splitlines() if 'ERROR:' in s and s != "ERROR: Capture not registered: 'fusion'."]
    good = code == 0 and marker in content and ' FAIL' not in content and not errors
    print(path.name, 'PASS' if good else 'FAIL', flush=True)
    if not good: print(content, flush=True)
    return good
ok = True
for name, args, marker in [
    ('weapon-runtime', ['--script','res://tests/weapon_runtime.gd'], '[WEAPON RESULT] failures=0'),
    ('weapon-editor', ['--editor','--','--weapon-plugin-test'], '[WEAPON EDITOR RESULT] failures=0'),
]:
    path = logs / (name+'.log')
    with path.open('w') as output:
        run = subprocess.run(base + args, stdout=output, stderr=subprocess.STDOUT, timeout=90)
    ok = check(path,run.returncode,marker) and ok
for script, marker in [('weapon_peer','[WEAPON PEER] PASS'),('camera_peer','[CAMERA PEER] PASS')]:
    children = []
    room = 'DGD_WPN_' + uuid.uuid4().hex[:10]
    try:
        for role in ['host','client']:
            path = logs / f'{script}-{role}.log'
            output = path.open('w')
            proc = subprocess.Popen(base + ['--script',f'res://tests/{script}.gd','--','--autojoin',f'--room={room}'], stdout=output, stderr=subprocess.STDOUT)
            children.append((proc,output,path))
            if role == 'host': time.sleep(2)
        for proc,output,path in children:
            code = proc.wait(timeout=45)
            output.close()
            ok = check(path,code,marker) and ok
    finally:
        for proc,output,_ in children:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
            output.close()
sys.exit(0 if ok else 1)
