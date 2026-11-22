package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"sync"
	"time"
)

// selfSignedTLS encrypts the ALB -> task hop (end-to-end encryption).
//
// The ALB does not validate target certificates, so no PKI is needed for this
// hop: each task generates an ECDSA P-256 key pair IN MEMORY at start-up (never
// written to disk, never in a secret store, never in Terraform) and renews it
// every 24 h. Tasks are also replaced at every deployment.
// TLS 1.3 only: with a TLS 1.3 listener policy the ALB negotiates TLS 1.3 with
// targets (backend policy ELBSecurityPolicy-TLS13-1-0-2021-06).
type selfSignedTLS struct {
	mu      sync.Mutex
	cert    *tls.Certificate
	created time.Time
	ttl     time.Duration
}

func newSelfSignedTLS() *selfSignedTLS { return &selfSignedTLS{ttl: 24 * time.Hour} }

func (s *selfSignedTLS) config() *tls.Config {
	return &tls.Config{
		MinVersion:     tls.VersionTLS13,
		GetCertificate: s.get,
	}
}

func (s *selfSignedTLS) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cert == nil || time.Since(s.created) > s.ttl {
		c, err := generateCert(s.ttl * 2)
		if err != nil {
			return nil, err
		}
		s.cert, s.created = c, time.Now()
	}
	return s.cert, nil
}

func generateCert(validity time.Duration) (*tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "soge-task"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(validity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
