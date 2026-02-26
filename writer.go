package blog

import (
	"fmt"
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

type ViewWriteSyncer struct {
	processor RecordConsumer
	w         WriteSyncer
}

func NewViewWriteSyncer(processor RecordConsumer, w WriteSyncer) *ViewWriteSyncer {
	return &ViewWriteSyncer{
		processor: processor,
		w:         w,
	}
}

func (v *ViewWriteSyncer) Write(p []byte) (n int, err error) {
	v.processor.Reset()
	if err := RecordSafeView(v.processor, p); err != nil {
		return 0, fmt.Errorf("process data: %w", err)
	}

	n, err = io.WriteString(v.w, v.processor.String())
	if err != nil {
		return 0, fmt.Errorf("write processed data: %w", err)
	}

	return n, nil
}
