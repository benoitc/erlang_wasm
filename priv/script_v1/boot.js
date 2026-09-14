// The `script_v1` bootstrap for QuickJS.
//
// Staged beside the tenant's source and run instead of it, so that the shape
// the tenant writes -- `export function main(context)` -- is the only thing
// they have to know. Everything here is the profile's half of the contract.
//
// It writes its output through rather than buffering it: a bootstrap that
// collected stdout and flushed at the end would defeat the streaming bound
// completely, and the bound is most of what makes an untrusted guest safe.
import * as std from 'std';

// argv without argv[0], so the marker the host minted for this request is
// args[1]. It is a delimiter and not a secret: this code can read it and so
// can the tenant's.
const marker = args[1];

function frame(envelope) {
    let json;
    try {
        json = JSON.stringify(envelope);
    } catch (e) {
        // A result that cannot be serialised is still an answer, and it has to
        // be framed as one rather than left to look like silence.
        json = JSON.stringify({
            error: { code: 'bad_result', message: 'result is not JSON-serialisable' }
        });
    }
    std.out.puts(marker);
    std.out.puts(json);
    std.out.puts('\n');
    std.out.flush();
}

function failed(code, e) {
    const message = (e && e.message) ? String(e.message) : String(e);
    frame({ error: { code: code, message: message } });
}

// Importing a module runs its top-level statements, so `main` cannot be
// checked before anything runs: a tenant's import-time exception is a real
// outcome and gets framed as one.
import('/main.js').then(
    (mod) => {
        if (typeof mod.main !== 'function') {
            frame({
                error: { code: 'no_entry_point', message: 'main is not exported' }
            });
            return;
        }
        let context;
        try {
            context = JSON.parse(std.loadFile('/context.json'));
        } catch (e) {
            failed('exception', e);
            return;
        }
        try {
            const result = mod.main(context);
            frame({ ok: result === undefined ? null : result });
        } catch (e) {
            failed('exception', e);
        }
    },
    (e) => failed('exception', e)
);
