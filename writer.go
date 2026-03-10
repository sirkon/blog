package blog

import (
	"io"
	"sync"

	"github.com/sirkon/blog/internal/core"
)

// NewSyncWriter returns sync writer that is safe to use with the [Logger].
func NewSyncWriter(w io.Writer) core.WriteSyncer {
	return &syncWriter{
		lock: &sync.Mutex{},
		w:    w,
	}
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
