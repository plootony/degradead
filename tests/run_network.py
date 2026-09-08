"""Launch three real Photon peers and validate late join, prediction, migration.
Usage: python3 tests/run_network.py /path/to/godot
"""
from pathlib import Path
import subprocess
import sys
import time
import uuid

root = Path(__file__).resolve().parents[1]
room = 'DGD_REG_' + uuid.uuid4().hex[:10]
logs = root / 'tests' / 'results'
logs.mkdir(exist_ok=True)
children = []
try:
    for role, delay in [('host', 0), ('client', 3), ('observer', 9)]:
        time.sleep(delay)
        path = logs / f'{role}.log'
        handle = path.open('w')
        args = [sys.argv[1], '--headless', '--path', str(root), '--script', 'res://tests/network_peer.gd', '--log-file', str(logs / f'{role}-engine.log'), '--', '--autojoin', f'--room={room}', f'--role={role}']
        child = subprocess.Popen(args, stdout=handle, stderr=subprocess.STDOUT)
        children.append((role, child, handle, path))
    failed = False
    for role, child, handle, path in children:
        status = child.wait(timeout=50)
        handle.close()
        content = path.read_text()
        required = {'host': ['limb_injury_recorded', 'headshot_one_damage_is_lethal', 'damage_before_migration', 'kill_before_migration', 'forged_shooter_rejected', 'invalid_shot_rejected', 'final_health_converged', 'final_injuries_converged'], 'client': ['respawn_clears_injuries', 'migrated_injuries', 'local_prediction_before_rtt', 'movement_distance', 'bounded_camera_correction', 'jump_replay_and_landing', 'old_life_input_rejected', 'look_survives_replay', 'migrated_death_deadline', 'respawn_after_migration', 'damage_after_migration'], 'observer': ['late_join_injury', 'late_join_hp', 'late_join_stance_equipment', 'final_health_converged', 'final_injuries_converged']}[role]
        # The native preview SDK unregisters an absent debugger capture on headless exit.
        errors = [line for line in content.splitlines() if 'ERROR:' in line and line != "ERROR: Capture not registered: 'fusion'."]
        good = status == 0 and all(f'{name} PASS' in content for name in required) and not errors and ' FAIL' not in content
        print(role, 'PASS' if good else 'FAIL', path, flush=True)
        for line in content.splitlines():
            if line.startswith(('[CHECK]', '[RESULT]')) or 'ERROR:' in line:
                print(line, flush=True)
        failed |= not good
    sys.exit(1 if failed else 0)
finally:
    for _, child, handle, _ in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        handle.close()
