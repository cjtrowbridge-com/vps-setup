# Use an official Python runtime as a parent image
FROM python:3.8

# Set the working directory to /app
WORKDIR /app

# Install JupyterLab with the git extension and git itself
RUN apt-get update \
    && apt-get install -y git \
    && pip install --no-cache-dir jupyterlab jupyterlab-git \
    && jupyter server extension enable --py jupyterlab_git

# Make port 8888 available to the world outside this container
EXPOSE 8888

# Run JupyterLab when the container launches
CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--allow-root"]
