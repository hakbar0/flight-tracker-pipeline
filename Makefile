SHELL := /bin/bash
BUILD_DIR := build
REGION := eu-west-2
ROLE_ARN := arn:aws:iam::000000000000:role/service-role

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo "For lambda-specific commands, use: make <target> lambda=<lambda-name>"

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
	@pip install -r src/lambdas/$(lambda)/requirements.txt -t $(BUILD_DIR)/$(lambda)_pkg/ > /dev/null
	@cd $(BUILD_DIR)/$(lambda)_pkg && zip -r ../$(lambda).zip . > /dev/null
	@echo "Lambda packaged"

deploy: package
	@echo "Deploying $(lambda)..."
	@# Try to create the function. If it fails (||), then update the code.
	@awslocal --region $(REGION) lambda create-function \
		--function-name $(lambda) \
		--runtime python3.12 \
		--handler lambda_function.handler \
		--role $(ROLE_ARN) \
		--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
		> /dev/null 2>&1 || \
	( \
		echo "Function exists, updating code..." && \
		awslocal --region $(REGION) lambda update-function-code \
			--function-name $(lambda) \
			--zip-file fileb://$(BUILD_DIR)/$(lambda).zip \
			> /dev/null \
	)
	@echo "Lambda deployed"

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
	@echo "Lambda deleted"

.PHONY: list logs clean-pyc clean full-clean ls
list:
	@awslocal --region $(REGION) lambda list-functions --query 'Functions[*].[FunctionName,Runtime,LastModified]' --output table

ls:
	@awslocal --region $(REGION) lambda list-functions --output table

logs:
	@localstack logs

clean-pyc:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	find . -type f -name "*.pyo" -delete

clean: clean-pyc ## Clean all build artifacts and venv
	rm -rf $(BUILD_DIR)/
	rm -rf .pytest_cache
	rm -rf htmlcov
	rm -rf .coverage
	rm -rf .ruff_cache
	rm -rf .venv
	@echo "Cleaned!"

full-clean: clean
	@echo "Full clean complete!"

check-lambda-var:
	@[ -z "$(lambda)" ] && echo "Error: 'lambda' variable is not set." && exit 1 || exit 0
