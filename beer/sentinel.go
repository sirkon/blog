package beer

import (
	"fmt"
)

// NewSentinel creates sentinel error with given message.
func NewSentinel(msg string) error {
	return &sentinelError{msg: msg}
}

// NewSentinelf creates sentinel error with given format.
func NewSentinelf(format string, a ...any) error {
	return &sentinelError{msg: fmt.Sprintf(format, a...)}
}

type sentinelError struct {
	msg string
}

func (s *sentinelError) Error() string {
	return s.msg
}
