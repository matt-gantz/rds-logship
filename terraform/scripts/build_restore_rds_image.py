import os
import subprocess
import sys


def run(command, *, input_text=None, env=None):
    subprocess.run(
        command,
        check=True,
        text=True,
        input=input_text,
        env=env,
    )


def main():
    repository_url = os.environ["IMAGE_REPOSITORY_URL"]
    image_tag = os.environ["IMAGE_TAG"]
    region = os.environ["AWS_REGION"]
    dockerfile_dir = os.environ["DOCKERFILE_DIR"]

    login_password = subprocess.run(
        [
            "aws",
            "ecr",
            "get-login-password",
            "--region",
            region,
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    registry = repository_url.split("/", 1)[0]
    run(["docker", "login", "--username", "AWS", "--password-stdin", registry], input_text=login_password)

    env = os.environ.copy()
    # Disable BuildKit/Buildx provenance and SBOM attestations which create multi-manifest OCI
    # indexes that AWS Lambda rejects with:
    # "InvalidParameterValueException: The image manifest, config or layer media type for the source image is not supported"
    env["BUILDX_NO_DEFAULT_ATTESTATIONS"] = "1"

    build_and_pushed = False
    for build_cmd in [
        ["docker", "buildx", "build", "--platform", "linux/amd64", "--provenance=false", "-t", f"{repository_url}:{image_tag}", "--push", dockerfile_dir],
        ["docker", "build", "--platform", "linux/amd64", "--provenance=false", "-t", f"{repository_url}:{image_tag}", dockerfile_dir],
        ["docker", "build", "--platform", "linux/amd64", "-t", f"{repository_url}:{image_tag}", dockerfile_dir],
    ]:
        try:
            print(f"Building image with: {' '.join(build_cmd)}")
            run(build_cmd, env=env)
            if "--push" in build_cmd:
                build_and_pushed = True
            break
        except subprocess.CalledProcessError as e:
            print(f"Command failed ({e}), trying fallback...")
            continue

    if not build_and_pushed:
        run(["docker", "push", f"{repository_url}:{image_tag}"], env=env)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
