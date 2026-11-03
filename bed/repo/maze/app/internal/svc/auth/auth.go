// Package auth verifies the session token of every request (the demo derives the token from the request's query).
package auth

import (
	"errors"

	"maze/internal/lib/token"
	"maze/internal/rt"
)

const expiry = 4102444800 // 2100-01-01

func init() {
	rt.Register("auth.verify", func(r *rt.Req) error {
		if !token.Verify(token.Sign("u"+r.Query, expiry), 0) {
			return errors.New("bad token")
		}
		return nil
	})
}
