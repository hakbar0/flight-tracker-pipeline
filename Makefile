SHELL := /bin/bash
BUILD_DIR := build
REGION := eu-west-2
ROLE_ARN := arn:aws:iam::000000000000:role/service-role

# List of all lambda functions
LAMBDAS := fetch_flight_list process-single-flight

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Main targets:"
	@echo "  start-services    - Start all services (LocalStack, Elasticsearch, Kibana)"
	@echo "  deploy-all        - Deploy all Lambda functions to LocalStack"
	@echo "  full-setup        - Start services and deploy all lambdas"
	@echo ""
	@echo "Lambda commands (use lambda=<name>):"
	@echo "  package           - Package a lambda"
	@echo "  deploy            - Deploy a lambda"
	@echo "  invoke            - Invoke a lambda"
	@echo "  delete            - Delete a lambda"
	@echo ""
	@echo "Utility commands:"
	@echo "  list/ls           - List all deployed lambdas"
	@echo "  logs              - Show LocalStack logs"
	@echo "  check-elastic     - Check Elasticsearch health"
	@echo "  clean             - Clean build artifacts"
	@echo "  down              - Stop all services"

.PHONY: venv install install-dev
venv:
	python3 -m venv .venv
install:
	pip install -e .
install-dev:
	pip install -e ".[dev,aws]"

.PHONY: test test-verbose test-coverage lint format
test:
	PYTHONPATH=$(pwd)/src pytest src/lambdas/
test-verbose:
	pytest -v -s src/lambdas/
test-coverage:
	pytest --cov=src/lambdas --cov-report=html src/lambdas/
lint:
	ruff check src/lambdas/
format:
	black src/lambdas/

.PHONY: package deploy invoke delete
package: check-lambda-var
	@echo "Packaging $(lambda)..."
	@mkdir -p $(BUILD_DIR)/$(lambda)_pkg
	@cp src/lambdas/$(lambda)/lambda_function.py $(BUILD_DIR)/$(lambda)_pkg/
	@if [ -f src/lambdas/$(lambda)/requirements.txt ]; then \
		pip install -r src/lambdas/$(lambda)/requirements.txt -t $(BUILD_DIR)/$(lambda)_pkg/ > /dev/null; \
	fi
	@cd $(BUILD_DIR)/$(lambda)_pkg && zip -r ../$(lambda).zip . > /dev/null
	@echo "Lambda packaged: $(lambda)"

deploy: package
	@echo "Deploying $(lambda)..."
	@awslocal --region $(REGION) lambda create-function \
		--function-name $(lambda) \
		--runtime python3.12 \
		--handler lambda_function.handler \
		--role $(ROLE_ARN) \
		--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
		--environment Variables="{ELASTICSEARCH_HOST=http://elasticsearch:9200,ELASTICSEARCH_USER=elastic,ELASTICSEARCH_PASSWORD=changeme}" \
		> /dev/null 2>&1 || \
	( \
		echo "Function exists, updating code..." && \
		awslocal --region $(REGION) lambda update-function-code \
			--function-name $(lambda) \
			--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
			> /dev/null && \
		awslocal --region $(REGION) lambda update-function-configuration \
			--function-name $(lambda) \
			--environment Variables="{ELASTICSEARCH_HOST=http://elasticsearch:9200,ELASTICSEARCH_USER=elastic,ELASTICSEARCH_PASSWORD=changeme}" \
			> /dev/null \
	)
	@echo "Lambda deployed: $(lambda)"

invoke: check-lambda-var
	@echo "Invoking $(lambda)..."
	@awslocal --region $(REGION) lambda invoke \
		--function-name $(lambda) \
		--payload file://src/lambdas/$(lambda)/payload.json \
		output.json >/dev/null 2>&1
	@if [ -f output.json ]; then cat output.json | jq; else echo "Invoke failed"; fi
	@rm -f output.json

delete: check-lambda-var
	@echo "Deleting $(lambda)..."
	@awslocal --region $(REGION) lambda delete-function --function-name $(lambda) > /dev/null 2>&1 || true
	@echo "Lambda deleted: $(lambda)"

.PHONY: deploy-all delete-all
deploy-all:
	@echo "=========================================="
	@echo "Deploying all Lambda functions..."
	@echo "=========================================="
	@for lambda in $(LAMBDAS); do \
		echo ""; \
		$(MAKE) deploy lambda=$$lambda || echo "Failed to deploy $$lambda"; \
	done
	@echo ""
	@echo "=========================================="
	@echo "All Lambda functions deployed"
	@echo "=========================================="
	@$(MAKE) list

delete-all:
	@echo "Deleting all Lambda functions..."
	@for lambda in $(LAMBDAS); do \
		$(MAKE) delete lambda=$$lambda; \
	done
	@echo "All Lambda functions deleted"

.PHONY: list logs clean-pyc clean full-clean ls
list:
	@echo "Deployed Lambda functions:"
	@awslocal --region $(REGION) lambda list-functions --query 'Functions[*].[FunctionName,Runtime,LastModified]' --output table

ls: list

logs:
	@docker logs localstack-main --tail 100

logs-elastic:
	@docker logs elasticsearch --tail 50

logs-kibana:
	@docker logs kibana --tail 50

clean-pyc:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	find . -type f -name "*.pyo" -delete

clean: clean-pyc
	rm -rf $(BUILD_DIR)/
	rm -rf .pytest_cache
	rm -rf htmlcov
	rm -rf .coverage
	rm -rf .ruff_cache
	rm -rf .venv
	@echo "Cleaned"

full-clean: clean
	@echo "Full clean complete"

check-lambda-var:
	@[ -z "$(lambda)" ] && echo "Error: 'lambda' variable is not set." && exit 1 || exit 0

.PHONY: up down setup-elastic start-services check-elastic full-setup
up:
	@echo "Spinning up LocalStack, Elasticsearch and Kibana..."
	@docker-compose up -d

down:
	@echo "Stopping all services..."
	@docker-compose down

setup-elastic:
	@echo "Waiting 30s for Elasticsearch to be ready..."
	@sleep 30
	@echo "Setting up Elasticsearch users and trial licence..."
	@curl -s -u elastic:changeme -X POST "http://localhost:9200/_security/user/kibana_system/_password" \
		-H "Content-Type: application/json" \
		-d '{"password": "changeme"}' > /dev/null 2>&1 || echo "User may already exist"
	@echo ""
	@echo "Starting trial licence..."
	@curl -s -u elastic:changeme -X POST "http://localhost:9200/_license/start_trial?acknowledge=true" > /dev/null 2>&1
	@echo ""
	@echo "Creating kibana_user for login..."
	@curl -s -u elastic:changeme -X POST "http://localhost:9200/_security/user/kibana_user_test" \
		-H "Content-Type: application/json" \
		-d '{"password": "newpassword", "roles": ["kibana_admin"]}' > /dev/null 2>&1 || echo "User may already exist"
	@echo ""
	@echo "Restarting Kibana..."
	@docker-compose restart kibana > /dev/null 2>&1
	@sleep 15

start-services: up setup-elastic
	@echo ""
	@echo "=========================================="
	@echo "All services are ready"
	@echo ""
	@echo "Elasticsearch: http://localhost:9200"
	@echo "  Username: elastic"
	@echo "  Password: changeme"
	@echo ""
	@echo "Kibana: http://localhost:5601"
	@echo "  Username: kibana_user_test"
	@echo "  Password: newpassword"
	@echo ""
	@echo "LocalStack: http://localhost:4566"
	@echo "=========================================="
	@echo ""

full-setup: start-services
	@echo "Waiting 10s for LocalStack to be fully ready..."
	@sleep 10
	@$(MAKE) deploy-all
	@echo ""
	@echo "=========================================="
	@echo "Complete setup ready"
	@echo ""
	@echo "Services:"
	@echo "  - Elasticsearch: http://localhost:9200"
	@echo "  - Kibana: http://localhost:5601"
	@echo "  - LocalStack: http://localhost:4566"
	@echo ""
	@echo "All Lambda functions deployed and ready"
	@echo "=========================================="

check-elastic:
	@echo "Checking Elasticsearch status..."
	@curl -s -u elastic:changeme http://localhost:9200/_cluster/health?pretty