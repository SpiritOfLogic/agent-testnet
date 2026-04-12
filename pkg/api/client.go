package api

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
)

// ServerClient is a Go client for the testnet-server control plane API.
type ServerClient struct {
	BaseURL    string
	HTTPClient *http.Client
	APIToken   string
}

// NewServerClient creates a client that trusts the given CA cert (PEM).
// If caCert is nil, TLS verification is skipped (bootstrap only — the first
// call should be to fetch the CA cert, which is then used for all subsequent
// requests).
func NewServerClient(baseURL string, caCert []byte) *ServerClient {
	tlsCfg := &tls.Config{}
	if caCert != nil {
		pool := x509.NewCertPool()
		pool.AppendCertsFromPEM(caCert)
		tlsCfg.RootCAs = pool
	} else {
		log.Printf("[api] WARNING: TLS verification disabled (no CA cert) — only safe for initial bootstrap")
		tlsCfg.InsecureSkipVerify = true
	}

	return &ServerClient{
		BaseURL: baseURL,
		HTTPClient: &http.Client{
			Transport: &http.Transport{TLSClientConfig: tlsCfg},
		},
	}
}

func (c *ServerClient) doRequest(method, path string, body interface{}, auth string, result interface{}) error {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshal request: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.BaseURL+path, bodyReader)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	const maxResponseSize = 10 * 1024 * 1024 // 10 MB
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("API error %d: %s", resp.StatusCode, string(respBody))
	}

	if result != nil {
		if err := json.Unmarshal(respBody, result); err != nil {
			return fmt.Errorf("decode response: %w", err)
		}
	}
	return nil
}

// Register registers a new client with the server using a join token.
func (c *ServerClient) Register(joinToken string, req *RegisterRequest) (*RegisterResponse, error) {
	var resp RegisterResponse
	err := c.doRequest("POST", "/api/v1/clients/register", req, joinToken, &resp)
	if err != nil {
		return nil, err
	}
	return &resp, nil
}

// FetchNodeCerts downloads TLS certs for a node using the node's secret.
func (c *ServerClient) FetchNodeCerts(nodeName, nodeSecret string) (*CertResponse, error) {
	var resp CertResponse
	err := c.doRequest("GET", "/api/v1/nodes/"+nodeName+"/certs", nil, nodeSecret, &resp)
	if err != nil {
		return nil, err
	}
	return &resp, nil
}

// ListNodes returns all declared nodes with VIPs.
func (c *ServerClient) ListNodes() ([]NodeInfo, error) {
	var resp []NodeInfo
	err := c.doRequest("GET", "/api/v1/nodes", nil, c.APIToken, &resp)
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// ListDomains returns all domain/VIP mappings.
func (c *ServerClient) ListDomains() ([]DomainMapping, error) {
	var resp []DomainMapping
	err := c.doRequest("GET", "/api/v1/domains", nil, c.APIToken, &resp)
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// GetCACert downloads the root CA certificate (no auth required).
func (c *ServerClient) GetCACert() ([]byte, error) {
	req, err := http.NewRequest("GET", c.BaseURL+"/api/v1/ca/root", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("GET /api/v1/ca/root: %d: %s", resp.StatusCode, string(body))
	}
	const maxCertSize = 1024 * 1024 // 1 MB
	return io.ReadAll(io.LimitReader(resp.Body, maxCertSize))
}
