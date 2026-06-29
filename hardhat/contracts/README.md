# Privacy-Preserving AI Bounty Judge — Homework Submission

This extends the workshop's `AIJudge` contract so that submissions stay
hidden until judging is complete, instead of being public the moment they
land on-chain.

## Files in this submission

| File | What it is |
|---|---|
| `AIJudgeCommitReveal.sol` | **Required track.** Commit-reveal bounty contract. Drop this into `hardhat/contracts/`. |
| `AIJudgeCommitReveal.t.sol` | Foundry-style Solidity test suite (23 tests, `forge-std`). Drop into `hardhat/contracts/`. |
| `AIJudgeRitualNative.sol` | **Advanced track.** Design sketch for fully-encrypted, TEE-judged submissions. Not unit-tested (see `ARCHITECTURE.md` for why). |
| `ARCHITECTURE.md` | Comparison of the two tracks, with a sequence diagram for the advanced flow. |
| `REFLECTION.md` | Answer to the reflection question. |

## The problem with the workshop version

In the original `AIJudge`, `submitAnswer(bountyId, answer)` writes the
plaintext answer straight into contract storage. Every submission is
public the instant it's mined, so submitter #5 can read submitters #1–4's
answers and ship a strictly-improved version before the deadline. Whoever
answers last has a structural advantage that has nothing to do with the
quality of their thinking — that's the fairness bug this homework fixes.

## New lifecycle (required track)

A bounty now has **two deadlines** instead of one:

```
createBounty()
     │
     ▼
┌─────────────────────────┐   submissionDeadline   ┌──────────────────────┐   revealDeadline   ┌───────────────┐
│   Submission phase       │ ──────────────────────▶ │     Reveal phase      │ ──────────────────▶ │ Judge + payout │
│ submitCommitment(hash)   │                         │ revealAnswer(ans,salt)│                     │ judgeAll()      │
│ (answers are hidden)     │                         │ (answers go public)  │                     │ finalizeWinner()│
└─────────────────────────┘                         └──────────────────────┘                     └───────────────┘
```

1. **Submission phase** (`block.timestamp < submissionDeadline`) —
   participants call `submitCommitment(bountyId, commitment)` where
   `commitment = keccak256(answer, salt, msg.sender, bountyId)`. Only the
   hash is on-chain. Nobody, including the bounty owner, can read anyone's
   answer yet.
2. **Reveal phase** (`submissionDeadline ≤ block.timestamp < revealDeadline`) —
   each participant calls `revealAnswer(bountyId, answer, salt)`. The
   contract recomputes the hash and reverts on any mismatch
   (`"commitment mismatch"`). Only a successful reveal gets pushed into
   `revealedSubmissions`; anything never revealed simply doesn't exist for
   judging purposes.
3. **Judging** (`block.timestamp ≥ revealDeadline`) — the owner calls
   `judgeAll(bountyId, llmInput)` exactly once. This forwards `llmInput` to
   the Ritual LLM precompile (`0x0802`) in a single batched request, the
   same one-call-for-everyone pattern as the workshop version, just now
   running only on revealed (and therefore validated) answers.
4. **Finalization** — the owner reads the AI's output (`aiReview`, stored
   verbatim, never auto-parsed by the contract) and calls
   `finalizeWinner(bountyId, winnerIndex)` with the index into
   `revealedSubmissions` they've decided on. The contract pays that address
   the full reward and zeroes it out. The AI never moves funds on its own —
   a human always confirms the index.

Why `msg.sender` and `bountyId` are inside the commitment hash: it stops a
participant from copying someone else's commitment hash verbatim and
re-revealing it under their own address. Since the hash check recomputes
using the *revealer's own* `msg.sender`, a copied hash will never match for
anyone except the original committer. `AIJudgeCommitReveal.t.sol` has a
test (`test_CannotCopyAnothersCommitmentAndReveal`) that exercises exactly
this attack and confirms it fails.

## Running the tests

From `hardhat/`:

```shell
npx hardhat test solidity
```

23 tests, all passing — happy path, every `require` in the contract, and
the copy-attack scenario above. The LLM precompile (`0x0802`) doesn't exist
on a local EVM, so tests that reach `judgeAll()` stub it with
`vm.mockCall`; see the comment at the top of the test file for why an
empty-bytes mock is enough to intercept any `llmInput`.

## What I did *not* change

`createBounty`'s `wallet` field and the unused `IRitualWallet` interface
from the original contract are kept as-is — they're not part of this
fairness fix and didn't need touching.
