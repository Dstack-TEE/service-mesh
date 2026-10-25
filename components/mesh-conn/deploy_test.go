package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeploymentDriverStagesAndChecksBrokers(t *testing.T) {
	for _, compatible := range []bool{true, false} {
		t.Run(map[bool]string{true: "compatible", false: "old-image"}[compatible], func(t *testing.T) {
			dir := t.TempDir()
			cluster := filepath.Join(dir, "cluster with spaces")
			if err := os.Mkdir(cluster, 0700); err != nil {
				t.Fatal(err)
			}
			write := func(path, body string, mode os.FileMode) {
				t.Helper()
				if err := os.WriteFile(path, []byte(body), mode); err != nil {
					t.Fatal(err)
				}
			}
			write(filepath.Join(cluster, "cluster.tf"), "# fixture\n", 0600)
			terraform := filepath.Join(dir, "terraform")
			write(terraform, `#!/bin/sh
printf '%s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *'output -json coordinator_signaling_urls'*) printf '%s\n' '["https://123abc-7000.example.com"]' ;;
esac
`, 0700)
			marker := "leaderless-signaling-v1"
			if !compatible {
				marker = "old-image"
			}
			write(filepath.Join(dir, "curl"), "#!/bin/sh\nprintf '%s\\n' '"+marker+"'\n", 0700)
			logPath := filepath.Join(dir, "calls")
			script, err := filepath.Abs("../../support/deploy-cluster.sh")
			if err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("bash", script, cluster, "-auto-approve")
			cmd.Env = append(os.Environ(), "TERRAFORM_BIN="+terraform, "CALL_LOG="+logPath, "PATH="+dir+":"+os.Getenv("PATH"))
			output, err := cmd.CombinedOutput()
			if (err == nil) != compatible {
				t.Fatalf("compatible=%v: %v\n%s", compatible, err, output)
			}
			calls, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(strings.TrimSpace(string(calls)), "\n")
			want := 3
			if compatible {
				want = 4
			}
			if len(lines) != want || !strings.Contains(lines[1], "-target=phala_app_instance.coordinator") {
				t.Fatalf("unexpected stages: %s", calls)
			}
			roster, rosterErr := os.ReadFile(filepath.Join(cluster, "signaling.auto.tfvars.json"))
			if compatible {
				if rosterErr != nil || !strings.Contains(string(roster), "https://123abc-7000.example.com") || strings.Contains(lines[3], "-target") {
					t.Fatalf("invalid full stage: %s / %v / %s", roster, rosterErr, calls)
				}
			} else if !os.IsNotExist(rosterErr) {
				t.Fatal("old image must not publish a roster or start stage two")
			}
		})
	}
}
