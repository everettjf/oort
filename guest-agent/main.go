// openorb-guest: a small, robust guest-side agent compiled to a static
// linux/arm64 binary (no Python runtime fragility).
//
// It serves two virtio-vsock ports:
//
//	2375  Docker bridge — splice each connection to /run/docker.sock, so the
//	      macOS host's `openorb` proxy projects the Docker API onto a Unix
//	      socket. (Replaces the socat/Python forwarder.)
//	2376  Exec agent    — read an HTTP request whose body is a shell command,
//	      run it, return combined stdout+stderr. Powers `orb exec` and
//	      headless diagnostics.
//
// Why Go: the earlier Python services were getting killed/wedged under memory
// pressure and sustained load. A compiled binary with goroutines and io.Copy
// is far steadier, and closing one side of a tunnel reliably unblocks the other.
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

const (
	dockerPort  = 2375
	agentPort   = 2376
	forwardPort = 2377
	dockerSock  = "/run/docker.sock"
)

func main() {
	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); serve(dockerPort, handleDocker) }()
	go func() { defer wg.Done(); serve(agentPort, handleExec) }()
	go func() { defer wg.Done(); serve(forwardPort, handleTCPForward) }()
	wg.Wait()
}

// serve listens on a vsock port and hands each accepted fd to handler.
func serve(port uint32, handler func(*os.File)) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vsock socket(%d): %v\n", port, err)
		return
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		fmt.Fprintf(os.Stderr, "vsock bind(%d): %v\n", port, err)
		unix.Close(fd)
		return
	}
	if err := unix.Listen(fd, 128); err != nil {
		fmt.Fprintf(os.Stderr, "vsock listen(%d): %v\n", port, err)
		unix.Close(fd)
		return
	}
	fmt.Printf("openorb-guest: listening on vsock:%d\n", port)
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			continue
		}
		conn := os.NewFile(uintptr(nfd), "vsock")
		go handler(conn)
	}
}

// handleDocker splices a vsock connection to the Docker Unix socket.
func handleDocker(vconn *os.File) {
	defer vconn.Close()
	dconn, err := net.Dial("unix", dockerSock)
	if err != nil {
		return
	}
	defer dconn.Close()
	// Copy both ways; when either direction ends, closing both fds unblocks
	// the other copy — no half-open leaks on keep-alive connections.
	done := make(chan struct{}, 2)
	go func() { io.Copy(dconn, vconn); done <- struct{}{} }()
	go func() { io.Copy(vconn, dconn); done <- struct{}{} }()
	<-done
	vconn.Close()
	dconn.Close()
	<-done
}

// handleTCPForward implements Stage 3 port forwarding. The host sends a single
// line with the target ("8080" or "127.0.0.1:8080"); we dial it inside the guest
// and splice. This is how a container's published port becomes reachable on the
// macOS localhost: openorb listens on 127.0.0.1:P and tunnels here over vsock.
func handleTCPForward(conn *os.File) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		return
	}
	target := strings.TrimSpace(line)
	if !strings.Contains(target, ":") {
		target = "127.0.0.1:" + target
	}
	dst, err := net.Dial("tcp", target)
	if err != nil {
		return
	}
	defer dst.Close()
	done := make(chan struct{}, 2)
	// r may hold bytes already read past the line; draining r (not conn) preserves them.
	go func() { io.Copy(dst, r); done <- struct{}{} }()
	go func() { io.Copy(conn, dst); done <- struct{}{} }()
	<-done
	conn.Close()
	dst.Close()
	<-done
}

// handleExec reads one HTTP request whose body is a shell command, runs it,
// and writes the combined output back as the response body.
func handleExec(conn *os.File) {
	defer conn.Close()
	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		return
	}
	body, _ := io.ReadAll(req.Body)
	cmd := string(body)
	if cmd == "" {
		cmd = "echo openorb-guest ok"
	}
	out, _ := exec.Command("/bin/sh", "-c", cmd).CombinedOutput()
	fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n",
		strconv.Itoa(len(out)))
	conn.Write(out)
}
