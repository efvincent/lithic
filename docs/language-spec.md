# Lithic Language Specification (Living Core Spec)

Status: Active living spec for implemented behavior.
Version: 0.1 (2026-05-06)
Scope baseline: Parser + current bidirectional checker through Phase 6.

This document is the normative source for the currently implemented Lithic surface language and static semantics. Where implementation and docs disagree, this spec is the authority to reconcile against.

## 1. Purpose and Governance

### 1.1 Purpose

Lithic is still in rapid language evolution phases. A complete formal report at this stage would incur frequent churn. This living core spec defines the stable implemented core needed to prevent semantic drift while Phase 7 (pattern exhaustiveness and reachability) is under active development.

### 1.2 Normative Status

Normative for:
- Lexical forms currently accepted by the lexer.
- Concrete syntax currently accepted by the parser.
- Pratt precedence and associativity behavior.
- Static typing behavior currently enforced by the bidirectional checker.
- Error-class contracts and source-span expectations.

Informative only for:
- Future evaluator/runtime semantics.
- Future elaboration/core lowering semantics.
- Future constraint solving and capability overloading semantics.

### 1.3 Change Policy (Anti-Drift)

Any change to lexer/parser/typechecker-observable behavior MUST update this spec in the same change.

Expected synchronization targets:
1. This file (`docs/language-spec.md`) (normative behavior).
2. `README.md` (user-facing summary/examples).
3. `docs/project-plan.md` and `.github/copilot-instructions.md` when roadmap scope or grammar commitments change.
4. Golden fixtures/snapshots in `test/fixtures` and `test/golden` for behavioral deltas.

### 1.4 Stability Labels

Each section is one of:
- Stable: intended to remain source-compatible during Phase 7.
- Provisional: implemented but likely to evolve before full formalization.
- Reserved: syntax/semantics intentionally not implemented yet.

## 2. Lexical Specification (Stable unless noted)

### 2.1 Identifier Classes

- Lowercase identifiers: `TokIdent`.
- Uppercase identifiers: `TokUIdent`.

Current role split:
- Term level: lowercase variables and uppercase variant constructors are accepted.
- Type level: lowercase type variables and uppercase concrete/nominal type names are accepted.

### 2.2 Keywords and Core Delimiters

The lexer recognizes the following core keywords/symbols used by the implemented grammar:

- `let`, `in`
- `case`, `of`
- `forall`
- `True`, `False`
- `\\` (lambda)
- `=>` (term-level lambda and case branch delimiter)
- `->` (type-level function arrow)
- `:` (type annotation)
- `=` (binding/field assignment)
- `.` (selection/path separator)
- `{`, `}`, `(`, `)`, `,`, `|`
- `:=` (lens set)
- `%=` (lens modify)
- `-` (prefix unary minus and infix subtraction)

### 2.3 Literals

Supported literal token families:
- Integer literals.
- Floating-point literals.
- String literals (single-line quoted).
- Boolean literals (`True`, `False`).

### 2.4 Comments

Line comments are supported with `--` through end-of-line.

### 2.5 Source Location Contract

Every emitted token carries a `SourceSpan` and downstream parse/type diagnostics preserve source-location reporting.

## 3. Surface Grammar (Core, with Stability Labels)

Notation is EBNF-like and descriptive for implemented behavior.

### 3.1 Expressions (Stable core, some Provisional branches)

```text
Expr ::= LetExpr
       | LamExpr
       | CaseExpr
       | AnnExpr

LetExpr ::= "let" Pattern [":" Type] "=" Expr "in" Expr
LamExpr ::= "\\" Pattern [":" Type] "=>" Expr
CaseExpr ::= "case" Expr "of" Branch+
Branch ::= "|" Pattern "=>" Expr

AnnExpr ::= SubExpr [":" Type]

SubExpr ::= SubExpr "-" AppExpr              // infix subtraction
          | AppExpr

AppExpr ::= AppExpr Atom                      // implicit application
          | SelectExpr

SelectExpr ::= Primary "." ident             // record selection
             | Primary ".{" Path UpdateOp Expr "}"  // lens update
             | Primary

Path ::= ident ("." ident)*
UpdateOp ::= ":=" | "%="

Primary ::= ident
          | UIdent Expr                       // variant constructor application
          | Literal
          | "-" Primary                      // unary minus
          | "(" Expr ")"
          | RecordExpr

RecordExpr ::= "{}"
             | "{" FieldList "}"
FieldList ::= Field ("," Field)* ["|" Expr]
Field ::= label "=" Expr
```

Notes:
1. `UIdent Expr` payloads are currently required; nullary constructors are represented with an explicit empty-record payload (for example, `None {}`).
2. Record labels in row-like forms may be lowercase or uppercase at parser level.
3. `fn` lambda syntax is documented in project guidance as accepted intent, but parser support is currently via `\\`; treat `fn` as Reserved until parser support lands.

### 3.2 Patterns (Provisional for exhaustiveness details)

```text
Pattern ::= "_"
          | ident
          | Literal
          | UIdent Pattern
          | RecordPattern

RecordPattern ::= "{" ... "}"            // AST includes PRecord; parser coverage is partial/in-progress.
```

Implemented pattern spaces used by binder positions and `case` branches:
- Variable pattern.
- Wildcard pattern.
- Literal pattern.
- Variant pattern with payload pattern.

Record patterns exist in AST/typechecker shape but parser support remains partial; this is Provisional.

### 3.3 Types (Stable core)

```text
Type ::= TypeAtom ["->" Type]               // right-associative

TypeAtom ::= ident                            // type variable
           | UIdent                           // nominal or primitive name
           | "forall" ident+ "." Type
           | "{" RowType "}"
           | "(" Type ")"

RowType ::= "}"
          | label ":" Type ("," label ":" Type)* ["|" Type] "}"
```

Primitive names with dedicated type AST nodes:
- `Int`, `Float`, `String`, `Bool`.

Wrappers:
- `Record <row-type>` represented as `TRecord` over row kind.
- `Variant <row-type>` represented as `TVariant` over row kind.

## 4. Precedence and Associativity (Stable)

Current Pratt precedence table (high to low):
1. Selection / lens prefix after dot (`.`): precedence 40.
2. Prefix unary minus: precedence 35.
3. Implicit application: precedence 30.
4. Infix subtraction: precedence 10.
5. Type annotation (`:`): precedence 5.
6. Base expression level: precedence 0.

Operational notes:
- Type annotation binds lower than application, so `f x : T` parses as `(f x) : T`.
- Dot selection binds tighter than application, so `f r.x` parses as `f (r.x)`.
- Let RHS and lambda body parse at lowest precedence to capture full expression forms.

## 5. Static Semantics (Implemented Core)

### 5.1 Typechecking Architecture (Stable)

Lithic uses bidirectional typing:
- `infer`: synthesizes type from expression structure.
- `check`: validates expression against expected type.

When direct checking is not shape-driven, checker falls back to infer + `subsumes`.

### 5.2 Subsumption / Rank-2 Bridge (Stable with planned extension)

Current `subsumes` routing:
1. Expected polymorphic type (`forall`) is skolemized.
2. Inferred polymorphic type (`forall`) is instantiated with fresh metas.
3. Arrow-vs-arrow uses contravariant domain + covariant codomain subsumption.
4. Otherwise fallback to structural unification.

### 5.3 Stateful Unification (Stable)

- Meta-variables (`TMeta`) are solved through a mutable substitution map in `TCState`.
- `force` performs shallow head normalization for meta chains.
- `zonk` performs deep finalization for user-visible types.
- Occurs check rejects infinite types.

### 5.4 Let-Polymorphism (Stable)

- Let-bound values are inferred.
- Inferred type is generalized to `forall` over free metas not present in environment.
- Lookup instantiates generalized bindings to fresh metas.

### 5.5 Records, Rows, and Lens Updates (Stable structural mode; nominal mode Provisional)

Structural mode:
- Records use row-polymorphic types (`TRowEmpty`, `TRowExtend`, wrapped by `TRecord`).
- Row unification is label-order insensitive.
- Field selection can expand open row metas as needed.

Lens updates:
- `record.{path := value}` requires `value` unifies with resolved field type.
- `record.{path %= f}` requires `f` unifies with `fieldTy -> fieldTy`.
- Expression result type is the original record type.

Nominal path resolution is intentionally stubbed for now and reports targeted type errors.

### 5.6 Variants and Pattern-Driven Environments (Stable core, Provisional exhaustiveness)

- Variant terms are typed through `TVariant` over row types.
- Pattern checking extends local environments for branch/body checking.
- Case branch result types must reconcile via checker constraints.

Exhaustiveness/reachability hard errors are not yet fully implemented (Phase 7 target).

### 5.7 Numeric Operators (Stable current policy, Provisional long-term model)

Current behavior:
- Unary minus and subtraction are primitive numeric operations over `Int`/`Float`.
- Concrete numeric context constrains unresolved metas where possible.
- Fully unresolved numeric arithmetic emits explicit ambiguity diagnostics.

Planned replacement:
- Constraint-driven capability predicates and evidence passing (future phase).

## 6. Error and Diagnostic Contracts (Stable)

Current REPL-visible categories:
- Lex error: `Lex Error: <msg>`
- Parse error: `Parse Error: <msg>`
- Type error: `Type Error: <msg> at <span>`

Contract requirements:
1. Diagnostics carry precise `SourceSpan` whenever an originating token/node exists.
2. Parser and checker should prefer targeted spans over coarse enclosing spans.
3. Changes to diagnostic formatting visible in REPL output require README/spec sync.

## 7. Out of Scope for This Living Core Spec

Explicitly deferred to later formalization:
- Full dynamic semantics and evaluation strategy (strict/lazy, small-step/big-step).
- Core language translation/elaboration judgments.
- Macro expansion semantics and hygiene model.
- Full constraint solver coherence proof/model.
- Full pattern matrix formalization and proof obligations.

## 8. Phase-7 Formalization Plan Boundary

During Phase 7, this living spec remains the anti-drift authority for implemented behavior.

After Phase 7 completes (matrix-based exhaustiveness + reachability integrated), the project should produce a fuller formal spec that adds:
1. Formal pattern matrix definitions and coverage/redundancy judgments.
2. A stricter distinction between Surface and Core syntax with explicit elaboration relation.
3. A more complete metatheory outline for type soundness-facing invariants.

## 9. Phase-7 Addendum Draft (Maranget Matrix)

Status: Provisional draft aligned to planned implementation. This section becomes fully normative once `Compiler.PatternMatch` lands and tests are merged.

### 9.1 Scope and Activation

Covered constructs (Phase 7 target):
1. `case` branch sets only.

Deferred to follow-up phase work:
1. Exhaustiveness/redundancy checks for binder patterns in `let` and lambda parameters.
2. Guard-aware usefulness semantics.

Diagnostic level:
1. Hard type errors (reject program).

Activation target:
1. First release containing `Compiler.PatternMatch` integration in `infer` for `Case` nodes.

### 9.2 Pattern Matrix Core Objects

Planned core representation:

```text
Occurrence o ::= Root
               | VariantPayload(o, ctor)
               | RecordField(o, label)

Row r ::= [Pattern]
Matrix P ::= [Row]
Query q ::= [Pattern]
```

Initial constructor universe policy:
1. Literal domains:
       - `Bool` is finite: `{True, False}`.
       - `Int`, `Float`, and `String` are treated as effectively open/infinite for coverage; only observed literal heads participate in specialization, with default branch required for totality.
2. Variants (`TVariant` over row):
       - Constructors are enumerated from statically known row labels when row is closed enough after forcing/zonking.
       - If variant row remains open/unknown, algorithm may not claim totality from constructor enumeration alone; default/wildcard coverage is required.
3. Record patterns:
       - Kept provisional until parser support for `PRecord` is complete.

Normalization policy:
1. `PVar` and `PWildcard` are treated as wildcard heads in matrix algorithms.
2. `PVariant ctor p` contributes constructor head `ctor` and one payload sub-column when specialized.
3. `PLit lit` contributes literal constructor head for specialization in that column.

### 9.3 Specialization and Default Operations

Planned operators:

```text
specialize(P, c) -> P_c
default(P) -> P_d
```

Semantics:
1. `specialize(P, c)` keeps rows whose head can match constructor/literal `c`:
       - Exact head `c`: include row, replacing head by constructor arguments (for `PVariant`, one payload pattern).
       - Wild head (`PVar`/`PWildcard`): include row, introducing fresh wildcard argument patterns matching `c` arity.
       - Any other concrete head: drop row.
2. `default(P)` keeps rows with wildcard-compatible heads (`PVar`, `PWildcard`) and removes that head column.
3. Column ordering is preserved by replacing the selected head with its argument subpatterns, then appending remaining original columns.

### 9.4 Exhaustiveness Judgment

Planned judgment shape:

```text
Exhaustive(T, P) => Covered | Missing(W)
```

Where:
1. `T` is the scrutinee type after forcing current substitutions.
2. `P` is the matrix built from branch patterns.
3. `W` is a non-empty ordered list of witness patterns not covered by `P`.

Witness policy:
1. Witnesses are rendered as surface-like patterns (for example `True`, `Err _`, `Ok (Err _)`).
2. Ordering is deterministic by:
       - Constructor/literal order from row label iteration and literal sort order.
       - Left-to-right traversal of matrix columns.
3. Cap witness emission to a small fixed bound (for example 3) to keep diagnostics readable.

### 9.5 Reachability / Redundancy Judgment

Planned usefulness judgment:

```text
Useful(P_prefix, r) => Useful | Redundant
```

Semantics:
1. A branch row `r` is redundant iff it is not useful relative to previously accepted rows `P_prefix`.
2. Redundancy check runs in source order for each case branch.
3. In Phase 7, every redundant branch is reported as an error; multi-branch reporting is preferred if diagnostics accumulation remains practical.

Guard policy:
1. Pattern guards are not part of Phase 7 enforcement; this judgment applies to unguarded branch sets only.

### 9.6 Diagnostic Contract Addendum

Planned user-visible errors:

```text
Type Error: Non-exhaustive patterns in case at <span>. Missing: <w1>, <w2>, ...
Type Error: Unreachable pattern branch at <span>
```

Span policy:
1. Non-exhaustive error span points at the `case` expression span.
2. Unreachable error span points at the redundant branch pattern span.

Emission policy:
1. If both kinds are present, prioritize unreachable diagnostics first when branch-local spans are available, then non-exhaustive summary.
2. If checker remains fail-fast, at least first deterministic diagnostic must be stable across runs.

### 9.7 Golden Test Obligations

Phase-7 merge gate expects fixtures for at least:
1. Exhaustive boolean case success.
2. Non-exhaustive boolean case failure with missing witness.
3. Redundant wildcard-after-wildcard branch failure.
4. Variant non-exhaustive failure with constructor witness (closed row case).
5. Nested variant redundancy or missing-case witness.

Expected output contract for failures:
1. Preserve existing `Type Error: <msg> at <span>` envelope.
2. Include witness text for non-exhaustive failures.

### 9.8 Implementation Cross-References

Planned modules and touch points:
1. New module: `src/Compiler/PatternMatch.hs`.
2. Typechecker integration: `infer` path for `Case` in `src/Compiler/TypeChecker.hs`.
3. Pipeline visibility: golden harness in `test/Main.hs` through existing REPL/type error formatting path.

Companion docs to update in same implementation change:
1. `README.md` examples/behavior bullets for exhaustiveness and unreachable branches.
2. `docs/project-plan.md` Phase 7 checklist status.
3. `CHANGELOG.md` release entry with diagnostics behavior details.
