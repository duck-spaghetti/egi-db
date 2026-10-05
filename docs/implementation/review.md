# Initial release review

## Fixed target

Two independent agents reviewed the same committed snapshot from master
87cc9d3d1b1637f59b4b26e570fa5b86e8a63369 to dev
57f7cd86958639ef91357ac558e22e3c64df3ed9. Snapshot patch SHA256:
d8a6e369da0d73927e51ab14da7a2433879da5c3f2fd688675a16d689f51e94d.
The target includes all initial implementation, tests and documentation.
Specification v1.1, approved plan r0.2, all ten issue criteria and explicit subsequent
user decisions govern scope. Initial four-change consolidation is authorized.

## Standards

One finding: verify_revision omitted the controlled mutation lock and READ COMMITTED
requirement documented in setup.md. Scope authorization could therefore read an
obsolete shared-resource consumer set. Corrected by locking before revision/scope
lookup. Regression checks demonstrate contention against a separate connection
(55P03), and reject REPEATABLE READ with the intended 22023 diagnostic.
No other actionable documented violation or baseline smell was reported.

## Spec

Two findings:

1. Weekly closing transitions omitted yesterday's overnight interval endpoint.
   Candidate civil dates now include the previous day. The hours contract asserts
   both closure at the correct instant and 3600 elapsed seconds remaining.
2. Approved taxonomy adoption changed public metadata without advancing public
   sequence. Adoption now records metadata invalidation anchored to the frozen
   vocabulary's retained publication and marks affected published services.
   The taxonomy contract asserts sequence advancement even in an empty territory
   and retained publication lineage.

No unrequested scope was reported. These are corrections within approved contracts.

## Verification and delivery boundary

The full disposable lifecycle passed after remediation, exit 0: staged deployment,
Sqitch verify, clean-data checks, all ten behavioral contracts, actual two-connection
concurrency, full revert/redeploy and repeated checks. Runtime PostgreSQL 18.3,
PostGIS 3.6.0, Sqitch 1.6.1. Target /private/tmp/egi-contract.M3wzaF/data was removed.
Evidence: work/execution/review-remediation.log. Reviewers inspect static code and
do not claim independent test execution. Final affected-change re-review follows
the remediation commit; the release report records its result and exact identity.

Dev push, PR to master and acceptance-based closure of all ten issues are authorized.
Production deployment, source bootstrap, exporters and a master merge remain outside
this delivery. Old Sqitch registries are not upgraded in place by this rebaseline.
