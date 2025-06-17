FROM python:3.10-slim

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# Install system dependencies needed for Essentia (no FFmpeg)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    python3-dev \
    libeigen3-dev \
    libfftw3-dev \
    libyaml-dev \
    libsamplerate0-dev \
    libtag1-dev \
    && rm -rf /var/lib/apt/lists/*

    
# Provide `python` binary for waf build scripts
RUN ln -s $(which python3) /usr/bin/python

# Clone and build Essentia without FFmpeg
# Clone and build Essentia without FFmpeg
RUN git clone https://github.com/MTG/essentia.git /opt/essentia && \
    pip install numpy && \
    cd /opt/essentia && chmod +x waf && \
    ./waf configure --fft=KISS --with-python --build-static && \
    ./waf && \
    ./waf install && \
    ldconfig

RUN apt-get update && apt-get install -y portaudio19-dev

# Copy app code
COPY . /app

# Install Python dependencies
RUN pip install --no-cache-dir -r /app/requirements.txt

# Use Cloud Run-injected PORT or default to 8080
EXPOSE 8080

# Start FastAPI with Uvicorn on the correct port
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
