# Fixture cutover charter

**Status: Owner-approved 2026-09-01.** Fixture charter for
run-phase-12-stage-preflight-tests.sh. Not the real charter; used only to
exercise the preflight's parsing.

## 9. Decision log

| # | Date | Stage | Decision | Evidence | Decider | Rollback trigger considered |
|---|---|---|---|---|---|---|
| 1 | 2026-09-01 | pre-A | Fixture approval row | n/a | owner | n/a |
| 2 | 2026-09-01 | pre-A | P12-903 ruled: R900 — fixture accepts the risk for Stage A | n/a | owner | n/a |

## 10. Defect list

### 12.00b.1 — I2 rejected-change handling (blocks Stage A entry) (1)

| ID | Item | Sev | State @`6d573a3` | Handling | Status |
|---|---|---|---|---|---|
| L238 | Fixture I2 item | S2 | Open | 12.00b.1 | Fixed — 12.00b.1 (fixture) |

### 12.00b.2 — S1/S2 code fixes (block Stage A entry) (2)

| ID | Item | Sev | State @`6d573a3` | Handling | Status |
|---|---|---|---|---|---|
| L74 | Fixture item one | S2 | Open | 12.00b.2 | Fixed — 12.00b.2 (fixture) |
| L130 | Fixture item two | S1 | Open | 12.00b.2 | Fixed — 12.00b.2 (fixture) |

### Backlog — post-cutover S3 work (does not block Stage A) (1)

| ID | Item | Sev | State @`6d573a3` | Handling | Status |
|---|---|---|---|---|---|
| L999 | Fixture backlog item | S3 | Open | backlog | Open |

### New in Phase 12 (3)

| ID | Item | Sev | Found (date, source) | Handling | Status |
|---|---|---|---|---|---|
| P12-901 | Fixture closed S1 item | **S1** | 2026-09-01, fixture | fixture | Fixed — fixture (`fix(fixture): closes P12-901`) |
| P12-902 | Fixture backlog S3 item, still open | S3 | 2026-09-01, fixture | backlog | Open (backlog) |
| P12-903 | Fixture open S1 item with an owner ruling on file | **S1** | 2026-09-01, fixture | owner ruling (R900) | Open. Blocks unless the owner records a ruling (R900) |
