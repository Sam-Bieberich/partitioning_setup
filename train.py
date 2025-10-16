#!/usr/bin/env python3

"""
Simple training script to test MIG CPU-GPU partitioning
Tests that a training job correctly uses:
- Assigned CPU cores
- Assigned MIG GPU partition
"""

import os
import sys
import time
import subprocess
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

def get_system_info():
    """Print current resource assignments"""
    print("=" * 60)
    print("SYSTEM INFORMATION")
    print("=" * 60)
    
    # CPU info
    pid = os.getpid()
    try:
        result = subprocess.run(['taskset', '-cp', str(pid)], 
                              capture_output=True, text=True)
        print(f"CPU Affinity: {result.stdout.strip()}")
    except:
        print("CPU Affinity: Could not determine")
    
    # GPU info
    cuda_devices = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
    print(f"CUDA_VISIBLE_DEVICES: {cuda_devices}")
    print(f"CUDA Available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"GPU Name: {torch.cuda.get_device_name(0)}")
        print(f"GPU Memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.2f} GB")
    
    # Cgroup info
    try:
        with open(f'/proc/{pid}/cgroup', 'r') as f:
            cgroup_line = f.read().strip()
            if 'mig' in cgroup_line:
                mig_path = [line for line in cgroup_line.split('\n') if 'mig' in line][0]
                print(f"Cgroup: {mig_path}")
    except:
        print("Cgroup: Could not determine")
    
    print("=" * 60)
    print()

def simple_neural_network():
    """Create a simple neural network for testing"""
    return nn.Sequential(
        nn.Linear(784, 256),
        nn.ReLU(),
        nn.Linear(256, 128),
        nn.ReLU(),
        nn.Linear(128, 10)
    )

def create_dummy_data(num_samples=1000, batch_size=32):
    """Create dummy MNIST-like data for testing"""
    X = torch.randn(num_samples, 784)  # Flattened 28x28 images
    y = torch.randint(0, 10, (num_samples,))  # 10 classes
    
    dataset = TensorDataset(X, y)
    dataloader = DataLoader(dataset, batch_size=batch_size, shuffle=True)
    return dataloader

def train():
    """Main training loop"""
    
    print()
    print("Starting Training Job")
    print("=" * 60)
    
    # Print resource info
    get_system_info()
    
    # Configuration
    epochs = 3
    batch_size = 32
    learning_rate = 0.001
    
    # Device
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Using device: {device}")
    print()
    
    # Model, loss, optimizer
    model = simple_neural_network().to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=learning_rate)
    
    # Create data
    print("Creating dummy training data...")
    train_loader = create_dummy_data(num_samples=5000, batch_size=batch_size)
    print(f"Created {len(train_loader)} batches of size {batch_size}")
    print()
    
    # Training loop
    print("Starting training...")
    print("=" * 60)
    
    start_time = time.time()
    total_batches = 0
    
    for epoch in range(epochs):
        epoch_start = time.time()
        epoch_loss = 0.0
        batch_count = 0
        
        for batch_idx, (data, target) in enumerate(train_loader):
            # Move to device
            data, target = data.to(device), target.to(device)
            
            # Forward pass
            output = model(data)
            loss = criterion(output, target)
            
            # Backward pass
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            
            epoch_loss += loss.item()
            batch_count += 1
            total_batches += 1
            
            # Print progress
            if batch_idx % 20 == 0:
                avg_loss = epoch_loss / (batch_idx + 1)
                print(f"Epoch [{epoch+1}/{epochs}], Batch [{batch_idx}/{len(train_loader)}], Loss: {avg_loss:.4f}")
        
        epoch_time = time.time() - epoch_start
        avg_epoch_loss = epoch_loss / batch_count
        
        print(f"Epoch {epoch+1} completed in {epoch_time:.2f}s, Avg Loss: {avg_epoch_loss:.4f}")
        print()
    
    total_time = time.time() - start_time
    
    # Summary
    print("=" * 60)
    print("TRAINING COMPLETE")
    print("=" * 60)
    print(f"Total time: {total_time:.2f} seconds")
    print(f"Total batches processed: {total_batches}")
    print(f"Avg time per batch: {(total_time / total_batches) * 1000:.2f} ms")
    print(f"Throughput: {total_batches / total_time:.2f} batches/sec")
    print()
    
    # Verify GPU was used
    if torch.cuda.is_available():
        print("GPU Usage:")
        print(f"  Peak memory allocated: {torch.cuda.max_memory_allocated() / 1e9:.2f} GB")
        print(f"  Current memory allocated: {torch.cuda.memory_allocated() / 1e9:.2f} GB")
    
    print("=" * 60)
    print()

if __name__ == '__main__':
    try:
        train()
        print("✓ Training completed successfully!")
        sys.exit(0)
    except Exception as e:
        print(f"✗ Error during training: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)