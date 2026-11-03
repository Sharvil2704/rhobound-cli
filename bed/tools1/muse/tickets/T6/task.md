Title: Reranked results should be diverse

Users of the feed and of search see near-duplicate items next to each other. rank returns the 10 highest-scoring of its
64 candidates, and similar candidates score alike. Rerank's top 10 should be diversified with maximal marginal relevance
(MMR).

In rank (maze/app/internal/svc/rank/rank.go):
- add `func Features(seed uint64, c int) []float64`: candidate c's 32 features for request seed, the values Rerank
  scores today: feature d is float64((seed+uint64(c*32+d)*40503)%997)/997;
- add `func Diversify(seed uint64, k int, lambda float64) []int`: k of the 64 candidates, chosen greedily by MMR:
  - the relevance r(c) of a candidate is Rerank's score of c divided by the highest score of the 64;
  - the first pick is the most relevant candidate;
  - each next pick is the candidate not yet chosen with the highest lambda*r(c) - (1-lambda)*s(c), where s(c) is the
    largest cosine similarity between c's features and the features of any chosen candidate;
  - ties go to the lower candidate index;
  - k below 0 counts as 0, and above 64 as 64;
- the /rerank hook (rank.rerank) answers Diversify(its seed, 10, 0.7), written as today ([i i ...]); today it answers
  Rerank(seed)[:10].

Acceptance criteria:
1. Features and Diversify are as defined. With lambda 1, Diversify gives the k highest-scoring candidates in score order.
2. The rank.rerank hook answers the diversified top 10.
3. Nothing else changes: Rerank and every existing exported name and signature stay as they are. The code is safe for
   concurrent use, uses the standard library and the module's own packages only, and changes only files under
   maze/app/internal/svc/rank/.

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
