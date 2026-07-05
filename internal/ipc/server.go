package ipc

import (
	"bufio"
	"bytes"
	"errors"
	"io/fs"
	"net"
	"os"

	"voice-inject/internal/logging"
)

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
	done := make(chan struct{})
	writerDone := make(chan struct{})

	// Sole writer to conn: serializes events and responses.
	go func() {
		defer close(writerDone)
		for line := range out {
			if _, err := conn.Write(line); err != nil {
				return
			}
		}
	}()

	// Event forwarder.
	go func() {
		for {
			select {
			case <-done:
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
				case <-done:
					return
				}
			}
		}
	}()

	// Reader loop.
	shutdown := false
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
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
			out <- respLine
		} else {
			s.logger.Printf("[ipc] encode response: %v", err)
		}
		if sd {
			shutdown = true
			break
		}
	}

	close(done)
	close(out)
	<-writerDone // flush pending writes before any shutdown
	if shutdown {
		s.onShutdown()
	}
}
