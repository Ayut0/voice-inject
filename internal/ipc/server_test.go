package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"voice-inject/internal/logging"
)

func startTestServer(t *testing.T, handle Handler, onShutdown func()) (*Server, *Bus, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sock")
	bus := NewBus()
	if handle == nil {
		handle = func(cmd Command) (Response, bool) {
			return ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
		}
	}
	if onShutdown == nil {
		onShutdown = func() {}
	}
	srv := NewServer(path, bus, handle, onShutdown, logging.New(os.Stderr))
	if err := srv.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	return srv, bus, path
}

func dialAndRead(t *testing.T, path string) (net.Conn, *bufio.Scanner) {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	return conn, bufio.NewScanner(conn)
}

func TestServerDeliversEventsToClient(t *testing.T) {
	_, bus, path := startTestServer(t, nil, nil)
	_, sc := dialAndRead(t, path)

	// Give the server a moment to register the subscription.
	time.Sleep(50 * time.Millisecond)
	bus.Publish(StateEvent(EventRecording))

	if !sc.Scan() {
		t.Fatalf("no line received: %v", sc.Err())
	}
	if got, want := sc.Text(), `{"type":"event","name":"recording"}`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestServerDispatchesCommandsAndSkipsMalformedLines(t *testing.T) {
	handle := func(cmd Command) (Response, bool) {
		if cmd.Name == CmdStatus {
			return OKResponse(cmd.ID, map[string]string{"state": "idle", "version": "test"}), false
		}
		return ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
	}
	_, _, path := startTestServer(t, handle, nil)
	conn, sc := dialAndRead(t, path)

	// A malformed line, then a real command: the bad line must be
	// skipped without dropping the connection.
	fmt.Fprintf(conn, "this is not json\n")
	fmt.Fprintf(conn, `{"type":"cmd","id":7,"name":"status"}`+"\n")

	if !sc.Scan() {
		t.Fatalf("no response: %v", sc.Err())
	}
	var resp Response
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		t.Fatalf("bad response json: %v", err)
	}
	if resp.ID != 7 || !resp.OK {
		t.Errorf("resp = %+v, want id=7 ok=true", resp)
	}
}

func TestServerUnknownCommandReturnsError(t *testing.T) {
	_, _, path := startTestServer(t, nil, nil)
	conn, sc := dialAndRead(t, path)

	fmt.Fprintf(conn, `{"type":"cmd","id":3,"name":"bogus"}`+"\n")
	if !sc.Scan() {
		t.Fatalf("no response: %v", sc.Err())
	}
	if !strings.Contains(sc.Text(), `"ok":false`) {
		t.Errorf("want ok:false, got %q", sc.Text())
	}
}

func TestServerRemovesStaleSocket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stale.sock")
	// Simulate a crash leftover: bind and abandon without cleanup.
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	ln.Close() // Close() on unix sockets removes the file...
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err) // ...so recreate a plain file at that path instead.
	}

	bus := NewBus()
	srv := NewServer(path, bus, func(cmd Command) (Response, bool) {
		return ErrResponse(cmd.ID, "x"), false
	}, func() {}, logging.New(os.Stderr))
	if err := srv.Start(); err != nil {
		t.Fatalf("Start over stale socket: %v", err)
	}
	defer srv.Close()

	if _, err := net.Dial("unix", path); err != nil {
		t.Errorf("dial after stale rebind: %v", err)
	}
}

func TestServerShutdownCommand(t *testing.T) {
	shutdownCalled := make(chan struct{})
	handle := func(cmd Command) (Response, bool) {
		if cmd.Name == CmdShutdown {
			return OKResponse(cmd.ID, nil), true
		}
		return ErrResponse(cmd.ID, "unknown"), false
	}
	_, _, path := startTestServer(t, handle, func() { close(shutdownCalled) })
	conn, sc := dialAndRead(t, path)

	fmt.Fprintf(conn, `{"type":"cmd","id":9,"name":"shutdown"}`+"\n")

	// The response must arrive BEFORE the shutdown callback fires.
	if !sc.Scan() {
		t.Fatalf("no shutdown response: %v", sc.Err())
	}
	if !strings.Contains(sc.Text(), `"ok":true`) {
		t.Errorf("want ok:true, got %q", sc.Text())
	}
	select {
	case <-shutdownCalled:
	case <-time.After(2 * time.Second):
		t.Error("onShutdown was not called")
	}
}

// TestServerConcurrentPublishAndDisconnectStress exercises the race that
// Bug 1 lived in: the event forwarder can be mid-select (about to send
// on the per-connection out channel) at the exact moment the connection
// tears down and out is closed. Before the fix, closing done did not
// guarantee the forwarder had already exited before out was closed, so
// this race could panic with "send on closed channel" and crash the
// whole daemon process. Run with -race (and ideally -count=N) to build
// confidence there is no flake.
func TestServerConcurrentPublishAndDisconnectStress(t *testing.T) {
	_, bus, path := startTestServer(t, nil, nil)

	runtime.GC()
	time.Sleep(20 * time.Millisecond)
	baseline := runtime.NumGoroutine()

	const iterations = 100
	for i := 0; i < iterations; i++ {
		conn, err := net.Dial("unix", path)
		if err != nil {
			t.Fatalf("iteration %d: dial: %v", i, err)
		}

		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			bus.Publish(StateEvent(EventRecording))
		}()
		go func() {
			defer wg.Done()
			conn.Close()
		}()
		wg.Wait()
	}

	// A crash (panic) anywhere above would already have failed the
	// test process. As a secondary sanity check, confirm the server
	// eventually cleans up every one of these short-lived connections
	// rather than leaking their goroutines.
	deadline := time.Now().Add(5 * time.Second)
	for {
		runtime.GC()
		n := runtime.NumGoroutine()
		if n <= baseline+2 { // small tolerance for background runtime activity
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines did not settle after stress loop: baseline=%d have=%d", baseline, n)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestServerHungClientTriggersWriteTimeoutAndCleansUp verifies the fix
// for Bug 2: a client that stops reading must not permanently wedge the
// server. Before the fix, the reader's response send (out <- respLine)
// had no escape once out's buffer filled from a stalled writer, so the
// reader goroutine, its bus subscription, and conn were never cleaned
// up. Here we never read from the client side and flood the bus with
// events until the server's write deadline fires, then confirm the
// per-connection goroutines (writer, forwarder, reader) exit and the
// bus subscription is released, observed via the process's goroutine
// count returning to baseline.
func TestServerHungClientTriggersWriteTimeoutAndCleansUp(t *testing.T) {
	_, bus, path := startTestServer(t, nil, nil)

	runtime.GC()
	time.Sleep(20 * time.Millisecond)
	baseline := runtime.NumGoroutine()

	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	// Deliberately never read from conn from here on: this simulates a
	// hung/buggy client and is the whole point of the test.

	// Give the server a moment to register the subscription, then
	// flood the bus so the per-connection out channel (and the kernel
	// socket buffer, since nothing drains it) both fill, forcing the
	// server's next conn.Write to block until the write deadline
	// fires.
	time.Sleep(50 * time.Millisecond)
	for i := 0; i < 20000; i++ {
		bus.Publish(StateEvent(EventRecording))
	}

	deadline := time.Now().Add(writeTimeout + 5*time.Second)
	for {
		runtime.GC()
		if n := runtime.NumGoroutine(); n <= baseline+2 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("goroutines did not return to baseline (%d) after write timeout: have %d", baseline, runtime.NumGoroutine())
		}
		time.Sleep(50 * time.Millisecond)
	}
}
