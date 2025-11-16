SHELL := /bin/bash
BUILD_DIR := build
REGION := eu-west-2
ROLE_ARN := arn:aws:iam::000000000000:role/service-role
STATE_MACHINE_NAME := flight-tracker-pipeline

LAMBDAS := fetch_flight_list process_single_flight

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Main setup:"
	@echo "  setup             - Creates venv and installs dev dependencies (Run this first!)"
	@echo "  start-services    - Starts all services (LocalStack, ES, Kibana)"
	@echo "  deploy-all        - Deploy all Lambda functions to LocalStack"
	@echo "  full-setup        - Run setup, start services, and deploy all lambdas"
	@echo ""
	@echo "Step Functions:"
	@echo "  create-state-machine   - Create/update the Step Functions state machine"
	@echo "  start-execution        - Start a state machine execution"
	@echo "  list-executions        - List recent executions"
	@echo "  describe-execution     - Describe execution (use arn=<execution-arn>)"
	@echo "  delete-state-machine   - Delete the state machine"
	@echo ""
	@echo "Lambda commands (use lambda=<n>):"
	@echo "  package           - Package a lambda"
	@echo "  deploy            - Deploy a lambda"
	@echo "  invoke            - Invoke a lambda"
	@echo "  delete            - Delete a lambda"
	@echo ""
	@echo "Utility commands:"
	@echo "  list/ls           - List all deployed lambdas"
	@echo "  logs              - Show LocalStack logs"
	@echo "  logs-elastic      - Show Elasticsearch logs"
	@echo "  logs-kibana       - Show Kibana logs"
	@echo "  check-elastic     - Check Elasticsearch health"
	@echo "  test              - Run all tests"
	@echo "  clean             - Clean build artifacts"
	@echo "  down              - Stop all services"

.PHONY: venv install install-dev setup
venv:
	python3 -m venv .venv

install:
	pip install -e .

install-dev:
	pip install -e ".[dev,aws]"

setup: venv
	@echo "Installing/upgrading dev dependencies into .venv..."
	@. .venv/bin/activate; \
	pip install --upgrade pip; \
	pip install -e ".[dev,aws]"
	@echo "================================================================"
	@echo "Dependencies installed."
	@echo "To activate the virtual environment, run:"
	@echo ""
	@echo "  source .venv/bin/activate"
	@echo ""
	@echo "================================================================"

.PHONY: test test-verbose test-coverage lint format
test:
	@echo "Running tests..."
	@. .venv/bin/activate && PYTHONPATH=$(shell pwd)/src pytest src/lambdas/

test-verbose:
	@. .venv/bin/activate && pytest -v -s src/lambdas/

test-coverage:
	@. .venv/bin/activate && pytest --cov=src/lambdas --cov-report=html src/lambdas/

lint:
	@. .venv/bin/activate && ruff check src/lambdas/

format:
	@. .venv/bin/activate && black src/lambdas/

.PHONY: package deploy invoke delete
package: check-lambda-var
	@echo "Packaging $(lambda)..."
	@mkdir -p $(BUILD_DIR)/$(lambda)_pkg
	@cp src/lambdas/$(lambda)/lambda_function.py $(BUILD_DIR)/$(lambda)_pkg/
	@if [ -f src/lambdas/$(lambda)/requirements.txt ]; then \
		echo "Installing requirements for $(lambda)..."; \
		. .venv/bin/activate && pip install -r src/lambdas/$(lambda)/requirements.txt -t $(BUILD_DIR)/$(lambda)_pkg/; \
	fi
	@cd $(BUILD_DIR)/$(lambda)_pkg && zip -r ../$(lambda).zip . > /dev/null
	@echo "Lambda packaged: $(lambda)"

deploy: package
	@echo "Deploying $(lambda)..."
	@. .venv/bin/activate && awslocal --region $(REGION) lambda create-function \
		--function-name $(lambda) \
		--runtime python3.12 \
		--handler lambda_function.handler \
		--role $(ROLE_ARN) \
		--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
		--timeout 30 \
		--environment Variables="{ELASTICSEARCH_HOST=http://elasticsearch:9200,ELASTICSEARCH_USER=elastic,ELASTICSEARCH_PASSWORD=changeme}" \
		2>/dev/null \
		|| \
	( \
		echo "Function exists, updating code..." && \
		. .venv/bin/activate && awslocal --region $(REGION) lambda update-function-code \
			--function-name $(lambda) \
			--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
			2>/dev/null \
			&& \
		. .venv/bin/activate && awslocal --region $(REGION) lambda update-function-configuration \
			--function-name $(lambda) \
			--timeout 30 \
			--environment Variables="{ELASTICSEARCH_HOST=http://elasticsearch:9200,ELASTICSEARCH_USER=elastic,ELASTICSEARCH_PASSWORD=changeme}" \
			2>/dev/null \
	)
	@echo "Lambda deployed: $(lambda)"

invoke: check-lambda-var
	@echo "Invoking $(lambda)..."
	@. .venv/bin/activate && awslocal --region $(REGION) lambda invoke \
		--function-name $(lambda) \
		--payload file://src/lambdas/$(lambda)/payload.json \
		output.json >/dev/null 2>&1
	@if [ -f output.json ]; then cat output.json | jq; else echo "Invoke failed"; fi
	@rm -f output.json

delete: check-lambda-var
	@echo "Deleting $(lambda)..."
	@. .venv/bin/activate && awslocal --region $(REGION) lambda delete-function --function-name $(lambda) > /dev/null 2>&1 || true
	@echo "Lambda deleted: $(lambda)"

.PHONY: deploy-all delete-all
deploy-all:
	@echo "=========================================="
	@echo "Deploying all Lambda functions..."
	@echo "=========================================="
	@for lambda in $(LAMBDAS); do \
		echo ""; \
		$(MAKE) deploy lambda=$$lambda || (echo "Failed to deploy $$lambda" && exit 1); \
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

.PHONY: create-state-machine start-execution list-executions describe-execution delete-state-machine
create-state-machine:
	@echo "Creating/updating Step Functions state machine..."
	STATE_MACHINE_ARN=$$(awslocal --region $(REGION) stepfunctions list-state-machines --query "stateMachines[?name=='$(STATE_MACHINE_NAME)'].stateMachineArn" --output text); \
	if [ -z "$$STATE_MACHINE_ARN" ] || [ "$$STATE_MACHINE_ARN" = "None" ]; then \
		echo "State machine does not exist, creating..."; \
		awslocal --region $(REGION) stepfunctions create-state-machine \
			--name $(STATE_MACHINE_NAME) \
			--definition file://src/step_function/state_machine.json \
			--role-arn $(ROLE_ARN); \
	else \
		echo "State machine exists, updating definition..."; \
		awslocal --region $(REGION) stepfunctions update-state-machine \
			--state-machine-arn $$STATE_MACHINE_ARN \
			--definition file://src/step_function/state_machine.json; \
	fi
	@echo "State machine ready: $(STATE_MACHINE_NAME)"

start-execution:
	@echo "Starting state machine execution..."
	@STATE_MACHINE_ARN=$$(. .venv/bin/activate && awslocal --region $(REGION) stepfunctions list-state-machines --query "stateMachines[?name=='$(STATE_MACHINE_NAME)'].stateMachineArn" --output text); \
	if [ -z "$$STATE_MACHINE_ARN" ]; then \
		echo "Error: State machine '$(STATE_MACHINE_NAME)' not found. Run 'make create-state-machine' first."; \
		exit 1; \
	fi; \
	EXECUTION_ARN=$$(. .venv/bin/activate && awslocal --region $(REGION) stepfunctions start-execution \
		--state-machine-arn $$STATE_MACHINE_ARN \
		--name execution-$$(date +%s) \
		--input '{}' \
		--query 'executionArn' --output text); \
	echo "Execution started: $$EXECUTION_ARN"; \
	echo ""; \
	echo "Waiting 3 seconds for execution to start..."; \
	sleep 3; \
	echo ""; \
	echo "Execution status:"; \
	. .venv/bin/activate && awslocal --region $(REGION) stepfunctions describe-execution \
		--execution-arn $$EXECUTION_ARN \
		--output table; \
	echo ""; \
	echo "Execution history (events):"; \
	. .venv/bin/activate && awslocal --region $(REGION) stepfunctions get-execution-history \
		--execution-arn $$EXECUTION_ARN \
		--max-items 200 \
		--output json | jq '.'


list-executions:
	@echo "Recent executions:"
	@STATE_MACHINE_ARN=$$(. .venv/bin/activate && awslocal --region $(REGION) stepfunctions list-state-machines --query "stateMachines[?name=='$(STATE_MACHINE_NAME)'].stateMachineArn" --output text); \
	if [ -z "$$STATE_MACHINE_ARN" ]; then \
		echo "Error: State machine '$(STATE_MACHINE_NAME)' not found."; \
		exit 1; \
	fi; \
	. .venv/bin/activate && awslocal --region $(REGION) stepfunctions list-executions \
		--state-machine-arn $$STATE_MACHINE_ARN \
		--max-results 10 \
		--query 'executions[*].[name, status, startDate, stopDate]' \
		--output table

describe-execution:
	@if [ -z "$(arn)" ]; then \
		echo "Error: Please provide execution ARN. Usage: make describe-execution arn=<execution-arn>"; \
		echo ""; \
		echo "To list executions, run: make list-executions"; \
		exit 1; \
	fi
	@echo "Execution details:"
	@. .venv/bin/activate && awslocal --region $(REGION) stepfunctions describe-execution \
		--execution-arn $(arn) \
		--output json | jq

delete-state-machine:
	@echo "Deleting state machine..."
	@STATE_MACHINE_ARN=$$(. .venv/bin/activate && awslocal --region $(REGION) stepfunctions list-state-machines --query "stateMachines[?name=='$(STATE_MACHINE_NAME)'].stateMachineArn" --output text); \
	if [ -z "$$STATE_MACHINE_ARN" ]; then \
		echo "State machine '$(STATE_MACHINE_NAME)' not found."; \
	else \
		. .venv/bin/activate && awslocal --region $(REGION) stepfunctions delete-state-machine \
			--state-machine-arn $$STATE_MACHINE_ARN 2>/dev/null; \
		echo "State machine deleted: $(STATE_MACHINE_NAME)"; \
	fi

.PHONY: list logs clean-pyc clean full-clean ls
list:
	@echo "Deployed Lambda functions:"
	@. .venv/bin/activate && awslocal --region $(REGION) lambda list-functions --query 'Functions[*].[FunctionName,Runtime,LastModified]' --output table

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
	find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaned"

full-clean: clean down
	rm -rf .venv
	@echo "Full clean complete"

check-lambda-var:
	@[ -z "$(lambda)" ] && echo "Error: 'lambda' variable is not set. Usage: make deploy lambda=fetch_flight_list" && exit 1 || exit 0

.PHONY: up down setup-elastic start-services check-elastic full-setup
up:
	@echo "Starting Docker containers..."
	@docker-compose up -d
	@echo "Docker containers started"

down:
	@echo "Stopping all services..."
	@docker-compose down
	@echo "All services stopped"

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
	@echo "Elasticsearch setup complete"

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

full-setup: setup start-services
	@echo "Waiting 10s for LocalStack to be fully ready..."
	@sleep 10
	@$(MAKE) deploy-all
	@$(MAKE) create-state-machine
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
	@echo "State machine created and ready"
	@echo ""
	@echo "To run the pipeline, execute:"
	@echo "  make start-execution"
	@echo "=========================================="

check-elastic:
	@echo "Checking Elasticsearch status..."
	@curl -s -u elastic:changeme http://localhost:9200/_cluster/health?pretty