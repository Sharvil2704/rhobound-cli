Service b is called by a, the user-facing entry, and calls c. A new feature will add about 4 ms of work to every call
of b. Before writing any code, use the rhobound tools on the environment `prod`, where production is already fitted:
read the context for entry a, then the latency budget of b with the fit_id the context returns, then predict a +4 ms
change to b's own time on env prod. Answer in three short lines: b's budget, the gate's verdict for +4 ms, and how you
would build the feature instead.
