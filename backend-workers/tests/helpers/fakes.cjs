// Shared fakes for the Stripe/pay/autopay Worker tests (Phase 24). Nothing
// here touches the network: `installFetch` replaces global.fetch with a
// router over Supabase REST, Stripe HTTP and Resend/Expo calls, and
// `fakeStripe` is an in-memory stand-in for the Stripe client that routes
// take through their injectable `stripeFactory`.

const STRIPE_API = 'https://api.stripe.com';

function jsonRes(body, status = 200, headers = {}) {
  return new Response(body === undefined ? '' : JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'request-id': 'req_test', ...headers },
  });
}

// Hono-like context. `c.json`/`c.body` return { status, body, headers } so a
// test can assert on the handler's response directly.
let ipCounter = 0;
function fakeC({
  method = 'POST',
  body,
  rawBody,
  query = {},
  headers = {},
  env = {},
  url = 'https://tradeready-backend.tradeready.workers.dev/api/x',
} = {}) {
  ipCounter += 1;
  const reqHeaders = {
    'cf-connecting-ip': `198.51.100.${ipCounter % 250}`,
    'user-agent': 'node-test-agent',
    ...Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v])),
  };
  const out = {};
  return {
    env: {
      SUPABASE_URL: 'https://supa.test',
      SUPABASE_ANON_KEY: 'anon',
      SUPABASE_SERVICE_ROLE_KEY: 'srk',
      STRIPE_SECRET_KEY: 'sk_test_platform',
      STRIPE_CONNECT_WEBHOOK_SECRET: 'whsec_test',
      RESEND_API_KEY: 're_test',
      ...env,
    },
    responseHeaders: out,
    header(name, value) { out[name] = value; },
    req: {
      method,
      url,
      header: (k) => reqHeaders[String(k).toLowerCase()],
      query: (k) => query[k],
      json: async () => {
        if (body === undefined) throw new Error('no body');
        return body;
      },
      text: async () => (rawBody !== undefined ? rawBody : JSON.stringify(body ?? {})),
    },
    json: (b, s = 200) => ({ status: s, body: b, headers: { ...out } }),
    body: (b, s = 200) => ({ status: s, body: b, headers: { ...out } }),
  };
}

// Replaces global.fetch with `route(req)`; every call is logged as
// { url, u (URL), method, headers (lowercased object), body (string),
// json (parsed JSON or form object) }. `route` returns a Response (or a
// plain { status, body } that is wrapped). Returns { calls, restore }.
function installFetch(route) {
  const original = global.fetch;
  const calls = [];
  global.fetch = async (input, init = {}) => {
    const url = String(input && input.url ? input.url : input);
    const u = new URL(url);
    const method = (init.method || 'GET').toUpperCase();
    const headers = {};
    new Headers(init.headers || {}).forEach((v, k) => { headers[k] = v; });
    const body = typeof init.body === 'string' ? init.body : init.body == null ? '' : String(init.body);
    let parsed = null;
    if (body) {
      try { parsed = JSON.parse(body); } catch { parsed = Object.fromEntries(new URLSearchParams(body)); }
    }
    const call = { url, u, method, headers, body, json: parsed };
    calls.push(call);
    const res = await route(call);
    if (res instanceof Response) return res;
    if (res && typeof res === 'object' && 'status' in res) return jsonRes(res.body, res.status, res.headers);
    throw new Error(`unrouted fetch ${method} ${url}`);
  };
  return {
    calls,
    restore() { global.fetch = original; },
  };
}

// --- Fake Stripe client ------------------------------------------------------

function stripeError(type, raw = {}) {
  const err = new Error(raw.message || type);
  err.type = type;
  err.raw = raw;
  err.code = raw.code;
  err.decline_code = raw.decline_code;
  err.statusCode = raw.statusCode;
  err.payment_intent = raw.payment_intent;
  return err;
}

const cardError = (code, decline_code, payment_intent) =>
  stripeError('StripeCardError', { code, decline_code, statusCode: 402, message: `Your card was declined (${decline_code || code}).`, payment_intent });
const connectionError = () => stripeError('StripeConnectionError', { message: 'socket hang up' });
const apiError = (statusCode = 500) => stripeError('StripeAPIError', { statusCode, message: 'Stripe is having a moment' });
const invalidRequest = (message = 'No such object', code = 'resource_missing') =>
  stripeError('StripeInvalidRequestError', { statusCode: 400, code, message });

// Each resource method is `async (…args) => handler(…args)`; `handlers` keys
// look like 'paymentIntents.create'. Unhandled calls throw so a test never
// silently passes through an unexpected Stripe call. Every call is logged.
function fakeStripe(handlers = {}) {
  const calls = [];
  const resource = (name, methods) => {
    const obj = {};
    for (const m of methods) {
      const key = `${name}.${m}`;
      obj[m] = async (...args) => {
        calls.push({ key, args });
        const h = handlers[key];
        if (!h) throw new Error(`unexpected stripe call ${key}`);
        return h(...args);
      };
    }
    return obj;
  };
  const client = {
    calls,
    customers: resource('customers', ['create', 'retrieve']),
    paymentIntents: resource('paymentIntents', ['create', 'retrieve', 'cancel', 'list']),
    setupIntents: resource('setupIntents', ['retrieve']),
    paymentMethods: resource('paymentMethods', ['retrieve', 'detach']),
    paymentLinks: resource('paymentLinks', ['create', 'update']),
    products: resource('products', ['create']),
    prices: resource('prices', ['create']),
    checkout: { sessions: resource('checkout.sessions', ['create', 'retrieve', 'list', 'expire']) },
    webhooks: {
      constructEventAsync: async (raw, sig, secret) => {
        calls.push({ key: 'webhooks.constructEventAsync', args: [raw, sig, secret] });
        if (handlers['webhooks.constructEventAsync']) return handlers['webhooks.constructEventAsync'](raw, sig, secret);
        if (sig !== 'valid') throw new Error('bad signature');
        return JSON.parse(raw);
      },
    },
  };
  client.callsTo = (key) => calls.filter((c) => c.key === key);
  return client;
}

// --- Fake Supabase (PostgREST subset) ----------------------------------------
//
// Tables are arrays of rows. Supports the filters this codebase uses:
// eq., neq., in.(…), is.null/is.false/is.true, not.is.null, lt./lte./gt./gte.
// on plain columns and on `data->>key`; select= (ignored: whole rows come
// back); order= (single column, asc/desc); limit=. POST inserts (with
// on_conflict + ignore-duplicates / merge-duplicates), PATCH updates the
// filtered rows (returns them with return=representation), DELETE removes.
// Unique constraints are declared per table so claim races are realistic.

function parseFilterValue(raw) {
  return raw;
}

function columnValue(row, col) {
  const m = /^data->>(.+)$/.exec(col);
  if (m) {
    const v = row.data ? row.data[m[1]] : undefined;
    return v === undefined || v === null ? null : String(v);
  }
  const m2 = /^data->(\w+)->>(.+)$/.exec(col);
  if (m2) {
    const inner = row.data ? row.data[m2[1]] : undefined;
    const v = inner ? inner[m2[2]] : undefined;
    return v === undefined || v === null ? null : String(v);
  }
  return row[col];
}

function matches(row, col, expr) {
  const v = columnValue(row, col);
  const s = (x) => (x === null || x === undefined ? null : String(x));
  if (expr.startsWith('eq.')) return s(v) === expr.slice(3);
  if (expr.startsWith('neq.')) return s(v) !== expr.slice(4);
  if (expr === 'is.null') return v === null || v === undefined;
  if (expr === 'not.is.null') return !(v === null || v === undefined);
  if (expr === 'is.false') return v === false || v === 'false';
  if (expr === 'is.true') return v === true || v === 'true';
  if (expr.startsWith('in.(')) {
    const list = expr.slice(4, -1).split(',').map((x) => x.replace(/^"|"$/g, ''));
    return list.includes(s(v));
  }
  const cmp = /^(lt|lte|gt|gte)\.(.+)$/.exec(expr);
  if (cmp) {
    const [, op, raw] = cmp;
    const a = String(v);
    const b = raw;
    if (op === 'lt') return a < b;
    if (op === 'lte') return a <= b;
    if (op === 'gt') return a > b;
    return a >= b;
  }
  throw new Error(`fake supabase: unsupported filter ${col}=${expr}`);
}

function fakeSupabase(tables = {}, { unique = {}, defaults = {}, failOn = {} } = {}) {
  const db = { tables: {}, unique, writes: [] };
  for (const [k, rows] of Object.entries(tables)) db.tables[k] = rows.map((r) => JSON.parse(JSON.stringify(r)));
  const rowsOf = (t) => (db.tables[t] = db.tables[t] || []);

  function filterRows(table, params) {
    let rows = rowsOf(table);
    for (const [k, v] of params) {
      if (['select', 'order', 'limit', 'on_conflict', 'offset'].includes(k)) continue;
      rows = rows.filter((r) => matches(r, k, parseFilterValue(v)));
    }
    const order = params.get('order');
    if (order) {
      const [col, dir] = order.split('.');
      rows = [...rows].sort((a, b) => {
        const x = String(a[col] ?? '');
        const y = String(b[col] ?? '');
        return dir === 'desc' ? (x < y ? 1 : x > y ? -1 : 0) : x < y ? -1 : x > y ? 1 : 0;
      });
    }
    const limit = params.get('limit');
    if (limit) rows = rows.slice(0, Number(limit));
    return rows;
  }

  function conflictKey(table, row, cols) {
    return cols.map((c) => String(row[c])).join('|');
  }

  db.handle = (call) => {
    const m = /^\/rest\/v1\/([^/?]+)/.exec(call.u.pathname);
    if (!m) return null;
    const table = decodeURIComponent(m[1]);
    const params = call.u.searchParams;
    const fail = failOn[`${call.method} ${table}`];
    if (fail) return jsonRes({ message: 'boom' }, typeof fail === 'number' ? fail : 500);
    const prefer = call.headers.prefer || '';
    if (call.method === 'GET') return jsonRes(JSON.parse(JSON.stringify(filterRows(table, params))));
    if (call.method === 'POST') {
      const incoming = Array.isArray(call.json) ? call.json : [call.json];
      const onConflict = params.get('on_conflict');
      const uniq = unique[table] || [];
      const keySets = onConflict ? [onConflict.split(','), ...uniq] : uniq;
      const out = [];
      for (const raw of incoming) {
        const row = { ...(defaults[table] ? defaults[table]() : {}), ...raw };
        if (!row.id && table !== 'invoices') row.id = require('node:crypto').randomUUID();
        const existing = rowsOf(table);
        let clash = null;
        for (const cols of keySets) {
          if (cols.some((c) => row[c] === undefined || row[c] === null)) continue;
          if (cols.where && !cols.where(row)) continue;
          const key = conflictKey(table, row, cols);
          clash = existing.find((r) => conflictKey(table, r, cols) === key && (!cols.where || cols.where(r)));
          if (clash) break;
        }
        if (!clash && table === 'invoices') clash = existing.find((r) => r.id === row.id);
        if (clash) {
          if (prefer.includes('ignore-duplicates')) continue;
          if (prefer.includes('merge-duplicates')) {
            Object.assign(clash, row);
            out.push(clash);
            db.writes.push({ table, op: 'upsert', row: JSON.parse(JSON.stringify(row)) });
            continue;
          }
          return jsonRes({ code: '23505', message: 'duplicate key value violates unique constraint' }, 409);
        }
        existing.push(row);
        out.push(row);
        db.writes.push({ table, op: 'insert', row: JSON.parse(JSON.stringify(row)) });
      }
      return jsonRes(prefer.includes('return=representation') ? JSON.parse(JSON.stringify(out)) : [], 201);
    }
    if (call.method === 'PATCH') {
      const rows = filterRows(table, params);
      const before = rows.map((r) => ({ ...r }));
      for (const r of rows) Object.assign(r, call.json);
      // Unique constraints (incl. partial ones via cols.where) after the write.
      for (const cols of unique[table] || []) {
        const seen = new Map();
        for (const r of rowsOf(table)) {
          if (cols.some((c) => r[c] === undefined || r[c] === null)) continue;
          if (cols.where && !cols.where(r)) continue;
          const key = conflictKey(table, r, cols);
          if (seen.has(key)) {
            rows.forEach((r2, i) => { for (const k of Object.keys(r2)) delete r2[k]; Object.assign(r2, before[i]); });
            return jsonRes({ code: '23505', message: 'duplicate key value violates unique constraint' }, 409);
          }
          seen.set(key, r);
        }
      }
      db.writes.push({ table, op: 'patch', filter: call.u.search, patch: call.json, count: rows.length });
      return jsonRes(prefer.includes('return=representation') ? JSON.parse(JSON.stringify(rows)) : [], 200);
    }
    if (call.method === 'DELETE') {
      const rows = filterRows(table, params);
      db.tables[table] = rowsOf(table).filter((r) => !rows.includes(r));
      db.writes.push({ table, op: 'delete', filter: call.u.search, count: rows.length });
      return jsonRes([], 200);
    }
    return null;
  };
  db.rows = (t) => rowsOf(t);
  return db;
}

// The autopay tables' constraints from 20261003_autopay.sql.
const AUTOPAY_UNIQUE = {
  autopay_enrollments: [Object.assign(['user_id', 'recurring_invoice_id'], { where: (r) => r.status === 'active' }), ['checkout_session_id']],
  autopay_charges: [['user_id', 'invoice_id', 'attempt']],
};

module.exports = {
  AUTOPAY_UNIQUE,
  STRIPE_API,
  jsonRes,
  fakeC,
  installFetch,
  fakeStripe,
  stripeError,
  cardError,
  connectionError,
  apiError,
  invalidRequest,
  fakeSupabase,
};
