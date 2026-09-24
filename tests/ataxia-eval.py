"""SLY CLI integration, run against assistant-lisp-world's disposable compositor."""
import subprocess
import sys
import tempfile
from pathlib import Path

cli = Path(__file__).resolve().parents[1] / "scripts/ataxia-eval"
port = sys.argv[1]


def evaluate(*arguments, ok=True, stdin=None):
    result = subprocess.run(
        [str(cli), "--port", port, *arguments], input=stdin,
        capture_output=True, text=True, timeout=10,
    )
    assert (result.returncode == 0) == ok, result
    return result.stdout if ok else result.stderr


assert evaluate("--agent", "test task", "agent").strip() == '"test task"'
assert evaluate("--world", "--agent", "test task", "agent").strip() == '"test task"'
assert evaluate("(+ 1 2)").strip() == "3"  # Raw worker mode remains compatible.
assert evaluate("--world", "(eq sb-thread:*current-thread* ataxia.test.assistant-lisp::*expected-owner*)").strip() == "T"
generation = int(evaluate("--world", "(ataxia.kernel:kernel-world-generation kernel)"))
assert evaluate("--world", '(write-string "captured") (values :ok "日本語" 7)').splitlines() == [
    "captured", ":OK", '"日本語"', "7",
]
assert "owner-value" in evaluate("--world", "(make-instance 'ataxia.test.assistant-lisp::owner-print-probe)")
assert evaluate("--apply", ":refreshed").strip() == ":REFRESHED"
assert "contained" in evaluate("--apply", '(error "contained")', ok=False)
evaluate("--world", "(sleep 2)", ok=False)  # Execution budget, caught inside the owner.
evaluate("--world", "#.(error \"reader ran\")", ok=False)
evaluate("--world", "--generation", str(generation + 1), ":stale", ok=False)
assert evaluate("--world", "--generation", str(generation), ":current").strip() == ":CURRENT"
assert evaluate("--world", "--package", "ATAXIA.TEST.ASSISTANT-LISP", "(length (world-outputs world))").strip() == "1"
assert evaluate("--world", stdin="(values 10 20)").splitlines() == ["10", "20"]
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "forms.lisp"
    source.write_text('(values "backslash \\\\ and quote \\\"" :file)', encoding="utf-8")
    assert ":FILE" in evaluate("--world", "--file", str(source))
assert int(evaluate("--world", "(ataxia.kernel:kernel-world-generation kernel)")) == generation
assert evaluate("--world", "(ataxia.kernel:kernel-world-status kernel)").strip() == ":RUNNING"
print("PASS: SLY owner execution, output, packages, files/stdin, refresh, generation checks and contained errors/timeouts.")
