// Command capi builds the Nearclip tailnet bridge as a C library: a static archive for the
// Apple apps (Swift), a shared library for Android (JNI, see jni.c) and Windows (P/Invoke),
// and a desktop shared library for the Kotlin/C# test harnesses.
//
// Every call returns a malloc'ed, NUL-terminated JSON status (bridge.Status) that the caller
// releases with NCTailnetFree. The JSON is pure ASCII (non-ASCII is \u-escaped), which keeps
// it valid "modified UTF-8" for JNI's NewStringUTF.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unicode/utf8"
	"unsafe"

	"nearclip.ivlis.studio/tailnet/bridge"
)

func main() {}

func ret(s bridge.Status) *C.char {
	b, err := json.Marshal(s)
	if err != nil {
		b = []byte(`{"state":"error","error":"marshal","peers":[]}`)
	}
	return C.CString(string(asciiJSON(b)))
}

func guard(f func() bridge.Status) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = ret(bridge.Status{State: "error", Error: fmt.Sprint("panic: ", r), Peers: []bridge.Peer{}})
		}
	}()
	return ret(f())
}

//export NCTailnetStart
func NCTailnetStart(config *C.char) *C.char {
	js := C.GoString(config)
	return guard(func() bridge.Status {
		var c bridge.Config
		if err := json.Unmarshal([]byte(js), &c); err != nil {
			return bridge.Status{State: "error", Error: "bad config: " + err.Error(), Peers: []bridge.Peer{}}
		}
		return bridge.Start(c)
	})
}

//export NCTailnetStatus
func NCTailnetStatus() *C.char { return guard(bridge.CurrentStatus) }

//export NCTailnetLogin
func NCTailnetLogin() *C.char { return guard(bridge.Login) }

//export NCTailnetLogout
func NCTailnetLogout() *C.char { return guard(bridge.Logout) }

//export NCTailnetStop
func NCTailnetStop() *C.char { return guard(bridge.Stop) }

//export NCTailnetSetNetwork
func NCTailnetSetNetwork(info *C.char) *C.char {
	js := C.GoString(info)
	return guard(func() bridge.Status {
		s := bridge.CurrentStatus()
		if err := bridge.SetNetwork([]byte(js)); err != nil {
			s.Error = err.Error()
		}
		return s
	})
}

//export NCTailnetNetworkChanged
func NCTailnetNetworkChanged() {
	defer func() { recover() }()
	bridge.NetworkChanged()
}

//export NCTailnetFree
func NCTailnetFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// asciiJSON escapes every non-ASCII rune of a JSON document as \uXXXX (UTF-16, with surrogate
// pairs). Non-ASCII bytes only occur inside JSON strings, where the escape is equivalent.
func asciiJSON(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for len(b) > 0 {
		if b[0] < utf8.RuneSelf {
			out = append(out, b[0])
			b = b[1:]
			continue
		}
		r, n := utf8.DecodeRune(b)
		b = b[n:]
		if r >= 0x10000 {
			r -= 0x10000
			out = fmt.Appendf(out, "\\u%04x\\u%04x", 0xD800+(r>>10), 0xDC00+(r&0x3FF))
		} else {
			out = fmt.Appendf(out, "\\u%04x", r)
		}
	}
	return out
}
