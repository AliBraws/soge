package main

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"time"
)

// CloudWatch Embedded Metric Format: metrics are emitted as structured log
// lines and extracted by CloudWatch Logs. No agent, no sidecar, no extra IAM.
type metrics struct {
	enabled bool
	mu      sync.Mutex
	c       map[string]float64
}

func newMetrics(enabled bool) *metrics { return &metrics{enabled: enabled, c: map[string]float64{}} }

func (m *metrics) inc(name string) {
	m.mu.Lock()
	m.c[name]++
	m.mu.Unlock()
}

func (m *metrics) run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			m.flush()
			return
		case <-t.C:
			m.flush()
		}
	}
}

func (m *metrics) flush() {
	if !m.enabled {
		return
	}
	m.mu.Lock()
	snap := m.c
	m.c = map[string]float64{}
	m.mu.Unlock()
	if len(snap) == 0 {
		return
	}
	defs := make([]map[string]string, 0, len(snap))
	doc := map[string]any{"Service": "soge-api"}
	for k, v := range snap {
		defs = append(defs, map[string]string{"Name": k, "Unit": "Count"})
		doc[k] = v
	}
	doc["_aws"] = map[string]any{
		"Timestamp": time.Now().UnixMilli(),
		"CloudWatchMetrics": []map[string]any{{
			"Namespace":  "Soge",
			"Dimensions": [][]string{{"Service"}},
			"Metrics":    defs,
		}},
	}
	_ = json.NewEncoder(os.Stdout).Encode(doc)
}
