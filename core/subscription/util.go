package subscription

import (
	"crypto/rand"
	"encoding/hex"
)

func shortID() string {
	b := make([]byte, 4)
	rand.Read(b)
	return hex.EncodeToString(b)
}
