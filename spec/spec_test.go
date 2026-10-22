package spec_test

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	gtypes "github.com/onsi/gomega/types"
)

var _ = BeforeSuite(func() {
	_, filename, _, _ := runtime.Caller(0)
	KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))

	// Every genesis command probes the stub director, which refuses the
	// connection. Genesis arms a GENESIS_NETWORK_TIMEOUT alarm for that probe
	// and leaves it armed when the connect fails, so a command still running
	// when it fires dies with SIGALRM. The default of 10 seconds is shorter
	// than an ocfp check takes on a busy machine.
	if os.Getenv("GENESIS_NETWORK_TIMEOUT") == "" {
		os.Setenv("GENESIS_NETWORK_TIMEOUT", "600")
	}
})

// refused matches the combined output of a genesis command that printed the
// given message and then exited non-zero. testkit appends
// "process: '<command>' exited with: <code>" to that output. Genesis wraps
// long messages to the terminal width, so each space in the message matches
// any run of whitespace, line breaks and indentation included.
func refused(message string) gtypes.GomegaMatcher {
	words := strings.Fields(message)
	for i, word := range words {
		words[i] = regexp.QuoteMeta(word)
	}
	return And(
		MatchRegexp(strings.Join(words, `\s+`)),
		MatchRegexp(`exited with: [1-9][0-9]*\n`),
	)
}

var _ = Describe("Garage Kit", func() {

	Describe("standalone", func() {
		Test(Environment{
			Name:        "base",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "cluster",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "cluster-ips",
			CloudConfig: "aws",
			CPI:         "aws",
		})
	})

	// The check hook refuses a cluster shape that loses data, and compares
	// each deploy with the exodus data the last one recorded. Only check
	// refuses, so add-secrets and the manifest still succeed.
	Describe("cluster shape", func() {
		Test(Environment{
			Name:           "rf1-cluster",
			CloudConfig:    "aws",
			CPI:            "aws",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("is 1 on a cluster of 3 nodes")},
		})
		Test(Environment{
			Name:        "rf1-cluster-allowed",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:           "rf-exceeds-instances",
			CloudConfig:    "aws",
			CPI:            "aws",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("deploys only 1 garage instance")},
		})
		Test(Environment{
			Name:           "rf-change",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "rf-change",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("would change from 1 to 3")},
		})
		Test(Environment{
			Name:           "legacy-exodus",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "legacy-exodus",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("did not record the replication factor")},
		})
		Test(Environment{
			Name:           "scale-down",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "scale-down",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("would drop from 3 to 2")},
		})
		Test(Environment{
			Name:        "scale-down-allowed",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "scale-down-allowed",
		})
		Test(Environment{
			Name:        "scale-down-drains",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "scale-down-drains",
		})
		Test(Environment{
			Name:           "scale-down-parallel",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "scale-down-parallel",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("updates instances in parallel")},
		})
		Test(Environment{
			Name:        "scale-down-parallel-turns",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "scale-down-parallel-turns",
		})
		Test(Environment{
			Name:           "scale-down-parallel-degraded",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "scale-down-parallel-degraded",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("garage_consistency_mode is degraded")},
		})
		Test(Environment{
			Name:           "scale-below-rf",
			CloudConfig:    "aws",
			CPI:            "aws",
			Exodus:         "scale-below-rf",
			OutputMatchers: OutputMatchers{GenesisCheck: refused("cannot shrink below 3 nodes")},
		})
		Test(Environment{
			Name:        "scale-to-one",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "scale-to-one",
		})
		Test(Environment{
			Name:        "scale-out-rf1",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "scale-out-rf1",
		})
	})

	Describe("ocfp", func() {
		Test(Environment{
			Name:        "ocfp-mgmt",
			CloudConfig: "aws-ocfp",
			CPI:         "aws",
		})
	})

	Describe("resolute", func() {
		Test(Environment{
			Name:        "resolute",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "resolute-mgmt",
			CloudConfig: "aws-resolute-mgmt",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "resolute-route-registrar",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "resolute-route-registrar",
		})
		Test(Environment{
			Name:        "resolute-wrong-stemcell-os",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("stemcell os to"),
				GenesisCheck:      refused("stemcell os to"),
				GenesisManifest:   refused("stemcell os to"),
			},
		})
		Test(Environment{
			Name:        "resolute-stemcell-without-feature",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("Enable the feature and remove that parameter"),
				GenesisCheck:      refused("Enable the feature and remove that parameter"),
				GenesisManifest:   refused("Enable the feature and remove that parameter"),
			},
		})
	})
})
