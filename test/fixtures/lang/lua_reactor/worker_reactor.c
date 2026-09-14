/*
 * An init()/handle() reactor over Lua 5.4, for the worker kernel.
 *
 * The third guest, and it exists to be unlike the other two rather than to be
 * useful: QuickJS and CPython are both large interpreters whose images run to
 * hundreds of kilobytes and tens of megabytes. Lua's is a few hundred
 * kilobytes, which is where a snapshot mechanism that quietly assumed bulk
 * would show it.
 *
 * `init()` opens the standard libraries and evaluates a JSON codec written in
 * Lua, so the codec is compiled once into the image rather than once per
 * request. That is a small demonstration of what an image is for, and it is
 * why the codec is not written in C.
 */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* `script_v1.channel`, for the reason the other two reactors use it: the
 * combined transport learns its per-request marker from argv, and anything
 * read during `init()` is frozen into the image every request restores. */
__attribute__((import_module("worker"), import_name("result")))
void worker_result(const char *ptr, int len);

/* WASI has neither, and a worker guest must not have them regardless: there is
 * no shell to run and one read-only directory to write into. Lua's standard
 * library still references them, so they are defined here to fail rather than
 * to be absent, and `docs/lua.md` says `os.execute` and `io.tmpfile` are among
 * the things this does not promise.
 *
 * `system(NULL)` is the "is there a shell" question, and the honest answer is
 * no; anything else is an error. */
FILE *tmpfile(void) { return NULL; }
int system(const char *cmd) { return cmd == NULL ? 0 : -1; }

static lua_State *L;

static int l_worker_result(lua_State *S)
{
    size_t n;
    const char *s = luaL_checklstring(S, 1, &n);
    worker_result(s, (int)n);
    return 0;
}

/* Enough of JSON for the profile, and no more: `script_v1` carries a context
 * in and a result out, both of which are objects of scalars, arrays and
 * objects. Written in Lua so that evaluating it is what `init()` pays for and
 * what the image keeps.
 *
 * Lua has one table type for both arrays and objects, so encoding has to
 * decide which a table is. An empty table encodes as an object, which is the
 * useful default for a result. */
static const char JSON[] =
    "local J = {}\n"
    "local function esc(c) return string.format('\\\\u%04x', c:byte()) end\n"
    "function J.encode(v)\n"
    "  local t = type(v)\n"
    "  if v == nil then return 'null'\n"
    "  elseif t == 'boolean' then return tostring(v)\n"
    "  elseif t == 'number' then\n"
    "    if v ~= v or v == math.huge or v == -math.huge then return 'null' end\n"
    "    if math.type(v) == 'integer' then return tostring(v) end\n"
    "    return string.format('%.14g', v)\n"
    "  elseif t == 'string' then\n"
    "    return '\"' .. v:gsub('[%c\"\\\\]', function(c)\n"
    "      if c == '\"' then return '\\\\\"' elseif c == '\\\\' then return '\\\\\\\\'\n"
    "      elseif c == '\\n' then return '\\\\n' elseif c == '\\t' then return '\\\\t'\n"
    "      elseif c == '\\r' then return '\\\\r' else return esc(c) end\n"
    "    end) .. '\"'\n"
    "  elseif t == 'table' then\n"
    "    local n = 0\n"
    "    for _ in pairs(v) do n = n + 1 end\n"
    "    if n > 0 and n == #v then\n"
    "      local out = {}\n"
    "      for i = 1, n do out[i] = J.encode(v[i]) end\n"
    "      return '[' .. table.concat(out, ',') .. ']'\n"
    "    end\n"
    "    local out = {}\n"
    "    for k, x in pairs(v) do\n"
    "      out[#out + 1] = J.encode(tostring(k)) .. ':' .. J.encode(x)\n"
    "    end\n"
    "    return '{' .. table.concat(out, ',') .. '}'\n"
    "  end\n"
    "  error('cannot encode a ' .. t)\n"
    "end\n"
    "local P = {}\n"
    "local function ws(s, i)\n"
    "  local _, j = s:find('^[ \\t\\r\\n]*', i)\n"
    "  return j + 1\n"
    "end\n"
    "function P.value(s, i)\n"
    "  i = ws(s, i)\n"
    "  local c = s:sub(i, i)\n"
    "  if c == '{' then\n"
    "    local o = {}\n"
    "    i = ws(s, i + 1)\n"
    "    if s:sub(i, i) == '}' then return o, i + 1 end\n"
    "    while true do\n"
    "      local k; k, i = P.value(s, i)\n"
    "      i = ws(s, i)\n"
    "      i = i + 1\n"
    "      local v; v, i = P.value(s, i)\n"
    "      o[k] = v\n"
    "      i = ws(s, i)\n"
    "      if s:sub(i, i) == ',' then i = i + 1 else return o, i + 1 end\n"
    "    end\n"
    "  elseif c == '[' then\n"
    "    local a = {}\n"
    "    i = ws(s, i + 1)\n"
    "    if s:sub(i, i) == ']' then return a, i + 1 end\n"
    "    while true do\n"
    "      local v; v, i = P.value(s, i)\n"
    "      a[#a + 1] = v\n"
    "      i = ws(s, i)\n"
    "      if s:sub(i, i) == ',' then i = i + 1 else return a, i + 1 end\n"
    "    end\n"
    "  elseif c == '\"' then\n"
    "    local out, j = {}, i + 1\n"
    "    while true do\n"
    "      local ch = s:sub(j, j)\n"
    "      if ch == '\"' then return table.concat(out), j + 1 end\n"
    "      if ch == '\\\\' then\n"
    "        local e = s:sub(j + 1, j + 1)\n"
    "        local m = {n = '\\n', t = '\\t', r = '\\r', b = '\\b', f = '\\f'}\n"
    "        if e == 'u' then\n"
    "          out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16))\n"
    "          j = j + 6\n"
    "        else\n"
    "          out[#out + 1] = m[e] or e\n"
    "          j = j + 2\n"
    "        end\n"
    "      else\n"
    "        out[#out + 1] = ch\n"
    "        j = j + 1\n"
    "      end\n"
    "    end\n"
    "  elseif s:sub(i, i + 3) == 'true' then return true, i + 4\n"
    "  elseif s:sub(i, i + 4) == 'false' then return false, i + 5\n"
    "  elseif s:sub(i, i + 3) == 'null' then return nil, i + 4\n"
    "  else\n"
    "    local n, j = s:match('^(%-?%d+%.?%d*[eE]?[-+]?%d*)()', i)\n"
    "    return tonumber(n), j\n"
    "  end\n"
    "end\n"
    "function J.decode(s)\n"
    "  if s == nil or s == '' then return nil end\n"
    "  local v = P.value(s, 1)\n"
    "  return v\n"
    "end\n"
    "json = J\n";

__attribute__((export_name("init")))
int init(void)
{
    L = luaL_newstate();
    if (L == NULL)
        return 1;
    luaL_openlibs(L);
    lua_pushcfunction(L, l_worker_result);
    lua_setglobal(L, "__worker_result");
    /* The codec is compiled here, into the image, rather than on every
     * request. */
    if (luaL_dostring(L, JSON) != LUA_OK)
        return 2;
    return 0;
}

/* Whether the runtime came up. `init()`'s own return value never reaches the
 * kernel, which does not read guest values, so the adapter's `validate` asks
 * this instead of asking the module what it exports. */
__attribute__((export_name("ready")))
int ready(void)
{
    return L != NULL;
}

/* The bootstrap. Loads the tenant's chunk by absolute path, never by a search
 * path, and writes a result on both the success and the failure path: a
 * request that ends without one is `no_result`, a different answer from an
 * error. */
static const char BOOT[] =
    "local function fail(code, message)\n"
    "  __worker_result(json.encode({error = {code = code, message = message}}))\n"
    "end\n"
    "local f = io.open('/context.json', 'r')\n"
    "local ctx = nil\n"
    "if f then ctx = json.decode(f:read('a')); f:close() end\n"
    "local chunk, err = loadfile('/main.lua')\n"
    "if not chunk then fail('exception', tostring(err)) return end\n"
    "local ok, res = pcall(chunk)\n"
    "if not ok then fail('exception', tostring(res)) return end\n"
    "if type(main) ~= 'function' then\n"
    "  fail('no_entry_point', 'main is not defined')\n"
    "else\n"
    "  local ok2, out = pcall(main, ctx)\n"
    "  if ok2 then __worker_result(json.encode({ok = out}))\n"
    "  else fail('exception', tostring(out)) end\n"
    "end\n";

__attribute__((export_name("handle")))
int handle(void)
{
    if (L == NULL)
        return 1;
    return luaL_dostring(L, BOOT) == LUA_OK ? 0 : 1;
}
