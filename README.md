# Flight Tracker Pipeline

This project sets up a local development environment for an AWS Lambda pipeline using LocalStack. It uses `make` to automate testing, packaging, and deployment.

## Local Development Workflow

This project uses `make` to automate common tasks for testing and deploying Lambda functions locally with LocalStack.

### 1. Prerequisites

Before you begin, make sure you have **LocalStack running** and your environment is set up.

1.  **Start LocalStack:**
    ```bash
    localstack start -d
    ```

2.  **Install Dependencies:**
    This will create a virtual environment (`.venv`) and install all necessary packages.
    ```bash
    make venv
    make install-dev
    ```

3.  **Activate Environment:**
    You must do this once per terminal session.
    ```bash
    source .venv/bin/activate
    ```

### 2. Running Tests

You can run the full test suite or get more detailed reports.

* **Run all tests:**
    ```bash
    make test
    ```

* **Run tests with verbose output:**
    ```bash
    make test-verbose
    ```

* **Get a test coverage report:**
    This generates an `htmlcov/` directory that you can open in your browser.
    ```bash
    make test-coverage
    ```

### 3. Local Lambda Workflow (Deploy & Invoke)

These commands manage your Lambda functions inside LocalStack.

**Note:** You must always provide the `lambda=` variable (e.g., `lambda=fetch_flight_list`).

#### Step 1: Deploy a Lambda

This command packages your Python code and its dependencies into a .zip file and deploys it to LocalStack. If the function already exists, it will be updated.
```bash
make deploy lambda=fetch_flight_list
```

#### Step 2: Check if a Lambda is Deployed
You can list all functions currently running in your LocalStack container to confirm the deployment was successful.
```bash
make list
```

#### Step 3: Invoke a Lambda
This will execute the specified Lambda function in LocalStack, using the payload.json file found in its directory. The Lambda's response (or error) will be printed to the terminal.
```bash
make invoke lambda=fetch_flight_list
```

#### Clean the Project: Removes all build artifacts, test caches, and coverage reports
```bash
make full-clean
```