"""Synthetic audio only; this fixture never opens a microphone or speaker."""
import sys
import time

if sys.argv[1] == "record":
    for _ in range(400):
        sys.stdout.buffer.write(bytes(2400))
        sys.stdout.flush()
        time.sleep(0.05)
else:
    with open(sys.argv[2], "wb", buffering=0) as output:
        while chunk := sys.stdin.buffer.read(4):
            output.write(chunk)
