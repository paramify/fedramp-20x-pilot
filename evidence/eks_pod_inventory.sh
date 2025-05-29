#!/bin/bash

# -----------
# USAGE 
#chmod +x eks_pod_inventory.sh
#./eks_pod_inventory.sh             # Uses gov_readonly
#./eks_pod_inventory.sh AWS_PROFILE # Uses AWS_PROFILE 
# -----------

# Set AWS profile, default to 'gov_readonly' if not provided
AWS_PROFILE=${1:-gov_readonly}
JSON_OUTPUT="eks_all_clusters_pod_inventory.json"
CSV_OUTPUT="eks_all_clusters_pod_inventory.csv"

echo "Using AWS profile: $AWS_PROFILE"

# Trigger AWS SSO login
echo "Logging in with AWS SSO..."
aws sso login --profile "$AWS_PROFILE"
if [ $? -ne 0 ]; then
  echo "SSO login failed. Exiting."
  exit 1
fi

# Initialize outputs
echo "[]" > "$JSON_OUTPUT"
echo "cluster,namespace,pod_name,node_name,status,images" > "$CSV_OUTPUT"

# Get list of EKS clusters
clusters=$(aws eks list-clusters --profile "$AWS_PROFILE" --query "clusters[]" --output text)

# Loop through clusters
for cluster in $clusters; do
  echo "Fetching pods for cluster: $cluster"

  # Update kubeconfig
  aws eks update-kubeconfig --name "$cluster" --profile "$AWS_PROFILE"

  # Get pod data as JSON array
  pod_data=$(kubectl get pods --all-namespaces -o json | jq --arg cluster "$cluster" '[.items[] | {
    cluster: $cluster,
    namespace: .metadata.namespace,
    pod_name: .metadata.name,
    node_name: .spec.nodeName,
    status: .status.phase,
    images: [.spec.containers[].image] | join(";")
  }]')

  # Merge into JSON output
  tmp_file=$(mktemp)
  jq --argjson newData "$pod_data" '. + $newData' "$JSON_OUTPUT" > "$tmp_file" && mv "$tmp_file" "$JSON_OUTPUT"

  # Append to CSV output
  echo "$pod_data" | jq -r '.[] | [
    .cluster,
    .namespace,
    .pod_name,
    .node_name,
    .status,
    .images
  ] | @csv' >> "$CSV_OUTPUT"

  echo "✅ Added $cluster data to JSON and CSV."
done

echo "🎉 Inventory complete!"
echo "📄 JSON: $JSON_OUTPUT"
echo "📄 CSV : $CSV_OUTPUT"
