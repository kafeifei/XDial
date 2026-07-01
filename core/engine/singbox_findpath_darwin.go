//go:build darwin

package engine

func platformSingBoxCandidates() []string {
	return []string{
		"/opt/homebrew/bin/sing-box",
		"/usr/local/bin/sing-box",
	}
}
