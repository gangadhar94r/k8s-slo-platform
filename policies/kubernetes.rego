# Guardrails for anything deployed into the platform. Tedious to catch in
# review, trivial to catch in CI.

package main

import rego.v1

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

is_workload if input.kind in workload_kinds

containers contains container if {
	is_workload
	some container in input.spec.template.spec.containers
}

pod_security_context := object.get(input, ["spec", "template", "spec", "securityContext"], {})

# No memory limit means one container can take the node down.
deny contains msg if {
	some container in containers
	not container.resources.limits.memory
	msg := sprintf("%s/%s: container %q has no memory limit", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
	some container in containers
	not container.resources.requests.memory
	msg := sprintf("%s/%s: container %q has no memory request, so the scheduler is guessing", [input.kind, input.metadata.name, container.name])
}

# No readiness probe means every rolling update sends traffic to pods that
# aren't ready, which shows up as errors against the SLO.
deny contains msg if {
	some container in containers
	not container.readinessProbe
	msg := sprintf("%s/%s: container %q has no readiness probe", [input.kind, input.metadata.name, container.name])
}

# No liveness probe means a wedged process stays in the endpoints forever.
deny contains msg if {
	some container in containers
	not container.livenessProbe
	msg := sprintf("%s/%s: container %q has no liveness probe", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
	is_workload
	not pod_security_context.runAsNonRoot
	msg := sprintf("%s/%s: pod does not set securityContext.runAsNonRoot", [input.kind, input.metadata.name])
}

deny contains msg if {
	some container in containers
	container.securityContext.allowPrivilegeEscalation != false
	msg := sprintf("%s/%s: container %q allows privilege escalation", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
	some container in containers
	not "ALL" in object.get(container, ["securityContext", "capabilities", "drop"], [])
	msg := sprintf("%s/%s: container %q does not drop ALL capabilities", [input.kind, input.metadata.name, container.name])
}

# A moving tag means what's running isn't what was reviewed.
deny contains msg if {
	some container in containers
	endswith(container.image, ":latest")
	msg := sprintf("%s/%s: container %q uses a :latest image tag", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
	some container in containers
	not contains(container.image, ":")
	msg := sprintf("%s/%s: container %q has an untagged image", [input.kind, input.metadata.name, container.name])
}

# Warn, not deny. Right for most workloads, awkward for some.
warn contains msg if {
	some container in containers
	not container.securityContext.readOnlyRootFilesystem
	msg := sprintf("%s/%s: container %q has a writable root filesystem", [input.kind, input.metadata.name, container.name])
}

# No scrape means no SLO, and no SLO means nobody notices it breaking.
warn contains msg if {
	input.kind == "Deployment"
	not input.spec.template.metadata.annotations["prometheus.io/scrape"]
	msg := sprintf("Deployment/%s: not annotated for scraping, so it can have no SLO", [input.metadata.name])
}
