  IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/build-push-tenant-images.sh
  IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/render-tenant-k8s.sh
  IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/deploy-tenant-k8s.sh
