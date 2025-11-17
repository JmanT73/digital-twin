
import os
import shutil
import zipfile
import subprocess
import time


def main():
    print("Creating Lambda deployment package...")

    # Clean up - use more robust method for Windows
    if os.path.exists("lambda-package"):
        try:
            shutil.rmtree("lambda-package")
        except PermissionError:
            # On Windows, sometimes files are locked. Try with retries
            for _ in range(3):
                time.sleep(1)
                try:
                    shutil.rmtree("lambda-package")
                    break
                except PermissionError:
                    continue
            else:
                # If still fails, try using PowerShell command
                subprocess.run(["powershell", "-Command", "Remove-Item -Recurse -Force lambda-package"], check=False)
    
    if os.path.exists("lambda-deployment.zip"):
        try:
            os.remove("lambda-deployment.zip")
        except PermissionError:
            pass

    # Create package directory
    os.makedirs("lambda-package")

    # Install dependencies using Docker with Lambda runtime image
    print("Installing dependencies for Lambda runtime...")

    # Use the official AWS Lambda Python 3.12 image
    # This ensures compatibility with Lambda's runtime environment
    subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "-v",
            f"{os.getcwd()}:/var/task",
            "--platform",
            "linux/amd64",  # Force x86_64 architecture
            "--entrypoint",
            "",  # Override the default entrypoint
            "public.ecr.aws/lambda/python:3.12",
            "/bin/sh",
            "-c",
            "pip install --target /var/task/lambda-package -r /var/task/requirements.txt --platform manylinux2014_x86_64 --only-binary=:all: --upgrade",
        ],
        check=True,
    )

    # Copy application files
    print("Copying application files...")
    for file in ["server.py", "lambda_handler.py", "context.py", "resources.py"]:
        if os.path.exists(file):
            shutil.copy2(file, "lambda-package/")
    
    # Copy data directory
    if os.path.exists("data"):
        shutil.copytree("data", "lambda-package/data")

    # Create zip
    print("Creating zip file...")
    with zipfile.ZipFile("lambda-deployment.zip", "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk("lambda-package"):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, "lambda-package")
                zipf.write(file_path, arcname)

    # Show package size
    size_mb = os.path.getsize("lambda-deployment.zip") / (1024 * 1024)
    print(f"Created lambda-deployment.zip ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()