## PisoFire typeshi 👟🔥

[Docker problems](https://docs.medusajs.com/learn/installation/docker)

[Storefront problems](https://docs.medusajs.com/resources/nextjs-starter)


# TODO

- [ ] - change the job, change the way the publishable key works





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

For M1 functional verification:

```bash
./scripts/smoke-test-k8s.sh
```

The M1 report draft is in [`docs/m1-report.md`](docs/m1-report.md).
The screenshot and evidence checklist is in [`docs/m1-evidence-checklist.md`](docs/m1-evidence-checklist.md).
