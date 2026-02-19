# Refactor TODO

- [x] 1. Share `AXWindowResolver` so resolver/dlopen initialization does not repeat across reflow paths.
- [x] 2. Remove duplicated floating decision branches by unifying snapshot/live evaluation.
- [x] 3. Unify duplicated reflow context setup shared by full/drop reflow paths.
- [x] 4. Simplify deferred lifecycle reflow logic into a single scheduling decision point.
- [ ] 5. Avoid repeated display lookups per cycle by introducing a display assignment snapshot.
- [ ] 6. Remove unused `WindowGeometryApplier.applyAsync`.
- [ ] 7. Remove duplicated target frame building logic (`LayoutPlanner` vs `DisplayLayoutPlan`).
- [ ] 8. Remove unused `WindowSemantics.isManageable` field.
