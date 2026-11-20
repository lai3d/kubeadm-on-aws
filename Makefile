SHELL := /bin/bash
.DEFAULT_GOAL := help

# AWS profile/region come from your environment (AWS_PROFILE) - nothing is stored here.
# Use the project-local Ansible if `uv venv` / `python -m venv .venv` was used.
export PATH := $(CURDIR)/.venv/bin:$(PATH)

TF        := terraform -chdir=terraform
KEY       := .ssh/lab_ed25519
ANSIBLE   ?= ansible-playbook
PLAY      := cd ansible && $(ANSIBLE)

# Your current public IP, used to fence SSH / API / NodePort access.
ADMIN_CIDR ?= $(shell curl -fsS https://checkip.amazonaws.com)/32
export TF_VAR_admin_cidr := $(ADMIN_CIDR)

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

$(KEY):
	@mkdir -p .ssh && chmod 700 .ssh
	ssh-keygen -t ed25519 -N '' -C kubeadm-lab -f $(KEY)

init: $(KEY) ## Generate the lab SSH key and initialise Terraform
	$(TF) init

plan: $(KEY) ## Show what Terraform would create
	$(TF) plan

apply: $(KEY) ## Create the AWS infrastructure (costs money until `make destroy`)
	$(TF) apply
	@$(MAKE) --no-print-directory wait

wait: ## Wait for SSH on all nodes
	cd ansible && ansible all -m ansible.builtin.wait_for_connection -a 'timeout=300'

cluster: ## MVP: containerd, kubeadm init/join, Cilium, cloud controller, sample app
	$(PLAY) site.yml

extras: ## EBS CSI driver, NLB-backed Gateway, kube-prometheus-stack
	$(PLAY) extras.yml

upgrade: ## kubeadm minor version upgrade (control plane, then workers one by one)
	$(PLAY) upgrade.yml

verify: ## End-to-end checks from this machine
	./scripts/verify.sh

kubeconfig: ## Fetch an admin kubeconfig pointing at the public API endpoint (git-ignored)
	@ip=$$(awk -F= '$$1=="control_plane_public_ip"{print $$2}' ansible/inventory.ini); \
	priv=$$(awk -F= '$$1=="control_plane_private_ip"{print $$2}' ansible/inventory.ini); \
	ssh -i $(KEY) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	  ubuntu@$$ip cat .kube/config | sed "s#https://$$priv:6443#https://$$ip:6443#" > kubeconfig; \
	chmod 600 kubeconfig; echo "export KUBECONFIG=$$PWD/kubeconfig"

teardown: ## Delete NLBs and EBS volumes created from inside the cluster
	$(PLAY) teardown.yml

destroy: teardown ## Tear everything down (teardown first, then terraform destroy)
	$(TF) destroy

.PHONY: help init plan apply wait cluster extras upgrade verify kubeconfig teardown destroy
