# Fixture stage runbook

Fixture for run-phase-12-stage-preflight-tests.sh. Not the real stage runbook. The
preflight reads each stage's evidence template from here to learn that template's own
placeholder tokens; the three templates below are copied from
`docs/native-phase-12-stage-runbook.md` §2.3, §4.3 and §5.3.

### 2.3 Evidence template (append to `EI §24`, "### Stage A (12.04)")

```
Run <N>, <DATE>
Build: <NATIVE_VERSION> (<NATIVE_BUILD>)   Profile: TestFlight internal
Devices/OS: <MODEL> / iOS <VERSION>[, ...]
Accounts (aliases only): <ALIAS1>, <ALIAS2>, ...
Environment: REL (staging-configured) | REL+KEYS
Rows run (ID: result): <P2-P1: pass>, <P2-P2: pass>, ... <one line per row, or a
  reference to the filled-in EI rows themselves>
Native baselines: launch <cold/warm ms>, crash-free sessions <%>, sync error rate <%>,
  migration timing <s>
Defects raised: <P12-... or none>
Rows moved to Stage B (charter §4.3, owner's log entry): <IDs, or none>
Timing: <upload to processed>, <SA2 upgrade duration>
```

### 4.3 Evidence template (append to `EI §24`, "### Stage B (12.05)")

```
Run <N>, <DATE range: start - end (>=14 consecutive days)>
Build: <VERSION> (<BUILD>)   Profile: TestFlight external
Cohort segments covered (CH SB1): new <alias(es)>, established <alias(es)>,
  offline-heavy <...>, Stripe <...>, booking <...>, recurring-work <...>, iPad <...>,
  two-device mixed-client <...>
Environment: REL+KEYS (production-configured once R59 is resolved, or staging per
  the owner's ruling)
Rows run / metrics (TH-1 to TH-11, final 7 days): <value, in target Y/N> per row
  (link full data externally; do not paste customer data here)
Support contacts: <count>, triaged within SLA: <Y/N>
Rejected changes classified: <Y/N>
Defects raised: <P12-... or none>
Expo rollback candidate status at exit: processed, not submitted (P12-RB-1)
Rows moved between stages (charter §4.3, owner's log entry): <IDs, or none>
```

### 5.3 Evidence template (append to `EI §24`, "### Stage C (12.07)")

```
Run <N>, <DATE>
Build: <VERSION> (<BUILD>)   Release type: phased | Release to All Users
Release day: <DATE>   Watch days logged: <CH §9 row #>
Phased-release day-by-day %: 1% <DATE>, 2% <DATE>, 5% <DATE>, 10% <DATE>, 20% <DATE>,
  50% <DATE>, 100% <DATE> (or: paused on day <N> at <%>, reason <...>)
Metrics (TH-1 to TH-11, rolling 24h days 1-7 then rolling 7 days): <in target Y/N>
  per row
Legacy migration / backend compatibility retained: <Y/N, evidence>
Defects raised: <P12-... or none>
Outcome: reached 100% with metrics in threshold | Release to All Users chosen |
  RB playbook executed (link the decision-log row and RB record)
```
