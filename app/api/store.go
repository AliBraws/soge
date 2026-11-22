package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"embed"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sort"
	"strings"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/lib/pq"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

type dbConfig struct {
	WriterHost, ReaderHost string
	Port                   int
	Name, User, Password   string
	Region                 string
	SSLMode, SSLRootCA     string
	MaxConns               int32
}

var (
	errDBUnavailable = errors.New("database unavailable")
	errIdemMismatch  = errors.New("idempotency key reused with different payload")
	errQuoteUsed     = errors.New("quote already executed")
)

type store struct {
	writer, reader *sql.DB
}

type deal struct {
	ID          string    `json:"id"`
	Owner       string    `json:"-"`
	IdemKey     string    `json:"-"`
	RequestHash string    `json:"-"`
	Pair        string    `json:"pair"`
	Side        string    `json:"side"`
	Notional    int64     `json:"notional"`
	Price       float64   `json:"price"`
	QuoteID     string    `json:"quote_id"`
	CreatedAt   time.Time `json:"created_at"`
}

type insertResult struct {
	Deal     deal
	Replayed bool
}

// iamConnector opens every new physical connection with a freshly generated
// 15-minute IAM auth token: the application has no database password at all,
// and token renewal is automatic.
type iamConnector struct {
	dsn string
	gen func(context.Context) (string, error)
}

func (c iamConnector) Connect(ctx context.Context) (driver.Conn, error) {
	pw := ""
	if c.gen != nil {
		tok, err := c.gen(ctx)
		if err != nil {
			return nil, err
		}
		pw = " password='" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(tok) + "'"
	}
	pc, err := pq.NewConnector(c.dsn + pw)
	if err != nil {
		return nil, err
	}
	return pc.Connect(ctx)
}

func (c iamConnector) Driver() driver.Driver { return &pq.Driver{} }

// newStore never fails: connections are lazy so the service starts (and keeps
// serving quotes) while Aurora is failing over.
func newStore(ctx context.Context, c dbConfig) *store {
	w, err := openDB(ctx, c, c.WriterHost)
	if err != nil {
		slog.Error("writer pool", "err", err)
	}
	r, err := openDB(ctx, c, c.ReaderHost)
	if err != nil {
		slog.Error("reader pool", "err", err)
	}
	return &store{writer: w, reader: r}
}

func openDB(ctx context.Context, c dbConfig, host string) (*sql.DB, error) {
	dsn := fmt.Sprintf("host=%s port=%d dbname=%s user=%s sslmode=%s connect_timeout=3",
		host, c.Port, c.Name, c.User, c.SSLMode)
	if c.SSLMode == "verify-full" || c.SSLMode == "verify-ca" {
		dsn += " sslrootcert=" + c.SSLRootCA // RDS CA bundle baked into the image
	}
	conn := iamConnector{dsn: dsn}
	if c.Password != "" {
		pw := c.Password
		conn.gen = func(context.Context) (string, error) { return pw, nil }
	} else {
		awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(c.Region))
		if err != nil {
			return nil, err
		}
		endpoint := fmt.Sprintf("%s:%d", host, c.Port)
		conn.gen = func(ctx context.Context) (string, error) {
			return auth.BuildAuthToken(ctx, endpoint, c.Region, c.User, awsCfg.Credentials)
		}
	}
	db := sql.OpenDB(conn)
	db.SetMaxOpenConns(int(c.MaxConns)) // bounded: tasks x MaxConns must stay < Aurora max_connections
	db.SetMaxIdleConns(int(c.MaxConns))
	db.SetConnMaxLifetime(10 * time.Minute) // rebalance across readers after a failover
	db.SetConnMaxIdleTime(2 * time.Minute)
	return db, nil
}

func (s *store) Close() {
	for _, d := range []*sql.DB{s.writer, s.reader} {
		if d != nil {
			_ = d.Close()
		}
	}
}

func (s *store) Ping(ctx context.Context) error {
	if s.writer == nil {
		return errDBUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	return s.writer.PingContext(ctx)
}

func isTransient(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		c := string(pqErr.Code)
		// 57P01 admin_shutdown (failover), 08xxx connection, 40001 serialization, 25006 read-only (writer demoted)
		return c == "57P01" || c == "40001" || c == "25006" || strings.HasPrefix(c, "08")
	}
	var netErr net.Error
	return errors.Is(err, driver.ErrBadConn) || errors.Is(err, context.DeadlineExceeded) ||
		errors.As(err, &netErr) || errors.Is(err, errDBUnavailable)
}

// InsertDeal is idempotent per (owner, idem_key). The deals table is append-only:
// the application role has no UPDATE/DELETE grant (ledger semantics).
func (s *store) InsertDeal(ctx context.Context, d deal) (insertResult, error) {
	if s.writer == nil {
		return insertResult{}, errDBUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	const q = `
INSERT INTO deals (id, owner, idem_key, request_hash, pair, side, notional, price, quote_id)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
ON CONFLICT (owner, idem_key) DO NOTHING
RETURNING created_at`
	err := s.writer.QueryRowContext(ctx, q, d.ID, d.Owner, d.IdemKey, d.RequestHash, d.Pair, d.Side, d.Notional, d.Price, d.QuoteID).Scan(&d.CreatedAt)
	if err == nil {
		return insertResult{Deal: d}, nil
	}
	if errors.Is(err, sql.ErrNoRows) { // conflict on the idempotency key -> replay the original response
		var prev deal
		err := s.writer.QueryRowContext(ctx, `SELECT id, request_hash, pair, side, notional, price, quote_id, created_at
FROM deals WHERE owner=$1 AND idem_key=$2`, d.Owner, d.IdemKey).
			Scan(&prev.ID, &prev.RequestHash, &prev.Pair, &prev.Side, &prev.Notional, &prev.Price, &prev.QuoteID, &prev.CreatedAt)
		if err != nil {
			if isTransient(err) {
				return insertResult{}, errDBUnavailable
			}
			return insertResult{}, err
		}
		if prev.RequestHash != d.RequestHash {
			return insertResult{}, errIdemMismatch
		}
		return insertResult{Deal: prev, Replayed: true}, nil
	}
	var pqErr *pq.Error
	if errors.As(err, &pqErr) && pqErr.Code == "23505" && pqErr.Constraint == "deals_quote_id_key" {
		return insertResult{}, errQuoteUsed
	}
	if isTransient(err) {
		return insertResult{}, errDBUnavailable
	}
	return insertResult{}, err
}

// ListDeals reads from the Aurora reader endpoint (read scaling, writer offload).
func (s *store) ListDeals(ctx context.Context, owner string, limit int) ([]deal, error) {
	db := s.reader
	if db == nil {
		db = s.writer
	}
	if db == nil {
		return nil, errDBUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	rows, err := db.QueryContext(ctx, `SELECT id, pair, side, notional, price, quote_id, created_at
FROM deals WHERE owner=$1 ORDER BY created_at DESC LIMIT $2`, owner, limit)
	if err != nil {
		if isTransient(err) {
			return nil, errDBUnavailable
		}
		return nil, err
	}
	defer rows.Close()
	out := []deal{}
	for rows.Next() {
		var d deal
		if err := rows.Scan(&d.ID, &d.Pair, &d.Side, &d.Notional, &d.Price, &d.QuoteID, &d.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		if isTransient(err) {
			return nil, errDBUnavailable
		}
		return nil, err
	}
	return out, nil
}

// migrate runs with the admin credentials managed by RDS in Secrets Manager,
// injected only into the one-shot migration task (never into the API task).
func migrate(ctx context.Context) error {
	cfg := dbConfig{
		WriterHost: env("DB_WRITER_HOST", "localhost"), Port: atoiDef(env("DB_PORT", "5432"), 5432),
		Name: env("DB_NAME", "soge"), User: env("DB_ADMIN_USER", "sogeadmin"), Password: os.Getenv("DB_ADMIN_PASSWORD"),
		SSLMode: env("DB_SSLMODE", "verify-full"), SSLRootCA: env("DB_SSLROOTCERT", "/etc/ssl/certs/rds-global-bundle.pem"),
		MaxConns: 1, Region: env("AWS_REGION", "eu-west-3"),
	}
	if cfg.Password == "" {
		return errors.New("DB_ADMIN_PASSWORD is required for migrate")
	}
	db, err := openDB(ctx, cfg, cfg.WriterHost)
	if err != nil {
		return err
	}
	defer db.Close()
	entries, _ := migrationsFS.ReadDir("migrations")
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, n := range names {
		q, _ := migrationsFS.ReadFile("migrations/" + n)
		if _, err := db.ExecContext(ctx, string(q)); err != nil {
			return fmt.Errorf("%s: %w", n, err)
		}
		slog.Info("migration applied", "file", n)
	}
	return nil
}
