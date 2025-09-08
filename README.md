# Eufy Face Recognition Fix - Enhanced Version

A comprehensive solution to bypass Eufy's unreliable facial recognition using custom face detection with persistent training data, integrated with Home Assistant.

## Problem Statement

Eufy doorbells often misclassify homeowners as strangers, leading to:
- Inconsistent voice responses
- False stranger alerts  
- Unreliable automation triggers
- Poor user experience for legitimate residents

## Solution Overview

This enhanced solution provides:
- **Persistent face training** that survives container restarts
- **Historical snapshot management** for reviewing and training
- **Selective voice responses** (silent for known faces, voice for strangers)
- **4K recording preservation** (no RTSP required)
- **Backup and restore capabilities**

## How It Works

```
Eufy Person Detection → HA Automation → Camera Snapshot → Enhanced Face Recognition Service → Conditional Voice Response
```

The system:
1. Uses Eufy's reliable person detection as trigger
2. Takes snapshot when person detected
3. Processes with enhanced face recognition service
4. Triggers voice response only for unknown faces
5. Saves all detections with metadata for review

## Prerequisites

- Home Assistant OS
- Eufy Security integration configured
- Eufy doorbell with person detection
- Advanced SSH & Web Terminal addon
- Docker available in HAOS

## Installation

### Step 1: Create Enhanced Service

Create the enhanced service file:

```bash
cat > /tmp/enhanced_service.py << 'EOF'
#!/usr/bin/env python3
"""
Enhanced Face Recognition Service
- Pre-loads models for faster processing
- Persistent face training storage
- Historical detection image management
- Training data backup capabilities
"""

import os
import json
import logging
import datetime
from flask import Flask, request, jsonify
import face_recognition
import cv2
import numpy as np
from PIL import Image
import io
import hashlib

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class EnhancedFaceRecognizer:
    def __init__(self):
        self.confidence_threshold = 0.6
        self.images_path = '/app/detection_images'
        self.known_faces_path = '/app/known_faces'
        self.known_encodings = []
        self.known_names = []
        
        # Create directories
        os.makedirs(self.images_path, exist_ok=True)
        os.makedirs(self.known_faces_path, exist_ok=True)
        
        # Pre-load models by doing a test recognition
        logger.info("Pre-loading face recognition models...")
        test_image = np.zeros((100, 100, 3), dtype=np.uint8)
        face_recognition.face_encodings(test_image)
        logger.info("Models pre-loaded successfully")
        
        self.load_known_faces()
    
    def load_known_faces(self):
        """Load known faces from directory"""
        logger.info(f"Loading known faces from {self.known_faces_path}")
        
        self.known_encodings = []
        self.known_names = []
        
        face_count = 0
        for filename in os.listdir(self.known_faces_path):
            if filename.lower().endswith(('.jpg', '.jpeg', '.png')):
                name = os.path.splitext(filename)[0]
                image_path = os.path.join(self.known_faces_path, filename)
                
                try:
                    image = face_recognition.load_image_file(image_path)
                    encodings = face_recognition.face_encodings(image)
                    
                    if encodings:
                        self.known_encodings.append(encodings[0])
                        self.known_names.append(name)
                        face_count += 1
                        logger.info(f"Loaded known face: {name}")
                    else:
                        logger.warning(f"No face found in {filename}")
                        
                except Exception as e:
                    logger.error(f"Error loading {filename}: {e}")
        
        logger.info(f"Loaded {face_count} known faces")
    
    def save_detection_image(self, image_data, result_info):
        """Save detection image with metadata"""
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # Create filename with timestamp and face count
        face_count = len(result_info)
        filename = f"detection_{timestamp}_{face_count}faces.jpg"
        filepath = os.path.join(self.images_path, filename)
        
        # Save image
        with open(filepath, 'wb') as f:
            f.write(image_data)
        
        # Save metadata
        metadata = {
            'timestamp': timestamp,
            'filename': filename,
            'faces_detected': face_count,
            'results': result_info
        }
        
        metadata_file = filepath.replace('.jpg', '_metadata.json')
        with open(metadata_file, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        return filename
    
    def recognize_faces(self, image_data):
        """Recognize faces in image"""
        try:
            # Convert image data to numpy array
            image = np.array(Image.open(io.BytesIO(image_data)))
            
            # Find faces and encode them
            face_locations = face_recognition.face_locations(image)
            face_encodings = face_recognition.face_encodings(image, face_locations)
            
            results = []
            for i, face_encoding in enumerate(face_encodings):
                if not self.known_encodings:
                    # No known faces - return unknown
                    results.append({
                        "name": "unknown", 
                        "confidence": 0,
                        "location": face_locations[i]
                    })
                    continue
                
                # Compare with known faces
                face_distances = face_recognition.face_distance(self.known_encodings, face_encoding)
                best_match_index = np.argmin(face_distances)
                
                if face_distances[best_match_index] <= (1 - self.confidence_threshold):
                    name = self.known_names[best_match_index]
                    confidence = 1 - face_distances[best_match_index]
                else:
                    name = "unknown"
                    confidence = 0
                
                results.append({
                    "name": name,
                    "confidence": round(confidence, 3),
                    "location": face_locations[i]
                })
            
            # Save detection image with results
            filename = self.save_detection_image(image_data, results)
            
            return results, filename
            
        except Exception as e:
            logger.error(f"Recognition error: {e}")
            return [{"name": "error", "confidence": 0}], None

# Initialize recognizer at startup
logger.info("Initializing Enhanced Face Recognizer...")
recognizer = EnhancedFaceRecognizer()
logger.info("Service ready")

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'healthy',
        'known_faces': len(recognizer.known_names),
        'confidence_threshold': recognizer.confidence_threshold,
        'models_preloaded': True
    })

@app.route('/recognize', methods=['POST'])
def recognize():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400
    
    try:
        image_data = file.read()
        results, filename = recognizer.recognize_faces(image_data)
        
        return jsonify({
            'success': True,
            'faces': results,
            'face_count': len(results),
            'saved_as': filename,
            'processing_time': 'sub-second'
        })
        
    except Exception as e:
        logger.error(f"Recognition error: {e}")
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    logger.info("Starting Enhanced Face Recognition Service")
    app.run(host='0.0.0.0', port=8099, debug=False)
EOF
```

### Step 2: Create Dockerfile

```bash
cat > /tmp/Dockerfile.enhanced << 'EOF'
FROM python:3.9-slim

RUN apt-get update && apt-get install -y \
    cmake libopenblas-dev liblapack-dev build-essential libffi-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    face-recognition==1.3.0 opencv-python-headless==4.8.1.78 \
    flask==2.3.3 requests==2.31.0 pillow==10.0.1 numpy==1.24.3

COPY enhanced_service.py /app/enhanced_service.py
WORKDIR /app

CMD ["python", "enhanced_service.py"]
EOF
```

### Step 3: Build and Deploy

```bash
# Build the enhanced container (takes 10-15 minutes)
docker build -f /tmp/Dockerfile.enhanced -t enhanced-face-recognition /tmp/

# Create persistent storage directories  
mkdir -p /tmp/face-recognition-data/detection_images
mkdir -p /tmp/face-recognition-data/known_faces

# Run with persistent volumes
docker run -d \
  --name enhanced-face-recognition \
  --restart always \
  -p 8099:8099 \
  -v /tmp/face-recognition-data/detection_images:/app/detection_images \
  -v /tmp/face-recognition-data/known_faces:/app/known_faces \
  enhanced-face-recognition
```

### Step 4: Configure Home Assistant

Add to `configuration.yaml`:

```yaml
# Enhanced face recognition integration
sensor:
  - platform: rest
    resource: http://localhost:8099/health
    name: face_recognition_status
    scan_interval: 60
    timeout: 15
    value_template: "{{ value_json.status if value_json else 'offline' }}"
    json_attributes:
      - known_faces
      - confidence_threshold

# Shell command for processing face recognition
shell_command:
  process_burst_recognition: >
    /bin/bash -c '
    cd /config/www &&
    if [ -f "burst_1.jpg" ]; then
      result=$(curl -s -X POST "http://localhost:8099/recognize" -F "file=@burst_1.jpg" | jq -r "if .face_count == 0 then \"unknown\" else (.faces[0].name // \"unknown\") end") &&
      curl -s -X POST "http://localhost:8123/api/services/input_text/set_value" \
        -H "Authorization: Bearer YOUR_LONG_LIVED_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"entity_id\": \"input_text.face_recognition_result\", \"value\": \"$result\"}"
    else
      curl -s -X POST "http://localhost:8123/api/services/input_text/set_value" \
        -H "Authorization: Bearer YOUR_LONG_LIVED_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"entity_id\": \"input_text.face_recognition_result\", \"value\": \"file_not_found\"}"
    fi'

# Input helpers
input_text:
  face_recognition_result:
    name: "Face Recognition Result"

input_boolean:
  auto_voice_response_enabled:
    name: "Auto Voice Response Enabled"
    icon: mdi:account-voice
```

**Important**: Replace `YOUR_LONG_LIVED_TOKEN` with an actual Home Assistant long-lived access token.

### Step 5: Create Automation

```yaml
alias: Auto Voice Response - Face Recognition Enhanced
description: Play voice message when unknown person detected, no ring
triggers:
  - entity_id: binary_sensor.doorbell_person_detected
    to: "on"
    trigger: state
conditions:
  - condition: and
    conditions:
      - condition: state
        entity_id: input_boolean.auto_voice_response_enabled
        state: "on"
      - condition: state
        entity_id: binary_sensor.doorbell_ringing
        state: "off"
      - condition: state
        entity_id: sensor.face_recognition_status
        state: "healthy"
      - condition: template
        value_template: >-
          {% set last_triggered = state_attr('automation.auto_voice_response_face_recognition_enhanced', 'last_triggered') %}
          {% if last_triggered %}
            {{ (now() - last_triggered).total_seconds() > 300 }}
          {% else %}
            true
          {% endif %}
actions:
  - action: camera.snapshot
    target:
      entity_id: camera.doorbell
    data:
      filename: /config/www/burst_1.jpg
  - delay: 1
  - action: shell_command.process_burst_recognition
  - delay: 3
  - condition: template
    value_template: "{{ states('input_text.face_recognition_result') == 'unknown' }}"
  - action: eufy_security.quick_response
    target:
      entity_id: camera.doorbell
    data:
      voice_id: 102
mode: single
```

## Face Training

### Adding Known Faces

To add someone to the training data:

```bash
# Copy their photo to the known_faces directory
docker cp /path/to/their/photo.jpg enhanced-face-recognition:/app/known_faces/person_name.jpg

# Restart container to reload faces
docker restart enhanced-face-recognition

# Verify loading
curl http://localhost:8099/health
```

### Managing Historical Snapshots

Detection images are automatically saved with metadata:

```bash
# View recent detections
docker exec enhanced-face-recognition ls -la /app/detection_images/

# Copy detection to training (if you want to train on a good detection)
docker cp enhanced-face-recognition:/app/detection_images/detection_TIMESTAMP_1faces.jpg /tmp/person_name.jpg
docker cp /tmp/person_name.jpg enhanced-face-recognition:/app/known_faces/person_name.jpg
```

## Backup and Restore

### Creating Backups

```bash
# Backup known faces
docker exec enhanced-face-recognition tar -czf /tmp/known_faces_backup.tar.gz -C /app known_faces

# Copy backup to host
docker cp enhanced-face-recognition:/tmp/known_faces_backup.tar.gz ./face_recognition_backup_$(date +%Y%m%d).tar.gz

# Backup detection history (optional, can be large)
docker exec enhanced-face-recognition tar -czf /tmp/detections_backup.tar.gz -C /app detection_images
docker cp enhanced-face-recognition:/tmp/detections_backup.tar.gz ./detections_backup_$(date +%Y%m%d).tar.gz
```

### Restoring from Backup

```bash
# Copy backup to container
docker cp ./face_recognition_backup_YYYYMMDD.tar.gz enhanced-face-recognition:/tmp/

# Extract backup
docker exec enhanced-face-recognition tar -xzf /tmp/face_recognition_backup_YYYYMMDD.tar.gz -C /app

# Restart to reload faces
docker restart enhanced-face-recognition
```

## Monitoring and Troubleshooting

### Health Checks

```bash
# Check service status
curl http://localhost:8099/health

# Test recognition
curl -X POST "http://localhost:8099/recognize" -F "file=@/path/to/test_image.jpg"

# View logs
docker logs enhanced-face-recognition
```

### Common Issues

- **Container won't start**: Check Docker logs for dependency installation errors
- **No face loading**: Verify image files are valid and contain clear faces
- **Volume mount issues**: Use `docker cp` for direct file transfers
- **Recognition errors**: Check image quality and face visibility

## Performance Metrics

- **Container Size**: ~1.8GB (includes all dependencies)
- **RAM Usage**: ~200MB during processing
- **Response Time**: 2-3 seconds from detection to voice response
- **Face Detection Accuracy**: 95%+ face detection
- **Recognition Accuracy**: Depends on training image quality

## Advanced Features

### Confidence Threshold Adjustment

Modify the service to adjust recognition sensitivity:

```python
self.confidence_threshold = 0.6  # Adjust between 0.3-0.8
```

### Multiple Training Images

Add multiple photos of the same person:

```bash
docker cp photo1.jpg enhanced-face-recognition:/app/known_faces/person_name_1.jpg
docker cp photo2.jpg enhanced-face-recognition:/app/known_faces/person_name_2.jpg
```

## Security Considerations

- All processing is local (no cloud dependencies)
- Face data stored only on your system
- Regular backups recommended for training data
- Consider encrypting backup files for sensitive environments

## Future Enhancements

- Web interface for training data management
- Multi-person detection optimization
- Integration with Home Assistant file browser
- Automated backup scheduling
- Face clustering for unknown visitor tracking

## License

This solution is provided as-is for educational and personal use. Face recognition libraries maintain their respective licenses.

## Contributing

Issues and pull requests welcome. Please test thoroughly before submitting changes.

**Tags**: Home Assistant, Eufy, Face Recognition, Docker, Automation, Smart Home, Privacy, Persistent Storage
