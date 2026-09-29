const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { describe, test } = require('node:test');

const workerCorePath = path.join(__dirname, '../lib/accountDeletion.js');
const vercelCorePath = path.join(__dirname, '../../backend/lib/accountDeletion.js');
const implementations = [
  ['Cloudflare Worker', require(workerCorePath)],
  ['Vercel', require(vercelCorePath)],
];

const USER_ID = '11111111-2222-4333-8444-555555555555';
const ENV = {
  SUPABASE_URL: 'https://staging-project.supabase.co/',
  SUPABASE_ANON_KEY: 'publishable-test-key',
  SUPABASE_SERVICE_ROLE_KEY: 'secret-test-key',
};

function fakeResponse(status, body = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function request(overrides = {}) {
  return {
    method: 'POST',
    ip: '203.0.113.7',
    authorization: 'Bearer user-jwt',
    env: ENV,
    ...overrides,
  };
}

describe('account deletion backend parity', () => {
  test('the Vercel and Worker cores remain byte-identical', () => {
    assert.equal(fs.readFileSync(workerCorePath, 'utf8'), fs.readFileSync(vercelCorePath, 'utf8'));
  });

  for (const [name, { RATE_LIMIT, createAccountDeletionService, parseBearer }] of implementations) {
    describe(name, () => {
      test('accepts one strict bearer token and rejects malformed values', () => {
        assert.equal(parseBearer('Bearer abc.def.ghi'), 'abc.def.ghi');
        for (const value of [undefined, '', 'Bearer', 'Bearer ', 'bearer token', 'Bearer a b']) {
          assert.equal(parseBearer(value), null);
        }
      });

      test('handles preflight and wrong methods without touching Supabase', async () => {
        const fetchImpl = async () => assert.fail('fetch must not run');
        const service = createAccountDeletionService({ fetchImpl });

        assert.deepEqual(await service.handle(request({ method: 'OPTIONS' })), {
          status: 200,
          body: null,
        });
        assert.deepEqual(await service.handle(request({ method: 'GET' })), {
          status: 405,
          body: { error: 'Method not allowed' },
        });
      });

      test('fails closed when configuration or authorization is missing', async () => {
        const fetchImpl = async () => assert.fail('fetch must not run');
        const service = createAccountDeletionService({ fetchImpl });

        assert.equal((await service.handle(request({ env: {} }))).status, 500);
        assert.deepEqual(
          await service.handle(request({ authorization: 'Bearer ' })),
          { status: 401, body: { error: 'Unauthorized' } }
        );
      });

      test('maps rejected and malformed verified users to bounded 401 responses', async () => {
        const rejected = createAccountDeletionService({
          fetchImpl: async () => fakeResponse(401),
        });
        assert.deepEqual(await rejected.handle(request()), {
          status: 401,
          body: { error: 'Invalid or expired session. Please sign in again.' },
        });

        const malformed = createAccountDeletionService({
          fetchImpl: async () => fakeResponse(200, { id: '../not-a-user-id' }),
        });
        assert.deepEqual(await malformed.handle(request({ ip: '203.0.113.8' })), {
          status: 401,
          body: { error: 'Unauthorized' },
        });
      });

      test('deletes the verified Auth user once and never issues table-by-table deletes', async () => {
        const calls = [];
        const events = [];
        const fetchImpl = async (url, init = {}) => {
          calls.push({ url, init });
          if (calls.length === 1) {
            events.push('verify-user');
            return fakeResponse(200, { id: USER_ID });
          }
          events.push('delete-auth-user');
          return fakeResponse(200);
        };
        const photos = {
          async list(options) {
            events.push(`list:${options.cursor || 'first'}`);
            if (!options.cursor) {
              return {
                objects: [{ key: `${USER_ID}/one.jpg` }, { key: 'another-user/two.jpg' }],
                truncated: true,
                cursor: 'next-page',
              };
            }
            return {
              objects: [{ key: `${USER_ID}/three.jpg` }],
              truncated: false,
            };
          },
          async delete(keys) {
            events.push(`delete-r2:${keys.join(',')}`);
          },
        };
        const service = createAccountDeletionService({ fetchImpl });

        assert.deepEqual(
          await service.handle(request({ env: { ...ENV, PHOTOS: photos } })),
          { status: 200, body: { success: true } }
        );
        assert.equal(calls.length, 2);
        assert.equal(calls[0].url, 'https://staging-project.supabase.co/auth/v1/user');
        assert.deepEqual(calls[0].init.headers, {
          Authorization: 'Bearer user-jwt',
          apikey: ENV.SUPABASE_ANON_KEY,
        });
        assert.equal(
          calls[1].url,
          `https://staging-project.supabase.co/auth/v1/admin/users/${USER_ID}`
        );
        assert.equal(calls[1].init.method, 'DELETE');
        assert.deepEqual(calls[1].init.headers, {
          Authorization: `Bearer ${ENV.SUPABASE_SERVICE_ROLE_KEY}`,
          apikey: ENV.SUPABASE_SERVICE_ROLE_KEY,
        });
        assert.ok(calls.every(({ url }) => !url.includes('/rest/v1/')));
        assert.deepEqual(events, [
          'verify-user',
          'delete-auth-user',
          'list:first',
          `delete-r2:${USER_ID}/one.jpg`,
          'list:next-page',
          `delete-r2:${USER_ID}/three.jpg`,
        ]);
      });

      test('does not touch R2 or expose provider details when Auth deletion fails', async () => {
        const logged = [];
        let calls = 0;
        const fetchImpl = async () => {
          calls += 1;
          return calls === 1
            ? fakeResponse(200, { id: USER_ID })
            : fakeResponse(503, { message: 'provider-internal-detail' });
        };
        const photos = {
          async list() {
            assert.fail('R2 must not run before confirmed Auth deletion');
          },
        };
        const service = createAccountDeletionService({
          fetchImpl,
          logger: { error: (message) => logged.push(message) },
        });

        assert.deepEqual(
          await service.handle(request({ env: { ...ENV, PHOTOS: photos } })),
          {
            status: 500,
            body: { error: 'Failed to delete account. Please try again or contact support.' },
          }
        );
        assert.deepEqual(logged, ['delete-account: request failed before confirmed completion']);
        assert.ok(!JSON.stringify(logged).includes('provider-internal-detail'));
      });

      test('treats post-delete R2 residue as success without leaking object errors', async () => {
        const logged = [];
        let calls = 0;
        const service = createAccountDeletionService({
          fetchImpl: async () => {
            calls += 1;
            return calls === 1 ? fakeResponse(200, { id: USER_ID }) : fakeResponse(200);
          },
          logger: { error: (message) => logged.push(message) },
        });
        const photos = {
          async list() {
            throw new Error('private-object-key');
          },
        };

        assert.deepEqual(
          await service.handle(request({ env: { ...ENV, PHOTOS: photos } })),
          { status: 200, body: { success: true } }
        );
        assert.deepEqual(logged, ['delete-account: R2 photo purge failed after account deletion']);
        assert.ok(!JSON.stringify(logged).includes('private-object-key'));
      });

      test('rate-limits the sixth destructive request from one IP', async () => {
        const service = createAccountDeletionService({
          fetchImpl: async () => fakeResponse(401),
          now: () => 1234,
        });

        for (let index = 0; index < RATE_LIMIT; index += 1) {
          assert.equal((await service.handle(request())).status, 401);
        }
        assert.equal((await service.handle(request())).status, 429);
      });
    });
  }
});
