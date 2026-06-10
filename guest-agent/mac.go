// `mac` client (M14): run a command on the Mac from inside the guest.
// The engine listens on vsock port 2400 (host CID 2); we send one command
// line, stream the combined output, and recover the exit code from the
// trailer line "\x01OORT-EXIT <code>".
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const (
	macPort       = 2400
	macTrailer    = "\x01OORT-EXIT "
	vsockHostCID  = 2
)

func runMac(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: mac <command…>   (runs on the Mac, as your Mac user)")
		return 2
	}
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mac: vsock: %v\n", err)
		return 1
	}
	defer unix.Close(fd)
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: vsockHostCID, Port: macPort}); err != nil {
		fmt.Fprintf(os.Stderr, "mac: can't reach the host (mac-exec disabled, or not an oort guest?): %v\n", err)
		return 1
	}
	cmd := strings.Join(args, " ") + "\n"
	if _, err := unix.Write(fd, []byte(cmd)); err != nil {
		fmt.Fprintf(os.Stderr, "mac: send: %v\n", err)
		return 1
	}
	// Stream output; the last line is the exit trailer. Buffer only the tail
	// that could still turn out to be the trailer.
	var tail []byte
	buf := make([]byte, 32*1024)
	for {
		n, err := unix.Read(fd, buf)
		if n > 0 {
			tail = append(tail, buf[:n]...)
			// Flush everything up to the LAST newline except a possible trailer.
			if i := strings.LastIndexByte(string(tail), '\n'); i >= 0 {
				head := tail[:i+1]
				rest := tail[i+1:]
				if j := strings.LastIndex(string(head), macTrailer); j >= 0 {
					os.Stdout.Write(head[:j])
					code, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(string(head[j:]), macTrailer)))
					return code
				}
				os.Stdout.Write(head)
				tail = append([]byte{}, rest...)
			}
		}
		if err != nil || n == 0 {
			os.Stdout.Write(tail)
			return 1 // connection ended without a trailer
		}
	}
}
