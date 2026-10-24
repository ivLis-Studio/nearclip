package main

import (
	"encoding/json"
	"testing"
)

func TestASCIIJSON(t *testing.T) {
	in, _ := json.Marshal(map[string]string{"a": "준서 📋 é", "b": "plain"})
	out := asciiJSON(in)
	for _, c := range out {
		if c >= 0x80 {
			t.Fatalf("non-ASCII byte in %s", out)
		}
	}
	var back map[string]string
	if err := json.Unmarshal(out, &back); err != nil || back["a"] != "준서 📋 é" || back["b"] != "plain" {
		t.Fatalf("round trip: %v %q", err, back)
	}
}
