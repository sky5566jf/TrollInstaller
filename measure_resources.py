#!/usr/bin/env python3
"""SSH into device and measure CPU/RSS/VSZ of MatisuTrollStore processes.

Run from your own machine (the one that can reach 192.69.0.41).
Usage: python3 measure_resources.py
"""
import paramiko, time

HOST = "192.69.0.41"
USER = "mobile"
PASS = "12345678"
PROCS = "matisusupervisor|TrollInstaller"

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect(HOST, username=USER, password=PASS, timeout=10)

def run(cmd, t=25):
    i, o, e = ssh.exec_command(cmd, timeout=t)
    return o.read().decode("utf-8", "replace") + e.read().decode("utf-8", "replace")

print("=== 内存 / CPU 占用 (ps: RSS/VSZ 单位 KB, 自动转 MB) ===")
out = run(f"ps -ax -o pid,rss,vsz,%cpu,command 2>/dev/null | grep -E '{PROCS}' | grep -v grep")
if not out.strip():
    print("  (未找到进程，App 可能未启动 / supervisor 未拉起)")
else:
    for line in out.strip().splitlines():
        print("  " + line)
    # 转 MB 汇总
    print("\n=== 汇总 (RSS/VSZ 转 MB) ===")
    conv = f"""ps -ax -o pid,rss,vsz,command 2>/dev/null | grep -E '{PROCS}' | grep -v grep | awk '{{printf "  PID=%s  RSS=%.1fMB  VSZ=%.1fMB  %s\\n", $1, $2/1024, $3/1024, $4}}'"""
    print(run(conv))

print("\n=== 实时 CPU 快照 (top 第二帧, 间隔1s) ===")
print(run(f"top -l 2 -s 1 2>/dev/null | grep -E '{PROCS}'"))

print("\n=== 设备系统内存 (vm_stat) ===")
print(run("vm_stat 2>/dev/null | head -8"))

ssh.close()
print("\n=== DONE ===")
