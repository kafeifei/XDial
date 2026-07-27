package engine

type TailscaleExitNode struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	IP     string `json:"ip"`
	Online bool   `json:"online"`
	OS     string `json:"os,omitempty"`
}

// TailscaleStatus 是 UI 判断 Tailscale 卡片处于哪个状态所需的全部信息。
//
// LoggedIn 为 false 不是错误 —— 未登录是一个正常状态，UI 据此显示登录入口。
// 只有真的读不到状态时才返回 error。
type TailscaleStatus struct {
	LoggedIn bool `json:"logged_in"`
	// Account 是登录邮箱。tailnet 域名对个人账号是随机串（tail4a7f2c.ts.net），
	// 认不出是哪个账号，所以身份一律用邮箱展示。
	Account   string              `json:"account,omitempty"`
	Hostname  string              `json:"hostname,omitempty"`
	ExitNodes []TailscaleExitNode `json:"exit_nodes"`
}
