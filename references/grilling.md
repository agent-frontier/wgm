# Grilling — the alignment interview

The most common failure in software is misalignment: the agent builds the wrong thing because it
never truly understood the request. The fix is a relentless interview **before** building. This is
the grill-me discipline, adapted for wgm.

## Prime directive
Interview the user about every material aspect of the plan until you reach shared understanding.
Walk down each branch of the decision tree, resolving dependencies between decisions one at a time.

## Rules
1. **One question at a time.** Never batch. A wall of questions gets a shallow answer.
2. **Always recommend an answer.** For every question, give your recommended choice and a one-line
   why. The user should be able to reply "yes" and move on.
3. **Explore before asking.** If a question can be answered by reading the codebase, read the
   codebase instead. Questions you can resolve yourself are not questions for the user.
4. **Resolve dependencies in order.** Some decisions gate others (data model before API shape,
   auth model before routes). Ask the upstream one first; let its answer prune the tree.
5. **Ask vs assume.** Only ask when the answer would *materially* change one of:
   architecture · UX · data model · security · deployment · acceptance criteria.
   For anything else, record a recommended assumption in the spec and proceed.
6. **Cap the interrogation.** After about five consecutive questions, pause: summarize the
   assumptions so far and offer **"proceed with defaults."** Autonomy beats interrogation theater.
7. **Capture as you go.** Every resolved decision and every assumption lands in a spec
   (`assets/spec.template.md`). The interview is worthless if the answers evaporate.

## What to drive toward
- **JTBD:** what job is the user hiring this software to do? For whom?
- **Success criteria:** what does "done" look like from the user's seat? How is it observed?
- **The magic moment:** the single thing that should make the user go "whoa." Protect it.
- **Constraints:** stack, deadlines, must-use/avoid tech, performance, security, deployment target.
- **Scope edges:** what is explicitly out of scope for this pass?
- **Acceptance + backpressure:** how will each criterion be *verified* by a command or check?

## Grill-exit gate
Stop interviewing and move to planning when **all** hold:
- [ ] Goal is known.
- [ ] User-visible success criteria are known.
- [ ] Major constraints are known.
- [ ] Each unknown is answered, explored from code, or recorded as an explicit assumption.
- [ ] The user said "go," or the remaining ambiguity cannot change the build.

## Anti-patterns
- Asking what the code already answers.
- Ten questions in one message.
- Open-ended questions with no recommendation ("How should auth work?" → instead: "I recommend
  email+password with sessions because X — good, or do you need OAuth?").
- Grilling forever. The interview ends; the build begins.
