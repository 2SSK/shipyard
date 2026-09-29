// Package state is the deployment lifecycle state machine.
//
// ############################################################################
// # THIS FILE IS A REFERENCE IMPLEMENTATION — A TEACHING ORACLE, NOT THE
// # DELIVERABLE. The human writes their own version of this file by hand and
// # diffs it against this one. Read it as the answer key, not as the homework.
//
// # Specifically: do NOT just copy this into your tree and call Phase 2 §2.3
// # done. Write it yourself first, then `diff` your version against this one
# # and justify every difference. The disagreements worth having are the ones
# # where you decided the *docs* were ambiguous and chose differently on
// # purpose — see the "Decisions the docs left open" note at the bottom.
//
// # It is committed as an oracle because three load-bearing properties of
// # Shipyard are decided entirely inside these ~150 lines, and none of them
// # are obvious until you write them down:
// #
// #   1. the exact 9-state set (lowercase, and only these 9),
// #   2. which 6 of them constitute `slot_busy` (the in-flight set), and
// #   3. the transition allow-list, including the two escape hatches
// #      (`failed` and `canceled`) that make Terminality provable.
// #
// # Those three facts are duplicated in `db/migrations/0001_init.sql` (the
// # `slot_busy` generated column) and in every API response. If they drift, the
// # database and the Go process disagree about what "in flight" means and the
// # bug is invisible until a deploy wedges a slot. The tests below exist
// # specifically to make that drift a build failure.
// ############################################################################
//
// # ---------------------------------------------------------------------------
// # THE CONTRACT (read this before using any function here)
// # ---------------------------------------------------------------------------
//
// This package is pure: no I/O, no clock, no context, no dependencies of any
// kind. Every function is total on its declared domain, and *panics* on values
// outside it, because an out-of-domain value is a programming error (a typo in
// a constant, a state that was added to the enum but not to a switch) and not
// a runtime condition.
//
// That is a deliberate trade, and here is the whole argument for it:
//
//   - The alternative — returning `false` for an unknown state — makes
//     `IsTerminal(State("BUILDING"))` quietly return `false`. A row with an
//     uppercase state is corrupt, and the *loudest* thing you can do about it
//     is refuse to reason about it. A silent `false` is indistinguishable from
//     "correctly reports not-terminal", which is precisely the confusion that
//     produces a stuck deploy.
//   - The panic is reachable from *untrusted* data, because `deployments.state`
//     is a `text` column with a `CHECK` constraint (decision D12) rather than a
//     native ENUM. So the rule is: **validate at the boundary, once.**
//     Every value read out of Postgres goes through [Parse] (or [IsValid])
//     first. After that, the predicates below are total and the panic is
//     genuinely unreachable — which the test suite asserts.
//   - Each predicate's `switch` has no `default` arm. Adding a 10th state to
//     the constant block without handling it here is therefore a *test
//     failure* that names the unhandled state, not a silently-wrong `false`.
//     That is the mechanism that makes "adding a state forces you to handle
//     it" true rather than aspirational.
//
// # ---------------------------------------------------------------------------
// # WHERE THE NINE STATES COME FROM
// # ---------------------------------------------------------------------------
//
// docs/MENTAL-MODEL.md §3 and docs/ROADMAP.md §2.1, decision D3:
//
//	pending → cloning → building → configuring → starting → health_checking → running
//	   ↘         ↘          ↘           ↘            ↘               ↘            ↘
//	                            failed  (reachable from ANY non-terminal)
//	cancel (abort_requested_at) → canceled   (any non-terminal, operator-forced)
//
// Lowercase, always. A draft migration used uppercase and was discarded; see
// db/migrations/_discarded/README.md. Lowercase is also the wire format and the
// database representation, so a `State` is stored and returned unchanged.
package state

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

// State is one step in the deployment lifecycle.
//
// The underlying type is `string` on purpose: the exact same bytes go into the
// `text` column, the JSON response body, the SSE event, and the log line. A
// named string type keeps the wire format and the database representation
// identical while still giving you a type the compiler can check, so you can
// never accidentally pass a `commit_sha` where a `State` is wanted.
//
// The zero value is the empty string, which is *not* a valid state. That is
// intentional: a struct you forgot to populate fails [IsValid] instead of
// silently claiming to be `pending`. See [TestZeroValueIsInvalid].
type State string

// The nine states. There are exactly nine; [TestStateSetMatchesCanonicalList]
// fails the build if this list ever stops matching the canonical set.
//
// These names are contract. They are lowercase, they are what the database
// CHECK constraint spells, and they are what the API returns. Renaming one is a
// breaking change to the wire format and requires a migration.
const (
	StatePending        State = "pending"
	StateCloning        State = "cloning"
	StateBuilding       State = "building"
	StateConfiguring    State = "configuring"
	StateStarting       State = "starting"
	StateHealthChecking State = "health_checking"
	StateRunning        State = "running"
	StateFailed         State = "failed"
	StateCanceled       State = "canceled"
)

// allStates is the single source of truth for "how many states are there and
// what order are they in".
//
// The order is the canonical lifecycle order: the six in-flight states in
// forward sequence, then the three terminal states. It is used for
// deterministic iteration in [All], and [TestForwardOnly] uses the first seven
// positions as the notion of "earlier" and "later".
var allStates = []State{
	StatePending,
	StateCloning,
	StateBuilding,
	StateConfiguring,
	StateStarting,
	StateHealthChecking,
	StateRunning,
	StateFailed,
	StateCanceled,
}

// inFlightStates is the exact 6-element set behind the `slot_busy` generated
// column. It is spelled out separately from [allStates] rather than derived,
// because it is a *second* fact that happens to coincide with "the first six":
// the day someone adds a 10th state, that coincidence ends, and the compile
// error is what you want.
var inFlightStates = []State{
	StatePending,
	StateCloning,
	StateBuilding,
	StateConfiguring,
	StateStarting,
	StateHealthChecking,
}

// allowedNext is the transition allow-list: the complete set of legal
// (from → to) edges. Anything not listed here is illegal, and there is no
// wildcard, no default, and no "anything from a terminal state" rule.
//
// The three arms of each entry are in canonical display order: the forward
// successor (if any), then `failed`, then `canceled`. [AllowedNext] returns
// entries in this order rather than sorting, so a log line or an API response
// reads sensibly; the test suite checks membership with a set, so the order is
// a presentation choice and not part of the contract.
var allowedNext = map[State][]State{
	StatePending:        {StateCloning, StateFailed, StateCanceled},
	StateCloning:        {StateBuilding, StateFailed, StateCanceled},
	StateBuilding:       {StateConfiguring, StateFailed, StateCanceled},
	StateConfiguring:    {StateStarting, StateFailed, StateCanceled},
	StateStarting:       {StateHealthChecking, StateFailed, StateCanceled},
	StateHealthChecking: {StateRunning, StateFailed, StateCanceled},

	// Terminal states have no outgoing edges. They are listed with an empty
	// slice rather than omitted, so that "this state exists and is a dead end"
	// is a fact in the map rather than an absence you have to infer.
	StateRunning:  {},
	StateFailed:   {},
	StateCanceled: {},
}

// ErrUnknownState is returned by [Parse] for a string that is not one of the
// nine. It is a sentinel so callers can use [errors.Is] and map it to their own
// error vocabulary — the API maps it to `400 invalid_state`.
//
// Note that it is *not* the mechanism that guards the predicates; those panic.
// This is the boundary-validation path, for values that came from outside the
// program.
var ErrUnknownState = errors.New("unknown deployment state")

// String returns the state name exactly as it is stored and transmitted.
//
// It deliberately does not normalise, decorate, or quote. If a caller has
// `State("BUILDING")`, printing it must yield `BUILDING` — the typo is the
// diagnostic you are looking for, and a pretty-printer that renders it as
// `invalid state` destroys the only clue you had. Validation is [IsValid]'s
// job, not the formatter's.
func (s State) String() string { return string(s) }

// Parse converts a string to a [State], rejecting anything not in the canonical
// nine.
//
// This is the only safe way to turn untrusted input — a `text` column read from
// Postgres, a query parameter, a JSON body — into a [State]. Because D12 chose
// `text` + `CHECK` over a native ENUM, the database is not doing this type
// conversion for you, and every read path must call this. Skipping it is how
// you get a panic from [IsTerminal] at 3 a.m.
func Parse(s string) (State, error) {
	candidate := State(s)
	if !candidate.IsValid() {
		return "", fmt.Errorf("%w: %q", ErrUnknownState, s)
	}
	return candidate, nil
}

// IsValid reports whether s is one of the nine canonical states. The empty
// string — the zero value of [State] — is not valid.
func (s State) IsValid() bool {
	return slices.Contains(allStates, s)
}

// All returns a copy of the canonical state list, in lifecycle order.
//
// A copy, deliberately. Returning the package-level slice would let a caller
// sort it in place or truncate it, and every other function in this package
// reads that same slice; that is a data race and a logic bug waiting to happen,
// both of them far from the line that caused them.
func All() []State { return slices.Clone(allStates) }

// InFlight returns a copy of the 6 states that hold the deploy slot, i.e. the
// exact contents of the `slot_busy` generated column.
//
// "In flight" answers "is a worker on this right now" — and it is *not* the
// same question as "is this terminal". `health_checking` is in flight, because
// between "health passed" and "promoted and serving" there is a real gap and
// the slot must stay held across it.
func InFlight() []State { return slices.Clone(inFlightStates) }

// IsTerminal reports whether the run has reached an end state and will never
// change again: `running` (the success end), `failed`, or `canceled`.
//
// Terminality is property 1 of "production-grade" in docs/MENTAL-MODEL.md §8:
// every run reaches exactly one terminal state, on its own or via
// reconciliation. This function is half of that proof; the other half is
// [CanTransition] returning false for every edge out of these three.
//
// Note that `failed` is terminal but NOT in flight: a failed run has released
// its slot, which is what lets the next deploy for that project+server proceed.
func IsTerminal(s State) bool {
	switch s {
	case StateRunning, StateFailed, StateCanceled:
		return true
	case StatePending, StateCloning, StateBuilding, StateConfiguring, StateStarting, StateHealthChecking:
		return false
	default:
		// Unreachable in a correct program: every value that reaches here came
		// from Parse, from a constant, or from All. See the package contract.
		panic(unhandled("IsTerminal", s))
	}
}

// IsInFlight reports whether s holds the deploy slot — the 6 pre-terminal,
// non-failed states. This MUST stay byte-for-byte equivalent to the expression
// in the `slot_busy` generated column; [SlotBusyPredicateSQL] emits the SQL and
// [TestSlotBusyPredicateSQLMatchesMigration] pins it.
//
// Why 6 and not 7: `running` is the absence of work, not the presence of a
// worker. Why `failed` is excluded: a failure releases the slot immediately so
// the next attempt is not blocked by a run that will never finish.
func IsInFlight(s State) bool {
	switch s {
	case StatePending, StateCloning, StateBuilding, StateConfiguring, StateStarting, StateHealthChecking:
		return true
	case StateRunning, StateFailed, StateCanceled:
		return false
	default:
		panic(unhandled("IsInFlight", s))
	}
}

// CanTransition reports whether from → to is a legal edge of the lifecycle.
//
// This is the allow-list, and nothing else is legal. In particular:
//
//   - No self-transitions. `pending → pending` is false. Writing the same state
//     again is not a transition; if you need to record progress you append a
//     `deployment_events` row (docs/MENTAL-MODEL.md §3, write model).
//   - No edge out of a terminal state. Not even to another terminal state, and
//     not to itself. A run that has ended does not un-end.
//   - No skipping ahead. `pending → building` is false, even though it is
//     tempting as an optimisation.
//   - No rewinding. There is no backward edge anywhere in the map, which
//     encodes "append-only: only ever moves forward" from
//     docs/data-architecture.md §1.4.
//   - `failed` and `canceled` are reachable from EVERY non-terminal state,
//     including `pending`. See the note on [TestFailureReachableFromEveryNonTerminal].
func CanTransition(from, to State) bool {
	// Validate both ends. A caller that got here with garbage is a bug, and
	// silently answering `false` for it is how a corrupt row becomes an
	// unexplained non-deploy.
	from.isValidOrPanic("CanTransition(from)")
	to.isValidOrPanic("CanTransition(to)")

	return slices.Contains(allowedNext[from], to)
}

// AllowedNext returns the states reachable from s in one transition, in
// canonical display order: forward successor, then `failed`, then `canceled`.
//
// This is what replaces the `Next(state) → state` signature in
// docs/ROADMAP.md §2.3. A single-return `Next` cannot express this lifecycle:
// every non-terminal state has *three* successors, not one, and terminal states
// have zero, not one. See the report; this is the docs' weakest point.
//
// The result is a copy. Mutating it must not corrupt the allow-list.
func AllowedNext(s State) []State {
	s.isValidOrPanic("AllowedNext")
	return slices.Clone(allowedNext[s])
}

// SlotBusyPredicateSQL returns the exact expression used for the `slot_busy`
// generated column in db/migrations/0001_init.sql.
//
// It exists so the two copies of this fact can be diffed by a test instead of
// by memory. The column is:
//
//	slot_busy boolean GENERATED ALWAYS AS (
//	    state IN ('pending','cloning','building','configuring',
//	              'starting','health_checking')) STORED
//
// `STORED` is written explicitly and is not optional: in PostgreSQL 18 a bare
// `GENERATED ALWAYS AS (...)` means `VIRTUAL`, so omitting it silently produces
// an unindexable column and the partial unique index on top of it stops doing
// its job. (Verified — see VERIFIED.md §1.7.)
func SlotBusyPredicateSQL() string {
	quoted := make([]string, 0, len(inFlightStates))
	for _, s := range inFlightStates {
		quoted = append(quoted, "'"+string(s)+"'")
	}
	return "state IN (" + strings.Join(quoted, ",") + ")"
}

// isValidOrPanic is the internal boundary guard. Keeping it a method rather
// than a free function is cosmetic; keeping it as its own function is not — it
// gives every call site a place to name the argument that was wrong, which is
// what ends up in the panic message.
func (s State) isValidOrPanic(site string) {
	if !s.IsValid() {
		panic(unhandled(site, s))
	}
}

// unhandled builds the panic value. It names both the function and the value,
// because a bare "unreachable" panic in a deploy engine tells you nothing at
// 3 a.m., and this message is the only evidence you will have.
func unhandled(site string, s State) string {
	return fmt.Sprintf("state: %s called with %q, which is not one of the %d canonical states %v — "+
		"a new state was added without updating this switch (or the value came from an unvalidated database read: use Parse)",
		site, string(s), len(allStates), allStates)
}
