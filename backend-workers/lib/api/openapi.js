// GET /v1/openapi.json (spec §8): an OpenAPI 3.1 document built once at
// module load from the same SCHEMA/FIELDS the mappers use and the same
// ROUTES table the router uses, so the document cannot drift from what the
// API actually returns. A test asserts every route and every field appears.
//
// API_BASE_URL is the one base-URL constant (decision Q4: workers.dev for
// v1). A branded host later is an edit here and in developers.html.

const { SCHEMA, FIELDS, API_VERSION } = require('./resources.js');
const { ROUTES, ERRORS, ERROR_CODES, DEFAULT_LIMIT, MAX_LIMIT } = require('./v1.js');
const { SCOPES, RESOURCE_SCOPE } = require('./keys.js');

const API_BASE_URL = 'https://tradeready-backend.tradeready.workers.dev';

const COMPONENT = Object.freeze({
  account: 'Account',
  customers: 'Customer',
  jobs: 'Job',
  estimates: 'Estimate',
  invoices: 'Invoice',
  payments: 'Payment',
  expenses: 'Expense',
  mileage: 'Mileage',
  tombstone: 'Tombstone',
});

const ref = (name) => ({ $ref: `#/components/schemas/${name}` });

function componentSchema(name) {
  return {
    type: 'object',
    properties: SCHEMA[name],
    required: [...FIELDS[name]],
    additionalProperties: false,
  };
}

const RATE_HEADERS = {
  'TradeReady-Api-Version': { $ref: '#/components/headers/ApiVersion' },
  'X-RateLimit-Limit': { $ref: '#/components/headers/RateLimitLimit' },
  'X-RateLimit-Remaining': { $ref: '#/components/headers/RateLimitRemaining' },
  'X-RateLimit-Reset': { $ref: '#/components/headers/RateLimitReset' },
};

function errorResponses(codes) {
  const byStatus = {};
  for (const code of codes) {
    const [status] = ERRORS[code];
    (byStatus[status] = byStatus[status] || []).push(code);
  }
  return Object.fromEntries(Object.entries(byStatus).map(([status, list]) => [
    status,
    {
      description: list.join(', '),
      headers: status === '429' ? { ...RATE_HEADERS, 'Retry-After': { $ref: '#/components/headers/RetryAfter' } } : undefined,
      content: { 'application/json': { schema: ref('Error') } },
    },
  ]));
}

const AUTH_ERRORS = ['invalid_key', 'key_revoked', 'key_expired', 'key_in_query', 'insufficient_scope',
  'invalid_parameter', 'method_not_allowed', 'rate_limited', 'unavailable', 'not_configured', 'server_error'];

function scopeNote(resource) {
  return resource === 'account' ? 'any scope' : RESOURCE_SCOPE[resource];
}

const LIST_PARAMETERS = [
  {
    name: 'limit',
    in: 'query',
    required: false,
    schema: { type: 'integer', minimum: 1, maximum: MAX_LIMIT, default: DEFAULT_LIMIT },
    description: `Records per page, 1 to ${MAX_LIMIT}.`,
  },
  {
    name: 'cursor',
    in: 'query',
    required: false,
    schema: { type: 'string' },
    description: 'The nextCursor from the previous page. Opaque.',
  },
  {
    name: 'updated_since',
    in: 'query',
    required: false,
    schema: { type: 'string', format: 'date-time' },
    description: 'Only records changed at or after this time. Turns on tombstones for deleted records.',
  },
];

function operation(route) {
  const tag = route.resource ? route.resource : 'meta';
  if (route.kind === 'openapi') {
    return {
      operationId: 'getOpenApiDocument',
      summary: 'This document',
      tags: [tag],
      security: [],
      responses: { 200: { description: 'OpenAPI 3.1 document', content: { 'application/json': { schema: { type: 'object' } } } } },
    };
  }
  const component = COMPONENT[route.resource];
  if (route.kind === 'account') {
    return {
      operationId: 'getAccount',
      summary: 'The business and the calling key',
      tags: [tag],
      'x-tradeready-scope': scopeNote(route.resource),
      responses: {
        200: {
          description: 'OK',
          headers: RATE_HEADERS,
          content: { 'application/json': { schema: { type: 'object', required: ['data'], properties: { data: ref(component) } } } },
        },
        ...errorResponses(AUTH_ERRORS),
      },
    };
  }
  if (route.kind === 'list') {
    return {
      operationId: `list${component}`,
      summary: `List ${route.resource}`,
      tags: [tag],
      'x-tradeready-scope': scopeNote(route.resource),
      parameters: LIST_PARAMETERS,
      responses: {
        200: {
          description: 'One keyset page, ordered by (updatedAt, id) ascending',
          headers: RATE_HEADERS,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['data', 'nextCursor', 'dataAsOf', 'nextUpdatedSince'],
                properties: {
                  data: { type: 'array', items: { oneOf: [ref(component), ref('Tombstone')] } },
                  nextCursor: { type: ['string', 'null'] },
                  dataAsOf: { type: ['string', 'null'], format: 'date-time' },
                  nextUpdatedSince: { type: ['string', 'null'], format: 'date-time' },
                },
              },
            },
          },
        },
        ...errorResponses([...AUTH_ERRORS, 'invalid_cursor']),
      },
    };
  }
  return {
    operationId: `get${component}`,
    summary: `One ${route.resource.replace(/s$/, '')} by id`,
    tags: [tag],
    'x-tradeready-scope': scopeNote(route.resource),
    parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
    responses: {
      200: {
        description: 'OK',
        headers: RATE_HEADERS,
        content: {
          'application/json': {
            schema: {
              type: 'object',
              required: ['data', 'dataAsOf'],
              properties: { data: ref(component), dataAsOf: { type: ['string', 'null'], format: 'date-time' } },
            },
          },
        },
      },
      ...errorResponses([...AUTH_ERRORS, 'not_found']),
    },
  };
}

function toOpenApiPath(template) {
  return template.replace(/:([A-Za-z]+)/g, '{$1}');
}

function buildDocument() {
  const paths = {};
  for (const route of ROUTES) {
    paths[toOpenApiPath(route.template)] = { get: operation(route) };
  }
  const schemas = Object.fromEntries(Object.entries(COMPONENT).map(([name, component]) => [component, componentSchema(name)]));
  schemas.Error = {
    type: 'object',
    required: ['error'],
    additionalProperties: false,
    properties: {
      error: {
        type: 'object',
        required: ['code', 'message'],
        additionalProperties: false,
        properties: { code: { type: 'string', enum: [...ERROR_CODES] }, message: { type: 'string' } },
      },
    },
  };
  const doc = {
    openapi: '3.1.0',
    info: {
      title: 'TradeReady API',
      version: API_VERSION,
      description:
        'Read-only access to your TradeReady data for your own tools. Keys are server-to-server only. ' +
        'Data is the cloud copy as of your device\'s last sync (see dataAsOf). Docs: https://gettradereadyapp.com/developers.html',
    },
    servers: [{ url: API_BASE_URL }],
    security: [{ bearerAuth: [] }],
    tags: [{ name: 'meta' }, { name: 'account' }, ...Object.keys(RESOURCE_SCOPE).map((name) => ({ name }))],
    paths,
    components: {
      securitySchemes: {
        bearerAuth: { type: 'http', scheme: 'bearer', description: `A TradeReady API key (trk_…). Scopes: ${SCOPES.join(', ')}.` },
      },
      headers: {
        ApiVersion: { schema: { type: 'string' }, description: 'Date of the last additive change to /v1.' },
        RateLimitLimit: { schema: { type: 'integer' }, description: 'Requests allowed per minute for this key.' },
        RateLimitRemaining: { schema: { type: 'integer' }, description: 'Requests left in the current minute.' },
        RateLimitReset: { schema: { type: 'integer' }, description: 'Unix time (seconds) when the minute window resets.' },
        RetryAfter: { schema: { type: 'integer' }, description: 'Seconds to wait before retrying.' },
      },
      schemas,
    },
  };
  // A plain JSON value: no undefined members, nothing shared with SCHEMA.
  return JSON.parse(JSON.stringify(doc));
}

const OPENAPI_DOCUMENT = Object.freeze(buildDocument());

module.exports = { OPENAPI_DOCUMENT, API_BASE_URL, COMPONENT, buildDocument, toOpenApiPath };
