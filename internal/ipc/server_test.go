package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
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
