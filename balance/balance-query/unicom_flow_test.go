package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseUnicomFlowUnlimitedAli(t *testing.T) {
	raw := []byte(`{
  "unlimitExclusiveFeeIdSet": ["8767552"],
  "resources": [{
    "details": [
      {
        "feePolicyId": "8767552",
        "feePolicyName": "河南0元Ali系主要APP专属畅爽定向流量包",
        "limited": "1",
        "remain": "-6318.26",
        "resourceType": "I3",
        "total": "0.00",
        "use": "6318.26"
      },
      {
        "feePolicyId": "61063839",
        "feePolicyName": "河南赠送腾讯、抖音国内定向流量40G",
        "limited": "0",
        "remain": "40959.94",
        "resourceType": "13",
        "total": "40960.00",
        "use": "0.06"
      },
      {
        "feePolicyId": "62588840",
        "feePolicyName": "河南校园得15G国内定向流量",
        "limited": "0",
        "remain": "15360.00",
        "resourceType": "13",
        "total": "15360.00",
        "use": "0.00"
      },
      {
        "feePolicyId": "62579934",
        "feePolicyName": "河南沃派流量王39元套餐(首月全量全价)",
        "limited": "0",
        "remain": "20228.0",
        "resourceType": "01",
        "total": "20480.0",
        "use": "252.0"
      }
    ]
  }]
}`)
	general, directed, err := parseUnicomFlow(raw, "", "")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !directed.Unlimited {
		t.Fatalf("expected directed.Unlimited")
	}
	wantUnlim := kbMB(6318.26)
	if directed.UnlimitUsedKB != wantUnlim {
		t.Fatalf("unlimit used got %d want %d", directed.UnlimitUsedKB, wantUnlim)
	}
	// 有限定向 40G+15G，不把无限包的 0 total 算进去
	wantDirRemain := kbMB(40959.94 + 15360.00)
	wantDirTotal := kbMB(40960.00 + 15360.00)
	if directed.RemainKB != wantDirRemain {
		t.Fatalf("finite directed remain got %d want %d", directed.RemainKB, wantDirRemain)
	}
	if directed.TotalKB != wantDirTotal {
		t.Fatalf("finite directed total got %d want %d", directed.TotalKB, wantDirTotal)
	}
	wantGenRemain := kbMB(20228.0)
	if general.RemainKB != wantGenRemain {
		t.Fatalf("general remain got %d want %d", general.RemainKB, wantGenRemain)
	}
}

func kbMB(mb float64) int64 { return int64(mb*1024 + 0.5) }

func TestParseUnicomFlowFromLocalCapture(t *testing.T) {
	path := filepath.Join("..", "_localtest", "flow.raw.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skip("no local capture:", err)
	}
	general, directed, err := parseUnicomFlow(raw, "", "")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !directed.Unlimited {
		t.Fatalf("expected unlimited Ali pack in live capture")
	}
	if directed.UnlimitUsedKB <= 0 {
		t.Fatalf("expected unlimit used > 0, got %d", directed.UnlimitUsedKB)
	}
	if directed.TotalKB <= 0 || general.TotalKB <= 0 {
		t.Fatalf("expected finite buckets; gen=%+v dir=%+v", general, directed)
	}
}
