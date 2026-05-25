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
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const (
	dockerPort  = 2375
	agentPort   = 2376
	forwardPort = 2377
	dockerSock  = "/run/docker.sock"

	// Bound every exec so a single hung command (a wedged `docker` call, a
	// process that never exits) can't leak its goroutine + fds + child process
	// forever. Left unbounded, these accumulate until the process hits its fd
	// limit, at which point accept() spins and the whole agent goes dark.
	execTimeout = 110 * time.Second
	// Cap concurrent execs so a burst can't exhaust fds/PIDs either.
	maxConcurrentExec = 64
)

var execSem = make(chan struct{}, maxConcurrentExec)

func main() {
	// Give plenty of fd headroom: the host opens many short-lived docker/exec
	// connections, and a transient pile-up must not exhaust the table.
	var lim unix.Rlimit
	if unix.Getrlimit(unix.RLIMIT_NOFILE, &lim) == nil {
		lim.Cur = lim.Max
		_ = unix.Setrlimit(unix.RLIMIT_NOFILE, &lim)
	}
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
			// Back off on real errors (notably EMFILE/ENFILE under fd
			// pressure) instead of busy-looping at 100% CPU — a spin here
			// starves every handler and makes the agent appear dead.
			time.Sleep(20 * time.Millisecond)
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

	// Limit concurrency so a burst of execs can't exhaust fds/PIDs.
	execSem <- struct{}{}
	defer func() { <-execSem }()

	// Run in its own process group and bound it with a timeout, so a hung
	// command is killed (whole group, including grandchildren) rather than
	// leaking forever.
	ctx, cancel := context.WithTimeout(context.Background(), execTimeout)
	defer cancel()
	c := exec.CommandContext(ctx, "/bin/sh", "-c", cmd)
	c.SysProcAttr = &unix.SysProcAttr{Setpgid: true}
	c.Cancel = func() error {
		if c.Process != nil {
			// Negative pid → signal the whole process group.
			_ = unix.Kill(-c.Process.Pid, unix.SIGKILL)
		}
		return nil
	}
	out, _ := c.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		out = append(out, []byte(fmt.Sprintf("\nopenorb-guest: command timed out after %s\n", execTimeout))...)
	}
	fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n",
		strconv.Itoa(len(out)))
	conn.Write(out)
}
