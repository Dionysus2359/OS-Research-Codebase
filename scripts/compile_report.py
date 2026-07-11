import subprocess
import os

project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_path = os.path.join(project_dir, 'Daemon_Results_Report.md')
base_cmd = ['python3', 'scripts/compare_metrics.py']

dirs = {
    'Synthetic Workload': 'results',
    'GAPBS': 'results/gapbs',
    'Redis + YCSB': 'results/redis',
    'STREAM': 'results/stream'
}

with open(out_path, 'w') as f:
    f.write("# ML Tiering Daemon Evaluation Results\n\n")
    f.write("This report compiles the evaluation metrics of the real Linux daemon across all real-world workloads.\n\n")
    
    for name, target_dir in dirs.items():
        f.write(f"## {name}\n")
        # We don't necessarily need markdown blocks if the output is markdown already
        # but wrapping in raw text might be cleaner since compare_metrics outputs tables.
        # Let's just output directly.
        try:
            output = subprocess.check_output(base_cmd + [target_dir], cwd=project_dir, text=True)
            f.write(output)
        except subprocess.CalledProcessError as e:
            f.write(f"Failed to generate results: {e}\n")
        f.write("\n---\n\n")

print("Report generated successfully.")
