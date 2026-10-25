package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestCoordinatorModulePreservesNativeDeploymentDependencies(t *testing.T) {
	read := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join("../..", path))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	block := func(config, kind, name string) string {
		t.Helper()
		pattern := "(?s)resource " + regexp.QuoteMeta("\""+kind+"\" \""+name+"\"") + " \\{.*?\n\\}"
		value := regexp.MustCompile(pattern).FindString(config)
		if value == "" {
			t.Fatalf("missing resource %s.%s", kind, name)
		}
		return value
	}
	module := read("modules/mesh-coordinators/main.tf")
	app := block(module, "phala_app", "this")
	slots := block(module, "phala_app_instance", "this")
	env := block(module, "phala_cvm_env", "this")
	for _, allocation := range []string{app, slots} {
		if regexp.MustCompile("(?m)^  env\\s*=").MatchString(allocation) ||
			!regexp.MustCompile("wait_for_ready\\s*= false").MatchString(allocation) {
			t.Fatal("allocation must not own runtime values or wait for boot")
		}
	}
	if !strings.Contains(app, "env_keys") ||
		!strings.Contains(slots, "phala_app.this.app_id") ||
		!regexp.MustCompile("wait_for_identity\\s*= true").MatchString(slots) ||
		!strings.Contains(env, "phala_app_instance.this[each.key].vm_uuid") ||
		!strings.Contains(env, "merge(var.env, var.instances[each.key].env") ||
		!regexp.MustCompile("wait_for_ready\\s*= true").MatchString(env) {
		t.Fatal("module lost identity allocation or per-slot value ownership")
	}
	outputs := read("modules/mesh-coordinators/outputs.tf")
	if strings.Contains(outputs, "phala_cvm_env") || strings.Contains(module, "depends_on") {
		t.Fatal("module outputs must not impose a full-configuration readiness barrier")
	}
	for _, cluster := range []string{"starter", "patroni-demo"} {
		t.Run(cluster, func(t *testing.T) {
			config := read("clusters/" + cluster + "/cluster.tf")
			for _, legacy := range []string{"var.signaling_urls", "var.coordinator_app_id", "var.coordinator_wait_for_ready", "deploy-cluster.sh"} {
				if strings.Contains(config, legacy) {
					t.Fatalf("deployment still needs external phase control: %s", legacy)
				}
			}
			if !strings.Contains(config, "source = \"../../modules/mesh-coordinators\"") ||
				!strings.Contains(config, "env = local.coordinator_env_by_slot[name]") ||
				!strings.Contains(config, "signaling_urls = module.coordinators.signaling_urls") {
				t.Fatal("example must colocate env with instances and consume the module roster")
			}
			for _, kind := range []string{"phala_app", "phala_app_instance", "phala_cvm_env"} {
				pattern := "from\\s*= " + regexp.QuoteMeta(kind+".coordinator") +
					"\\s+to\\s*= " + regexp.QuoteMeta("module.coordinators."+kind+".this")
				if !regexp.MustCompile(pattern).MatchString(config) {
					t.Fatalf("missing migration for %s.coordinator", kind)
				}
			}
			if strings.Contains(block(config, "phala_app", "workload"), "depends_on") {
				t.Fatal("workloads must not wait behind coordinator configuration")
			}
			preflight := block(config, "phala_app_preflight", "workload")
			if !strings.Contains(preflight, "!var.enable_attestation_admission || var.admission_expected_kms_public_key") ||
				!strings.Contains(preflight, "!var.production_profile || local.launch_os_image") {
				t.Fatal("module extraction removed admission or production policy checks")
			}
		})
	}
	if _, err := os.Stat("../../support/deploy-cluster.sh"); !os.IsNotExist(err) {
		t.Fatal("deployment must not require the old staged shell driver")
	}
}
