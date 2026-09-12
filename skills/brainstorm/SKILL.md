---
name: brainstorm
description: >-
  Divergent precursor to /plan. Given a feature idea, surface adjacent ideas,
  pros/cons, and the open questions worth resolving before any design work — one
  sharp pass, depth scaled to the idea's size, ending with a brief "also worth
  discussing" block and a nudge to go deeper. Use whenever the user runs
  /brainstorm, or asks to brainstorm / explore ideas / think through a feature
  before planning it.
---

# Brainstorm a feature (before /plan)

A lightweight thinking primer that runs *before* `/plan`. Where `/plan`
**converges** on one implementation path, this **diverges** — it opens the
problem space so the eventual plan starts from a well-explored place.

Produce one sharp pass, then let the user pull on whatever thread they want. The
user triggers `/plan` themselves when ready; this skill never starts planning.

## Step 1 — Resolve the subject

- If the user gave a feature description as an argument, that is the subject.
- If they invoked `/brainstorm` with no argument, infer the subject from the
  active conversation.
- You may note a *fair assumption* about which actively-discussed repo the feature
  relates to. **Do NOT read a repo's code** unless the user named a repo in the
  call — this is deliberately not repo-aware by default (they work from
  `/srv/dev`, not a fixed repo).

## Step 2 — Scale the depth to the feature

Use judgment. A small, well-defined idea gets a tight pass (a few ideas, a few
questions). A large or ambiguous idea gets a fuller one. Tailor the number of
ideas and questions to the size — keep every section sharp, never padded
brainstorm-sludge. Divergent, not convergent: do not pre-empt `/plan` with a full
design.

## Step 3 — Output these sections, in order

1. **Restate** — the idea in one line, to confirm understanding.
2. **Related / adjacent ideas** — a tailored handful, sharp not exhaustive.
3. **Pros & cons** — of the idea and any notable variants (a table reads well).
4. **Open questions** — what to resolve before `/plan`.
5. **Also worth discussing** — a brief 2-3 sentence closing block naming related
   threads not yet covered.
6. **Nudge** — one line offering to go deeper on any branch.

## Step 4 — Optionally recommend a direction

If a clear recommendation genuinely helps and isn't a distraction, give it at the
end. Otherwise stay divergent and leave the call to the user.

## Guardrails

- No repo code reads unless the user named a repo in the call.
- Write no files; this skill only produces conversation output.
- No emojis in any written output (chat only), per house rules.

## Shape at a glance

```
> /brainstorm add a dark-mode toggle to the site

**Idea:** a user-facing dark-mode toggle on the site.

**Related ideas**
- Respect the OS `prefers-color-scheme` as the default, toggle overrides it
- Persist the choice (localStorage vs. account setting)
- A three-state control (light / dark / system) rather than a binary

**Pros / cons**
| | Pro | Con |
|--|--|--|
| CSS-vars theming | one source of truth, cheap toggle | upfront token refactor |
| duplicate stylesheets | no refactor | drift, double maintenance |

**Open questions**
- Per-device or synced to the account?
- Does anything render server-side that needs the theme at request time?

**Also worth discussing:** the theming mechanism is the real fork here — CSS
variables vs. a class-swap — and it ripples into how much of the existing styles
you touch. Worth a look at how images/illustrations behave in dark before you plan.

Want me to go deeper on any of these?
```
