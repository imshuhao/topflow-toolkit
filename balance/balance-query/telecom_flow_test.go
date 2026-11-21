package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseTelecomFlowUnlimitedChangxiang(t *testing.T) {
	raw := []byte(`{
  "flowInfo": {
    "commonFlow": {"balance": "31176319", "used": "280961"},
    "specialAmount": {"balance": "", "used": "6084460", "title": "已用专用流量"},
    "flowList": [
      {
        "title": "国内通用流量",
        "leftTitle": "已用", "leftTitleHh": "274.38MB",
        "rightTitle": "剩余", "rightTitleHh": "29.73GB", "rightTitleEnd": "/30GB"
      },
      {
        "title": "专用流量(畅享)",
        "leftTitle": "已用", "leftTitleHh": "5.80GB",
        "rightTitle": "", "rightTitleHh": "", "rightTitleEnd": ""
      },
      {
        "title": "专用流量(非畅享)",
        "leftTitle": "已用", "leftTitleHh": "0KB",
        "rightTitle": "剩余", "rightTitleHh": "70GB", "rightTitleEnd": "/70GB"
      }
    ]
  }
}`)
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil {
		t.Fatal(err)
	}
	general, directed := parseTelecomImportant(data, "", "")
	if !directed.Unlimited {
		t.Fatalf("expected directed unlimited (畅享), got %+v", directed)
	}
	wantUnlim := parseFlowToKB("5.80GB", "")
	if directed.UnlimitUsedKB != wantUnlim {
		t.Fatalf("unlimit used got %d want %d", directed.UnlimitUsedKB, wantUnlim)
	}
	wantDirRemain := parseFlowToKB("70GB", "")
	if directed.RemainKB != wantDirRemain {
		t.Fatalf("finite directed remain got %d want %d", directed.RemainKB, wantDirRemain)
	}
	wantDirTotal := parseFlowToKB("70GB", "")
	if directed.TotalKB != wantDirTotal {
		t.Fatalf("finite directed total got %d want %d (must not swallow 畅享 into total)", directed.TotalKB, wantDirTotal)
	}
	wantGenRemain := parseFlowToKB("29.73GB", "")
	if general.RemainKB != wantGenRemain {
		t.Fatalf("general remain got %d want %d", general.RemainKB, wantGenRemain)
	}
	wantGenTotal := parseFlowToKB("30GB", "")
	if general.TotalKB != wantGenTotal {
		t.Fatalf("general total got %d want %d", general.TotalKB, wantGenTotal)
	}
}

func TestParseTelecomFlowFromLocalCapture(t *testing.T) {
	path := filepath.Join("..", "_localtest", "telecom-flow.raw.json")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Skip("no local capture:", err)
	}
	var resp map[string]any
	if err := json.Unmarshal(b, &resp); err != nil {
		t.Fatal(err)
	}
	rd, _ := resp["responseData"].(map[string]any)
	data, _ := rd["data"].(map[string]any)
	if data == nil {
		t.Fatal("no data")
	}
	general, directed := parseTelecomImportant(data, "", "")
	if !directed.Unlimited {
		t.Fatalf("live capture should mark 畅享 unlimited: %+v", directed)
	}
	if directed.UnlimitUsedKB <= 0 {
		t.Fatalf("expected unlimit used > 0, got %d", directed.UnlimitUsedKB)
	}
	if directed.RemainKB <= 0 || general.RemainKB <= 0 {
		t.Fatalf("expected finite remain; gen=%+v dir=%+v", general, directed)
	}
}
