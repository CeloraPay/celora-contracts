#!/bin/bash

echo "Deleting the abi/ directory"
rm -rf abi

echo "Creating the abi/ directory"
mkdir abi

echo "Exporting ABIS to abi/ directory"
forge inspect Gateway abi --json > abi/GATEWAY_ABI.json
forge inspect Payment abi --json > abi/PAYMENT_ABI.json