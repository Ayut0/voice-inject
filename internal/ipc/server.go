package ipc

import (
	"bufio"
	"bytes"
	"errors"
	"io/fs"
	"net"
	"os"
	"sync"
	"time"

	"voice-inject/internal/logging"
)

// writeTimeout bounds how long a single conn.Write may take. A client
// that stops reading its socket (hung or buggy) would otherwise let
// conn.Write block forever, wedging this connection's writer goroutine
// and, transitively, its reader goroutine once the shared out channel
// fills. Once a write misses this deadline we treat the connection as
// dead and tear it down.
const writeTimeout = 3 * time.Second

// Handler processes one command and returns its response. shutdown=true
// instructs the server to invoke its onShutdown callback after the
// response has been written to the client.
type Handler func(cmd Command) (resp Response, shutdown bool)

// Server accepts Unix-socket clients, streams bus events to them, and
// dispatches their commands to a Handler.
type Server struct {
	path       string
	bus        *Bus
	handle     Handler
	onShutdown func()
	logger     *logging.Logger
	ln         net.Listener
}

func NewServer(path string, bus *Bus, handle Handler, onShutdown func(), logger *logging.Logger) *Server {
	return &Server{path: path, bus: bus, handle: handle, onShutdown: onShutdown, logger: logger}
}

// Start removes any stale socket file, binds, and accepts in the
// background until Close.
func (s *Server) Start() error {
	if err := os.Remove(s.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	ln, err := net.Listen("unix", s.path)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.path, 0o600); err != nil {
		ln.Close()
		return err
	}
	s.ln = ln
	go s.acceptLoop()
	return nil
}

func (s *Server) Close() error {
	if s.ln == nil {
		return nil
	}
	err := s.ln.Close()
	if rmErr := os.Remove(s.path); rmErr != nil && !errors.Is(rmErr, fs.ErrNotExist) {
		s.logger.Printf("[ipc] socket cleanup: %v", rmErr)
	}
	return err
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return // listener closed
		}
		go s.serveConn(conn)
	}
}

func (s *Server) serveConn(conn net.Conn) {
	defer conn.Close()

	subID, events := s.bus.Subscribe()
	defer s.bus.Unsubscribe(subID)

	out := make(chan []byte, 64)

	// stop is the single, once-only shutdown signal for this connection.
	// It is closed by whichever of the two paths below happens first:
	// the reader loop ending (EOF, read error, or a shutdown command),
	// or the writer hitting a conn.Write error/timeout (a hung or dead
	// client). Every goroutine that might otherwise block forever on
	// out selects on stop as an escape hatch, and out is only ever
	// closed after both the forwarder and the reader have confirmed
	// they will no longer send on it — so nothing can panic on a
	// send-on-closed-channel, and nothing can leak blocked forever.
	stop := make(chan struct{})
	var stopOnce sync.Once
	stopFn := func() { stopOnce.Do(func() { close(stop) }) }

	writerDone := make(chan struct{})
	forwarderDone := make(chan struct{})

	// Sole writer to conn: serializes events and responses. A write
	// deadline turns a hung client (one that stops reading) into a
	// timeout error instead of an indefinite block, which lets us
	// unstick the reader and forwarder via stop and unblock the
	// reader's in-flight conn.Read by closing conn.
	go func() {
		defer close(writerDone)
		for line := range out {
			conn.SetWriteDeadline(time.Now().Add(writeTimeout))
			if _, err := conn.Write(line); err != nil {
				stopFn()
				conn.Close() // unblock a reader parked in sc.Scan()
			}
		}
	}()

	// Event forwarder.
	go func() {
		defer close(forwarderDone)
		for {
			select {
			case <-stop:
				return
			case ev, ok := <-events:
				if !ok {
					return
				}
				line, err := EncodeLine(ev)
				if err != nil {
					s.logger.Printf("[ipc] encode event: %v", err)
					continue
				}
				select {
				case out <- line:
				case <-stop:
					return
				}
			}
		}
	}()

	// Reader loop.
	shutdown := false
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
readLoop:
	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		cmd, err := DecodeCommand(line)
		if err != nil {
			s.logger.Printf("[ipc] skipping malformed line: %v", err)
			continue
		}
		resp, sd := s.handle(cmd)
		if respLine, err := EncodeLine(resp); err == nil {
			select {
			case out <- respLine:
			case <-stop:
				// Writer/connection died; abandon this connection
				// rather than trying to read another line.
				break readLoop
			}
		} else {
			s.logger.Printf("[ipc] encode response: %v", err)
		}
		if sd {
			shutdown = true
			break
		}
	}

	stopFn()        // no-op if the writer already tripped it
	<-forwarderDone // forwarder guaranteed to no longer touch out
	close(out)      // safe: reader and forwarder have stopped sending
	<-writerDone    // flush pending writes before any shutdown
	if shutdown {
		s.onShutdown()
	}
}
