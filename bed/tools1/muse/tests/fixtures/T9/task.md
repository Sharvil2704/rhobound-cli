Title: Catalog greets its callers

catalog (maze/app/internal/svc/catalog/catalog.go) should offer `func Hello() string` that returns "hi", for the
storefront's health page. Nothing else changes; standard library only; change only maze/app/internal/svc/catalog/.

Latency SLO: no user-facing entry's mean latency may rise more than 4 ms.
