// webdemo — tiny Connect-mesh sample sitting on the peer-VIP / service-VIP
// fabric.
//
// Binds 127.0.0.1:8080 for the local sidecar and non-loopback host
// addresses for the public gateway, then serves two endpoints:
//
//	GET /hello  → "hello from <peer-id>"
//	GET /all    → fan-out N times to http://webdemo:8080/hello and
//	              aggregate replies; demonstrates Envoy-LB across peers
//
// Platform plumbing — Consul registration, sidecar provisioning,
// service-VIP allocation, and mesh name setup via /run/mesh/exec.sh —
// happens outside this binary. The app has zero awareness of any of it;
// it just binds and serves.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const webdemoPort = 8080

func main() {
	name := envOr("PEER_ID", "webdemo")
	fanoutN := envOr("FANOUT_N", "8")

	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from %s\n", name)
	})
	http.HandleFunc("/all", func(w http.ResponseWriter, r *http.Request) {
		// Hit `webdemo:8080/hello` (resolved via /etc/hosts → service
		// VIP → local Envoy upstream). Envoy's load-balancer rotates
		// across all registered webdemo instances; with enough samples
		// we should reach each peer at least once.
		var n int
		fmt.Sscanf(fanoutN, "%d", &n)
		results := fanOut(n)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"from":    name,
			"samples": n,
			"results": results,
		})
	})

	addrs, err := listenAddrs(webdemoPort)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("webdemo: peer=%s listening on %s", name, strings.Join(addrs, ", "))
	log.Fatal(serveAll(addrs))
}

func fanOut(n int) map[string]int {
	results := make(map[string]int)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 3 * time.Second}
			resp, err := client.Get(fmt.Sprintf("http://webdemo:%d/hello", webdemoPort))
			body := ""
			if err != nil {
				body = "error: " + err.Error()
			} else {
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				body = strings.TrimSpace(string(b))
			}
			mu.Lock()
			results[body]++
			mu.Unlock()
		}()
	}
	wg.Wait()
	return results
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func listenAddrs(port int) ([]string, error) {
	seen := map[string]bool{}
	addrs := []string{fmt.Sprintf("127.0.0.1:%d", port)}
	seen[addrs[0]] = true

	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("list interfaces: %w", err)
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		ifaceAddrs, err := iface.Addrs()
		if err != nil {
			return nil, fmt.Errorf("list addresses for %s: %w", iface.Name, err)
		}
		for _, addr := range ifaceAddrs {
			ip, _, err := net.ParseCIDR(addr.String())
			if err != nil || ip == nil || ip.To4() == nil {
				continue
			}
			listen := fmt.Sprintf("%s:%d", ip.String(), port)
			if !seen[listen] {
				addrs = append(addrs, listen)
				seen[listen] = true
			}
		}
	}
	return addrs, nil
}

func serveAll(addrs []string) error {
	errCh := make(chan error, len(addrs))
	for _, addr := range addrs {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return fmt.Errorf("listen on %s: %w", addr, err)
		}
		go func(addr string, ln net.Listener) {
			errCh <- fmt.Errorf("%s: %w", addr, http.Serve(ln, nil))
		}(addr, ln)
	}
	return <-errCh
}
