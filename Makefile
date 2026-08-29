# wgm — developer convenience targets.
#
# A thin front-end over scripts/ and the backpressure suite. Nothing here is required to USE wgm
# (it's a portable SKILL.md); these targets just make contributing and updating ergonomic.
#
#   make update     git pull --ff-only (when run in a checkout) then reinstall your copy
#   make validate   run the local backpressure suite (what CI runs, minus skills-ref/pwsh/actionlint)

.DEFAULT_GOAL := help
SHELL := bash
SCRIPTS := $(wildcard scripts/*.sh)

.PHONY: help update install install-project lint docs test validate check clean-worktrees

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

update: ## Pull latest from origin (when run in a git checkout), then reinstall the skill
	@if [ -d .git ]; then \
		echo "==> git pull --ff-only"; git pull --ff-only; \
	else \
		echo "==> no .git here — skipping pull; reinstalling from this tree"; \
	fi
	@$(MAKE) install

install: ## Install/refresh wgm into your agent client dirs (~/.copilot, ~/.agents, ~/.claude)
	bash scripts/install.sh --client all --force

install-project: ## Install wgm into the current project (./.agents, ./.claude)
	bash scripts/install.sh --project --force

lint: ## ShellCheck + bash syntax for every script
	shellcheck $(SCRIPTS)
	for s in $(SCRIPTS); do bash -n "$$s"; done

docs: ## Docs backpressure (structure, links, mermaid, placeholders, evals fixture schema, harness contract, role-adapter derivation)
	bash scripts/check-docs.sh
	bash scripts/check-evals.sh
	bash scripts/check-harnesses.sh
	bash scripts/sync-agent-adapters.sh --check

test: ## Run the bash harnesses (install, agent-adapters, plugin-registry, stage10-memory, runner, qualification, live qualification, router, experiments, policy, loop, swarm, audit, devcontainer, harvest-hive, grade-evals, check-evals, check-harnesses, check-docs, check-trailers, check-doc-sync, release-index, wsl-boundary)
	bash scripts/test-install.sh
	bash scripts/test-agent-adapters.sh
	bash scripts/test-plugin-registry.sh
	bash scripts/test-stage10-memory.sh
	bash scripts/test-stage10-runner.sh
	bash scripts/test-stage10-qualification.sh
	bash scripts/test-stage10-live-qualification.sh
	bash scripts/test-stage10-router.sh
	bash scripts/test-stage10-experiments.sh
	bash scripts/test-stage10-policy.sh
	bash scripts/test-stage10-e2e.sh
	bash scripts/test-loop.sh
	bash scripts/test-swarm.sh
	bash scripts/test-audit.sh
	bash scripts/test-devcontainer.sh
	bash scripts/test-harvest-hive.sh
	bash scripts/test-grade-evals.sh
	bash scripts/test-check-evals.sh
	bash scripts/test-check-harnesses.sh
	bash scripts/test-check-docs.sh
	bash scripts/test-check-trailers.sh
	bash scripts/test-check-doc-sync.sh
	bash scripts/test-release-index.sh
	bash scripts/test-wsl-boundary-harness.sh

validate: lint docs test ## The local backpressure suite (CI also runs skills-ref, actionlint, pwsh)
	@echo "validate: GREEN"

check: validate ## Alias for validate

clean-worktrees: ## Remove leftover swarm worktrees + branches (.wgm/worktrees, wgm/* branches)
	-git worktree list --porcelain | awk '/^worktree /{print $$2}' | grep '/\.wgm/worktrees/' \
		| xargs -r -I{} git worktree remove --force {}
	-git worktree prune
	-git for-each-ref --format='%(refname:short)' refs/heads/ | grep -E '^wgm/' \
		| xargs -r -n1 git branch -D
	-rm -rf .wgm/worktrees
