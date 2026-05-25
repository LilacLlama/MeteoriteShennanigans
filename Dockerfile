# ============================================================
# Meteorite Explorer — Lambda-compatible Docker image
#
# Uses AWS Lambda Web Adapter (LWA) so a plain uvicorn/FastAPI
# process runs inside Lambda with full streaming support.
# The LWA intercepts Lambda invocations and proxies them to
# uvicorn on PORT 8000 — no Mangum or handler shims needed.
# ============================================================

# Stage 1: pull in the Lambda Web Adapter binary
FROM public.ecr.aws/awslabs/aws-lambda-web-adapter:latest AS adapter

# Stage 2: our actual runtime
FROM python:3.12-slim

# Copy the LWA extension binary
COPY --from=adapter /lambda-adapter /opt/extensions/lambda-adapter

# LWA config
ENV PORT=8000
ENV AWS_LWA_INVOKE_MODE=response_stream
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install Python deps first (better layer caching)
COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY backend/ ./

# Bundle the NASA dataset so Lambda has it without any S3 dependency
COPY data/Meteorite_Landings.csv ./data/Meteorite_Landings.csv

# LWA starts uvicorn for us when Lambda invokes the container
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
