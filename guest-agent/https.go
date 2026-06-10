// HTTPS for *.oort.local (M10) — OrbStack-style trusted https:// for any
// container, terminated INSIDE the guest so macOS never needs a privileged
// port or proxy daemon.
//
// How a request flows:
//
//	Mac browser → https://web.oort.local        (DNS → container IP, route → guest)
//	  → guest PREROUTING: dst 172.17/16:443 REDIRECTed to the agent's :8443
//	  → TLS terminated here with a per-SNI leaf minted from the oort local CA
//	    (generated on the Mac by `oort https enable`, trusted in the keychain)
//	  → plain HTTP to the ORIGINAL container IP:80 (SO_ORIGINAL_DST)
//
// Enabled when /etc/oort/https/{ca.pem,ca.key} exist (staged by the CLI);
// otherwise this is entirely inert.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	httpsDir      = "/etc/oort/https"
	httpsPort     = 8443
	soOriginalDst = 80 // netfilter SO_ORIGINAL_DST
)

type certMinter struct {
	caCert *x509.Certificate
	caKey  *ecdsa.PrivateKey
	mu     sync.Mutex
	cache  map[string]*tls.Certificate
}

// serveHTTPS starts the terminator if the CA material is staged; no-op otherwise.
func serveHTTPS() {
	caPEM, err1 := os.ReadFile(httpsDir + "/ca.pem")
	keyPEM, err2 := os.ReadFile(httpsDir + "/ca.key")
	if err1 != nil || err2 != nil {
		return
	}
	minter, err := newMinter(caPEM, keyPEM)
	if err != nil {
		fmt.Fprintf(os.Stderr, "https: bad CA material: %v\n", err)
		return
	}
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", httpsPort))
	if err != nil {
		fmt.Fprintf(os.Stderr, "https: listen :%d: %v\n", httpsPort, err)
		return
	}
	ensureRedirectRule()
	fmt.Printf("oort-guest: https terminator on :%d (*.oort.local)\n", httpsPort)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			go handleTLS(c, minter)
		}
	}()
}

// ensureRedirectRule sends Mac→container :443 traffic to the terminator.
// Idempotent (-C probe first); enp0s1 only, so guest/container-local traffic
// is never intercepted.
func ensureRedirectRule() {
	args := []string{"-t", "nat", "-C", "PREROUTING", "-i", "enp0s1",
		"-d", "172.17.0.0/16", "-p", "tcp", "--dport", "443",
		"-j", "REDIRECT", "--to-ports", fmt.Sprint(httpsPort)}
	if exec.Command("iptables", args...).Run() != nil {
		args[2] = "-A"
		if out, err := exec.Command("iptables", args...).CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "https: iptables: %v %s\n", err, out)
		}
	}
}

func handleTLS(c net.Conn, m *certMinter) {
	defer c.Close()
	backend := originalDst(c) // "172.17.0.2" or "" for direct :8443 connects
	var sni string
	tc := tls.Server(c, &tls.Config{
		GetCertificate: func(h *tls.ClientHelloInfo) (*tls.Certificate, error) {
			sni = h.ServerName
			return m.mint(sni)
		},
	})
	if err := tc.Handshake(); err != nil {
		return
	}
	if backend == "" {
		backend = resolveContainer(sni) // direct connects (tests, port-forward)
	}
	if backend == "" {
		return
	}
	dst, err := net.Dial("tcp", backend+":80")
	if err != nil {
		return
	}
	defer dst.Close()
	tdst := dst.(*net.TCPConn)
	done := make(chan struct{}, 2)
	go func() { io.Copy(dst, tc); tdst.CloseWrite(); done <- struct{}{} }()
	go func() { io.Copy(tc, dst); tc.CloseWrite(); done <- struct{}{} }()
	<-done
	<-done
}

// originalDst reads netfilter's SO_ORIGINAL_DST: the container IP the Mac
// actually dialed before the REDIRECT. Empty for direct connections.
func originalDst(c net.Conn) string {
	tcp, ok := c.(*net.TCPConn)
	if !ok {
		return ""
	}
	raw, err := tcp.SyscallConn()
	if err != nil {
		return ""
	}
	var addr unix.RawSockaddrInet4
	var got bool
	raw.Control(func(fd uintptr) {
		sz := uint32(unsafe.Sizeof(addr))
		_, _, errno := syscall.Syscall6(syscall.SYS_GETSOCKOPT, fd,
			unix.IPPROTO_IP, soOriginalDst,
			uintptr(unsafe.Pointer(&addr)), uintptr(unsafe.Pointer(&sz)), 0)
		got = errno == 0
	})
	if !got {
		return ""
	}
	ip := net.IPv4(addr.Addr[0], addr.Addr[1], addr.Addr[2], addr.Addr[3])
	port := binary.BigEndian.Uint16((*[2]byte)(unsafe.Pointer(&addr.Port))[:])
	// A direct connect to :8443 reports the listener itself — not a container.
	if port != 443 || !strings.HasPrefix(ip.String(), "172.") {
		return ""
	}
	return ip.String()
}

// resolveContainer maps an *.oort.local SNI to a container bridge IP using the
// local Docker API — same rules as the host's DNS responder (container name,
// machine name, compose service.project).
func resolveContainer(sni string) string {
	host := strings.TrimSuffix(strings.ToLower(sni), ".oort.local")
	if host == "" || host == sni {
		return ""
	}
	client := http.Client{Transport: &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) { return net.Dial("unix", dockerSock) },
	}}
	resp, err := client.Get("http://localhost/containers/json")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	var list []struct {
		Names           []string
		Labels          map[string]string
		NetworkSettings struct {
			Networks map[string]struct{ IPAddress string }
		}
	}
	if json.NewDecoder(resp.Body).Decode(&list) != nil {
		return ""
	}
	for _, c := range list {
		ip := ""
		for _, n := range c.NetworkSettings.Networks {
			if n.IPAddress != "" {
				ip = n.IPAddress
				break
			}
		}
		if ip == "" {
			continue
		}
		for _, raw := range c.Names {
			name := strings.ToLower(strings.TrimPrefix(raw, "/"))
			if name == host || strings.TrimPrefix(name, "ovm-") == host {
				return ip
			}
		}
		if svc, proj := c.Labels["com.docker.compose.service"], c.Labels["com.docker.compose.project"]; svc != "" && proj != "" {
			if strings.ToLower(svc+"."+proj) == host {
				return ip
			}
		}
	}
	return ""
}

func newMinter(caPEM, keyPEM []byte) (*certMinter, error) {
	cb, _ := pem.Decode(caPEM)
	if cb == nil {
		return nil, fmt.Errorf("no CA cert PEM")
	}
	caCert, err := x509.ParseCertificate(cb.Bytes)
	if err != nil {
		return nil, err
	}
	kb, _ := pem.Decode(keyPEM)
	if kb == nil {
		return nil, fmt.Errorf("no CA key PEM")
	}
	var key *ecdsa.PrivateKey
	if k, err := x509.ParseECPrivateKey(kb.Bytes); err == nil {
		key = k
	} else if k8, err := x509.ParsePKCS8PrivateKey(kb.Bytes); err == nil {
		ec, ok := k8.(*ecdsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("CA key is not ECDSA")
		}
		key = ec
	} else {
		return nil, fmt.Errorf("unparseable CA key")
	}
	return &certMinter{caCert: caCert, caKey: key, cache: map[string]*tls.Certificate{}}, nil
}

// mint returns a cached or freshly-signed leaf for the requested SNI — so every
// name level (web.oort.local, api.myproj.oort.local) gets a valid cert.
func (m *certMinter) mint(sni string) (*tls.Certificate, error) {
	name := strings.ToLower(sni)
	if name == "" || !strings.HasSuffix(name, ".oort.local") {
		name = "oort.local"
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if c, ok := m.cache[name]; ok {
		return c, nil
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 64))
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(825 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, m.caCert, &leafKey.PublicKey, m.caKey)
	if err != nil {
		return nil, err
	}
	cert := &tls.Certificate{Certificate: [][]byte{der, m.caCert.Raw}, PrivateKey: leafKey}
	m.cache[name] = cert
	return cert, nil
}
