.PHONY: help install dev-backend dev-frontend lint format check build bootstrap tf-plan tf-apply dbt-install dbt-build dbt-test dbt-clean test

# ── Colours ──────────────────────────────────────────────────────────────────
CYAN  := \033[36m
RESET := \033[0m

help: ## Show available targets
	@echo ""
	@echo "  Meteorite Explorer — available make targets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────

install: ## Install all dependencies (Python + Node)
	pip install -r backend/requirements.txt
	cd frontend && npm install

# ── Local dev ─────────────────────────────────────────────────────────────────

dev-backend: ## Run FastAPI with hot reload on :8000
	cd backend && uvicorn main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on :5173 (proxies /api → :8000)
	cd frontend && npm run dev

# ── Lint & format ─────────────────────────────────────────────────────────────

lint: ## Lint Python (ruff) and TypeScript (tsc --noEmit)
	ruff check backend/
	cd frontend && npx tsc --noEmit

format: ## Auto-format Python (ruff) and TypeScript (prettier), then type-check
	ruff format backend/
	ruff check --fix backend/
	cd frontend && npx prettier --write "src/**/*.{ts,tsx}"
	cd frontend && npx tsc --noEmit

check: ## Lint + format-check without modifying files (used in CI)
	ruff check backend/
	ruff format --check backend/
	cd frontend && npx tsc --noEmit

test: ## Run backend pytest suite (requires data/meteorites.duckdb — run dbt-build first)
	pytest -v

# ── dbt warehouse ─────────────────────────────────────────────────────────────

dbt-install: ## Install dbt-duckdb + h3 into the current venv
	pip install -r dbt/requirements.txt

dbt-build: ## Run dbt build — produces data/meteorites.duckdb and runs tests
	cd dbt && dbt deps && dbt build

dbt-test: ## Run dbt tests only (assumes warehouse already built)
	cd dbt && dbt test

dbt-clean: ## Delete the built warehouse and dbt artifacts
	rm -f data/meteorites.duckdb data/meteorites.duckdb.wal
	rm -rf dbt/target dbt/dbt_packages dbt/logs

# ── Build ─────────────────────────────────────────────────────────────────────

build: ## Build the Docker image locally (multi-stage: dbt build → runtime)
	docker build -t meteorite-explorer:local .

# ── Infrastructure ────────────────────────────────────────────────────────────

bootstrap: ## One-time setup: ECR, IAM user, initial image push, terraform apply
	./scripts/bootstrap.sh

tf-plan: ## Preview infrastructure changes (terraform plan)
	cd terraform && terraform init -input=false && terraform plan

tf-apply: ## Apply infrastructure changes (terraform apply)
	cd terraform && terraform init -input=false && terraform apply
