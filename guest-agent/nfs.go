// Finder integration (M13) — the guest's and every machine's filesystem,
// browsable from macOS, OrbStack's ~/OrbStack for oort.
//
// A pure-Go NFSv3 server (no guest packages needed) exports a tree the agent
// assembles under /run/oort-fs:
//
//	guest/            → /            (the whole guest, via a bind mount)
//	machines/<name>/  → that machine container's live merged rootfs
//
// macOS mounts it with no sudo through Finder's automount:
//
//	oort fs open     →  open "nfs://<guest-ip>/"
//
// Machine binds are reconciled against `docker ps` every few seconds, so
// machines appear/disappear in Finder as they start and stop.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-git/go-billy/v5/osfs"
	nfs "github.com/willscott/go-nfs"
	nfshelper "github.com/willscott/go-nfs/helpers"
)

const (
	nfsRoot = "/run/oort-fs"
	nfsPort = 2049
)

func serveNFS() {
	if err := os.MkdirAll(nfsRoot+"/machines", 0755); err != nil {
		fmt.Fprintf(os.Stderr, "nfs: mkdir: %v\n", err)
		return
	}
	// The whole guest at guest/ (bind, so it tracks live state).
	_ = os.MkdirAll(nfsRoot+"/guest", 0755)
	if !isMountpoint(nfsRoot + "/guest") {
		_ = exec.Command("mount", "--bind", "/", nfsRoot+"/guest").Run()
	}

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", nfsPort))
	if err != nil {
		fmt.Fprintf(os.Stderr, "nfs: listen :%d: %v\n", nfsPort, err)
		return
	}
	fmt.Printf("oort-guest: nfs export of %s on :%d\n", nfsRoot, nfsPort)

	go reconcileMachineBinds()
	go func() {
		handler := nfshelper.NewNullAuthHandler(osfs.New(nfsRoot))
		_ = nfs.Serve(ln, nfshelper.NewCachingHandler(handler, 1024))
	}()
}

// reconcileMachineBinds keeps /run/oort-fs/machines/<name> bind-mounted to
// each RUNNING machine container's merged rootfs.
func reconcileMachineBinds() {
	for {
		time.Sleep(5 * time.Second)
		want := machineRoots() // name -> merged dir
		entries, _ := os.ReadDir(nfsRoot + "/machines")
		for _, e := range entries {
			name := e.Name()
			if _, ok := want[name]; !ok {
				p := filepath.Join(nfsRoot, "machines", name)
				_ = exec.Command("umount", p).Run()
				_ = os.Remove(p)
			}
		}
		for name, merged := range want {
			p := filepath.Join(nfsRoot, "machines", name)
			if isMountpoint(p) {
				continue
			}
			_ = os.MkdirAll(p, 0755)
			_ = exec.Command("mount", "--bind", merged, p).Run()
		}
	}
}

// machineRoots returns running machine containers' merged overlay dirs.
func machineRoots() map[string]string {
	client := http.Client{Transport: &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) { return net.Dial("unix", dockerSock) },
	}}
	resp, err := client.Get("http://localhost/containers/json")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var list []struct{ Names []string }
	if json.NewDecoder(resp.Body).Decode(&list) != nil {
		return nil
	}
	out := map[string]string{}
	for _, c := range list {
		for _, raw := range c.Names {
			name := strings.TrimPrefix(raw, "/")
			if !strings.HasPrefix(name, "ovm-") {
				continue
			}
			short := strings.TrimPrefix(name, "ovm-")
			r2, err := client.Get("http://localhost/containers/" + name + "/json")
			if err != nil {
				continue
			}
			var detail struct {
				GraphDriver struct{ Data map[string]string }
			}
			if json.NewDecoder(r2.Body).Decode(&detail) == nil {
				if merged := detail.GraphDriver.Data["MergedDir"]; merged != "" {
					out[short] = merged
				}
			}
			r2.Body.Close()
		}
	}
	return out
}

func isMountpoint(p string) bool {
	return exec.Command("mountpoint", "-q", p).Run() == nil
}
