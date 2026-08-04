# What is needed
***

Currently acces to private endpoints work through wireguard. The problem is that it can't resolve private k8s services. There're multiple ways to solve this:

1. Point wireguard `DNS` to kube-dns which resolves services by full cluster domain `<resource-name>.<namespace>.svc.cluster.local`. While it's simply and robust solution - you have not control over what services are exposed, except namespaces and netework policies.
2. ExternalDNS + etcd + CoreDns - External DNS updates records in etcd, separate CoreDNS watches etcd and reconcill dns records. It seems that you can just use CoreDNS, but ExternalDNS may be use later for public endpoints.
3. CoreDNS - CoreDNS is lightweight solution of only about 100m cpus and 100mb, easily deployed without any crds. Even though, it's possible to reuse existing cluster CoreDNS, managed k8s cluster may later reconcil it, resulting in vanished config changes. Also it's just a bad practice to change cluster backing resource.

