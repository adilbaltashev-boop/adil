---
name: grill-me
description: "Продуктовый допрос по плану, фиче или идее: сценарии, логика, правила, крайние случаи. Тяжёлые инженерные решения агент берёт на себя."
disable-model-invocation: true
---

Interview the user relentlessly until you reach a shared understanding of **what the thing does and how people use it**. Map this as a **design tree**: every decision branches into the decisions that hang off it.

The person you are interviewing is not a deep technical expert. Your job is to extract everything they know about the product — scenarios, logic, rules, edge cases — and to carry the heavy engineering decisions yourself.

Run the whole session in the user's language.

## Step 0 — Recon before the first question

**Never open with questions.** First build enough context that every question you ask could only come from someone who has read the code. This is the one time you block: no round starts until recon is done.

**Start with the project's own instruction file** (`CLAUDE.md`, `AGENTS.md`). It is the map: it usually states which doc answers which kind of request, and its own rules are settled decisions in their own right. Read it before deciding what else to read.

**Then pull only the docs this request actually needs**, and work out for yourself which those are — a change to the interface needs the design system, a "does this even belong in the product" question needs the scope doc, a fork between technologies needs the stack doc. Reading every doc in the project is not thoroughness: it buries the two facts that would actually change a question. If the project has no such map, skim what the docs directory holds and pick from the titles.

**Alongside the docs, send sub-agents over the code the request touches** — entry points, data model, the routes and screens nearest to it, and how a *similar* feature is already built in this repo. Precedent is the default answer to half the design questions. Note also **what already exists**: capabilities the user may assume are missing, and gaps they may assume are covered.

Scope recon to the area the request touches; don't read the whole repo. If there is no repo — a greenfield idea — read whatever docs exist and move on.

Recon ends with three lists, kept internally:

1. **Settled** — answered by docs, code, or convention. **Never ask these.** Put them in the ledger if they still shape the work.
2. **Constraints** — facts that narrow the options and belong *inside* the questions you do ask.
3. **Open** — the genuine forks. This is your first frontier.

Then open the session with a short recap in plain words: how the relevant part works today, what you understood the request to be, and what you are treating as already decided. One paragraph, so a wrong premise dies before six questions get built on it. Then start round 1.

**The bar for every question: it could not have been asked before recon.** A question that would have made just as much sense without reading anything is too shallow — either recon isn't finished, or it isn't a real fork.

## What you ask vs. what you decide

Two gates. Ask only when a decision passes **both**.

**Gate 1 — the fork test.** Are there genuinely two or more options a reasonable person would defend, *and* is the answer still open after recon?

> If docs, existing code, or an obvious convention already answer it, there is no fork. Decide it, record it in the ledger, move on.

**Gate 2 — the consequence test.** Can the user choose between the options without knowing how the code is built — because the difference shows up in money, limits, convenience, timelines, or what they see on screen?

> If not, it is yours. Decide it silently.

**Both pass → ask.** These are fair game and not too hard for a non-engineer:

- whether a feature exists at all, who can see it, what it is allowed to do
- how the interface looks and behaves at each step
- limits with a price tag (uploads up to 100 MB, free — or up to 2 GB at ~$15/mo)
- how people sign in (Google login vs. email + password)
- **which service or technology**, when the choice changes the result — cost, availability in their market, lock-in, how fast it ships
- **which AI model for a given task**, when quality, price per request, latency, or availability differ in ways they can weigh
- where things live (managed cloud vs. their own server)

**Gate 2 fails → yours, silently.** Anything where choosing requires understanding the code:

- data schema, indexes, migrations
- queues, retries, idempotency, background jobs
- caching, module structure, state management
- API shape, error handling, logging, test strategy
- libraries and frameworks that don't change what the user gets

When in doubt, run both tests again rather than guessing. Never dump a choice on the user just because you are unsure — that is the failure this skill exists to prevent. And never ask a question whose answers all lead to the same build: if nothing downstream changes, it isn't a question.

## How to phrase a question

Ask in consequences, not in technology. If a technology name is genuinely the clearest label for an option, keep it but add one line of what it means for them.

- ❌ "Postgres or SQLite for storage?"
- ✅ "Videos from students: cap them at 100 MB (free) or allow up to 2 GB (~$15/mo)?"

Anchor the question in what recon found — the constraint that makes this a real choice. "The feed loads 30 posts at a time and hides ads; for saved posts, should…" beats the same question asked in a vacuum.

Give two or three concrete options, each with its consequence spelled out — never an open "how would you like it?". Your recommendation must be a workable default, so that a bare "yes" is a complete answer.

Never ask the user to resolve a technical trade-off dressed up as a product question. If two options differ only in engineering effort, that is your call, not theirs.

## What to squeeze out of them

Push hard on the product side — this is where the interrogation should be relentless:

- **Who** uses this, and what are they trying to get done
- **The happy path**, step by step, in the user's own words
- **Rules and logic** — what is allowed, what is forbidden, who can do what
- **Edge cases** — empty state, first run, duplicates, someone abandoning halfway, someone doing it twice, someone doing it wrong
- **What happens when it fails** from the user's point of view, not the system's
- **What "done" means** — how they will know the feature is good enough

And just as hard on the interface, because that is theirs to decide too:

- **Entry point** — where the feature lives in the navigation that already exists, how someone gets to it
- **Shape** — its own page, a modal, or inline in what is already on screen
- **What they see** at each step, and what tells them it worked
- **Every state** — empty, loading, error, success — as something visible, not as a code path
- **Confirmation and reversibility** — does the action ask first, can it be undone, what does it destroy
- **Mobile** — what changes on a narrow screen
- **Blast radius** — what changes on the screens that already exist

Don't ask about details a design system already fixes: colors, spacing and typography are settled, not forks.

When the logic is vague, keep drilling on that branch until it is unambiguous. A vague answer is an unsettled decision, not a settled one.

## Rounds

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet.

Ask the frontier in one round, numbered, each with your recommended answer — but cap it at about five. If the frontier is wider, take the questions that most change the shape of the work and let the rest wait: a non-expert answers five questions well and twelve badly.

Format a round like so:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Then wait for the user's answers before the next round. Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact recon didn't cover, dispatch a sub-agent; don't ask the user for anything you could look up yourself. Mid-session, don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; ask the rest of the frontier now. The _decisions_ are the user's: put each to them and wait.

### Reading their answers

- **"You decide" / "whatever you think"** — take it. Decide, record it in the ledger, never re-ask. Delegation is an answer.
- **An answer that misses the question** — the question landed badly. Rephrase it once in consequences; don't repeat it verbatim.
- **A vague answer on substance** — that branch is not settled. Keep drilling it.
- **An answer that contradicts recon** — say in one line what the code does today, then ask which way they want it. They may be describing the future, or they may be wrong about the present.

## Keep a ledger of what you decided

Every time you settle something instead of asking — a deep technical call, or a question that failed the fork test — record it: what you chose, and the one-line reason a non-engineer would care about. Do not interrupt the rounds with the ledger.

One exception: when a decision you made silently *constrains* a question you are about to ask, state it in one line inside that question. Otherwise they are answering blind.

## Ending the session

The session is done when the frontier is empty — every branch of the design tree visited, nothing left silently assumed — or when the questions still open no longer change what gets built.

Close with two things:

1. A short summary of the shared understanding — the scenarios and logic as you now understand them.
2. The ledger, so nothing is hidden:

```
🔧 **What I decided for you**

- **<the decision, in plain words>** — <why, in one line of consequences>
- **<the decision, in plain words>** — <why, in one line of consequences>
```

Invite them to push back on any line of it. Do not act on the plan until the user confirms you have reached a shared understanding.

Then point at the next step: `/to-spec` turns this conversation into a written spec.
