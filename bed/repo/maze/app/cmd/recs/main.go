// recs is the maze image of that name (spec.json: the services that run it and what each route does).
package main

import (
	"maze/internal/rt"
	_ "maze/internal/svc/recs"
)

func main() { rt.Main() }
