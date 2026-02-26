package blog

import (
	"io"
	"sync"
)

// NewSyncWriter returns sync writer that is safe to use with the [Logger].
func NewSyncWriter(w io.WriteCloser) WriteSyncer {
	return &syncWriter{w: w}
}

type syncWriter struct {
	lock *sync.Mutex
	w    io.Writer
}

func (s *syncWriter) Write(p []byte) (n int, err error) {
	s.lock.Lock()
	defer s.lock.Unlock()

	n, err = s.w.Write(p)
	if err != nil {
		return n, err
	}

	return n, nil
}
