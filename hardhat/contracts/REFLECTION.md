# Reflection

**What should be public, what should stay hidden, and what should be
decided by AI versus by a human in a bounty system?**

The bounty's terms — the rubric, the reward amount, both deadlines, and who
the owner is — should be public from the start, since participants need
that to decide whether to compete at all, and a hidden rubric would just
move the unfairness problem somewhere else. The answers themselves are the
opposite: they should stay hidden for as long as another participant could
still act on seeing them, which is the entire submission window and, in the
commit-reveal design, the reveal window too. Once judging is done, hiding
them any longer stops protecting anyone and starts hurting trust, so they
should become public (or at least independently verifiable via a hash
commitment) so participants can check the process was fair after the fact.
Judging quality — actually comparing answers against the rubric — is a good
fit for AI: it's repetitive, benefits from not getting tired or skimming
submission #9 less carefully than submission #1, and batching it into one
call avoids the obvious exploit of an AI that scores submissions one at a
time and leaks its running opinion. But picking the *winner* — the action
that actually moves money — should stay a human decision: the owner reads
the AI's ranking and reasoning and explicitly confirms it, so a
prompt-injected submission, a malformed model response, or a rubric the AI
quietly misread can't silently pay out the wrong person. That split —
AI proposes, human disposes — is what `finalizeWinner()` enforces in both
contracts here: the AI's output is stored as advisory data, never as a
funds-moving instruction.
