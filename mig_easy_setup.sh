echo "Starting MIG setup (7 partitions)"

#checking that MIG is enabled
echo "MIG partitioning enabled check"

sudo nvidia-smi -i 0 -mig 1

echo "--------------------------"


echo "Deleting any old instances"

sudo nvidia-smi mig -dci -i 0   # Delete all compute instances
sudo nvidia-smi mig -dgi -i 0   # Delete all GPU instances

echo "MIG Profiles"

nvidia-smi mig -lgip

echo "--------------------------"


echo "Creating 7 partitions"
sudo nvidia-smi mig -cgi 19,19,19,19,19,19,19 -C

echo "Confirming partitions"

nvidia-smi -L

echo "--------------------------"

# How to use this script:

# Make the script executable (if not already)
# chmod +x mig_setup_7.sh

# Run the script
# ./mig_setup_7.sh