#!/bin/bash

echo "Deleting the abi/ directory"
rm -rf abi

echo "Creating the abi/ directory"
mkdir abi

echo "Exporting ABIS to abi/ directory"
forge inspect PaymentGateway abi --json > abi/GATEWAY_ABI.json
forge inspect PaymentEscrow abi --json > abi/ESCROW_ABI.json