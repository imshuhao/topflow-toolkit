package main

import (
	"bytes"
	"gopkg.in/yaml.v3"
	"strings"
	"testing"
)

const active = "# gateway\ntun: {enable: true}\ndns: {listen: '0.0.0.0:53'}\nsecret: local\nmixed-port: 7890\nproxies: [{name: old}]\nrules: ['MATCH,DIRECT']\n"

func TestImport(t *testing.T) {
	for name, input := range map[string]string{
		"full": "dns: {enable: false}\ntun: {enable: false}\nsecret: imported\nmixed-port: 0\nanchor: &r ['MATCH,REJECT']\nrules: *r",
		"list": "['MATCH,REJECT']",
		"map":  "rules: ['MATCH,REJECT']",
	} {
		t.Run(name, func(t *testing.T) {
			b, err := rewrite([]byte(active), []byte(input))
			if err != nil {
				t.Fatal(err)
			}
			d, err := document(b)
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]any
			if err = d.Decode(&got); err != nil {
				t.Fatal(err)
			}
			if got["secret"] != "local" || got["mixed-port"] != 7890 ||
				got["tun"].(map[string]any)["enable"] != true || got["dns"].(map[string]any)["listen"] != "0.0.0.0:53" ||
				got["proxies"].([]any)[0].(map[string]any)["name"] != "old" || got["rules"].([]any)[0] != "MATCH,REJECT" {
				t.Fatal(got)
			}
			again, err := rewrite(b, []byte(input))
			if err != nil || !bytes.Equal(again, b) {
				t.Fatal("unstable rewrite", err)
			}
		})
	}
	for _, input := range []string{"", "dns: {}", "rules: [", "rules: []\nrules: [a]", "rules: []\n---\nrules: [a]", strings.Repeat("a", maxSize+1)} {
		if _, err := rewrite([]byte(active), []byte(input)); err == nil {
			t.Fatal("invalid import accepted")
		}
	}
	b, err := rewrite([]byte(active), []byte("rules: ['MATCH,DIRECT']"))
	if err != nil || string(b) != active {
		t.Fatal("unchanged YAML was modified")
	}
}

func TestProviderAliasesAndCredentialSpelling(t *testing.T) {
	in := "default: &d {type: http, password: 00123}\nproxies: [{<<: *d, name: new}]"
	b, err := rewrite([]byte(active), []byte(in))
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Proxies []struct{ Name, Type, Password string }
	}
	if err := yaml.Unmarshal(b, &parsed); err != nil {
		t.Fatal(err)
	}
	if len(parsed.Proxies) != 1 || parsed.Proxies[0].Password != "00123" || parsed.Proxies[0].Type != "http" {
		t.Fatal(parsed)
	}
}
