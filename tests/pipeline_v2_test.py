#!/usr/bin/env python3

import kfp
import sys
import time
import tempfile
from pathlib import Path
from kfp import dsl
from kfp import kubernetes
from kfp_server_api.exceptions import ApiException


@dsl.component
def hello_world_operation() -> str:
    print("Hello World from Kubeflow Pipelines V2!")
    return "Hello World"


@dsl.pipeline(name="hello-world-v2", description="A very simple hello world pipeline")
def hello_world_pipeline():
    hello_world_task = hello_world_operation()
    kubernetes.set_security_context(
        hello_world_task, run_as_user=1000, run_as_group=0, run_as_non_root=True
    )


def run_pipeline(token, namespace, upload=False):
    client = kfp.Client(host="http://localhost:8080/pipeline", existing_token=token)

    try:
        pipelines = client.list_pipelines(namespace=namespace)
        print(
            f"Successfully connected to KFP server, found {len(pipelines.pipelines or [])} pipelines"
        )

        experiment = client.create_experiment("v2-pipeline-test", namespace=namespace)
        print(f"Created experiment: v2-pipeline-test in namespace {namespace}")

        if upload:
            with tempfile.TemporaryDirectory() as directory:
                package = str(Path(directory) / "pipeline.yaml")
                kfp.compiler.Compiler().compile(hello_world_pipeline, package)
                pipeline = client.upload_pipeline(
                    package, pipeline_name="v2-storage-test", namespace=namespace
                )
                version = client.upload_pipeline_version(
                    package, "v2-storage-version", pipeline_id=pipeline.pipeline_id
                )
            run = client.run_pipeline(
                experiment_id=experiment.experiment_id,
                job_name="v2-stored-test-run",
                pipeline_id=pipeline.pipeline_id,
                version_id=version.pipeline_version_id,
            )
        else:
            run = client.create_run_from_pipeline_func(
                pipeline_func=hello_world_pipeline,
                experiment_name="v2-pipeline-test",
                run_name="v2-test-run",
                arguments={},
                namespace=namespace,
            )

        run_id = run.run_id

        for _ in range(30):
            status = client.get_run(run_id=run_id).state

            if status == "SUCCEEDED":
                return
            elif status not in ["PENDING", "RUNNING"]:
                print(f"Pipeline failed with status: {status}")

                pods = client._get_k8s_client().list_namespaced_pod(
                    namespace=namespace, label_selector=f"pipeline/runid={run_id}"
                )

                print(f"Found {len(pods.items)} pods for this run")
                for pod in pods.items:
                    print(f"Pod {pod.metadata.name}: {pod.status.phase}")

                sys.exit(1)

            time.sleep(10)

        sys.exit(1)

    except Exception as exception:
        print(f"Error in pipeline execution: {exception}")
        sys.exit(1)


def test_unauthorized_access(token, namespace):
    client = kfp.Client(host="http://localhost:8080/pipeline", existing_token=token)

    try:
        pipeline = client.list_runs(namespace=namespace)
        sys.exit(1)
    except ApiException as exception:
        if exception.status != 403:
            sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)

    action = sys.argv[1]
    token = sys.argv[2]
    namespace = sys.argv[3]

    if action == "run_pipeline":
        run_pipeline(token, namespace)
    elif action == "run_uploaded_pipeline":
        run_pipeline(token, namespace, upload=True)
    elif action == "test_unauthorized_access":
        test_unauthorized_access(token, namespace)
    else:
        sys.exit(1)
