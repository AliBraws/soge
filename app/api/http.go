package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync/atomic"
	"time"
)

type server struct {
	cfg      config
	rates    *ratesBook
	store    *store
	metrics  *metrics
	quotes   *quoteSigner
	draining atomic.Bool
}

// Opaque, deliberately non-descriptive routes (see docs/DECISIONS.md, ADR-009).
//
//	GET  /x/q?p=EURUSD   indicative + lockable quote
//	POST /x/d            execute a locked quote (Idempotency-Key required)
//	GET  /x/d            caller's deal blotter (served from Aurora readers)
//	POST /x/s            DEV ONLY - in AWS this route is served by the issuer Lambda
func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.Handle("GET /", uiHandler())
	mux.HandleFunc("GET /x/q", s.authed(s.getQuote))
	mux.HandleFunc("POST /x/d", s.authed(s.postDeal))
	mux.HandleFunc("GET /x/d", s.authed(s.listDeals))
	if s.cfg.DevAuth {
		mux.HandleFunc("POST /x/s", s.devSession)
	}
	return s.observe(mux)
}

type ctxKey struct{}

// authed extracts the caller identity. In AWS, API Gateway overwrites X-Sub with
// $context.authorizer.principalId and the ALB only accepts traffic from the VPC
// link security group, so the header cannot be spoofed by a client.
func (s *server) authed(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sub := r.Header.Get("X-Sub")
		if sub == "" || len(sub) > 128 {
			writeErr(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		next(w, r, sub)
	}
}

func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	status := map[string]any{
		"draining":    s.draining.Load(),
		"rates":       s.rates.status(),
		"db_writable": s.store.Ping(r.Context()) == nil,
	}
	code := http.StatusOK
	if s.draining.Load() {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, status)
}

var pairRe = regexp.MustCompile(`^[A-Z]{6}$`)

func (s *server) getQuote(w http.ResponseWriter, r *http.Request, _ string) {
	pair := strings.ToUpper(r.URL.Query().Get("p"))
	if !pairRe.MatchString(pair) {
		writeErr(w, http.StatusBadRequest, "invalid pair")
		return
	}
	mid, src, ok := s.rates.mid(pair)
	if !ok {
		writeErr(w, http.StatusNotFound, "unknown pair")
		return
	}
	q := s.quotes.issue(pair, mid, src)
	writeJSON(w, http.StatusOK, q)
}

type dealRequest struct {
	Quote    string `json:"quote"`
	Side     string `json:"side"`
	Notional int64  `json:"notional"`
}

var idemRe = regexp.MustCompile(`^[A-Za-z0-9-]{16,64}$`)

func (s *server) postDeal(w http.ResponseWriter, r *http.Request, sub string) {
	idem := r.Header.Get("Idempotency-Key")
	if !idemRe.MatchString(idem) {
		writeErr(w, http.StatusBadRequest, "Idempotency-Key header required")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req dealRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Side != "BUY" && req.Side != "SELL" {
		writeErr(w, http.StatusBadRequest, "side must be BUY or SELL")
		return
	}
	if req.Notional < 1_000 || req.Notional > 10_000_000 {
		writeErr(w, http.StatusBadRequest, "notional out of range [1000, 10000000]")
		return
	}
	q, err := s.quotes.verify(req.Quote, time.Now())
	if errors.Is(err, errQuoteExpired) {
		writeErr(w, http.StatusConflict, "quote expired")
		return
	} else if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid quote")
		return
	}
	price := q.Ask
	if req.Side == "SELL" {
		price = q.Bid
	}
	h := sha256.Sum256([]byte(req.Quote + "|" + req.Side + "|" + itoa(req.Notional)))
	d := deal{
		ID: newID(), Owner: sub, IdemKey: idem, RequestHash: hex.EncodeToString(h[:]),
		Pair: q.Pair, Side: req.Side, Notional: req.Notional, Price: price, QuoteID: q.ID,
	}
	res, err := s.store.InsertDeal(r.Context(), d)
	switch {
	case errors.Is(err, errIdemMismatch):
		writeErr(w, http.StatusUnprocessableEntity, "Idempotency-Key reused with a different payload")
	case errors.Is(err, errQuoteUsed):
		writeErr(w, http.StatusConflict, "quote already executed")
	case errors.Is(err, errDBUnavailable):
		w.Header().Set("Retry-After", "2")
		writeErr(w, http.StatusServiceUnavailable, "temporarily unavailable, retry with the same Idempotency-Key")
	case err != nil:
		slog.Error("insert deal", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
	default:
		code := http.StatusCreated
		if res.Replayed {
			code = http.StatusOK
			w.Header().Set("Idempotent-Replayed", "true")
		} else {
			s.metrics.inc("DealsExecuted")
		}
		writeJSON(w, code, res.Deal)
	}
}

func (s *server) listDeals(w http.ResponseWriter, r *http.Request, sub string) {
	deals, err := s.store.ListDeals(r.Context(), sub, 50)
	if errors.Is(err, errDBUnavailable) {
		w.Header().Set("Retry-After", "2")
		writeErr(w, http.StatusServiceUnavailable, "temporarily unavailable")
		return
	} else if err != nil {
		slog.Error("list deals", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deals": deals})
}

func (s *server) devSession(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"token": "dev", "expires_in": 300})
}

// observe: structured access log + EMF counters. The trace id comes from the ALB.
type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(c int) { r.code = c; r.ResponseWriter.WriteHeader(c) }

func (s *server) observe(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: 200}
		if s.cfg.DevAuth && r.Header.Get("X-Sub") == "" {
			r.Header.Set("X-Sub", "local-user")
		}
		if strings.HasPrefix(r.URL.Path, "/x/") {
			w.Header().Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(rec, r)
		if r.URL.Path == "/healthz" || !strings.HasPrefix(r.URL.Path, "/x/") {
			return // static hits are logged by CloudFront / API Gateway
		}
		s.metrics.inc("Requests_" + statusClass(rec.code))
		sum := sha256.Sum256([]byte(r.Header.Get("X-Sub")))
		slog.Info("http",
			"trace_id", r.Header.Get("X-Amzn-Trace-Id"),
			"method", r.Method, "path", r.URL.Path, "status", rec.code,
			"duration_ms", time.Since(start).Milliseconds(),
			"sub_hash", hex.EncodeToString(sum[:6]), // pseudonymised, no PII in logs
		)
	})
}

func statusClass(c int) string { return string(rune('0'+c/100)) + "xx" }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40 // UUIDv4
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
