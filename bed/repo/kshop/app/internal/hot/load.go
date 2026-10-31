package hot

import (
	"math"
	"sort"
	"strings"
	"sync"
)

// The workload: production and both A/B arms draw their inputs from these generators, so the input distribution
// is part of the measured code path. Each process seeds its own generators (QuerySeed, CartSeed).
const (
	// QueryLogSize is the number of distinct queries; NextQuery draws them with Zipf weights 1/k^ZipfS.
	QueryLogSize = 2000
	ZipfS        = 1.1
	QuerySeed    = 2027
	CartSeed     = 2028
	queryLogSeed = 2029
)

var (
	logOnce  sync.Once
	queryLog []string
	zipfCDF  []float64
)

// QueryLog returns the distinct queries in rank order (index 0 is the most frequent). Shared: do not modify.
func QueryLog() []string {
	logOnce.Do(buildQueryLog)
	return queryLog
}

func buildQueryLog() {
	vocab := Vocabulary()
	r := &rng{s: queryLogSeed}
	seen := map[string]bool{}
	seps := []string{" ", " ", " ", ", ", " + "}
	for len(queryLog) < QueryLogSize {
		n := 1 + r.intn(3)
		var b strings.Builder
		for j := 0; j < n; j++ {
			w := vocab[r.skewed(len(vocab))]
			switch r.intn(6) {
			case 0:
				w = titleCase(w)
			case 1:
				w = strings.ToUpper(w)
			}
			if j > 0 {
				b.WriteString(seps[r.intn(len(seps))])
			}
			b.WriteString(w)
		}
		if q := b.String(); !seen[q] {
			seen[q] = true
			queryLog = append(queryLog, q)
		}
	}
	zipfCDF = make([]float64, QueryLogSize)
	sum := 0.0
	for k := range zipfCDF {
		sum += 1 / math.Pow(float64(k+1), ZipfS)
		zipfCDF[k] = sum
	}
}

// promo spellings carts carry: the codes as printed, lower case, without accents, full width, unknown
var cartPromos = []string{"SAVE10", "save10", "SPRING15", "Spring15", "QUARTER", "quarter", "HALF", "half", "ＨＡＬＦ",
	"ÉTÉ25", "été25", "ETE25", "ete25", "NOËL50", "noël50", "NOEL50", "ＶＩＰ２０", "VIP20", "vip20", "WELCOME5"}

// Gen is a seeded input generator (queries or carts), safe for concurrent use.
type Gen struct {
	mu    sync.Mutex
	r     rng
	carts bool
}

// NewQueryGen returns a generator of queries: QueryLog entries drawn with Zipf weights (s = ZipfS).
func NewQueryGen(seed uint64) *Gen { return &Gen{r: rng{s: seed}} }

// NewCartGen returns a generator of carts in Quote's format: 1 to 4 items (skewed toward low IDs), QTY 1 to 4, a
// promotion code (some unknown, some spelled differently from the table) on about half of them.
func NewCartGen(seed uint64) *Gen { return &Gen{r: rng{s: seed}, carts: true} }

// Next returns the generator's next input.
func (g *Gen) Next() string {
	if !g.carts {
		ql := QueryLog()
		g.mu.Lock()
		u := g.r.float()
		g.mu.Unlock()
		k := sort.SearchFloat64s(zipfCDF, u*zipfCDF[len(zipfCDF)-1])
		return ql[min(k, len(ql)-1)]
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	var b strings.Builder
	for i, n := 0, 1+g.r.intn(4); i < n; i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(itoa(1 + g.r.skewed(NumDocs)))
		b.WriteByte(':')
		b.WriteString(itoa(1 + g.r.intn(4)))
	}
	if g.r.intn(2) == 0 {
		b.WriteByte(';')
		b.WriteString(cartPromos[g.r.intn(len(cartPromos))])
	}
	return b.String()
}

var (
	defaultQueries = NewQueryGen(QuerySeed)
	defaultCarts   = NewCartGen(CartSeed)
)

// NextQuery returns the process's next search query (catalog's code path "rank": Rank(NextQuery())).
func NextQuery() string { return defaultQueries.Next() }

// NextCart returns the process's next cart (pricing's code path "quote": Quote(NextCart())).
func NextCart() string { return defaultCarts.Next() }

// Warm builds the catalog and the query log and runs Rank and Quote once on fixed inputs (not drawn from the
// generators), so a service's first request does not pay for them.
func Warm() {
	QueryLog()
	Rank("warm up")
	Quote("1:1;SAVE10")
}
