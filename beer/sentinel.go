package beer

import (
	"fmt"
)

// NewSentinel creates sentinel error.
func NewSentinel(msg string) error {
	return &sentinelError{msg: msg}
}

func NewSentinelf(format string, a ...any) error {
	return &sentinelError{msg: fmt.Sprintf(format, a...)}
}

type sentinelError struct {
	msg string
}

func (s *sentinelError) Error() string {
	return s.msg
}
