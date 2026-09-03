package main

import rego.v1

good_container := {
	"name": "app",
	"image": "example/app:1.4.2",
	"resources": {
		"requests": {"cpu": "50m", "memory": "64Mi"},
		"limits": {"cpu": "200m", "memory": "128Mi"},
	},
	"livenessProbe": {"httpGet": {"path": "/healthz", "port": 8080}},
	"readinessProbe": {"httpGet": {"path": "/ready", "port": 8080}},
	"securityContext": {
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["ALL"]},
	},
}

deployment(container) := {
	"kind": "Deployment",
	"metadata": {"name": "example"},
	"spec": {"template": {
		"metadata": {"annotations": {"prometheus.io/scrape": "true"}},
		"spec": {
			"securityContext": {"runAsNonRoot": true},
			"containers": [container],
		},
	}},
}

test_a_well_formed_deployment_passes if {
	count(deny) == 0 with input as deployment(good_container)
	count(warn) == 0 with input as deployment(good_container)
}

test_missing_memory_limit_is_denied if {
	container := json.remove(good_container, ["resources/limits/memory"])
	count(deny) == 1 with input as deployment(container)
}

test_missing_memory_request_is_denied if {
	container := json.remove(good_container, ["resources/requests/memory"])
	count(deny) == 1 with input as deployment(container)
}

test_missing_readiness_probe_is_denied if {
	container := json.remove(good_container, ["readinessProbe"])
	count(deny) == 1 with input as deployment(container)
}

test_missing_liveness_probe_is_denied if {
	container := json.remove(good_container, ["livenessProbe"])
	count(deny) == 1 with input as deployment(container)
}

test_running_as_root_is_denied if {
	manifest := json.remove(deployment(good_container), ["spec/template/spec/securityContext/runAsNonRoot"])
	count(deny) == 1 with input as manifest
}

test_privilege_escalation_is_denied if {
	container := json.patch(good_container, [{
		"op": "replace",
		"path": "/securityContext/allowPrivilegeEscalation",
		"value": true,
	}])
	count(deny) == 1 with input as deployment(container)
}

test_not_dropping_all_capabilities_is_denied if {
	container := json.patch(good_container, [{
		"op": "replace",
		"path": "/securityContext/capabilities/drop",
		"value": ["NET_RAW"],
	}])
	count(deny) == 1 with input as deployment(container)
}

test_latest_tag_is_denied if {
	container := json.patch(good_container, [{
		"op": "replace",
		"path": "/image",
		"value": "example/app:latest",
	}])
	count(deny) == 1 with input as deployment(container)
}

test_untagged_image_is_denied if {
	container := json.patch(good_container, [{
		"op": "replace",
		"path": "/image",
		"value": "example/app",
	}])
	count(deny) == 1 with input as deployment(container)
}

test_writable_root_filesystem_warns_but_does_not_deny if {
	container := json.remove(good_container, ["securityContext/readOnlyRootFilesystem"])
	count(deny) == 0 with input as deployment(container)
	count(warn) == 1 with input as deployment(container)
}

test_unscraped_deployment_warns if {
	manifest := json.remove(deployment(good_container), ["spec/template/metadata/annotations"])
	count(warn) == 1 with input as manifest
}

# A ConfigMap has no containers, so none of the workload rules should fire.
test_non_workload_kinds_are_ignored if {
	manifest := {"kind": "ConfigMap", "metadata": {"name": "example"}}
	count(deny) == 0 with input as manifest
	count(warn) == 0 with input as manifest
}
