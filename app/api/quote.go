package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"time"
)

// Quotes are stateless and HMAC-signed: the read path (the hot path under load)
// never touches the database, so it scales linearly with the number of tasks.
// Only the execution path writes to Aurora.

type quote struct {
	ID      string  `json:"id"`
	Pair    string  `json:"pair"`
	Bid     float64 `json:"bid"`
	Ask     float64 `json:"ask"`
	Source  string  `json:"source"`
	Expires int64   `json:"exp"`
	Token   string  `json:"token,omitempty"`
}

var (
	errQuoteExpired = errors.New("quote expired")
	errQuoteInvalid = errors.New("quote invalid")
)

type quoteSigner struct {
	key []byte
	ttl time.Duration
	now func() time.Time
}

func newQuoteSigner(key []byte, ttl time.Duration) *quoteSigner {
	return &quoteSigner{key: key, ttl: ttl, now: time.Now}
}

const spreadBps = 2.0

func (s *quoteSigner) issue(pair string, mid float64, source string) quote {
	half := mid * spreadBps / 2 / 10_000
	q := quote{
		ID:      newID(),
		Pair:    pair,
		Bid:     round(mid-half, 5),
		Ask:     round(mid+half, 5),
		Source:  source,
		Expires: s.now().Add(s.ttl).Unix(),
	}
	payload, _ := json.Marshal(q)
	p := base64.RawURLEncoding.EncodeToString(payload)
	q.Token = p + "." + s.sign(p)
	return q
}

func (s *quoteSigner) sign(p string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(p))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *quoteSigner) verify(token string, now time.Time) (quote, error) {
	p, sig, ok := strings.Cut(token, ".")
	if !ok || !hmac.Equal([]byte(sig), []byte(s.sign(p))) {
		return quote{}, errQuoteInvalid
	}
	raw, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return quote{}, errQuoteInvalid
	}
	var q quote
	if err := json.Unmarshal(raw, &q); err != nil {
		return quote{}, errQuoteInvalid
	}
	if now.Unix() > q.Expires {
		return q, errQuoteExpired
	}
	return q, nil
}

func round(v float64, d int) float64 {
	p := math.Pow(10, float64(d))
	return math.Round(v*p) / p
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
