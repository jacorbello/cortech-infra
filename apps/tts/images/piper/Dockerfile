# apps/tts/images/piper/Dockerfile
FROM python:3.12-slim

ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIPER_DATA_DIR=/models

RUN apt-get update && \
    apt-get install --yes --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Install piper-tts and HTTP server dependencies
# Note: piper-tts[http] extra may not exist on PyPI, so install flask explicitly
RUN pip3 install --no-cache-dir piper-tts 'flask>=3,<4'

# Create model directories
RUN mkdir -p /models

# Download en_GB-aru-medium voice (multi-speaker)
RUN curl -L -o /models/en_GB-aru-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/aru/medium/en_GB-aru-medium.onnx" && \
    curl -L -o /models/en_GB-aru-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/aru/medium/en_GB-aru-medium.onnx.json"

# Download en_GB-northern_english_male-medium voice
RUN curl -L -o /models/en_GB-northern_english_male-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx" && \
    curl -L -o /models/en_GB-northern_english_male-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx.json"

EXPOSE 5000

ENTRYPOINT ["python3", "-m", "piper.http_server"]
CMD ["-m", "/models/en_GB-aru-medium.onnx", "--data-dir", "/models", "--host", "0.0.0.0", "--port", "5000"]
