Title: Some cart totals are one cent off finance's figures

Finance reconciles every order against its ledger. For a small share of orders the total from pricing
(`hot.Quote`, kshop/app/internal/hot/price.go, called once per /quote request) differs from theirs by one cent,
sometimes several cents on large carts. Every order they flagged carried a promotion code.

Finance's rule, which pricing must follow:

- a line's amount is unit price (cents) x quantity x (100 - the promotion's percent) / 100, computed exactly;
- each line is rounded to whole cents on its own; an amount exactly halfway between two cents goes to the even
  cent (12.5 -> 12, 13.5 -> 14);
- the cart's total is the sum of the rounded lines.

Acceptance criteria:

1. `Quote(cart)` follows finance's rule for every cart.
2. Nothing else about `Quote` changes: the cart format, which items are ignored, the promotion codes and how a code
   is matched, and the total of every cart that has no line exactly on half a cent.
3. Safe for concurrent use; standard library only; change only files under kshop/app/internal/hot/; the catalog,
   the input generators and every exported name and signature stay as they are; the existing tests keep passing.

How it is judged: hidden tests with carts finance checked by hand; a benchmark of `Quote` against today's code; the
change is then measured on the running service before it ships.
