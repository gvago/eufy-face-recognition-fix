#!/bin/bash
# Simple Face Recognition Service for Eufy Doorbell Integration
# Run this script to start the face recognition container

# Remove existing container if it exists
docker stop simple-face-recognition 2>/dev/null || true
docker rm simple-face-recognition 2>/dev/null || true

# Run the face recognition service
docker run -d \
  --name simple-face-recognition \
  --restart always \
  -p 8099:8099 \
  python:3.9-slim \
  bash -c "
    apt-get update && apt-get install -y cmake build-essential && 
    pip install face-recognition flask pillow requests && 
    python -c \"
from flask import Flask, request, jsonify
import face_recognition
import numpy as np
from PIL import Image
import io

app = Flask(__name__)

@app.route('/health')
def health():
    return jsonify({'status': 'healthy', 'known_faces': 0})

@app.route('/recognize', methods=['POST'])
def recognize():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    try:
        file = request.files['file']
        image_data = file.read()
        image = np.array(Image.open(io.BytesIO(image_data)))
        face_encodings = face_recognition.face_encodings(image)
        
        return jsonify({
            'success': True,
            'faces': [{'name': 'unknown', 'confidence': 0} for _ in face_encodings],
            'face_count': len(face_encodings)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

print('Starting face recognition service...')
app.run(host='0.0.0.0', port=8099, debug=False)
\"
  "

echo "Face recognition service starting..."
echo "Check status with: curl http://localhost:8099/health"
echo "View logs with: docker logs simple-face-recognition"
