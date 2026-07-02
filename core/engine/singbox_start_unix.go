//go:build darwin || linux

package engine

import (
	"fmt"
	"os"
	"os/exec"
)

// startSingBoxCmd launches sing-box with a pipe sentinel that kills it if the parent dies.
func startSingBoxCmd(singboxBin, configPath, workDir string) (*exec.Cmd, *os.File, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, fmt.Errorf("create pipe: %w", err)
	}

	// 父进程死亡看门狗：fd 3 收到 EOF（父进程退出→写端关闭）时 kill 自身。
	// 路径经 cmd.Env 以环境变量传入、脚本内用双引号引用，绝不拼进命令串——
	// 否则含单引号的路径会破引号结构造成命令注入（daemon 以 root 运行放大后果）。
	wrapper := `(read <&3; kill $$) & exec 3>&- "$SB" run -c "$CFG" -D "$WD"`

	cmd := exec.Command("sh", "-c", wrapper)
	cmd.Env = append(os.Environ(),
		"SB="+singboxBin,
		"CFG="+configPath,
		"WD="+workDir,
	)
	cmd.ExtraFiles = []*os.File{r}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return nil, nil, fmt.Errorf("start sing-box: %w", err)
	}

	r.Close()
	return cmd, w, nil
}
