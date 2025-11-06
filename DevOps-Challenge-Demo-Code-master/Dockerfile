# Use Python 3.9 to ensure compatibility with older tornado
FROM python:3.9-slim

# Set working directory
WORKDIR /app

# Copy application files
COPY . /app

# Upgrade pip and install dependencies
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

# Expose the application port
EXPOSE 8888

# Run the application
CMD ["python", "hello.py"]

