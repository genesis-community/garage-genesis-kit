package spec_test

import (
	"path/filepath"
	"runtime"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	gtypes "github.com/onsi/gomega/types"
)

var _ = BeforeSuite(func() {
	_, filename, _, _ := runtime.Caller(0)
	KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))
})

// refused matches the combined output of a genesis command that printed the
// given message and then exited non-zero. testkit appends
// "process: '<command>' exited with: <code>" to that output.
func refused(message string) gtypes.GomegaMatcher {
	return And(
		ContainSubstring(message),
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
