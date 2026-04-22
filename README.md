## PisoFire typeshi 👟🔥

[Docker problems](https://docs.medusajs.com/learn/installation/docker)

[Storefront problems](https://docs.medusajs.com/resources/nextjs-starter)

## Kubernetes Deploy

From the repo root, after you manually switch `kubectl` to the correct local test context:

```bash
./scripts/deploy-k8s.sh
```

The script:
- builds the Medusa and storefront images
- imports them into the `pisofire` `k3d` cluster
- refuses to run unless the current context is `k3d-pisofire`
- applies the manifests in `k8s/`
