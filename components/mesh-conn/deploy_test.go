package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestNativeDeploymentHasSeparateAllocationAndEnvironmentOwnership(t *testing.T) {
	for _, cluster := range []string{"starter", "patroni-demo"} {
		t.Run(cluster, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join("../../clusters", cluster, "cluster.tf"))
			if err != nil {
				t.Fatal(err)
			}
			config := string(data)
			for _, legacy := range []string{"var.signaling_urls", "var.coordinator_app_id", "var.coordinator_wait_for_ready", "deploy-cluster.sh"} {
				if strings.Contains(config, legacy) {
					t.Fatalf("deployment still needs external phase control: %s", legacy)
				}
			}
			block := func(kind, name string) string {
				t.Helper()
				pattern := "(?s)resource " + regexp.QuoteMeta("\""+kind+"\" \""+name+"\"") + " \\{.*?\n\\}"
				value := regexp.MustCompile(pattern).FindString(config)
				if value == "" {
					t.Fatalf("missing resource %s.%s", kind, name)
				}
				return value
			}
			coordinator := block("phala_app", "coordinator")
			if !strings.Contains(coordinator, "env_keys =") || regexp.MustCompile("(?m)^  env\\s*=").MatchString(coordinator) ||
				!regexp.MustCompile("wait_for_ready\\s*= false").MatchString(coordinator) {
				t.Fatal("coordinator allocation must declare keys, not own runtime values or wait for boot")
			}
			instance := block("phala_app_instance", "coordinator")
			if !strings.Contains(instance, "app_id = phala_app.coordinator.app_id") ||
				!regexp.MustCompile("wait_for_identity\\s*= true").MatchString(instance) ||
				!regexp.MustCompile("wait_for_ready\\s*= false").MatchString(instance) ||
				regexp.MustCompile("(?m)^  env\\s*=").MatchString(instance) {
				t.Fatal("coordinator slots must allocate real identities without runtime values or boot waits")
			}
			env := block("phala_cvm_env", "coordinator")
			if !strings.Contains(env, "phala_app_instance.coordinator[each.key].vm_uuid") ||
				!strings.Contains(env, "local.coordinator_env_by_slot[each.key]") ||
				!regexp.MustCompile("wait_for_ready\\s*= true").MatchString(env) {
				t.Fatal("separate env resources must configure and await every coordinator")
			}
			if strings.Contains(block("phala_app", "workload"), "depends_on") {
				t.Fatal("workload allocation must not wait behind coordinator environment updates")
			}
		})
	}
	if _, err := os.Stat("../../support/deploy-cluster.sh"); !os.IsNotExist(err) {
		t.Fatal("deployment must not require the old staged shell driver")
	}
}
