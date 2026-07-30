package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/engine"
	"github.com/kafeifei/xdial/core/subscription"
	"github.com/kafeifei/xdial/core/tailscalesetup"
)

// daemonExeHash 是本进程二进制在启动时刻的内容 hash。必须启动时算一次缓存住：
// SMAppService 模式下 daemon 从 app bundle 运行，重编后 bundle 里的文件已是新
// 内容，运行中的老进程若现读 os.Executable() 会拿到新文件的 hash，
// 「运行中的版本 == bundle 里的版本」永远为真，自愈更新就死了。
var daemonExeHash = "unknown"

func initDaemonExeHash() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	f, err := os.Open(exe)
	if err != nil {
		return
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return
	}
	daemonExeHash = fmt.Sprintf("%x", h.Sum(nil))
}

// shortDaemonExeHash 取日志用的短 hash。initDaemonExeHash 任一步失败时
// daemonExeHash 仍是 "unknown"（7 字节），直接切前 16 位会 panic 在启动路径上。
func shortDaemonExeHash() string {
	const shortLen = 16
	if len(daemonExeHash) < shortLen {
		return daemonExeHash
	}
	return daemonExeHash[:shortLen]
}

// respawnDaemon 用 bundle 里当前的二进制原地 re-exec。Go 的 net fd 全部
// O_CLOEXEC，exec 后旧 listener/连接自动关闭，新进程重建 socket；pid 不变，
// launchd 全程无感，不吃 ThrottleInterval。失败则退出交给 KeepAlive 兜底。
func respawnDaemon() {
	exe, err := os.Executable()
	if err == nil {
		slog.Info("respawning", "exe", exe)
		if err := syscall.Exec(exe, os.Args, os.Environ()); err != nil {
			slog.Error("re-exec failed, exiting for launchd restart", "err", err)
		}
	}
	os.Exit(0)
}

type daemonCallback struct {
	clients *ClientSet
}

func (d *daemonCallback) OnStatusChanged(statusJSON string) {
	slog.Info("status", "data", statusJSON)
	d.clients.BroadcastEvent(Event{Event: "status", Data: statusJSON})
}

func (d *daemonCallback) OnError(code int, message string) {
	slog.Error("engine", "code", code, "msg", message)
	d.clients.BroadcastEvent(Event{Event: "error", Data: message})
}

func runDaemon(socketPath string) {
	if isAlreadyRunning(socketPath) {
		slog.Info("another instance is already running, exiting")
		os.Exit(0)
	}

	initDaemonExeHash()

	basePath := filepath.Join(os.TempDir(), "xdial-engine")
	os.MkdirAll(basePath, 0700) // 内含明文节点密码的 sing-box.json，收紧目录权限
	statePath := filepath.Join("/Library", "Application Support", "XDial")
	if err := os.MkdirAll(statePath, 0700); err != nil {
		slog.Error("create state directory failed", "path", statePath, "err", err)
		os.Exit(1)
	}

	clients := NewClientSet()
	cb := &daemonCallback{clients: clients}
	eng := engine.New(basePath, statePath, cb)
	networkStatePath := networkExtensionStatePath(statePath)
	if err := tailscalesetup.PreparePersistentState(
		statePath,
		networkStatePath,
	); err != nil {
		slog.Error(
			"prepare shared Tailscale state failed",
			"path",
			networkStatePath,
			"err",
			err,
		)
		os.Exit(1)
	}
	tailscaleSetup := tailscalesetup.New(networkStatePath)
	var networkRuntimeMu sync.Mutex
	// daemon 是唯一有资格接管系统 DNS 的宿主：它由 launchd KeepAlive 托管，被
	// SIGKILL 后会被拉起并立刻跑下面的 RestoreLeftoverDNS 自愈。
	eng.AllowSystemDNSTakeover(true)

	// 上次没恢复干净的系统 DNS 会让整机解析停在死 tun 上。必须在开始 accept 之前
	// 自愈：这条路径就是 launchd KeepAlive 把被 SIGKILL 的 daemon 拉起来后的补救。
	//
	// 也必须排在 killOrphanSingBox 之前：残留场景下那个孤儿 sing-box 还在真正服务
	// DNS（系统 DNS 指着它的 tun），先杀再恢复中间就是一整段谁都答不了查询的断网
	// 窗口。反向没有依赖倒置：恢复只发 networksetup / dscacheutil，纯本地 IPC，不
	// 依赖解析、不依赖数据面、也不依赖 socket 已监听。
	eng.RestoreLeftoverDNS()

	// 启动自愈只跑一次，救不回来的软失败条目（服务还在、只是当前被禁用）会一直留在状态
	// 文件里。daemon 由 launchd KeepAlive 托管，可能几星期都不重启一次，中间用户把那块
	// 网卡重新启用的话，它就带着一个指向已消失 tun 的 DNS 上线，而没有任何路径去救它。
	// 周期自愈补的就是这一段：没有残留文件时一个 tick 只花一次 stat，零成本。
	// 退出时由 eng.Close() 收摊。
	eng.StartDNSSelfHeal()

	killOrphanSingBox()

	os.Remove(socketPath)
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		slog.Error("listen failed", "path", socketPath, "err", err)
		os.Exit(1)
	}
	// 之前 0666 且无任何校验：任意本地用户/进程都能指挥这个 root daemon（含 parse-sub
	// 让 root 抓取任意 URL）。授权改由每个连接的对端凭据决定（peerAllowed），只放行 root
	// 和当前登录用户；用文件权限做校验会碰上"开机 daemon 先于登录启动、此刻拿不到 console
	// 用户"的时序问题，而 peerAllowed 在连接发生时（已登录）才判断，天然避开该竞态。
	os.Chmod(socketPath, 0666)

	slog.Info("daemon started", "socket", socketPath, "pid", os.Getpid(), "exe_sha256", shortDaemonExeHash())

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			if !peerAllowed(conn) {
				slog.Warn("rejected unauthorized socket peer")
				conn.Close()
				continue
			}
			go handleClient(conn, eng, tailscaleSetup, &networkRuntimeMu, clients)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	slog.Info("shutting down")
	// Stop 内部会先恢复系统 DNS 再停数据面，关机路径的 DNS 工作量到此封顶在一份预算
	// （15 秒）之内。故意不再补一次 RestoreLeftoverDNS：launchd 从 SIGTERM 到 SIGKILL
	// 只给 20 秒宽限，再叠一份预算最坏会被 SIGKILL 打断在半路——那比不做更糟（有可能
	// 停在"一半服务已恢复、另一半刚被改动"的中间态）。恢复只成功一部分的场景交给启动
	// 自愈：状态文件还在（restoreLocked 会把已恢复的条目剔掉、只留没救回来的），
	// launchd KeepAlive 把 daemon 拉起来后第一件事就是 RestoreLeftoverDNS。
	networkRuntimeMu.Lock()
	_ = tailscaleSetup.Stop()
	eng.Stop()
	networkRuntimeMu.Unlock()
	// 后台恢复重试到这里没有意义了：要么已经恢复成功，要么状态文件还在、下次启动
	// 的 RestoreLeftoverDNS 会接着救。
	eng.Close()
	ln.Close()
	os.Remove(socketPath)
}

func isAlreadyRunning(socketPath string) bool {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func handleClient(
	conn net.Conn,
	eng *engine.Engine,
	tailscaleSetup *tailscalesetup.Manager,
	networkRuntimeMu *sync.Mutex,
	clients *ClientSet,
) {
	client := NewClient(conn)
	clients.Add(client)
	defer func() {
		clients.Remove(client)
		client.Close()
	}()

	client.SendEvent(Event{Event: "status", Data: eng.Status()})

	reqCh := make(chan Request)
	go ReadRequests(conn, reqCh)

	for req := range reqCh {
		switch req.Cmd {
		case "start":
			profile, err := config.ParseProfile([]byte(req.Profile))
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: "invalid profile: " + err.Error()})
				continue
			}
			networkRuntimeMu.Lock()
			setupErr := tailscaleSetup.Stop()
			var startErr error
			if setupErr == nil {
				startErr = preflightTailscale(profile, req.Profile, tailscaleSetup)
			}
			if setupErr == nil && startErr == nil {
				startErr = eng.Start(profile)
			}
			networkRuntimeMu.Unlock()
			if setupErr != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: setupErr.Error()})
			} else if startErr != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: startErr.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true})
			}

		case "stop":
			networkRuntimeMu.Lock()
			err := eng.Stop()
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true})
			}

		case "kill-session":
			eng.KillSession()
			client.SendResponse(Response{ID: req.ID, OK: true})

		case "status":
			client.SendResponse(Response{ID: req.ID, OK: true, Data: eng.Status()})

		case "daemon-info":
			data, _ := json.Marshal(struct {
				Version   string `json:"version"`
				ExeSHA256 string `json:"exe_sha256"`
				PID       int    `json:"pid"`
			}{Version: version, ExeSHA256: daemonExeHash, PID: os.Getpid()})
			client.SendResponse(Response{ID: req.ID, OK: true, Data: string(data)})

		case "connection-report":
			data, err := readProviderConnectionReport()
			if err != nil {
				client.SendResponse(Response{
					ID:      req.ID,
					OK:      false,
					Message: err.Error(),
				})
			} else {
				client.SendResponse(Response{
					ID:   req.ID,
					OK:   true,
					Data: string(data),
				})
			}

		case "respawn":
			// 仅在引擎空闲时允许：re-exec 后 killOrphanSingBox 会扫掉数据面，
			// 连接中 respawn 等于静默断流。app 侧本就只在断开时发，这里兜底。
			var st struct {
				Status string `json:"status"`
			}
			if json.Unmarshal([]byte(eng.Status()), &st) == nil && st.Status != "disconnected" {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: "engine busy: " + st.Status})
				continue
			}
			networkRuntimeMu.Lock()
			if err := tailscaleSetup.Stop(); err != nil {
				networkRuntimeMu.Unlock()
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
				continue
			}
			client.SendResponse(Response{ID: req.ID, OK: true})
			slog.Info("respawn requested")
			networkRuntimeMu.Unlock()
			respawnDaemon()

		case "parse-sub":
			result, err := subscription.Parse(req.SubURL, req.SubContent, req.SubFormat)
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				subscription.ExpandRulesets(result)
				data, _ := json.Marshal(result)
				client.SendResponse(Response{ID: req.ID, OK: true, Data: string(data)})
			}

		case "runtime-lines":
			profile, err := config.ParseProfile([]byte(req.Profile))
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: "invalid profile: " + err.Error()})
			} else {
				data, _ := json.Marshal(config.BuildLineRuntimeCatalog(profile))
				client.SendResponse(Response{ID: req.ID, OK: true, Data: string(data)})
			}

		case "tailscale-prepare":
			networkRuntimeMu.Lock()
			if status := engineStatus(eng); status != "disconnected" {
				networkRuntimeMu.Unlock()
				req.AuthKey = ""
				client.SendResponse(Response{ID: req.ID, OK: false, Message: "disconnect XDial before configuring Tailscale"})
				continue
			}
			data, err := tailscaleSetup.Prepare(req.Profile, req.LineID, req.AuthKey)
			req.AuthKey = ""
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true, Data: data})
			}

		case "tailscale-status":
			networkRuntimeMu.Lock()
			data, err := tailscaleSetup.Status(req.LineID)
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true, Data: data})
			}

		case "tailscale-login":
			networkRuntimeMu.Lock()
			data, err := tailscaleSetup.BeginLogin(req.LineID)
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true, Data: data})
			}

		case "tailscale-logout":
			networkRuntimeMu.Lock()
			data, err := tailscaleSetup.Logout(req.LineID)
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true, Data: data})
			}

		case "tailscale-stop-setup":
			networkRuntimeMu.Lock()
			err := tailscaleSetup.StopLine(req.LineID)
			networkRuntimeMu.Unlock()
			if err != nil {
				client.SendResponse(Response{ID: req.ID, OK: false, Message: err.Error()})
			} else {
				client.SendResponse(Response{ID: req.ID, OK: true})
			}

		default:
			client.SendResponse(Response{ID: req.ID, OK: false, Message: "unknown command: " + req.Cmd})
		}
	}
}

func engineStatus(eng *engine.Engine) string {
	var status struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(eng.Status()), &status); err != nil {
		return "unknown"
	}
	return status.Status
}

func preflightTailscale(
	profile *config.Profile,
	profileJSON string,
	setup *tailscalesetup.Manager,
) error {
	line, err := config.ActiveTailscaleLine(profile)
	if err != nil || line == nil {
		return err
	}
	rawStatus, err := setup.Prepare(profileJSON, line.ID, "")
	if err != nil {
		return err
	}
	statusErr := validateTailscalePreflightStatus(line, rawStatus)
	stopErr := setup.Stop()
	if statusErr != nil {
		return statusErr
	}
	if stopErr != nil {
		return fmt.Errorf("Tailscale setup could not stop: %w", stopErr)
	}
	return nil
}

func validateTailscalePreflightStatus(line *config.Line, rawStatus string) error {
	var status struct {
		BackendState string `json:"backend_state"`
		ExitNodes    []struct {
			IP     string `json:"ip"`
			Online bool   `json:"online"`
		} `json:"exit_nodes"`
	}
	if err := json.Unmarshal([]byte(rawStatus), &status); err != nil {
		return fmt.Errorf("Tailscale status is invalid")
	}
	if status.BackendState != "Running" {
		return fmt.Errorf("Tailscale sign-in is required")
	}
	if line.TailscaleExitNode == "" {
		return nil
	}
	for _, node := range status.ExitNodes {
		if node.IP != line.TailscaleExitNode {
			continue
		}
		if !node.Online {
			return fmt.Errorf("selected Tailscale exit node is offline")
		}
		return nil
	}
	return fmt.Errorf("selected Tailscale exit node is unavailable")
}
