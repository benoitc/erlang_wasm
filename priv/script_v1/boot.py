"""The `script_v1` bootstrap for CPython.

Staged beside the tenant's source and run instead of it, so the shape the
tenant writes -- `def main(context)` -- is the only thing they have to know.

It writes its output through rather than buffering it. The interpreter is
started with `-u` for the same reason: a bootstrap that collected stdout and
flushed at the end would defeat the streaming bound completely, and the bound
is most of what makes an untrusted guest safe.
"""
import json
import sys
import traceback

# argv[0] is the script, so the marker the host minted for this request is
# argv[1]. It is a delimiter and not a secret: this code can read it and so can
# the tenant's.
MARKER = sys.argv[1]


def frame(envelope):
    try:
        payload = json.dumps(envelope)
    except (TypeError, ValueError):
        # A result that cannot be serialised is still an answer, and it has to
        # be framed as one rather than left to look like silence.
        payload = json.dumps({
            "error": {"code": "bad_result",
                      "message": "result is not JSON-serialisable"}
        })
    sys.stdout.write(MARKER)
    sys.stdout.write(payload)
    sys.stdout.write("\n")
    sys.stdout.flush()


def failed(code, exc):
    frame({"error": {"code": code, "message": str(exc)}})


def load():
    """Load the tenant's module by explicit path.

    `-I` implies `-P`, so the work directory is not on `sys.path` and an
    ordinary `import` would not find `/main.py` at all. That is deliberate:
    loading by path means nothing the tenant writes can reach a module the host
    did not put there, and it is why the bootstrap does not simply add the
    directory to the path.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location("tenant_main", "/main.py")
    module = importlib.util.module_from_spec(spec)
    # Importing runs the module's top level, so `main` cannot be checked before
    # anything runs: a tenant's import-time exception is a real outcome.
    spec.loader.exec_module(module)
    return module


def run():
    try:
        module = load()
    except BaseException as exc:
        failed("exception", exc)
        return

    entry = getattr(module, "main", None)
    if not callable(entry):
        frame({"error": {"code": "no_entry_point",
                         "message": "main is not defined"}})
        return

    try:
        with open("/context.json", "r") as handle:
            context = json.load(handle)
    except BaseException as exc:
        failed("exception", exc)
        return

    try:
        frame({"ok": entry(context)})
    except BaseException as exc:
        # The traceback goes to stderr, where the tenant's own output lives,
        # and the message goes in the envelope. Neither becomes an atom on the
        # way back: both are text.
        traceback.print_exc(file=sys.stderr)
        failed("exception", exc)


run()
