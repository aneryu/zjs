# compiler-v2 anchor-split classification (A / B / C / D)

QCP-1 stage F3. Classification of the anchoring exposure the boundary
uniqueness oracle (`7c6bf575`) reported. **Analysis only** — nothing in the
identity model, the frozen `Builder` / `SourceSlot` API, or the resolver's
production behaviour changes here. The oracle grew a classifier; the compiler
did not change.

---

## 0. The answer first

**Class A is ZERO.** Not "small", not "none found so far in the interesting
cases" — zero over the whole corpus, in both coordinate spaces, with a
classifier whose class-A arm is proven to fire on synthetic input.

```
mc.js   A=0  B=104766  C=179883  D=41406
ma.js   A=0  B=104766  C=179886  D=41406
```

The ruling's premise holds in full: **4,082 contested points are not 4,082
bugs, and they are not 1 bug either.** The anchoring exposure is a
naming/uniformity question, not a correctness one, and the ruling's
"do not force-merge identities to reduce the count" applies to all of it.

Class D still needs a rule — not because anything is broken, but because
"the fold replacement anchor is positional" is currently an accident of the
implementation rather than a stated invariant. §6 proposes that rule.

---

## 1. What "class" means operationally

The ruling's four classes are distinguished by **what competes for a
position**:

| class | competitor | verdict |
|---|---|---|
| A | another owner of the *same semantic boundary* | MUST MERGE — changes the model |
| B | a *different* semantic event at the same PC | allowed |
| C | a source/debug anchor | allowed |
| D | the optimization replacement anchor | needs a rule |

That taxonomy alone is not falsifiable — it is a naming scheme. So the
classifier adds one **falsifiable arm** applied to every case in every class:

> Every competing owner of one INPUT offset resolves to a PRODUCT offset.
> The label group resolves through `product_labels[..].bound_offset`; the
> source event resolves through the product source slot the resolver attached
> it to; the fold replacement resolves through the product offset captured at
> the instant of the replacing emission. **Owners that resolve apart are a
> genuine split — class A — whatever kind the competitor is.**

Only owners that provably resolve *together* are allowed to stay in B / C / D.
This is what turns "179,883 unanchored events" from a count into a
classification: each of them is now compared, not assumed.

`src/compiler_v2/cfg.zig` — `classifyAnchorSplits`, `AnchorClass`,
`AnchorCase`, `AnchorSplitCensus`. Debug/ReleaseSafe only, comptime-erased in
ReleaseFast (`comptime { if (!audit_oracles) assert(@sizeOf(...) == 0); }`,
and `zig build zjs` — a ReleaseFast build — is a standing gate).

### 1.1 Why the A arm is credible

An oracle that reports zero is worthless unless it can report non-zero.
Two unit tests are positive controls that construct the split by hand and
require the arm to fire, then re-run the identical fixture with the owners
agreeing and require it not to:

- `compiler_v2.cfg: class A arm fires when a source event resolves off its boundary`
- `compiler_v2.cfg: class A arm fires when a fold replacement resolves off its boundary`

Both are in `src/compiler_v2/cfg.zig` and run in `test-compiler-v2`.

### 1.2 Why the product-offset comparison is meaningful

The source-event comparison relies on product source slot `i` being input
source slot `i` (the resolver appends absorbed events in order). That is not
assumed — the classifier compares `line`/`col` on every pair and counts
disagreements in `source-index-violations`. Corpus result: **0**.

The fold comparison relies on `replacement_product` being recorded for every
fold. Folds whose replacement is emitted later than the boundary is recorded
(the deferred `make_ref_tail`) patch it at the emission point. Unpatched folds
are counted in `fold-product-unknown`. Corpus result: **0**; unit-test result
(the only place the make_ref fold is reachable): **0**.

---

## 2. Corpus and totals

Corpus: `mc.js` and `ma.js` — Octane 2.0 CodeLoad payloads (Closure `base.js`
+ jQuery 1.7.2) compiled as global programs through indirect `eval`,
120 iterations x 2 payloads. Both run **240/240** under `-Dzjs_compiler=v2`.
Build: `zjs-dev` (Debug, `audit_oracles = true`).

```
ZJS-V2-ANCHOR-SPLIT A=0 B=104766 C=179883 D=41406
  cases{a_source_product_split=0 a_fold_product_split=0
        b_multi_role_boundary=0 b_boundary_is_fold_region_end=480
        b_barrier_with_reference=104286 b_triple_owner_pc=0
        c_source_coresident=179403 c_source_outlives_identity=0
        c_identity_outlives_source=0 c_boundary_fully_retired=480
        d_fold_uncontested=37324 d_fold_contested_agree=4082}
  folds{make_ref_head=0/0 make_ref_tail=0/0 dup_branch_fold=840/24600
        insert_tail_fold=360/7920 gosub_empty=2882/8886}       (contested/total)
  relax{compactions=0 window-sources=0 window-labels=0
        coincident=0->0 lost=0 gained=0}                       (.plain layout)
  integrity{fold-product-unknown=0 source-index-violations=0}
```

The pre-existing census is reproduced exactly by the classifier
(`unanchored{source=179883 fold=41406 contested=4082}` on mc.js), so the
partition below is a partition **of the reported exposure**, not of a
different population:

```
179,883 source events on a bound offset  = 179,403 (C) + 480 (C) + 0 (A)
 41,406 fold replacement anchors         =  37,324 (D) +  4,082 (D) + 0 (A)
```

Per-payload, one compile each (harness baseline B=3 C=1 D=3 subtracted):

| payload | C | B | D | dup_branch | insert_tail | gosub_empty |
|---|---|---|---|---|---|---|
| Closure `base.js` | 90 | 29 | 26 | 12 (0 contested) | 11 (0) | 3 (1) |
| jQuery 1.7.2 | 1,409 | 844 | 319 | 193 (7) | 55 (3) | 71 (23) |

---

## 3. Class A — 0 instances

Nothing to merge. There is no position in the corpus where two owners of one
semantic boundary resolve to different product offsets, and no source event
that drifts off its boundary through the one pass that could move it.

### 3.1 The cost of NOT merging: nil, and it is measured, not argued

The stage asks, for each class A instance, the exact failure it would cause if
source attribution became label-anchored. There are no instances, so instead
here is the **falsification budget** — every mechanism by which an instance
could have existed, and the measurement that shows it does not:

**(a) Input -> product (`resolve_variables`).** A label bound at input offset
`P` takes `product.code_len` at `passBindsAt(P)`; a source event at `P` is
absorbed at the same point and takes `product.code_len` at the next
`emitInstruction`. Between those two reads the resolver may emit nothing
(erased `nop`, `set_class_name`, a fully folded `scope_make_ref` head) or many
instructions — either way both owners read the same cursor.
Measured: **179,403 / 179,403 co-resident pairs agree; 0 disagree.**

**(b) Product -> final, jump compaction (`resolve_labels.relaxJumps`).** This
is the exposure's sharpest edge: `addr[]` and `output_sources[].pc` are two
independent arrays shifted by two separate loops. Both use the predicate
`x > jump.pos` with the same `delta`, so they can only disagree for an event
sitting **strictly inside** the removed bytes `(jump.pos, jump.pos + size + delta)`.
The classifier counts that population per compaction, and snapshots which
source events sit on an identity before the pass and re-derives after it.

`.plain` is `default_layout` today, so production never runs `relaxJumps`
(0 compactions above) — the exposure is **latent, on the path S4 switches to
when short-form layout lands.** Measured under a throwaway
`default_layout = .short` build (not committed; the committed tree is
`.plain`), both corpus files still 240/240:

```
mc.js   relax{compactions=17881 window-sources=0 window-labels=0
              coincident=232564->232564 lost=0 gained=0}
ma.js   relax{compactions=17880 window-sources=0 window-labels=0
              coincident=232566->232566 lost=0 gained=0}
```

17,881 compactions, **zero** events in a compaction window, and the
source-on-identity set is preserved **exactly** — same cardinality, zero lost,
zero gained. Positional attribution survives the pass that was supposed to be
its weak point.

**(c) Product -> final, emission (`resolve_labels.walk`).** Covered by the
pre-existing F1/F2 oracles (alias groups resolve to one final address; the
jump subsystem's canonical identity equals the position subsystem's, compared
before any address is read) and end-to-end by the dual comparator, whose
normalized tier compares source positions between the legacy and v2 products.
`-Dzjs_compiler=dual` on both corpus files: 240/240, zero `ZJS-DUAL-MISMATCH`.

### 3.2 What a class A instance would look like

For the record, so a future reader can recognise one. Both shapes are exactly
what the positive-control tests construct:

- **Source split** — a line marker at input offset `P` and a label bound at
  `P` that land at different product offsets. If attribution then became
  label-anchored, the marker would be *moved* to the label's address: every
  pc in `[label_addr, marker_addr)` would report the wrong line, and the error
  would be invisible to bytecode-equality checks because the code is identical
  — only `pc2line` differs. This is why "same final address" is never accepted
  as a defence anywhere in the oracle.
- **Fold split** — a fold whose replacement is written at a product offset
  other than the one the label bound at its `fold_start` received. A jump to
  that label would land *beside* the replacement instruction, i.e. mid-stream
  or one instruction late. That is a wrong-code bug, not a debug-info bug.

Neither occurs. Both are detected if they ever start to.

---

## 4. Class B — 104,766 instances: one PC, several distinct semantic events

Allowed by the ruling and confirmed benign: in every case the events resolve
together, they are simply not the *same* event.

### 4.1 `b_barrier_with_reference` — 104,286

A retained match barrier sharing its PC with a live reference target. The
barrier is the identity-native analogue of QuickJS's physical `OP_label`: it
says "Stage 4 must not fold across this point even when every incoming
reference disappears". The jump target says "control arrives here". Two
different statements about one PC.

Exemplars. Source is cited verbatim with ` @ ` marking the column the boundary
sits at; all payload columns are on line 1 of the eval'd program (both payloads
are single-line minified sources, so `col` is the character offset). `op` is
the temporary-stream opcode at the boundary offset, `label#N@P` is the label
identity and the product offset it resolved to.

| payload | col | source ` @ ` boundary | op | owners |
|---|---|---|---|---|
| jQuery | 264 | `a:a.nodeType===9?a.defaultView\|\|a. @ parentWindow:!1}function cu(a){if(` | `goto` | `label#3@69` + barrier |
| jQuery | 397 | `);d.remove();if(e==="none"\|\|e==="" @ ){ck\|\|(ck=c.createElement("iframe"` | `if_false` | `label#1@115` + barrier |
| jQuery | 469 | `.frameBorder=ck.width=ck.height=0) @ ,b.appendChild(ck);if(!cl\|\|!ck.cre` | `drop` | `label#3@183` + barrier |
| Closure | 442 | `if(COMPILED&&!goog.DEBUG)throw a=a @ \|\|"",Error("Importing test-only co` | `dup` | `label#2@37` + barrier |
| Closure | 563 | `ED\|\|(goog.isProvided_=function(a){ @ return!goog.implicitNamespaces_[a]` | `return` | `label#0@36` + barrier |
| Closure | 713 | `n(a,b,c){a=a.split(".");c=c\|\|goog. @ global;!(a[0]in c)&&c.execScript&&` | `dup` | `label#0@39` + barrier |

Every one of them is a short-circuit merge (`&&` / `||`), an `if` body entry
or a function body entry — the shapes QuickJS puts a physical `OP_label` on.

### 4.2 `b_boundary_is_fold_region_end` — 480

A boundary that is also the exclusive end of a consumed fold region. These are
adjacent, not identical: the fold's replacement sits at product offset `N`, the
boundary binds at `N+1`.

Exemplars (jQuery, all `insert_tail_fold`):

| col | source ` @ ` boundary | op | owners |
|---|---|---|---|
| 12,575 | `;else while(c[e]!==b)a[d++]=c[e++] @ ;a.length=d;return a},grep:functio` | `goto` | `label#8@136`, region end of a replacement at `@135` |
| 77,609 | `Last-Modified"))f.lastModified[k]= @ y;if(z=v.getResponseHeader("Etag")` | `leave_scope` | `label#11@250`, replacement `@249` |
| 77,654 | `tResponseHeader("Etag"))f.etag[k]= @ z}if(a===304)w="notmodified",o=!0;` | `leave_scope` | `label#12@290`, replacement `@289` |
| 78,540 | `exec(n))o[c[1].toLowerCase()]=c[2] @ }c=o[a.toLowerCase()]}return c===b` | `goto` | `label#4@82`, replacement `@81` |

### 4.3 `b_multi_role_boundary` — 0, and `b_triple_owner_pc` — 0

Two structural facts worth recording because they were not previously known:

- **No boundary in the corpus is referenced under two different roles.** Not
  one position is both a jump target and an exception landing pad, or both a
  cleanup-subroutine target and a jump target. Reference roles are already
  single-valued per boundary.
- **No PC carries a line marker, a label target and a fold replacement at
  once** — the ruling's own class B illustration does not occur here. It is
  constructible (the positive-control test builds it and it classifies as B),
  it just is not produced by this corpus.

---

## 5. Class C — 179,883 instances: the source anchor is an independent identity

Every source event that sits on a bound offset. All of them resolve with their
boundary; **none** drifts.

### 5.1 `c_source_coresident` — 179,403

Line marker and label bind at one input offset, one product offset. Exemplars:

| payload | col | source ` @ ` boundary | op | owners |
|---|---|---|---|---|
| jQuery | 209 | `*/ (function(a,b){function cy(a){ @ return f.isWindow(a)?a:a.nodeType=` | `return` | `label#1@80` + `source_event@80`, fanout 2 |
| jQuery | 264 | `a:a.nodeType===9?a.defaultView\|\|a. @ parentWindow:!1}function cu(a){if(` | `goto` | `label#3@69` + `source_event@69` |
| jQuery | 397 | `);d.remove();if(e==="none"\|\|e==="" @ ){ck\|\|(ck=c.createElement("iframe"` | `if_false` | `label#1@115` + `source_event@115` |
| Closure | 261 | `implicitNamespaces_[a];for(var b=a @ ;(b=b.substring(0,b.lastIndexOf(".` | `scope_get_var` | `label#2@69` + `source_event@69` |
| Closure | 325 | `f(".")))&&!goog.getObjectByName(b) @ ;)goog.implicitNamespaces_[b]=!0}g` | `if_false` | `label#3@125` + `source_event@125` |
| Closure | 356 | `(b);)goog.implicitNamespaces_[b]=! @ 0}goog.exportPath_(a)};goog.setTes` | `goto` | `label#5@148` + `source_event@148` |

### 5.2 `c_boundary_fully_retired` — 480

The dead-code case, and the sharpest argument that the debug anchor must stay
independent rather than be merged into the label. The CodeLoad payload begins
with `throw 0;`, so the entire top level of every compiled program is
unreachable. The resolver retires the labels there (`dead_skipped`) and drops
the trailing source events at the same time — **both owners disappear
together, neither one deciding the other's fate.**

Exemplars (Closure `base.js`, all four in the dead top level — and exactly
four per compiled Closure program, 4 x 120 iterations = 480):

| col | source ` @ ` boundary | op | owners |
|---|---|---|---|
| 44 | `ar googsalt=0;var COMPILED=!0,goog @ =goog\|\|{};goog.global=this;goog.DE` | `scope_put_var` | `label#0@unbound` + `source_event@unbound` |
| 654 | `e(a)},goog.implicitNamespaces_={}) @ ;goog.exportPath_=function(a,b,c){` | `put_loc` | `label#1@unbound` + `source_event@unbound` |
| 3,594 | `tScript_(goog.basePath+"deps.js")) @ ;goog.typeOf=function(a){var b=typ` | `put_loc` | `label#2@unbound` + `source_event@unbound`, fanout 2 |
| 7,448 | `g.global.CLOSURE_CSS_NAME_MAPPING) @ ;goog.getMsg=function(a,b){var c=b` | `put_loc` | `label#5@unbound` + `source_event@unbound` |

`c_source_outlives_identity` and `c_identity_outlives_source` are both 0 on
this corpus: no surviving marker is ever left standing on a retired boundary,
and no boundary survives with its marker dropped.

### 5.3 The cost of merging, if anyone proposes it

Class C is the largest population, so the temptation is to "fix" it by giving
`SourceSlot` an `anchor_label`. The measurements say what that would cost:

- **2,232,782 of 2,465,346 emitted events (90.6%) sit BETWEEN identities.**
  They have no boundary to anchor to at all. Label-anchoring source
  attribution would require either minting ~2.23M identities that nothing
  references — growing the identity space from 298,450 live boundaries to
  2,531,232, a factor of 8.5 — or keeping a positional fallback, i.e. keeping
  exactly the mechanism the anchor was supposed to replace.
- The 480 dead-top-level events would be anchored to identities that are
  retired before the anchor could be read.

The exposure is real as *reported*; it is not a defect, and closing it by
merging would be strictly worse than leaving it. The ruling's "do not
force-merge" is the right call for this class.

---

## 6. Class D — 41,406 instances: the optimization replacement anchor

`OptimizationBoundary` records offsets and no `replacement_label`. Every one
of the 41,406 anchors is therefore positional; 4,082 of them (9.9%) sit on an
offset a label identity also claims. **All 4,082 resolve to the same product
offset as that label (`d_fold_contested_agree`), and 0 resolve apart.** The
remaining 37,324 have no label at the replacement start at all — there is
nothing to contest and nothing to anchor to.

| kind | anchors | contested | class |
|---|---|---|---|
| `gosub_empty` | 8,886 | 2,882 (32.4%) | D |
| `dup_branch_fold` | 24,600 | 840 (3.4%) | D |
| `insert_tail_fold` | 7,920 | 360 (4.5%) | D |
| `make_ref_head` | 0 | 0 | unreachable from this corpus (see 6.2) |
| `make_ref_tail` | 0 | 0 | unreachable from this corpus (see 6.2) |

### 6.1 Exemplars

Uncontested (`d_fold_uncontested`) — no identity at the replacement start.
` @ ` marks the fold's `replacement_start`:

| payload | col | source ` @ ` replacement | fold |
|---|---|---|---|
| jQuery | 933 | `turn cq=f.now()}function ci(){try{ @ return new a.ActiveXObject("Micros` | `gosub_empty` |
| jQuery | 732 | `"display"),b.removeChild(ck)}cj[a] @ =e}return cj[a]}function ct(a,b){v` | `insert_tail_fold` |
| jQuery | 833 | `,cp.slice(0,b)),function(){c[this] @ =a});return c}function cs(){cq=b}f` | `insert_tail_fold` |
| Closure | 276 | `ces_[a];for(var b=a;(b=b.substring @ (0,b.lastIndexOf(".")))&&!goog.get` | `dup_branch_fold` |
| Closure | 410 | `)};goog.setTestOnly=function(a){if @ (COMPILED&&!goog.DEBUG)throw a=a\|\|` | `dup_branch_fold` |
| Closure | 785 | `ecScript("var "+a[0]);for(var d;a. @ length&&(d=a.shift());)!a.length&&` | `dup_branch_fold` |

Contested (`d_fold_contested_agree`) — a label identity claims the same offset,
and both resolve to the same product offset:

| payload | col | source ` @ ` replacement | fold | owners |
|---|---|---|---|---|
| jQuery | 988 | `bject("Microsoft.XMLHTTP")}catch(b @ ){}}function ch(){try{return new a` | `gosub_empty` | `label#3@40`, `fold_replacement@40` |
| jQuery | 1,045 | `eturn new a.XMLHttpRequest}catch(b @ ){}}function cb(a,c){a.dataFilter&` | `gosub_empty` | `label#3@35`, `fold_replacement@35` |
| jQuery | 6,025 | `j.test(d)?f.parseJSON(d):d}catch(g @ ){}f.data(a,c,d)}else d=b}return d` | `gosub_empty` | `label#16@274`, `fold_replacement@274` |
| jQuery | 10,194 | `try{b=a.frameElement==null}catch(d @ ){}c.documentElement.doScroll&&b&&` | `gosub_empty` | `label#8@255`, `fold_replacement@255` |
| jQuery | 21,934 | `ts";if((!n\|\|!m[n]\|\|!o&&!e&&!m[n].d @ ata)&&k&&d===b)return;n\|\|(l?a[j]=n` | `dup_branch_fold` | `label#6@192`, `fold_replacement@192`, fanout 2 |
| jQuery | 35,124 | `());if((!e\|\|f.event.customEvent[h] @ )&&!f.event.global[h])return;c=typ` | `dup_branch_fold` | `label#7@283`, `fold_replacement@283` |
| jQuery | 66,434 | `port.leadingWhitespace\|\|!X.test(a) @ )&&!bg[(Z.exec(a)\|\|["",""])[1].toL` | `dup_branch_fold` | `label#5@171`, `fold_replacement@171` |
| jQuery | 49,273 | `Name.toLowerCase()===b?h\|\|!1:h===b @ }e&&m.filter(b,a,!0)},">":function` | `insert_tail_fold` | `label#17@249`, `fold_replacement@249` |
| jQuery | 49,475 | `=g.nodeName.toLowerCase()===b?g:!1 @ }}}else{for(;e<f;e++)c=a[e],c&&(a[` | `insert_tail_fold` | `label#8@164`, `fold_replacement@164` |
| jQuery | 74,680 | `++)f[a+bx[d]+b]=e[d]\|\|e[d-2]\|\|e[0] @ ;return f}}});var bC=/%20/g,bD=/\\[` | `insert_tail_fold` | `label#6@134`, `fold_replacement@134` |

The pattern is legible: `gosub_empty` contests a boundary a third of the time
because an empty `finally` subroutine is deleted exactly where a `catch`
landing pad binds; the two stack-shape folds contest ~4% of the time, at
`&&` / `||` merge points that happen to also be branch targets.

### 6.2 `make_ref_head` / `make_ref_tail` are unreachable from this corpus

`scope_make_ref` is only emitted for a `with`-scoped lvalue
(`src/parser.zig:7946-7956` for v2, `:7802-7806` for legacy — both arms are
inside `if (with_scope)`), and `planMakeRefFold` bails whenever the binding
needs a var-object probe or is a non-optimizable global — which is every
`with` lvalue the corpus produces. Probed directly with
`with(o){v+=1}`, `with(o){for(w in o){}}`, `delete`, destructuring and
compound assignment: still 0. The fold is exercised only by
`compiler_v2.resolve_variables: local scope_make_ref fold equals legacy`,
which now also asserts the classification is complete there
(`make_ref_head=2`, `make_ref_tail=1`, `fold_product_unknown=0`,
class A total 0). **Class D's counts for these two kinds are unit-test
evidence, not corpus evidence, and the rule below must not assume otherwise.**

`make_ref_tail` is also the only fold whose replacement is emitted *after* the
boundary is recorded (planned in `lowerScopeMakeRef`, emitted later in
`emitPendingTailRewrite`). That gap is precisely where a class A split could
be introduced by a careless future change, which is why the rule makes the
capture point explicit.

### 6.3 THE RULE (proposed, not implemented)

**D-RULE — the optimization replacement anchor is a derived position, never a
new identity.**

1. **No minting.** A fold must not create a `LabelId` for its replacement.
   Rationale: 37,324 of 41,406 replacements (90.1%) have no identity at their
   start and nothing ever references them; minting one per fold would add
   ~12.5% to the 298,450 live boundaries purely to satisfy uniformity. The
   ruling's "do not force-merge to reduce the count" has a mirror image —
   do not mint to increase it.

2. **Reuse, do not duplicate.** When a label identity *is* bound at the
   replacement start, that boundary's canonical identity
   (`canonicalIdentityAtOffset(binds, replacement_start)`) **is** the
   replacement's owner. A fold may never record a second owner for a position
   that already has one; the standing obligation is
   `product_labels[canonical].bound_offset == replacement_product`, which is
   exactly today's `a_fold_product_split` arm. Corpus status: 4,082/4,082
   satisfied.

3. **Capture at emission, never at planning.** `replacement_product` must be
   read from the output cursor at the instant the replacing bytes are written
   — before the write, so it names the replacement's first byte. A fold whose
   plan and emission are separated (`make_ref_tail`) must patch the anchor at
   the emission point. Never re-derive it afterwards from an offset, and never
   default it silently: an unresolved anchor is a defect, reported as
   `fold-product-unknown` (corpus and unit-test status: 0).

4. **The consumed range is a span, not a boundary.** `fold_start ..
   consumed_end` is a region; no identity may bind strictly inside it
   (already enforced by `bind_inside_fold`). Its exclusive end frequently
   coincides with the *next* boundary — 480 occurrences — and that coexistence
   is class B, not an alias of the replacement. A rule that treated
   `consumed_end` as belonging to the fold would wrongly claim 480 boundaries
   the fold does not own.

5. **Debug markers inside a consumed span belong to the next emitted
   instruction, not to the replacement.** `dup_branch_fold` and
   `insert_tail_fold` call `absorbSourcesThrough(drop_pos)` *after* emitting
   the replacement, so markers from inside the consumed range attach to the
   following instruction. This is observable behaviour today; the rule should
   state it deliberately rather than leave it as an ordering accident, because
   the alternative (absorbing before the emission) silently re-attributes
   those lines to the replacement.

6. **Keep the arm.** `a_fold_product_split` stays as a standing oracle. If a
   future fold ever emits its replacement at a product offset other than the
   boundary bound at its `fold_start`, that is a class A split and must be
   fixed by making the two owners agree — by binding the label where the
   replacement lands — and **not** by recording a second identity or by
   widening the comparison to accept "same final address".

Implementation surface if the rule is ever adopted: `OptimizationBoundary`
already carries `replacement_product`; points 1-4 are assertions, not new
state; point 5 is a comment plus a test; point 6 is already live.

---

## 7. What this does NOT prove

Stated so the "class A is zero" headline is not read wider than the evidence.

1. **One workload family.** The corpus is Octane CodeLoad (Closure `base.js` +
   jQuery 1.7.2). The *class distribution* is workload-dependent — the 480
   `c_boundary_fully_retired` cases exist only because the payload starts with
   `throw 0;`, and `b_barrier_with_reference` tracks how many `&&` / `||`
   merges the source contains. The *class A count* is not a distribution
   statistic, but it is still a corpus result: the classifier is a standing
   oracle, so every future test262 / unit-test / benchmark run in a
   Debug or ReleaseSafe build extends the evidence for free.
2. **`make_ref_head` / `make_ref_tail` are unit-test evidence only** (§6.2).
   The corpus never reaches them.
3. **The `.short` relax evidence came from a throwaway build.** The committed
   tree is `default_layout = .plain`; the numbers in §3.1(b) were taken from a
   local `.short` build that was reverted. The instrumentation is committed, so
   the measurement re-runs by itself the day `.short` becomes the default —
   which is exactly when it starts to matter.
4. **The product -> final `walk` edge is covered indirectly** — by the
   pre-existing F1/F2 identity oracles for the label side and by the dual
   comparator's normalized source-position tier end-to-end, not by a dedicated
   coincidence-preservation counter like the one relaxJumps now has.
5. **Nothing here says the model is optimal**, only that it is not wrong.
   Whether `SourceSlot` should carry an `anchor_label` for uniformity's sake is
   a design question the ruling deferred; §5.3 gives the price tag, not the
   verdict.

---

## 8. What changed in the tree

Audit-only, Debug/ReleaseSafe, comptime-erased in ReleaseFast.

- `src/compiler_v2/cfg.zig` — `AnchorClass` / `AnchorCase` /
  `AnchorSplitCensus` / `AnchorExemplar`, `classifyAnchorSplits` (replaces the
  two bare census loops; reproduces their counts exactly),
  `formatAnchorSplit`, `formatAnchorExemplar`, per-label reference role mask,
  `replacement_product` on `OptimizationBoundary`, two class-A positive-control
  tests. `auditBoundaryUniqueness` takes the product source slots.
- `src/compiler_v2/resolve_variables.zig` — `recordOptimizationBoundary` takes
  the product offset at all five fold sites; `resolveDeferredFoldProduct`
  patches the deferred `make_ref_tail`; the make_ref fold test asserts the
  classification is complete.
- `src/compiler_v2/resolve_labels.zig` — `relaxJumps` counts events inside a
  compaction window; `captureAnchorCoincidence` / `reportAnchorCoincidence`
  measure source-on-identity preservation across the pass.
- `src/compiler_v2/root.zig` — `ZJS_V2_ANCHOR_SPLIT` prints the cumulative
  class totals, `ZJS_V2_ANCHOR_EXEMPLARS` prints each retained exemplar once.

Reproduce:

```
zig build zjs-dev -Dzjs_compiler=v2
ZJS_V2_ANCHOR_SPLIT=1 ZJS_V2_ANCHOR_EXEMPLARS=1 ./zig-out/bin/zjs-dev mc.js
```

## 9. Gates

| gate | result |
|---|---|
| `zig build zjs` (ReleaseFast, legacy) | PASS |
| `zig build zjs -Dzjs_compiler=v2` | PASS |
| `zig build zjs -Dzjs_compiler=dual` | PASS |
| `zig build test-compiler-v2` (legacy / v2 / dual) | PASS, 194 tests each |
| `zig build test` (legacy / v2 / dual) | PASS |
| `zig build test262-smoke -Dzjs_compiler=v2` | PASS |
| `mc.js` / `ma.js` under v2 | 240/240, 240/240 |
| `mc.js` / `ma.js` under dual | 240/240, 240/240, 0 `ZJS-DUAL-MISMATCH` |
| `zig fmt --check src/compiler_v2` | PASS |

`zig fmt --check` over the whole tree still reports `src/tests/core.zig`; that
file is unformatted at `ae7940e0` already and is untouched here.

The ReleaseFast `zjs` binary contains no classifier symbol and no
`ZJS-V2-ANCHOR-*` string — checked with `nm` and `strings`, on top of the
comptime `@sizeOf(...) == 0` assertions.
