//go:build linux

package engine

func platformSingBoxCandidates() []string {
	return []string{
		"/usr/bin/sing-box",
		"/usr/local/bin/sing-box",
	}
}
