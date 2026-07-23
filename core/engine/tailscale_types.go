package engine

type TailscaleExitNode struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	IP     string `json:"ip"`
	Online bool   `json:"online"`
	OS     string `json:"os,omitempty"`
}
