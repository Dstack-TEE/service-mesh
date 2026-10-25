package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeploymentDriverStagesAndChecksBrokers(t *testing.T) {
	for _, parallelism := range []string{"default", "1", "4", "10"} {
		for _, compatible := range []bool{true, false} {
			t.Run(parallelism+"/"+map[bool]string{true: "compatible", false: "old-image"}[compatible], func(t *testing.T) {
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
				write(filepath.Join(cluster, "signaling.auto.tfvars.json"), `{"signaling_urls":["https://old-7000.example.com"]}`, 0600)
				terraform := filepath.Join(dir, "terraform")
				write(terraform, `#!/bin/sh
printf '%s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *'output -raw coordinator_app_id'*) printf '%s\n' 'app_1111111111111111111111111111111111111111' ;;
  *'output -json coordinator_signaling_urls'*) printf '%s\n' '["https://123abc-7000.example.com"]' ;;
  *'-target=phala_app_instance.coordinator'*) jq -e '.coordinator_app_id == "app_1111111111111111111111111111111111111111" and .signaling_urls == ["https://old-7000.example.com"]' "${1#-chdir=}/signaling.auto.tfvars.json" >/dev/null || exit 32 ;;
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
				for _, item := range os.Environ() {
					if !strings.HasPrefix(item, "DEPLOY_PARALLELISM=") {
						cmd.Env = append(cmd.Env, item)
					}
				}
				cmd.Env = append(cmd.Env, "TERRAFORM_BIN="+terraform, "CALL_LOG="+logPath, "PATH="+dir+":"+os.Getenv("PATH"))
				wantParallelism := parallelism
				if parallelism == "default" {
					wantParallelism = "10"
				} else {
					cmd.Env = append(cmd.Env, "DEPLOY_PARALLELISM="+parallelism)
				}
				output, err := cmd.CombinedOutput()
				if (err == nil) != compatible {
					t.Fatalf("compatible=%v: %v\n%s", compatible, err, output)
				}
				calls, err := os.ReadFile(logPath)
				if err != nil {
					t.Fatal(err)
				}
				lines := strings.Split(strings.TrimSpace(string(calls)), "\n")
				want := 6
				if len(lines) != want || !strings.Contains(lines[1], "-target=phala_app.coordinator") || !strings.Contains(lines[3], "-target=phala_app_instance.coordinator") {
					t.Fatalf("unexpected stages: %s", calls)
				}
				if !strings.Contains(lines[1], "-parallelism="+wantParallelism) || !strings.Contains(lines[3], "-parallelism="+wantParallelism) || !strings.Contains(lines[5], "-parallelism="+wantParallelism) ||
					!strings.Contains(lines[1], "-var=coordinator_wait_for_ready=false") || !strings.Contains(lines[3], "-var=coordinator_wait_for_ready=false") || !strings.Contains(lines[5], "-var=coordinator_wait_for_ready=true") {
					t.Fatalf("parallelism/readiness not forwarded to all stages: %s", calls)
				}
				roster, rosterErr := os.ReadFile(filepath.Join(cluster, "signaling.auto.tfvars.json"))
				if rosterErr != nil || !strings.Contains(string(roster), "https://123abc-7000.example.com") || !strings.Contains(string(roster), "app_1111111111111111111111111111111111111111") || strings.Contains(lines[5], "-target") {
					t.Fatalf("invalid full stage: %s / %v / %s", roster, rosterErr, calls)
				}
			})
		}
	}
}

func TestDeploymentDriverRejectsInvalidParallelism(t *testing.T) {
	for _, value := range []string{"", "0", "-1", "two", "1.5", "4 -target=other"} {
		t.Run(value, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "cluster.tf"), []byte("# fixture\n"), 0600); err != nil {
				t.Fatal(err)
			}
			script, err := filepath.Abs("../../support/deploy-cluster.sh")
			if err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("bash", script, dir)
			cmd.Env = append(os.Environ(), "DEPLOY_PARALLELISM="+value, "TERRAFORM_BIN=/not-a-terraform")
			output, err := cmd.CombinedOutput()
			if err == nil || !strings.Contains(string(output), "DEPLOY_PARALLELISM must be a positive integer") {
				t.Fatalf("invalid parallelism accepted or reached Terraform: %v\n%s", err, output)
			}
		})
	}
}
