package config

import "encoding/json"

// oldToNewKey 是旧比喻命名 JSON key → 新正式命名 key 的映射表。
//
// 仅对“精确 key 名”做重写，不做任何子串替换 —— 因此 Line 内部的复合字段
// （trojan_port / ss_port / vmess_port 等，虽含 "port" 子串）绝不会被误伤，
// 它们的完整 key 名不在本表中。
//
// 覆盖的旧 key（出现在 Profile 顶层、Subscription 内嵌、Mode / RuleBinding 内）：
//
//	ports            → lines            (Profile 顶层、Subscription 内嵌)
//	cargoes          → rule_sets        (Profile 顶层)
//	cruises          → modes            (Profile 顶层)
//	active_cruise_id → active_mode_id   (Profile 顶层)
//	default_port_id  → default_line_id  (Mode 内)
//	cargo_id         → rule_set_id      (RuleBinding 内)
//	port_id          → line_id          (RuleBinding 内)
//
// 注意 default_port_id 必须先于 port_id 判定，但因为这里是按 key 全等匹配、
// 一个 key 只会命中一项，二者互不干扰。
var oldToNewKey = map[string]string{
	"ports":            "lines",
	"cargoes":          "rule_sets",
	"cruises":          "modes",
	"active_cruise_id": "active_mode_id",
	"default_port_id":  "default_line_id",
	"cargo_id":         "rule_set_id",
	"port_id":          "line_id",
}

// normalizeProfileKeys 把一段 profile JSON 里的旧比喻 key 递归重写为新 key，
// 返回规范化后的 JSON。若输入已是新格式，重写是幂等无副作用的（没有旧 key 命中）。
//
// 递归覆盖对象与数组的每一层，保证 Subscription 内嵌的 "ports"、Mode 的
// "bindings" 数组里每个 RuleBinding 的 "cargo_id"/"port_id" 都被处理到。
// 重写仅换 key 名，value 原样保留（对 value 继续递归）。
func normalizeProfileKeys(data []byte) ([]byte, error) {
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, err
	}
	rewriteKeys(v)
	return json.Marshal(v)
}

// rewriteKeys 就地递归重写 map 的 key。对数组逐元素递归。
// 对新旧 key 同时存在的极端情况（不应出现在真实数据里），新 key 值优先保留，
// 旧 key 被丢弃，避免 key 冲突时行为不确定。
func rewriteKeys(v interface{}) {
	switch node := v.(type) {
	case map[string]interface{}:
		for oldKey, newKey := range oldToNewKey {
			val, hasOld := node[oldKey]
			if !hasOld {
				continue
			}
			if _, hasNew := node[newKey]; !hasNew {
				node[newKey] = val
			}
			delete(node, oldKey)
		}
		for _, child := range node {
			rewriteKeys(child)
		}
	case []interface{}:
		for _, child := range node {
			rewriteKeys(child)
		}
	}
}
