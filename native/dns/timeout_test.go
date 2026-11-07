package main

import (
	"context"
	"flag"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLifecycleTimeoutKillsDescendants(t *testing.T) {
	if path := os.Getenv("PKC_TIMEOUT_TEST_CHILD"); path != "" {
		flag.CommandLine = flag.NewFlagSet("native-timeout", flag.ExitOnError)
		os.Args = []string{"native-timeout", "-run-timeout", "1", "--", "/bin/sh", "-c", "sleep 30 & echo $! > \"$1\"; wait", "probe", path}
		if run() == nil {
			os.Exit(2)
		}
		os.Exit(0)
	}
	path := t.TempDir() + "/child"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLifecycleTimeoutKillsDescendants$")
	cmd.Env = append(os.Environ(), "PKC_TIMEOUT_TEST_CHILD="+path)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("bounded CLI failed: %v %s", err, out)
	}
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(text)))
	if err != nil || pid < 2 {
		t.Fatal("invalid child PID")
	}
	defer syscall.Kill(pid, syscall.SIGKILL)
	for i := 0; i < 100; i++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return
		}
		if stat, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil && strings.Contains(string(stat), ") Z ") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timeout left its descendant running")
}
