//go:build !darwin

package main

func networkExtensionStatePath(fallback string) string {
	return fallback
}
