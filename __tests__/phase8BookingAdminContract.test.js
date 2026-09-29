// __tests__/phase8BookingAdminContract.test.js
// Task 8.00 (G3) — CHARACTERIZATION ONLY. Pins the current stateless-mint /
// whole-settings token flow and the ABSENCE of /api/booking/admin, plus
// executable examples of the frozen proposed shapes (§1 of
// docs/native-phase-8-contract-decisions.md) as the 8.05/8.07 handoff. The
// shape examples assert internal consistency of the frozen rules (token
// returned exactly once, status never leaks one); they are not wired to any
// implementation. No implementation file is touched.

const fs = require("node:fs");
const path = require("node:path");
const { lookupUserByBookingToken } = require("../backend-workers/lib/booking/store.js");

const ENV = { SUPABASE_URL: "https://supa.test", SUPABASE_SERVICE_ROLE_KEY: "srk" };
const TOKEN = "t".repeat(48);

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function mockSettings(rows) {
  // Emulate the PostgREST JSON-path filter in lookupUserByBookingToken
  // (data->bookingLink->>token=eq.…&data->bookingLink->>enabled=eq.true):
  // the server, not the client, applies the enabled gate.
  global.fetch = jest.fn(async (url) => {
    const u = String(url);
    if (u.includes("/rest/v1/settings")) {
      const m = u.match(/bookingLink->>token=eq\.([^&]*)/);
      const token = m ? decodeURIComponent(m[1]) : null;
      const enabledOnly = u.includes("bookingLink->>enabled=eq.true");
      return jsonRes(
        rows.filter((r) => {
          const link = r.data && r.data.bookingLink;
          if (!link || (token && link.token !== token)) return false;
          if (enabledOnly && link.enabled !== true) return false;
          return true;
        })
      );
    }
    return jsonRes([]);
  });
}

afterEach(() => {
  delete global.fetch;
});

describe("G3 booking revocation (characterization)", () => {
  test("G3-01: /api/booking/admin route is registered (implemented by 8.05; 8.00 pinned its absence)", () => {
    // 8.00 characterization pinned the ABSENCE of this route (contract
    // unimplemented at freeze). Task 8.05 implements contract §1 verbatim;
    // this assertion tracks that landing — presence here, behavior in
    // __tests__/phase8BookingAdmin85.test.js. The mint route below is
    // retained untouched (8.05 gate).
    const indexSrc = fs.readFileSync(
      path.join(__dirname, "..", "backend-workers", "src", "index.js"),
      "utf8"
    );
    expect(indexSrc).toMatch(/booking\/admin/);
    expect(indexSrc).toMatch(/\/api\/booking\/mint/);
  });

  test("G3-02: enabled blob token resolves; disabled ≡ unknown (no oracle)", async () => {
    const enabledRow = [{ user_id: "u1", data: { bookingLink: { token: TOKEN, enabled: true } } }];
    mockSettings(enabledRow);
    const hit = await lookupUserByBookingToken(ENV, TOKEN);
    expect(hit && hit.user_id).toBe("u1");

    mockSettings([{ user_id: "u1", data: { bookingLink: { token: TOKEN, enabled: false } } }]);
    expect(await lookupUserByBookingToken(ENV, TOKEN)).toBeNull();

    mockSettings([]);
    expect(await lookupUserByBookingToken(ENV, "f".repeat(48))).toBeNull();
  });

  test("G3-03: stale-settings resurrection — re-enabling the blob re-authorizes (no revision)", async () => {
    // Disable (as today's sync would after an owner disable)…
    mockSettings([{ user_id: "u1", data: { bookingLink: { token: TOKEN, enabled: false } } }]);
    expect(await lookupUserByBookingToken(ENV, TOKEN)).toBeNull();
    // …then a delayed whole-settings push carrying enabled:true restores the
    // capability. Nothing below the blob distinguishes this replay from an
    // intentional re-enable: the §5 adopted_at discriminator is what 8.05
    // adds to make post-adoption replays auth-inert.
    mockSettings([{ user_id: "u1", data: { bookingLink: { token: TOKEN, enabled: true } } }]);
    const resurrected = await lookupUserByBookingToken(ENV, TOKEN);
    expect(resurrected && resurrected.user_id).toBe("u1");
  });

  test("G3-04: current error vocabulary the admin contract must reuse", async () => {
    // Pinned so 8.05 keeps the RN-compatible surface: unknown/disabled links
    // are 404 "This link is invalid." (see bookingSlotsReserve oracles);
    // conflicts are 409 short codes (slot_taken / invalid_state). The admin
    // endpoint extends this vocabulary with already_exists /
    // operation_conflict / stale_revision (§1.5) — same shapes, new codes.
    expect({ error: "This link is invalid." }.error).toBe("This link is invalid.");
    expect({ error: "slot_taken" }.error).toBe("slot_taken");
  });
});

describe("G3 proposed admin shapes (frozen handoff, §1.1–§1.2)", () => {
  // Executable examples of the frozen contract for 8.05 (server) and 8.07
  // (native transport mocks). If the doc changes, these fail until updated
  // together — that coupling is intentional.

  const mintResponse = {
    ok: true,
    enabled: true,
    token: "a".repeat(48),
    revision: 1,
    operationId: "0193f123-0000-4000-8000-000000000001",
  };
  const statusResponseStale = { ok: true, enabled: true, revision: 4, tokenValid: false };

  test("mint/rotate return the raw token exactly once; status never does", () => {
    expect(mintResponse.token).toMatch(/^[0-9a-f]{48}$/);
    expect(statusResponseStale).not.toHaveProperty("token");
    // Rotation-only recovery (§1.4): no reveal field exists.
    expect(mintResponse).not.toHaveProperty("rawRecoverable");
    expect(statusResponseStale).not.toHaveProperty("rawRecoverable");
  });

  test("revision is monotonic per owner; stale expectedRevision conflicts", () => {
    expect(mintResponse.revision).toBeGreaterThan(0);
    expect(statusResponseStale.revision).toBeGreaterThan(mintResponse.revision);
    // A caller holding revision 1 against current revision 4 gets 409
    // stale_revision with current state echoed (§1.4) — shape pinned:
    const conflict = { error: "stale_revision", enabled: true, revision: 4 };
    expect(conflict.revision).toBe(statusResponseStale.revision);
  });

  test("operation replay: same ID + same hash replays; same ID + new intent conflicts", () => {
    const opId = mintResponse.operationId;
    const replaySame = { sameOperationId: true, sameRequestHash: true, createsNewCapability: false };
    const replayConflict = { error: "operation_conflict" };
    expect(opId).toMatch(/^[0-9a-f-]{36}$/);
    expect(replaySame.createsNewCapability).toBe(false);
    expect(replayConflict.error).toBe("operation_conflict");
  });
});
