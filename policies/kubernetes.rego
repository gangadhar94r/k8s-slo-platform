# Guardrails for anything deployed into the platform.
#
# These are the rules that are tedious to enforce in review and trivial to
# enforce in CI. Each one exists because forgetting it has a specific
# consequence, noted above the rule.

package main

import rego.v1

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

is_workload if input.kind in workload_kinds

containers contains container if {
	is_workload
	some container in input.spec.template.spec.containers
}

pod_security_context := object.get(input, ["spec", "template", "spec", "securityContext"], {})

# A container with no memory limit can take the whole node down with it.
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

# Without a readiness probe, traffic is sent to a pod that is not ready yet,
# and every rolling update causes a burst of errors that eats the error budget.
deny contains msg if {
	some container in containers
	not container.readinessProbe
	msg := sprintf("%s/%s: container %q has no readiness probe", [input.kind, input.metadata.name, container.name])
}

# Without a liveness probe, a wedged process stays in the Service endpoints
# forever and nothing restarts it.
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

# A moving tag means the thing running in production is not the thing that was
# reviewed, and a rollback does not necessarily roll anything back.
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

# Not a hard failure: a read-only root filesystem is right for most workloads
# but genuinely awkward for some, so this is a nudge rather than a block.
warn contains msg if {
	some container in containers
	not container.securityContext.readOnlyRootFilesystem
	msg := sprintf("%s/%s: container %q has a writable root filesystem", [input.kind, input.metadata.name, container.name])
}

# A workload nobody scrapes cannot have an SLO, and a service with no SLO is one
# nobody will notice breaking.
warn contains msg if {
	input.kind == "Deployment"
	not input.spec.template.metadata.annotations["prometheus.io/scrape"]
	msg := sprintf("Deployment/%s: not annotated for scraping, so it can have no SLO", [input.metadata.name])
}
