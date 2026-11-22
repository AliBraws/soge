package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestQuoteSignVerify(t *testing.T) {
	s := newQuoteSigner([]byte(strings.Repeat("k", 32)), 15*time.Second)
	q := s.issue("EURUSD", 1.1, "test")
	if q.Bid >= q.Ask {
		t.Fatalf("bid %v must be < ask %v", q.Bid, q.Ask)
	}
	got, err := s.verify(q.Token, time.Now())
	if err != nil || got.ID != q.ID {
		t.Fatalf("verify: %v", err)
	}
	if _, err := s.verify(q.Token, time.Now().Add(time.Minute)); !errors.Is(err, errQuoteExpired) {
		t.Fatalf("want expired, got %v", err)
	}
	tampered := strings.Replace(q.Token, q.Token[:5], "AAAAA", 1)
	if _, err := s.verify(tampered, time.Now()); !errors.Is(err, errQuoteInvalid) {
		t.Fatalf("want invalid, got %v", err)
	}
	other := newQuoteSigner([]byte(strings.Repeat("x", 32)), time.Second)
	if _, err := other.verify(q.Token, time.Now()); !errors.Is(err, errQuoteInvalid) {
		t.Fatalf("foreign key must fail, got %v", err)
	}
}

func TestParseECB(t *testing.T) {
	xml := `<?xml version="1.0"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time="2026-11-18"><Cube currency="USD" rate="1.0812"/><Cube currency="JPY" rate="161.20"/></Cube></Cube></gesmes:Envelope>`
	r, asOf, err := parseECB(strings.NewReader(xml))
	if err != nil || asOf != "2026-11-18" || r["USD"] != 1.0812 || r["JPY"] != 161.20 {
		t.Fatalf("parse: %v %v %v", r, asOf, err)
	}
	if _, _, err := parseECB(strings.NewReader("<x/>")); err == nil {
		t.Fatal("empty feed must error")
	}
	snap, asOf, err := parseSnapshot(strings.NewReader(`{"as_of":"2026-11-18","rates":{"USD":1.08}}`))
	if err != nil || asOf != "2026-11-18" || snap["USD"] != 1.08 {
		t.Fatalf("snapshot: %v %v", snap, err)
	}
}

func TestMidInversionAndBounds(t *testing.T) {
	b := newRatesBook(nil, newMetrics(false))
	for i := 0; i < 1000; i++ {
		m, _, ok := b.mid("EURUSD")
		if !ok || m < 1.08*0.998 || m > 1.08*1.002 {
			t.Fatalf("mid out of bounds: %v", m)
		}
	}
	if m, _, ok := b.mid("USDEUR"); !ok || m > 1 {
		t.Fatalf("inverse: %v", m)
	}
	if _, _, ok := b.mid("XXXYYY"); ok {
		t.Fatal("unknown pair must fail")
	}
}

func newTestServer() *server {
	cfg := config{DevAuth: false}
	return &server{
		cfg: cfg, rates: newRatesBook(nil, newMetrics(false)), store: &store{},
		metrics: newMetrics(false), quotes: newQuoteSigner([]byte(strings.Repeat("k", 32)), 15*time.Second),
	}
}

func TestRoutesAuthAndValidation(t *testing.T) {
	h := newTestServer().routes()

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest("GET", "/x/q?p=EURUSD", nil))
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("no X-Sub: want 401 got %d", rr.Code)
	}

	req := httptest.NewRequest("GET", "/x/q?p=EURUSD", nil)
	req.Header.Set("X-Sub", "u1")
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("quote: %d %s", rr.Code, rr.Body)
	}
	var q quote
	_ = json.Unmarshal(rr.Body.Bytes(), &q)

	// missing idempotency key
	body, _ := json.Marshal(dealRequest{Quote: q.Token, Side: "BUY", Notional: 10000})
	req = httptest.NewRequest("POST", "/x/d", bytes.NewReader(body))
	req.Header.Set("X-Sub", "u1")
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("idem: want 400 got %d", rr.Code)
	}

	// DB down -> 503 + Retry-After (graceful degradation), quotes still served above
	req = httptest.NewRequest("POST", "/x/d", bytes.NewReader(body))
	req.Header.Set("X-Sub", "u1")
	req.Header.Set("Idempotency-Key", "0123456789abcdef-0001")
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusServiceUnavailable || rr.Header().Get("Retry-After") == "" {
		t.Fatalf("db down: want 503 got %d", rr.Code)
	}
}

func TestSelfSignedTLS13(t *testing.T) {
	s := newSelfSignedTLS()
	c1, err := s.get(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c2, _ := s.get(nil); c2 != c1 {
		t.Fatal("certificate must be cached within its TTL")
	}
	s.created = time.Now().Add(-25 * time.Hour)
	if c3, _ := s.get(nil); c3 == c1 {
		t.Fatal("certificate must be renewed after 24h")
	}
	if s.config().MinVersion != tls.VersionTLS13 {
		t.Fatal("TLS 1.3 minimum expected")
	}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	srv.TLS = s.config()
	srv.StartTLS()
	defer srv.Close()
	cli := srv.Client()
	cli.Transport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true, MaxVersion: tls.VersionTLS12} //nolint:gosec // test: TLS 1.2 must be refused
	if _, err := cli.Get(srv.URL); err == nil {
		t.Fatal("TLS 1.2 must be refused")
	}
}

func TestUIServedWithSecurityHeaders(t *testing.T) {
	h := newTestServer().routes()
	for _, p := range []string{"/", "/some/deep/link", "/assets/app.js"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest("GET", p, nil))
		if rr.Code != http.StatusOK {
			t.Fatalf("%s: %d", p, rr.Code)
		}
		if rr.Header().Get("Content-Security-Policy") == "" || rr.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("%s: missing security headers", p)
		}
	}
}
