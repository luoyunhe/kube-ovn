package ovs

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/alauda/kube-ovn/pkg/util"
)

// PodNameToPortName return the ovn port name for a given pod
func PodNameToPortName(pod, namespace, provider string) string {
	if provider == util.OvnProvider {
		return fmt.Sprintf("%s.%s", pod, namespace)
	}
	return fmt.Sprintf("%s.%s.%s", pod, namespace, provider)
}

func PodNameToLocalnetName(subnet string) string {
	return fmt.Sprintf("localnet.%s", subnet)
}

func trimCommandOutput(raw []byte) string {
	output := strings.TrimSpace(string(raw))
	return strings.Trim(output, "\"")
}

// ExpandExcludeIPs parse ovn exclude_ips to ip slice
func ExpandExcludeIPs(excludeIPs []string, cidr string) []string {
	rv := []string{}
	subnetNum := util.SubnetNumber(cidr)
	broadcast := util.SubnetBroadCast(cidr)
	for _, excludeIP := range excludeIPs {
		if strings.Index(excludeIP, "..") != -1 {
			parts := strings.Split(excludeIP, "..")
			s := util.Ip2BigInt(parts[0])
			e := util.Ip2BigInt(parts[1])
			for s.Cmp(e) <= 0 {
				ipStr := util.BigInt2Ip(s)
				if ipStr != subnetNum && ipStr != broadcast && util.CIDRContainIP(cidr, ipStr) && !util.ContainsString(rv, ipStr) {
					rv = append(rv, ipStr)
				}
				s.Add(s, big.NewInt(1))
			}
		} else {
			rv = append(rv, excludeIP)
		}
	}
	return rv
}
