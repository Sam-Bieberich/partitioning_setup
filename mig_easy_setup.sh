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

GI_ID=$(nvidia-smi mig -lgip | awk '/1g\./{print $2,$0}' | awk '$1 ~ /[0-9]+/ {print $1}' | head -n1)
if [ -z "$GI_ID" ]; then echo "ERROR: Could not find 1g.* GI profile id"; exit 1; fi
sudo nvidia-smi mig -cgi $GI_ID -C --count 7

# sudo nvidia-smi mig -cgi 19,19,19,19,19,19,19 -C

echo "Confirming partitions"

nvidia-smi -L

echo "--------------------------"

# How to use this script:

# Make the script executable (if not already)
# chmod +x mig_setup_7.sh

# Run the script
# ./mig_setup_7.sh