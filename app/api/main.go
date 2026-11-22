// soge API — FX quote & execution service.
//
// Subcommands:
//
//	soge serve        HTTP server (default)
//	soge migrate      apply embedded SQL migrations (one-shot ECS task, uses the DB admin secret)
//	soge healthcheck  probe /healthz on localhost (container HEALTHCHECK, distroless has no shell)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

type config struct {
	Port           string // plain HTTP (local dev only)
	TLSPort        string // AWS: TLS 1.3 listener for the ALB (end-to-end encryption)
	TLSEnabled     bool
	HealthAddr     string        // loopback-only plain listener for the container health check
	QuoteKey       []byte        // HMAC key used to sign quotes (injected by ECS from Secrets Manager)
	QuoteTTL       time.Duration // validity of a locked quote
	RatesURL       string        // local dev only: direct ECB feed
	RatesBucket    string        // AWS: private bucket written by the rates_sync Lambda
	RatesKey       string
	RatesRefresh   time.Duration
	DB             dbConfig
	DevAuth        bool // local only: serve /x/s and trust X-Sub without API Gateway
	ShutdownGrace  time.Duration
	MetricsEnabled bool
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func loadConfig() (config, error) {
	ttl, err := time.ParseDuration(env("QUOTE_TTL", "15s"))
	if err != nil {
		return config{}, fmt.Errorf("QUOTE_TTL: %w", err)
	}
	refresh, err := time.ParseDuration(env("RATES_REFRESH", "60s"))
	if err != nil {
		return config{}, fmt.Errorf("RATES_REFRESH: %w", err)
	}
	key := os.Getenv("QUOTE_SIGNING_KEY")
	if len(key) < 32 {
		return config{}, errors.New("QUOTE_SIGNING_KEY must be at least 32 bytes")
	}
	port, _ := strconv.Atoi(env("DB_PORT", "5432"))
	return config{
		Port:           env("PORT", "8080"),
		TLSPort:        env("TLS_PORT", "8443"),
		TLSEnabled:     env("TLS_ENABLED", "false") == "true",
		HealthAddr:     env("HEALTH_ADDR", "127.0.0.1:8079"),
		QuoteKey:       []byte(key),
		QuoteTTL:       ttl,
		RatesURL:       env("RATES_URL", "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"),
		RatesRefresh:   refresh,
		DevAuth:        env("DEV_AUTH", "false") == "true",
		ShutdownGrace:  25 * time.Second, // < ECS stopTimeout (30s) and > ALB deregistration delay
		MetricsEnabled: env("EMF_METRICS", "true") == "true",
		DB: dbConfig{
			WriterHost: env("DB_WRITER_HOST", "localhost"),
			ReaderHost: env("DB_READER_HOST", env("DB_WRITER_HOST", "localhost")),
			Port:       port,
			Name:       env("DB_NAME", "soge"),
			User:       env("DB_USER", "soge_app"),
			Password:   os.Getenv("DB_PASSWORD"), // local / migrate only; empty => IAM auth
			Region:     env("AWS_REGION", "eu-west-3"),
			SSLMode:    env("DB_SSLMODE", "verify-full"),
			SSLRootCA:  env("DB_SSLROOTCERT", "/etc/ssl/certs/rds-global-bundle.pem"),
			MaxConns:   int32(atoiDef(env("DB_MAX_CONNS", "10"), 10)),
		},
	}, nil
}

func atoiDef(s string, d int) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return d
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve()
	case "migrate":
		err = migrate(context.Background())
	case "healthcheck":
		err = healthcheck()
	default:
		err = fmt.Errorf("unknown command %q", cmd)
	}
	if err != nil {
		slog.Error("fatal", "cmd", cmd, "err", err)
		os.Exit(1)
	}
}

func healthcheck() error {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get("http://" + env("HEALTH_ADDR", "127.0.0.1:8079") + "/healthz")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func serve() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	metrics := newMetrics(cfg.MetricsEnabled)
	go metrics.run(ctx, 10*time.Second)

	// The DB is optional at start-up: quotes keep working while Aurora fails over.
	store := newStore(ctx, cfg.DB)
	defer store.Close()

	fetch, err := ratesFetcher(ctx, cfg)
	if err != nil {
		return err
	}
	rates := newRatesBook(fetch, metrics)
	go rates.run(ctx, cfg.RatesRefresh)

	srv := &server{cfg: cfg, rates: rates, store: store, metrics: metrics, quotes: newQuoteSigner(cfg.QuoteKey, cfg.QuoteTTL)}
	handler := srv.routes()
	httpSrv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       65 * time.Second, // > ALB idle timeout (60s) to avoid 502 on keep-alive races
		MaxHeaderBytes:    16 << 10,
	}

	errCh := make(chan error, 2)
	if cfg.TLSEnabled {
		httpSrv.Addr = ":" + cfg.TLSPort
		httpSrv.TLSConfig = newSelfSignedTLS().config()
		go func() {
			slog.Info("listening (TLS 1.3)", "port", cfg.TLSPort)
			errCh <- httpSrv.ListenAndServeTLS("", "") // certificate comes from TLSConfig.GetCertificate
		}()
	} else {
		httpSrv.Addr = ":" + cfg.Port
		go func() {
			slog.Info("listening (plain HTTP, local only)", "port", cfg.Port)
			errCh <- httpSrv.ListenAndServe()
		}()
	}
	// Container health check: loopback only, never reachable from the network.
	healthMux := http.NewServeMux()
	healthMux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	healthSrv := &http.Server{Addr: cfg.HealthAddr, Handler: healthMux, ReadHeaderTimeout: 2 * time.Second}
	go func() { errCh <- healthSrv.ListenAndServe() }()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	// Graceful shutdown: flip readiness, let the ALB drain, then close.
	srv.draining.Store(true)
	slog.Info("SIGTERM received, draining")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	_ = healthSrv.Shutdown(shutdownCtx)
	return httpSrv.Shutdown(shutdownCtx)
}
