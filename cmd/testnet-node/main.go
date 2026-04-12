package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"

	"github.com/agent-testnet/agent-testnet/pkg/api"
)

func main() {
	serverURL := flag.String("server-url", "", "testnet server URL (https://...)")
	name := flag.String("name", "", "node name (as declared in nodes.yaml)")
	secret := flag.String("secret", "", "per-node secret from nodes.yaml")
	listenAddr := flag.String("listen", ":443", "address to listen on")
	flag.Parse()

	if *serverURL == "" || *name == "" || *secret == "" {
		log.Fatal("--server-url, --name, and --secret are required")
	}

	// Fetch certs from the server
	log.Printf("Fetching TLS certificates from %s for node %s...", *serverURL, *name)
	client := api.NewServerClient(*serverURL, nil)
	certs, err := client.FetchNodeCerts(*name, *secret)
	if err != nil {
		log.Fatalf("Failed to fetch certs: %v", err)
	}
	log.Println("Certificates received.")

	// Parse the TLS certificate
	tlsCert, err := tls.X509KeyPair([]byte(certs.CertPEM), []byte(certs.KeyPEM))
	if err != nil {
		log.Fatalf("Failed to parse TLS cert: %v", err)
	}

	// Set up HTTPS server
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]string{
			"node":   *name,
			"status": "ok",
			"host":   r.Host,
			"path":   r.URL.Path,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "OK")
	})

	srv := &http.Server{
		Addr:    *listenAddr,
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCert},
		},
	}

	log.Printf("Testnet node %s listening on %s (HTTPS)", *name, *listenAddr)
	if err := srv.ListenAndServeTLS("", ""); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
