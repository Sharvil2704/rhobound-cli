package token

import "testing"

func TestVerify(t *testing.T) {
	tok := Sign("u1", 100)
	if !Verify(tok, 50) || Verify(tok, 101) || Verify(tok+"0", 50) || Verify("x.y", 0) {
		t.Fatal("verify")
	}
}

func BenchmarkVerify(b *testing.B) {
	tok := Sign("u1", 100)
	for b.Loop() {
		Verify(tok, 0)
	}
}
