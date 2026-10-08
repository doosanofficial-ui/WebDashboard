"""Contract-check the actual workflow's narrow job-condition syntax.

The evaluator models documented status/needs semantics, not GitHub's scheduler.
It accepts only the operators and zero-argument status functions used here and
fails on unsupported syntax. Actual Actions execution remains separate evidence.
"""
import ast
from pathlib import Path
import re
import unittest


def job_block(workflow, name):
    match = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:\n|\Z)",
                      workflow, re.MULTILINE | re.DOTALL)
    if match is None:
        raise ValueError("Missing workflow job: " + name)
    return match.group(1)


def job_setting(block, name):
    match = re.search(r"^    " + re.escape(name) + r":\s*(.+)$", block, re.MULTILINE)
    return match.group(1).strip() if match else None


def job_needs(block):
    value = job_setting(block, "needs")
    if not value:
        raise ValueError("Missing explicit job dependencies")
    return [item.strip() for item in value.strip("[]").split(",")]


def job_eligible(block, results, cancelled=False):
    dependencies = job_needs(block)
    if any(results.get(name) is None for name in dependencies):
        return False  # Dependencies, including the whole matrix, must finish.
    success = not cancelled and all(results[name] == "success" for name in dependencies)
    condition = job_setting(block, "if")
    if condition is None:
        return success  # GitHub's implicit success() prerequisite.
    if condition.startswith("${{") and condition.endswith("}}"):
        condition = condition[3:-2].strip()
    functions = {"always": True, "cancelled": cancelled, "success": success,
                 "failure": any(results[name] == "failure" for name in dependencies)}
    status_calls = re.findall(r"\b(always|cancelled|success|failure)\s*\(\s*\)", condition)
    values = {}

    def need_value(match):
        job = match.group(1)
        if job not in dependencies:
            raise ValueError("Condition references an undeclared dependency: " + job)
        key = "need_" + job.replace("-", "_")
        values[key] = results[job]
        return key

    condition = re.sub(r"\bneeds\.([\w-]+)\.result\b", need_value, condition)
    condition = re.sub(r"\b(always|cancelled|success|failure)\s*\(\s*\)",
                       lambda match: str(functions[match.group(1)]), condition)
    condition = condition.replace("&&", " and ").replace("||", " or ")
    condition = re.sub(r"!(?!=)", " not ", condition).strip()

    def evaluate(node):
        if isinstance(node, ast.Expression):
            return evaluate(node.body)
        if isinstance(node, ast.Constant) and type(node.value) in (bool, str):
            return node.value
        if isinstance(node, ast.Name) and node.id in values:
            return values[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not evaluate(node.operand)
        if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
            items = [bool(evaluate(item)) for item in node.values]
            return all(items) if isinstance(node.op, ast.And) else any(items)
        if isinstance(node, ast.Compare) and len(node.ops) == len(node.comparators) == 1:
            left, right = evaluate(node.left), evaluate(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                left, right = left.lower(), right.lower()
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
        raise ValueError("Unsupported workflow condition syntax")

    value = bool(evaluate(ast.parse(condition, mode="eval")))
    return value and (bool(status_calls) or success)


class NativeUISchedulingTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (Path(__file__).resolve().parents[2] /
                         ".github/workflows/native-reliability.yml").read_text()
        self.ui = job_block(self.workflow, "native-replay-ui")
        self.se = job_block(self.workflow, "native-se-viewport")

    def test_ui_matrix_is_serial_and_failure_does_not_cancel_remaining_groups(self):
        self.assertRegex(self.ui, re.compile(r"^      max-parallel: 1$", re.MULTILINE))
        self.assertIn("      fail-fast: false\n", self.ui)
        self.assertNotIn("continue-on-error:", self.ui)
        self.assertEqual(job_setting(self.ui, "runs-on"), "xcode-27")

    def test_se_waits_for_seed_and_the_whole_matrix(self):
        self.assertEqual(set(job_needs(self.se)), {"native-seed", "native-replay-ui"})
        self.assertFalse(job_eligible(self.se,
                                     {"native-seed": "success", "native-replay-ui": None}))

    def test_se_runs_after_matrix_failure_or_skip_when_seed_succeeded(self):
        for matrix in ("success", "failure", "skipped"):
            with self.subTest(matrix=matrix):
                self.assertTrue(job_eligible(self.se,
                                            {"native-seed": "success", "native-replay-ui": matrix}))

    def test_cancelled_workflow_or_unqualified_seed_never_launches_se(self):
        for seed in ("success", "failure", "skipped", "cancelled"):
            for matrix in ("success", "failure", "skipped", "cancelled"):
                for cancelled in (False, True):
                    with self.subTest(seed=seed, matrix=matrix, cancelled=cancelled):
                        result = job_eligible(self.se,
                                              {"native-seed": seed, "native-replay-ui": matrix},
                                              cancelled=cancelled)
                        self.assertEqual(result, seed == "success" and not cancelled)


if __name__ == "__main__":
    unittest.main()
