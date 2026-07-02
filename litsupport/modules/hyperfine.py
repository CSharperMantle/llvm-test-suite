import json
import os

from litsupport import shellcommand


def _mutatePlanForHyperfine(context, plan):
    if len(plan.runscript) == 0:
        return

    context.hyperfine_jsons = []
    new_script = []
    multiple_runs = len(plan.runscript) > 1

    for i, cmdline in enumerate(plan.runscript):
        suffix = "-%s" % (i,) if multiple_runs else ""
        outfile = os.path.normpath(context.tmpBase + suffix + ".out")
        hyperfine_json = os.path.normpath(context.tmpBase + suffix + ".hyperfine.json")

        context.hyperfine_jsons.append(hyperfine_json)

        cmd = shellcommand.parse(cmdline)
        cmd_str = cmd.toCommandline()

        if cmd.stdin is None and os.name != "nt":
            redirect_stdin = " </dev/null"
        else:
            redirect_stdin = ""

        cmd_verify = shellcommand.ShellCommand()
        cmd_verify.executable = "sh"
        cmd_verify.arguments = [
            "-c",
            '(%s) >%s 2>&1 %s; echo "exit $?" >>%s'
            % (cmd_str, outfile, redirect_stdin, outfile),
        ]

        cmd_hyperfine = shellcommand.ShellCommand()
        cmd_hyperfine.executable = "hyperfine"
        cmd_hyperfine.arguments = [
            "--ignore-failure",
            "--warmup",
            "3",
            "--min-runs",
            "10",
            "--export-json",
            hyperfine_json,
            cmd_str,
        ]

        new_script.append(cmd_verify.toCommandline())
        new_script.append(cmd_hyperfine.toCommandline())

    plan.runscript = new_script
    plan.metric_collectors.append(lambda context: _collectWalltime(context))


def _collectWalltime(context):
    total_mean = 0.0
    total_stddev = 0.0
    total_min = float("inf")
    total_max = float("-inf")
    total_runs = 0
    n_jsons = 0

    for json_file in getattr(context, "hyperfine_jsons", []):
        try:
            content = context.read_result_file(context, json_file)
            data = json.loads(content)
            r = data["results"][0]
            total_mean += r["mean"]
            total_stddev += r["stddev"]
            total_min = min(total_min, r["min"])
            total_max = max(total_max, r["max"])
            total_runs += len(r["times"])
            n_jsons += 1
        except (KeyError, json.JSONDecodeError, FileNotFoundError):
            return {}

    if n_jsons == 0:
        return {}

    avg_mean = total_mean / n_jsons
    avg_stddev = total_stddev / n_jsons
    return {
        "exec_time": avg_mean,
        "walltime_mean": avg_mean,
        "walltime_stddev": avg_stddev,
        "walltime_min": total_min,
        "walltime_max": total_max,
        "walltime_runs": total_runs,
    }


def mutatePlan(context, plan):
    if len(plan.runscript) == 0:
        return
    _mutatePlanForHyperfine(context, plan)
