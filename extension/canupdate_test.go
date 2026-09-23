package extension

import "testing"

func TestCanUpdateInPlace(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name                                 string
		curImg, wantImg, curVer, wantVer     string
		ok                                   bool
	}{
		{"version only", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.35.8", "v1.36.4", true},
		{"same version", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.36.4", "v1.36.4", false},
		{"image changed", "ubuntu-24.04-amd64", "ubuntu-22.04-amd64", "v1.35.8", "v1.36.4", false},
		{"empty image", "", "ubuntu-24.04-amd64", "v1.35.8", "v1.36.4", false},
		{"empty desired ver", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.35.8", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := CanUpdateInPlace(tc.curImg, tc.wantImg, tc.curVer, tc.wantVer)
			if got != tc.ok {
				t.Fatalf("got %v want %v", got, tc.ok)
			}
		})
	}
}
