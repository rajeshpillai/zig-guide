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
* Do not use contractions. Write "it is", "do not", "you are". (ASD-STE100, see below.)
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

Do not use **we** or **let's**. Use the imperative for a step, and a plain statement for a fact:

> Add the router. The router checks each route in order.

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

## ASD-STE100 (from 2026-10-20)

All prose follows the writing rules of ASD-STE100, Simplified Technical English. Where this file and STE disagree, STE wins. Zig names, std names and programming terms (allocator, slice, handle, comptime) are STE *technical names*. Verbs such as "compile", "allocate" and "parse" are *technical verbs*. Both are allowed.

* **Sentence length.** A procedure sentence (an instruction) has 20 words or fewer. A descriptive sentence has 25 words or fewer. Inline code counts as one word.
* **One instruction per sentence.** Use the imperative: "Free the memory with the same allocator."
* **Simple tenses only.** Use the present, the simple past and the simple future. Do not use "has been", "had read", "is reading" or "will have".
* **Active voice.** Write "The compiler rejects the cast", not "The cast is rejected". A passive is allowed in a description when the actor is unknown or does not matter.
* **No -ing forms**, except in a technical name (`string`, "padding", "ownership") or a quoted error. "Reading a file" becomes "Read a file" or "To read a file".
* **No phrasal verbs.** "Goes back" becomes "returns". "Find out" becomes "find". "Set up" becomes "configure" or "prepare".
* **One word, one meaning.** Do not use "since" for "because", "as" for "because", or "once" for "when". Do not change the word for one concept inside a chapter.
* **No noun clusters of more than three words.** "Integer overflow safety check result" becomes "the result of the safety check for integer overflow".
* **Use the articles** "a", "an" and "the". Do not drop them to make a sentence shorter.
* **Paragraphs** have one topic and six sentences or fewer.
* **Vertical lists** for a sequence of steps, a set of conditions, or a choice between options.
* **Warnings and conditions first.** Write "If the file is missing, the function returns `error.FileNotFound`."

The cost is visible: the text is longer, and a named subject repeats where a pronoun used to be. That is correct. A reader who learned English second must not have to look back to find what "it" means.

## Rewriting rule

When rewriting existing material:

**Preserve the meaning. Preserve the technical accuracy. Simplify only the language.**

Do not add, remove, strengthen or weaken a technical claim unless explicitly asked.

The final test is simple:

**Would I naturally say this while teaching another developer?**

If not, rewrite it. Then check the result against the STE rules above.
