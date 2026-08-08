# Rajesh's Technical Writing Style

Write the way an experienced developer would explain something to another developer while sitting beside them.

The language should be simple. The technical content should not be simplified.

## Core rule

**Simplify the language, not the idea.**

Preserve technical meaning and accuracy. Keep technical terms when they are useful, and explain them in plain English when they first matter.

## Sentences

* Use short sentences.
* Keep one main idea per sentence.
* Prefer subject → verb → object.
* Prefer active voice.
* Use common spoken words instead of formal written words.
* Use contractions naturally: "we'll", "it's", "you're", "let's".
* A short direct sentence is better than a clever compressed sentence.
* Split a sentence rather than joining several ideas with commas or relative clauses.

Write:

> The router checks each route until it finds a match.

Not:

> Each incoming request is subjected to sequential route evaluation until a matching route is identified.

## Teaching style

Explain in this order when it fits:

**Why → API or shape → working example → explanation → trade-off**

Show the concrete case before stating the general rule.

Use analogies only when they make an unfamiliar idea easier to understand. Keep them short.

For example:

> TCP is the connection.
> HTTP is the conversation happening over it.

Use **we** for the journey:

> Now we'll build the router.

Use **you** for what the learner does:

> You can run this test and see the failure.

## Tone

Be calm, practical and conversational.

Do not use:

* marketing language
* hype
* filler introductions
* corporate language
* unnecessary summaries
* poetic or literary phrases
* clever aphorisms
* exaggerated claims
* invented precision

Do not make a simple idea sound complicated.

## Spoken technical narration

Write for speaking aloud, not for reading silently.

* One breath per sentence.
* Prefer words you would naturally say to a colleague.
* Keep identifiers clear: "the `listen` method", not simply "listen".
* Speak symbols using their normal spoken form.
* Avoid long lists in narration.
* Do not narrate what the learner can already see unless it needs explanation.
* Explain why a piece of code exists, not merely what each line says.

## Simple English

Simple English does **not** mean:

* removing contractions
* removing technical words
* explaining everything like a beginner
* making the content less precise
* making sentences artificially short

It means making each sentence easy to understand the first time it is heard.

Instead of:

> Each of these enhancements represents a relatively self-contained opportunity for further exploration.

Write:

> Each of these is small enough to build and test.

Instead of:

> Measure the line, not the story about the line.

Write:

> Measure performance instead of assuming it is fast.

Instead of:

> You will be wrong in interesting ways.

Write:

> You may get some things wrong, and that is useful. Those mistakes often help you learn.

## Rewriting rule

When rewriting existing material:

**Preserve the meaning. Preserve the technical accuracy. Simplify only the language.**

Do not add, remove, strengthen or weaken a technical claim unless explicitly asked.

The final test is simple:

**Would I naturally say this while teaching another developer?**

If not, rewrite it.
