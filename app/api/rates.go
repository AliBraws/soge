package main

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"math/rand/v2"
	"net/http"
	"sync"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// ratesBook holds EUR-based reference rates (ECB daily reference rates).
//
// In AWS the API has NO internet egress: a dedicated Lambda (rates_sync) is the
// only component allowed out (through the network-account egress, behind the
// DNS Firewall allowlist). It publishes rates/latest.json to a private bucket
// that the API reads through the S3 gateway endpoint.
//
// Degradation ladder (reliability under failure):
//  1. latest published snapshot (fresh)
//  2. last snapshot successfully loaded by this task (flagged by its age)
//  3. embedded seed rates (service still answers, flagged "seed")
//
// A small bounded random walk around the reference mid makes the UI "tick".
type ratesBook struct {
	fetch   func(context.Context) (map[string]float64, string, error)
	metrics *metrics

	mu      sync.RWMutex
	ref     map[string]float64 // currency -> units per 1 EUR
	asOf    string
	source  string // ecb | seed
	fetched time.Time
	drift   map[string]float64
}

var seedRates = map[string]float64{"USD": 1.08, "GBP": 0.85, "JPY": 162.0, "CHF": 0.94}

func newRatesBook(fetch func(context.Context) (map[string]float64, string, error), m *metrics) *ratesBook {
	return &ratesBook{fetch: fetch, metrics: m, ref: seedRates, source: "seed", asOf: "seed", drift: map[string]float64{}}
}

// ratesFetcher picks the source: S3 snapshot in AWS, direct ECB feed locally.
func ratesFetcher(ctx context.Context, cfg config) (func(context.Context) (map[string]float64, string, error), error) {
	if cfg.RatesBucket == "" {
		c := &http.Client{Timeout: 5 * time.Second}
		return func(ctx context.Context) (map[string]float64, string, error) { return fetchECB(ctx, c, cfg.RatesURL) }, nil
	}
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.DB.Region))
	if err != nil {
		return nil, err
	}
	cli := s3.NewFromConfig(awsCfg)
	return func(ctx context.Context) (map[string]float64, string, error) {
		ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		out, err := cli.GetObject(ctx, &s3.GetObjectInput{Bucket: &cfg.RatesBucket, Key: &cfg.RatesKey})
		if err != nil {
			return nil, "", err
		}
		defer out.Body.Close()
		return parseSnapshot(io.LimitReader(out.Body, 1<<20))
	}, nil
}

type snapshot struct {
	AsOf  string             `json:"as_of"`
	Rates map[string]float64 `json:"rates"`
}

func parseSnapshot(r io.Reader) (map[string]float64, string, error) {
	var s snapshot
	if err := json.NewDecoder(r).Decode(&s); err != nil {
		return nil, "", err
	}
	if len(s.Rates) == 0 {
		return nil, "", errors.New("empty snapshot")
	}
	return s.Rates, s.AsOf, nil
}

func (b *ratesBook) run(ctx context.Context, every time.Duration) {
	b.refresh(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			b.refresh(ctx)
		}
	}
}

func (b *ratesBook) refresh(ctx context.Context) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ { // retry, jittered exponential backoff
		rates, asOf, err := b.fetch(ctx)
		if err == nil {
			b.set(rates, asOf, "ecb")
			return
		}
		lastErr = err
		backoff := time.Duration(float64(time.Second) * math.Pow(2, float64(attempt)) * (0.5 + rand.Float64()))
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
	}
	b.metrics.inc("RatesFetchFailures")
	slog.Warn("rates refresh failed, serving last known rates", "err", lastErr, "status", b.status())
}

type ecbEnvelope struct {
	Cube struct {
		Cube struct {
			Time  string `xml:"time,attr"`
			Rates []struct {
				Currency string  `xml:"currency,attr"`
				Rate     float64 `xml:"rate,attr"`
			} `xml:"Cube"`
		} `xml:"Cube"`
	} `xml:"Cube"`
}

func fetchECB(ctx context.Context, c *http.Client, url string) (map[string]float64, string, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := c.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("ecb status %d", resp.StatusCode)
	}
	return parseECB(io.LimitReader(resp.Body, 1<<20))
}

func parseECB(r io.Reader) (map[string]float64, string, error) {
	var env ecbEnvelope
	if err := xml.NewDecoder(r).Decode(&env); err != nil {
		return nil, "", err
	}
	out := map[string]float64{}
	for _, c := range env.Cube.Cube.Rates {
		if c.Rate > 0 {
			out[c.Currency] = c.Rate
		}
	}
	if len(out) == 0 {
		return nil, "", errors.New("empty ECB feed")
	}
	return out, env.Cube.Cube.Time, nil
}

func (b *ratesBook) set(rates map[string]float64, asOf, source string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.ref, b.asOf, b.source, b.fetched = rates, asOf, source, time.Now()
}

// mid returns the tradable mid for EURxxx pairs (and xxxEUR via inversion).
func (b *ratesBook) mid(pair string) (float64, string, bool) {
	base, quoteCcy := pair[:3], pair[3:]
	b.mu.Lock()
	defer b.mu.Unlock()
	var ref float64
	switch {
	case base == "EUR":
		ref = b.ref[quoteCcy]
	case quoteCcy == "EUR" && b.ref[base] > 0:
		ref = 1 / b.ref[base]
	}
	if ref <= 0 {
		return 0, "", false
	}
	d := b.drift[pair] + (rand.Float64()-0.5)*0.0002 // bounded walk: +-0.15%
	d = math.Max(-0.0015, math.Min(0.0015, d))
	b.drift[pair] = d
	return ref * (1 + d), b.source + ":" + b.asOf, true
}

func (b *ratesBook) status() map[string]any {
	b.mu.RLock()
	defer b.mu.RUnlock()
	age := -1
	if !b.fetched.IsZero() {
		age = int(time.Since(b.fetched).Seconds())
	}
	return map[string]any{"source": b.source, "as_of": b.asOf, "loaded_age_seconds": age}
}
