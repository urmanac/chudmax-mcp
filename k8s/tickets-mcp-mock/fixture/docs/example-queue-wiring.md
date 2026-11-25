# Example: the sample queue's wiring (mock doc)

An invented doc so `read_doc` and `search_docs` have a stable target. The real repo's docs
talk about its own systems; this one talks about a frobnicator and a sample queue.

## The shape
- The frobnicator boots, registers its sample queue (capacity 40, poll 1m — invented numbers),
  and starts draining lorem rows.
- Widgets alpha, beta, gamma are wired to the queue's head; nothing real is involved.

## The one surprise
The frobnicator emits a startup event the sample queue ignores on purpose: the fixture does
not model event handling. This section sits near the end of the file so an end-trim rehearsal
finds it — docs read top-down, trims cut from the end.
