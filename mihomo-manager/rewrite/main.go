// Merge a Mihomo policy import into the device's working gateway configuration.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"gopkg.in/yaml.v3"
)

const maxSize = 1 << 20

func document(data []byte) (*yaml.Node, error) {
	if len(data) > maxSize {
		return nil, errors.New("配置超过 1 MB")
	}
	d := yaml.NewDecoder(bytes.NewReader(data))
	var doc yaml.Node
	if err := d.Decode(&doc); err != nil {
		return nil, err
	}
	if err := d.Decode(new(yaml.Node)); err != io.EOF {
		return nil, errors.New("每次只能导入一份 YAML 文档")
	}
	// The decoder checks duplicate keys, recursive aliases and excessive expansion.
	if err := doc.Decode(new(any)); err != nil {
		return nil, err
	}
	return doc.Content[0], nil
}

// Detach references to anchors that may be outside an imported policy section.
// Keep scalar spelling, quoting and comments, including numeric-looking passwords.
func detached(n *yaml.Node, budget *int) (*yaml.Node, error) {
	*budget -= 1 + len(n.Value) + len(n.HeadComment) + len(n.LineComment) + len(n.FootComment)
	if *budget < 0 {
		return nil, errors.New("展开后的配置过大")
	}
	if n.Kind == yaml.AliasNode {
		return detached(n.Alias, budget)
	}
	out := *n
	out.Anchor = ""
	out.Content = nil
	for _, child := range n.Content {
		copy, err := detached(child, budget)
		if err != nil {
			return nil, err
		}
		out.Content = append(out.Content, copy)
	}
	return &out, nil
}

func rewrite(active, upload []byte) ([]byte, error) {
	base, err := document(active)
	if err != nil {
		return nil, fmt.Errorf("设备配置读取失败: %w", err)
	}
	if base.Kind != yaml.MappingNode {
		return nil, errors.New("设备配置必须是 YAML 映射")
	}
	src, err := document(upload)
	if err != nil {
		return nil, fmt.Errorf("导入的 YAML 无效: %w", err)
	}
	policy := make(map[string]yaml.Node)
	switch src.Kind {
	case yaml.MappingNode:
		if err := src.Decode(&policy); err != nil {
			return nil, err
		}
	case yaml.SequenceNode:
		policy["rules"] = *src
	default:
		return nil, errors.New("请输入 Mihomo 配置或 YAML 规则列表")
	}

	budget := maxSize
	base, err = detached(base, &budget)
	if err != nil {
		return nil, err
	}
	indices := make(map[string]int)
	for i := 0; i < len(base.Content); i += 2 {
		indices[base.Content[i].Value] = i + 1
	}
	found, changed := false, false
	budget = maxSize
	for _, key := range []string{"proxies", "proxy-providers", "proxy-groups", "rule-providers", "sub-rules", "rules"} {
		incoming, supplied := policy[key]
		if !supplied {
			continue
		}
		found = true
		n, err := detached(&incoming, &budget)
		if err != nil {
			return nil, err
		}
		if i, exists := indices[key]; exists {
			before, err := yaml.Marshal(base.Content[i])
			if err != nil {
				return nil, err
			}
			after, err := yaml.Marshal(n)
			if err != nil {
				return nil, err
			}
			if bytes.Equal(before, after) {
				continue
			}
			base.Content[i] = n
		} else {
			base.Content = append(base.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, n)
		}
		changed = true
	}
	if !found {
		return nil, errors.New("配置中没有节点、策略组或规则")
	}
	if !changed {
		return active, nil
	}
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(base); err != nil {
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	if buf.Len() > maxSize {
		return nil, errors.New("合并后的配置超过 1 MB")
	}
	return buf.Bytes(), nil
}

func run() error {
	if len(os.Args) != 2 {
		return errors.New("usage: rewrite-policy ACTIVE_CONFIG < IMPORT")
	}
	active, err := os.ReadFile(os.Args[1])
	if err != nil {
		return err
	}
	upload, err := io.ReadAll(io.LimitReader(os.Stdin, maxSize+1))
	if err != nil {
		return err
	}
	result, err := rewrite(active, upload)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(result)
	return err
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
