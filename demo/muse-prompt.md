Service b is called by a, the user-facing entry, and calls c. A new feature will add about 4 ms of work to every call
of b. Before writing any code, use the rhobound tools: fit the production capture `loop` (worker counts a=1, b=2,
c=1), read the context for entry a and the latency budget of b, then predict a +4 ms change to b's own time. Answer in
three short lines: b's budget, the gate's verdict for +4 ms, and how you would build the feature instead.
