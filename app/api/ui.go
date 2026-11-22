package main

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

// The UI is compiled into the binary (go:embed): one versioned image, UI and
// API always deployed together and always compatible, served over the same
// TLS 1.3 listener. CloudFront caches it at the edge, so the containers only
// see cache misses.
//
//go:embed ui
var uiFS embed.FS

// Same policy as the CloudFront response headers policy (defence in depth, and
// identical behaviour when running locally).
const csp = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

func uiHandler() http.Handler {
	sub, _ := fs.Sub(uiFS, "ui")
	files := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		if strings.HasPrefix(r.URL.Path, "/assets/") {
			h.Set("Cache-Control", "public, max-age=300")
		} else {
			h.Set("Cache-Control", "no-cache")
			r.URL.Path = "/" // single page: every non-asset path serves index.html
		}
		files.ServeHTTP(w, r)
	})
}
