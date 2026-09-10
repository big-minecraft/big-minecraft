# Choosing your Environment

> The installation process will proceed assuming you wish to use BMC's cluster installation system.
> If you already have an cluster that meets the previously defined requirements, you may skip to [INSERT]

BMC's cluster installation system currently supports the following environments:

- Bare-metal (Linux machines)
- [Amazon EKS](https://aws.amazon.com/eks/)
- [Google GKE](https://cloud.google.com/kubernetes-engine)
- [Azure AKS](https://azure.microsoft.com/en-us/products/kubernetes-service)

## Comparison
Each environment comes with different minimum costs. While cloud environment costs tend to be too high to be feasible for smaller networks, keep in mind that a bulk of these costs are from minimal options. This means costs will increase at a significantly lower rate when scaling up. In other words, the larger your network, the more cloud compute becomes an economical choice.

| Environment | Auto-scaling | Minimum cost |
|---|---|---|
| **Bare-metal** | No | Your hardware and bandwidth only |
| **Amazon EKS** | Yes | ~$468/mo |
| **Google GKE** | Yes | ~$615/mo (~$270 zonal) |
| **Azure AKS** | Yes | ~$325/mo |

Every install guide has a full **Cost** breakdown and the levers that move it.
While **running bare-metal will almost always be the cheapest option for your network**, the tradeoff of auto-scaling is quite benefitial for networks with heavily fluctuating player counts.

## Next Steps
Once you have chosen your install environment, continue to the cooresponding environment-specific install guide.

[Bare-metal](baremetal-install.md){ .md-button .md-button--primary }
[Amazon EKS](eks-install.md){ .md-button }
[Google GKE](gke-install.md){ .md-button }
[Azure AKS](aks-install.md){ .md-button }
